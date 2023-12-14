"A result from a PostgreSQL database query"
mutable struct Result{BinaryFormat}
    "A pointer to a libpq PGresult object (C_NULL if cleared)"
    result::Ptr{libpq_c.PGresult}

    "True if the PG object has been cleaned up"
    closed::Atomic{Bool}

    "PostgreSQL Oids for each column in the result"
    column_oids::Vector{Oid}

    "Julia types for each column in the result"
    column_types::Vector{Type}

    "Whether to expect NULL for each column (whether output data can have `missing`)"
    not_null::Vector{Bool}

    "Conversions from PostgreSQL data to Julia types for each column in the result"
    column_funcs::Vector{Base.Callable}

    "Name of each column in the result"
    column_names::Vector{String}

    # TODO: attach encoding per https://wiki.postgresql.org/wiki/Driver_development#Result_object_and_client_encoding
    function Result{BinaryFormat}(
        result::Ptr{libpq_c.PGresult},
        jl_conn::Connection;
        column_types::Union{AbstractDict,AbstractVector}=ColumnTypeMap(),
        type_map::AbstractDict=PQTypeMap(),
        conversions::AbstractDict=PQConversions(),
        not_null=false,
    ) where BinaryFormat
        jl_result = new{BinaryFormat}(result, Atomic{Bool}(result == C_NULL))

        type_lookup = LayerDict(
            PQTypeMap(type_map), jl_conn.type_map, LIBPQ_TYPE_MAP, _DEFAULT_TYPE_MAP
        )

        func_lookup = LayerDict(
            PQConversions(conversions),
            jl_conn.func_map,
            LIBPQ_CONVERSIONS,
            _DEFAULT_CONVERSIONS,
            _FALLBACK_CONVERSION,
        )

        jl_result.column_oids = col_oids = map(1:num_columns(jl_result)) do col_num
                libpq_c.PQftype(jl_result.result, col_num - 1)
            end

        jl_result.column_names = map(1:num_columns(jl_result)) do col_num
            unsafe_string(libpq_c.PQfname(jl_result.result, col_num - 1))
        end

        column_type_map = ColumnTypeMap()
        for (k, v) in pairs(column_types)
            column_type_map[column_number(jl_result, k)] = v
        end

        jl_result.column_types = col_types = collect(
                Type,
                imap(enumerate(col_oids)) do itr
                    col_num, col_oid = itr
                    get(column_type_map, col_num) do
                        get(type_lookup, col_oid, String)
                    end
                end,
            )

        jl_result.column_funcs = collect(
            Base.Callable,
            imap(col_oids, col_types) do oid, typ
                func_lookup[(oid, typ)]
            end,
        )

        # figure out which columns the user says may contain nulls
        if not_null isa Bool
            jl_result.not_null = fill(not_null, size(col_types))
        elseif not_null isa AbstractArray
            if eltype(not_null) === Bool
                if length(not_null) != length(col_types)
                    throw(
                        ArgumentError(
                            "The length of keyword argument not_null, when an array, must be equal to the number of columns",
                        ),
                    )
                end

                jl_result.not_null = not_null
            else
                # assume array of column names
                jl_result.not_null = fill(false, size(col_types))

                for col_name in not_null
                    col_num = column_number(jl_result, col_name)
                    if col_num > 0
                        jl_result.not_null[col_num] = true
                    end
                end
            end
        else
            throw(
                ArgumentError(
                    "Unsupported type $(typeof(not_null)) for keyword argument not_null"
                ),
            )
        end

        finalizer(close, jl_result)

        return jl_result
    end
end

Result(args...; kwargs...) = Result{TEXT}(args...; kwargs...)

"""
    show(io::IO, jl_result::Result)

Show a PostgreSQL result and whether it has been cleared.
"""
function Base.show(io::IO, jl_result::Result)
    print(io, "PostgreSQL result")

    if !isopen(jl_result)
        print(io, " (cleared)")
    end
end

"""
    status(jl_result::Result) -> libpq_c.ExecStatusType

Return the status of a result's corresponding database query according to libpq.

See also: [`error_message`](@ref)
"""
status(jl_result::Result) = libpq_c.PQresultStatus(jl_result.result)

