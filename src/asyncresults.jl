"An asynchronous PostgreSQL query"
mutable struct AsyncResult{BinaryFormat}
    "The LibPQ.jl Connection used for the query"
    jl_conn::Connection

    "Keyword arguments to pass to Result on creation"
    result_kwargs::Ref

    "Whether or not the query should be cancelled, if running"
    should_cancel::Bool

    "Task which errors or returns a LibPQ.jl Result which is created once available"
    result_task::Task

    function AsyncResult{BinaryFormat}(
        jl_conn::Connection, result_kwargs::Ref
    ) where BinaryFormat
        return new{BinaryFormat}(jl_conn, result_kwargs, false)
    end
end

function AsyncResult{BinaryFormat}(jl_conn::Connection; kwargs...) where BinaryFormat
    return AsyncResult{BinaryFormat}(jl_conn, Ref(kwargs))
end

function Base.show(io::IO, async_result::AsyncResult)
    status = if isready(async_result)
        if iserror(async_result)
            "errored"
        else
            "finished"
        end
    else
        "in progress"
    end
    return print(io, typeof(async_result), " (", status, ")")
end

"""
    handle_result(async_result::AsyncResult; throw_error=true) -> Result

Executes the query in `async_result` and waits for results.

This implements the loop described in the PostgreSQL documentation for
[Asynchronous Command Processing](https://www.postgresql.org/docs/10/libpq-async.html).

The `throw_error` option only determines whether to throw errors when handling the new
[`Result`](@ref)s; the `Task` may error for other reasons related to processing the
asynchronous loop.

The result returned will be the [`Result`](@ref) of the last query run (the only query if
using parameters).
Any errors produced by the queries will be thrown together in a `CompositeException`.
"""
function handle_result(
    async_result::AsyncResult{BinaryFormat}; throw_error=true
) where BinaryFormat
    errors = []
    result = nothing
    for result_ptr in _consume(async_result.jl_conn)
        try
            result = handle_result(
                Result{BinaryFormat}(
                    result_ptr, async_result.jl_conn; async_result.result_kwargs[]...
                );
                throw_error=throw_error,
            )
        catch err
            push!(errors, err)
        end
    end

    if throw_error && !isempty(errors)
        throw(CompositeException(errors))
    elseif result === nothing
        error(LOGGER, Errors.JLResultError("Async query did not return result"))
    else
        return result
    end
end

function _consume(jl_conn::Connection)
    # libpq does this to "give the data a push" and I don't know what that means but maybe
    # this is important?
    # https://github.com/postgres/postgres/blob/master/src/interfaces/libpq/fe-exec.c#L1266
    # if we used non-blocking connections we would need to check for `1` as well
    # See _flush(jl_conn::Connection) in connections.jl
    if !_flush(jl_conn)
        error(LOGGER, Errors.PQConnectionError(jl_conn))
    end

    async_result = jl_conn.async_result
    result_ptrs = Ptr{libpq_c.PGresult}[]
    watcher = FDWatcher(socket(jl_conn), true, false)  # can wait for reads
    try
        # Wait at least 5 seconds between emitting wait or consume log messages
        last_log = time()

        while true
            curr = time()
            last_log = curr - last_log > 5.0 ? curr : last_log

            if async_result.should_cancel
                debug(LOGGER, "Received cancel signal for connection $(jl_conn.conn)")
                _cancel(jl_conn)
            end

            last_log == curr &&
                debug(LOGGER, "Waiting to read from connection $(jl_conn.conn)")
            wait(watcher)
            last_log == curr &&
                debug(LOGGER, "Consuming input from connection $(jl_conn.conn)")
            success = libpq_c.PQconsumeInput(jl_conn.conn) == 1
            !success && error(LOGGER, Errors.PQConnectionError(jl_conn))

            while libpq_c.PQisBusy(jl_conn.conn) == 0
                debug(LOGGER, "Checking the result from connection $(jl_conn.conn)")
                result_ptr = libpq_c.PQgetResult(jl_conn.conn)
                if result_ptr == C_NULL
                    debug(LOGGER, "Finished reading from connection $(jl_conn.conn)")
                    return result_ptrs
                else
                    result_num = length(result_ptrs) + 1
                    debug(
                        LOGGER, "Saving result $result_num from connection $(jl_conn.conn)"
                    )
                    push!(result_ptrs, result_ptr)
                end
            end
        end
    catch err
        if err isa Base.IOError && err.code == -9  # EBADF
            debug(() -> sprint(showerror, err), LOGGER)
            error(
                LOGGER,
                Errors.JLConnectionError(
                    "PostgreSQL connection socket was unexpectedly closed"
                ),
            )
        else
            rethrow(err)
        end
    finally
        close(watcher)
    end
end

"""
    cancel(async_result::AsyncResult)

If this [`AsyncResult`](@ref) represents a currently-executing query, attempt to cancel it.
"""
function cancel(async_result::AsyncResult)
    # just sets the `should_cancel` flag
    # the actual cancellation will be triggered in the main loop of _consume
    # which will call `_cancel` on the `Connection`
    async_result.should_cancel = true
    return nothing
end

function _cancel(jl_conn::Connection)
    cancel_ptr = libpq_c.PQgetCancel(jl_conn.conn)
    try
        # https://www.postgresql.org/docs/10/libpq-cancel.html#LIBPQ-PQCANCEL
        errbuf_size = 256
        errbuf = zeros(UInt8, errbuf_size)
        success = libpq_c.PQcancel(cancel_ptr, pointer(errbuf), errbuf_size) == 1
        if !success
            warn(
                LOGGER,
                Errors.JLConnectionError("Failed cancelling query: $(String(errbuf))"),
            )
        else
            debug(LOGGER, "Cancelled query for connection $(jl_conn.conn)")
        end
    finally
        libpq_c.PQfreeCancel(cancel_ptr)
    end
end

iserror(async_result::AsyncResult) = Base.istaskfailed(async_result.result_task)
Base.isready(async_result::AsyncResult) = istaskdone(async_result.result_task)
Base.wait(async_result::AsyncResult) = wait(async_result.result_task)
Base.fetch(async_result::AsyncResult) = fetch(async_result.result_task)
Base.close(async_result::AsyncResult) = cancel(async_result)

"""
    async_execute(
        jl_conn::Connection,
        query::AbstractString,
        [parameters::Union{AbstractVector, Tuple},]
        binary_format::Bool=false,
        kwargs...
    ) -> AsyncResult

Run a query on the PostgreSQL database and return an [`AsyncResult`](@ref).

The `AsyncResult` contains a `Task` which processes a query asynchronously.
Calling `fetch` on the `AsyncResult` will return a [`Result`](@ref).

All keyword arguments are the same as [`execute`](@ref) and are passed to the created
`Result`.

Only one `AsyncResult` can be active on a [`Connection`](@ref) at once.
If multiple `AsyncResult`s use the same `Connection`, they will execute serially but
without any guarantee of order.

`async_execute` does not yet support [`Statement`](@ref)s.

`async_execute` optionally takes a `parameters` vector which passes query parameters as
strings to PostgreSQL.

`binary_format`, when set to true, will transfer the data in binary format.
Support for binary transfer is currently limited to a subset of basic data types.

Queries without parameters can contain multiple SQL statements, and the result of the final
statement is returned.
Any errors which occur during executed statements will be bundled together in a
`CompositeException` and thrown.

As is normal for `Task`s, any exceptions will be thrown when calling `wait` or `fetch`.
"""
function async_execute end

function async_execute(conn, query; binary_format=false, kwargs...)
    if binary_format
        async_execute(conn, query, []; binary_format=binary_format, kwargs...)
    else
        _multi_async_execute(conn, query; kwargs...)
    end
end

function _multi_async_execute(jl_conn::Connection, query::AbstractString; kwargs...)
    async_result = _async_execute(jl_conn; kwargs...) do jl_conn
        _async_submit(jl_conn, query)
    end

    return async_result
end

function async_execute(jl_conn::Connection, query::SQLStrings.Sql; kwargs...)
    query_str, parameters = SQLStrings.prepare(query)
    return async_execute(jl_conn, query_str, parameters; kwargs...)
end

function async_execute(
    jl_conn::Connection,
    query::AbstractString,
    parameters::Union{AbstractVector,Tuple};
    binary_format::Bool=false,
    kwargs...,
)
    string_params = string_parameters(parameters)
    pointer_params = parameter_pointers(string_params)

    async_result =
        _async_execute(jl_conn; binary_format=binary_format, kwargs...) do jl_conn
            GC.@preserve string_params _async_submit(
                jl_conn, query, pointer_params; binary_format=binary_format
            )
        end

    return async_result
end

function _async_execute(
    submission_fn::Function,
    jl_conn::Connection;
    binary_format::Bool=false,
    throw_error::Bool=true,
    kwargs...,
)
    async_result = AsyncResult{binary_format}(jl_conn; kwargs...)

    async_result.result_task = @async lock(jl_conn) do
        jl_conn.async_result = async_result

        try
            # error if submission fails
            # does not respect `throw_error` as there's no result to return on this error
            if !submission_fn(jl_conn)
                error(LOGGER, Errors.PQConnectionError(async_result.jl_conn))
            end

            return handle_result(async_result; throw_error=throw_error)::Result
        finally
            jl_conn.async_result = nothing
        end
    end

    return async_result
end

function _async_submit(jl_conn::Connection, query::AbstractString)
    send_status = libpq_c.PQsendQuery(jl_conn.conn::Ptr{libpq_c.PGconn}, query)
    if isnonblocking(jl_conn)
        return _flush(jl_conn)
    else
        return send_status == 1
    end
end

function _async_submit(
    jl_conn::Connection,
    query::AbstractString,
    parameters::Vector{Ptr{UInt8}};
    binary_format::Bool=false,
)
    conn_ptr::Ptr{libpq_c.PGconn} = jl_conn.conn
    num_params = length(parameters)

    send_status = libpq_c.PQsendQueryParams(
        conn_ptr,
        query,
        num_params,
        C_NULL,  # set paramTypes to C_NULL to have the server infer a type
        parameters,
        C_NULL,  # paramLengths is ignored for text format parameters
        zeros(Cint, num_params),  # all parameters in text format
        Cint(binary_format),  # return result in text or binary format
    )
    # send_status must be 1
    # if nonblock, we also want to _flush
    if isnonblocking(jl_conn)
        return send_status == 1 && _flush(jl_conn)
    else
        return send_status == 1
    end
end