"""
    error_message(jl_result::Result; verbose=false) -> String

Return the error message associated with the result, or an empty string if there was no
error.
If `verbose`, have libpq generate a more verbose version of the error message if possible.
Includes a trailing newline.
"""
function error_message(jl_result::Result; verbose=false)
    return verbose ? _verbose_error_message(jl_result) : _error_message(jl_result)
end

function _error_message(jl_result::Result)
    return unsafe_string(libpq_c.PQresultErrorMessage(jl_result.result))
end

function _verbose_error_message(jl_result::Result)
    msg_ptr = libpq_c.PQresultVerboseErrorMessage(
        jl_result.result, libpq_c.PQERRORS_VERBOSE, libpq_c.PQSHOW_CONTEXT_ALWAYS
    )

    if msg_ptr == C_NULL
        error(
            LOGGER,
            Errors.JLResultError(
                "libpq could not allocate memory for the result error message"
            ),
        )
    end

    msg = unsafe_string(msg_ptr)
    libpq_c.PQfreemem(msg_ptr)
    return msg
end

"""
    error_field(jl_result::Result, field_code::Char) -> Union{String, Nothing}

Get an individual field from the error report in a [`Result`](@ref).
Returns `nothing` if that field is not provided for this error, or if there is no error or
warning in this `Result`.

See [](https://www.postgresql.org/docs/10/libpq-exec.html#LIBPQ-PQRESULTERRORFIELD)
for all available fields.

## Example

```
julia> LibPQ.error_field(result, LibPQ.libpq_c.PG_DIAG_SEVERITY)
"ERROR"
```
"""
function error_field(jl_result::Result, field_code::Union{Char,Integer})
    ret = libpq_c.PQresultErrorField(jl_result.result, field_code)
    return ret == C_NULL ? nothing : unsafe_string(ret)
end

"""
    close(jl_result::Result)

Clean up the memory used by the `PGresult` object.
The `Result` will no longer be usable.
"""
function Base.close(jl_result::Result)
    if !atomic_cas!(jl_result.closed, false, true)
        ptr, jl_result.result = jl_result.result, C_NULL
        libpq_c.PQclear(ptr)
    end
    return nothing
end

"""
    isopen(jl_result::Result)

Determine whether the given `Result` has been `close`d, i.e. whether the memory
associated with the underlying `PGresult` object has been cleared.
"""
Base.isopen(jl_result::Result) = !jl_result.closed[]

"""
    handle_result(jl_result::Result; throw_error::Bool=true) -> Result

Check status and handle errors for newly-created result objects.

If `throw_error` is `true`, throw an error and clear the result if the query results in a
fatal error or unreadable response.
Otherwise a warning is shown.

Also print an info message about the result.
"""
function handle_result(jl_result::Result; throw_error::Bool=true)
    result_status = status(jl_result)

    if result_status in (libpq_c.PGRES_BAD_RESPONSE, libpq_c.PGRES_FATAL_ERROR)
        err = Errors.PQResultError(jl_result)

        if throw_error
            close(jl_result)
            error(LOGGER, err)
        else
            warn(LOGGER, err)
        end
    else
        if result_status == libpq_c.PGRES_NONFATAL_ERROR
            warn(LOGGER, Errors.PQResultError(jl_result))
        end

        debug(LOGGER, unsafe_string(libpq_c.PQcmdStatus(jl_result.result)))
    end

    return jl_result
end

"""
    execute(
        {jl_conn::Connection, query::AbstractString | stmt::Statement},
        [parameters::Union{AbstractVector, Tuple},]
        throw_error::Bool=true,
        binary_format::Bool=false,
        column_types::AbstractDict=ColumnTypeMap(),
        type_map::AbstractDict=LibPQ.PQTypeMap(),
        conversions::AbstractDict=LibPQ.PQConversions(),
        not_null::Union{Bool, AbstractVector}=false,
    ) -> Result

Run a query on the PostgreSQL database and return a `Result`.
If `throw_error` is `true`, throw an error and clear the result if the query results in a
fatal error or unreadable response.

The query may be passed as `Connection` and `AbstractString` (SQL) arguments, or as a
`Statement`.

`execute` optionally takes a `parameters` vector which passes query parameters as
strings to PostgreSQL.

`column_types` accepts type overrides for columns in the result which take priority over
those in `type_map`.

`not_null` indicates whether parsed columns should be able to contain null values, parsed as
`missing`. The argument can be a single `Bool` for all columns, a list of `Bool`, or a list
of column names.

For information on the `column_types`, `type_map`, and `conversions` arguments, see
[Type Conversions](@ref typeconv).

`binary_format`, when set to true, will transfer the data in binary format.
Support for binary transfer is currently limited to a subset of basic data types.
"""
function execute end

function execute(conn, query; binary_format=false, kwargs...)
    if binary_format
        execute(conn, query, []; binary_format=binary_format, kwargs...)
    else
        _multi_execute(conn, query; kwargs...)
    end
end

function _multi_execute(
    jl_conn::Connection, query::AbstractString; throw_error::Bool=true, kwargs...
)
    result = lock(jl_conn) do
        _execute(jl_conn.conn, query)
    end

    return handle_result(Result(result, jl_conn; kwargs...); throw_error=throw_error)
end

function execute(jl_conn::Connection, query::SQLStrings.Sql; kwargs...)
    query_str, parameters = SQLStrings.prepare(query)
    return execute(jl_conn, query_str, parameters; kwargs...)
end

function execute(
    jl_conn::Connection,
    query::AbstractString,
    parameters::Union{AbstractVector,Tuple};
    throw_error::Bool=true,
    binary_format::Bool=false,
    kwargs...,
)
    string_params = string_parameters(parameters)
    pointer_params = parameter_pointers(string_params)

    result = lock(jl_conn) do
        GC.@preserve string_params _execute(
            jl_conn.conn, query, pointer_params; binary_format=binary_format
        )
    end

    return handle_result(
        Result{binary_format}(result, jl_conn; kwargs...); throw_error=throw_error
    )
end

function _execute(conn_ptr::Ptr{libpq_c.PGconn}, query::AbstractString)
    return libpq_c.PQexec(conn_ptr, query)
end

function _execute(
    conn_ptr::Ptr{libpq_c.PGconn},
    query::AbstractString,
    parameters::Vector{Ptr{UInt8}};
    binary_format::Bool=false,
)
    num_params = length(parameters)

    return libpq_c.PQexecParams(
        conn_ptr,
        query,
        num_params,
        C_NULL,  # set paramTypes to C_NULL to have the server infer a type
        parameters,
        C_NULL,  # paramLengths is ignored for text format parameters
        zeros(Cint, num_params),  # all parameters in text format
        Cint(binary_format),  # return result in text format
    )
end

"""
    string_parameters(parameters::AbstractVector) -> Vector{Union{String, Missing}}

Convert parameters to strings which can be passed to libpq, propagating `missing`.
"""
function string_parameters end

string_parameters(parameters::AbstractVector{<:Parameter}) = parameters

# Tuples of parameters
string_parameters(parameters::Tuple) = string_parameters(collect(parameters))

# vector which can't contain missing
string_parameters(parameters::AbstractVector) = map(string_parameter, parameters)

# vector which might contain missings
function string_parameters(parameters::AbstractVector{>:Missing})
    return collect(
        Union{String,Missing},
        imap(parameters) do parameter
            ismissing(parameter) ? missing : string_parameter(parameter)
        end,
    )
end

string_parameter(parameter) = string(parameter)

function string_parameter(parameter::AbstractVector)
    io = IOBuffer()
    print(io, "{")
    join(io, (_array_element(el) for el in parameter), ",")
    print(io, "}")
    return String(take!(io))
end

function _array_element(el::AbstractString)
    el = replace(el, "\\" => "\\\\")
    el = replace(el, "\"" => "\\\"")
    return "\"$el\""
end
_array_element(el::Missing) = "NULL"
_array_element(el) = string_parameter(el)

function string_parameter(interval::AbstractInterval)
    io = IOBuffer()
    L, R = bounds_types(interval)
    print(io, L === Closed ? '[' : '(')
    print(io, L === Unbounded ? "" : string_parameter(first(interval)), ",")
    print(io, R === Unbounded ? "" : " " * string_parameter(last(interval)))
    print(io, R === Closed ? ']' : ')')

    return String(take!(io))
end

function string_parameter(parameter::InfExtendedTime{T}) where T<:Dates.TimeType
    if isinf(parameter)
        return isposinf(parameter) ? "infinity" : "-infinity"
    else
        return string_parameter(parameter.finitevalue)
    end
end

"""
    parameter_pointers(parameters::AbstractVector{<:Parameter}) -> Vector{Ptr{UInt8}}

Given a vector of parameters, returns a vector of pointers to either the string bytes in the
original or `C_NULL` if the element is `missing`.
"""
function parameter_pointers(parameters::AbstractVector{<:Parameter})
    pointers = Vector{Ptr{UInt8}}(undef, length(parameters))

    map!(pointers, parameters) do parameter
        ismissing(parameter) ? C_NULL : pointer(parameter)
    end

    return pointers
end

"""
    num_params(jl_result::Result) -> Int

Return the number of parameters in a prepared statement.
If this result did not come from the description of a prepared statement, return 0.
"""
function num_params(jl_result::Result)::Int
    # todo: check cleared?
    return libpq_c.PQnparams(jl_result.result)
end

"""
    num_rows(jl_result::Result) -> Int

Return the number of rows in the query result.
This will be 0 if the query would never return data.
"""
function num_rows(jl_result::Result)::Int
    # todo: check cleared?
    return libpq_c.PQntuples(jl_result.result)
end

"""
    num_affected_rows(jl_result::Result) -> Int

Return the number of rows affected by the command returning the result.
This is useful for counting the rows affected by operations such as INSERT,
UPDATE and DELETE that do not return rows but affect them.
This will be 0 if the query does not affect any row.
"""
function num_affected_rows(jl_result::Result)::Int
    # todo: check cleared?
    str = unsafe_string(libpq_c.PQcmdTuples(jl_result.result))
    if isempty(str)
        throw(ArgumentError("Result generated by an incompatible command"))
    else
        return parse(Int, str)
    end
end

"""
    num_columns(jl_result::Result) -> Int

Return the number of columns in the query result.
This will be 0 if the query would never return data.
"""
function num_columns(jl_result::Result)::Int
    # todo: check cleared?
    return libpq_c.PQnfields(jl_result.result)
end

"""
    column_name(jl_result::Result, column_number::Integer) -> String

Return the name of the column at index `column_number` (1-based).
"""
function column_name(jl_result::Result, column_number::Integer)
    return jl_result.column_names[column_number]
end

"""
    column_names(jl_result::Result) -> Vector{String}

Return the names of all the columns in the query result.
"""
column_names(jl_result::Result) = copy(jl_result.column_names)

"""
    column_number(jl_result::Result, column_name::Union{AbstractString, Symbol}) -> Int

Return the index (1-based) of the column named `column_name`.
"""
function column_number(jl_result::Result, column_name::Union{AbstractString,Symbol})::Int
    return something(findfirst(isequal(String(column_name)), jl_result.column_names), 0)
end

"""
    column_number(jl_result::Result, column_idx::Integer) -> Int

Return the index of the column if it is valid, or error.
"""
function column_number(jl_result::Result, column_idx::Integer)::Int
    @boundscheck if !checkindex(Bool, Base.OneTo(num_columns(jl_result)), column_idx)
        throw(BoundsError(column_names(jl_result), column_idx))
    end

    return column_idx
end

"""
    column_oids(jl_result::Result) -> Vector{LibPQ.Oid}

Return the PostgreSQL oids for each column in the result.
"""
column_oids(jl_result::Result) = jl_result.column_oids

"""
    column_types(jl_result::Result) -> Vector{Type}

Return the corresponding Julia types for each column in the result.
"""
column_types(jl_result::Result) = jl_result.column_types

"""
    getindex(jl_result::Result, row::Integer, col::Integer) -> Union{_, Missing}

Return the parsed value of the result at the row and column specified (1-indexed).
The returned value will be `missing` if `NULL`, or will be of the type specified in
[`column_types`](@ref).
"""
function Base.getindex(jl_result::Result, row::Integer, col::Integer)
    if isnull(jl_result, row, column_number(jl_result, col))
        return missing
    else
        oid = column_oids(jl_result)[col]
        T = column_types(jl_result)[col]
        return jl_result.column_funcs[col](PQValue{oid}(jl_result, row, col))::T
    end
end
