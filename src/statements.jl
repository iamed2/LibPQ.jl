"A PostgreSQL prepared statement"
struct Statement
    """
    A `Connection` for which this statement is valid.
    It may become invalid if the connection is reset.
    """
    jl_conn::Connection

    "An autogenerated name for the prepared statement (using [`unique_id`](@ref)"
    name::String

    "The query string of the prepared statement"
    query::String

    "A `Result` containing a description of the prepared statement"
    description::Result

    "The number of parameters accepted by this statement according to `description`"
    num_params::Int
end

Base.broadcastable(stmt::Statement) = Ref(stmt)

"""
    prepare(jl_conn::Connection, query::AbstractString) -> Statement

Create a prepared statement on the PostgreSQL server using libpq.
The statement is given an generated unique name using [`unique_id`](@ref).

!!! note

    Currently the statement is not explicitly deallocated, but it is deallocated at the end
    of session per the [PostgreSQL documentation on DEALLOCATE](https://www.postgresql.org/docs/10/sql-deallocate.html).
"""
function prepare(jl_conn::Connection, query::AbstractString)
    uid = unique_id(jl_conn, "stmt")

    result = lock(jl_conn) do
        libpq_c.PQprepare(
            jl_conn.conn,
            uid,
            query,
            0,  # infer all parameters from the query string
            C_NULL,
        )
    end

    close(handle_result(Result(result, jl_conn); throw_error=true))

    result = lock(jl_conn) do
        libpq_c.PQdescribePrepared(jl_conn.conn, uid)
    end

    description = handle_result(Result(result, jl_conn); throw_error=true)

    Statement(jl_conn, uid, query, description, num_params(description))
end

"""
    show(io::IO, jl_result::Statement)

Show a PostgreSQL prepared statement and its query.
"""
function Base.show(io::IO, stmt::Statement)
    print(
        io,
        "PostgreSQL prepared statement named ",
        stmt.name,
        " with query ",
        stmt.query,
    )
end

"""
    num_params(stmt::Statement) -> Int

Return the number of parameters in the prepared statement.
"""
num_params(stmt::Statement) = num_params(stmt.description)

"""
    num_columns(stmt::Statement) -> Int

Return the number of columns that would be returned by executing the prepared statement.
"""
num_columns(stmt::Statement) = num_columns(stmt.description)

"""
    column_name(stmt::Statement, column_number::Integer) -> String

Return the name of the column at index `column_number` (1-based) that would be returned by
executing the prepared statement.
"""
function column_name(stmt::Statement, column_number::Integer)
    column_name(stmt.description, column_number)
end

"""
    column_names(stmt::Statement) -> Vector{String}

Return the names of all the columns in the query result that would be returned by executing
the prepared statement.
"""
column_names(stmt::Statement) = column_names(stmt.description)

"""
    column_number(stmt::Statement, column_name::AbstractString) -> Int

Return the index (1-based) of the column named `column_name` that would be returned by
executing the prepared statement.
"""
function column_number(stmt::Statement, column_name::AbstractString)
    column_number(stmt.description, column_name)
end

function execute_params(
    stmt::Statement,
    parameters::Union{AbstractVector, Tuple};
    throw_error::Bool=true,
    binary_format::Bool=TEXT,
    kwargs...
)
    num_params = length(parameters)
    string_params = string_parameters(parameters)
    pointer_params = parameter_pointers(string_params)

    result = lock(stmt.jl_conn) do
        _execute_prepared(stmt.jl_conn.conn, stmt.name, pointer_params; binary_format=binary_format)
    end

    return handle_result(Result{binary_format}(result, stmt.jl_conn; kwargs...); throw_error=throw_error)
end

function execute(
    stmt::Statement;
    throw_error::Bool=true,
    binary_format::Bool=TEXT,
    kwargs...
)
    result = lock(stmt.jl_conn) do
        _execute_prepared(stmt.jl_conn.conn, stmt.name; binary_format=binary_format)
    end

    return handle_result(Result{binary_format}(result, stmt.jl_conn; kwargs...); throw_error=throw_error)
end

function _execute_prepared(
    conn_ptr::Ptr{libpq_c.PGconn},
    stmt_name::AbstractString,
    parameters::Vector{Ptr{UInt8}}=Ptr{UInt8}[];
    binary_format::Bool=false,
)
    num_params = length(parameters)

    return libpq_c.PQexecPrepared(
        conn_ptr,
        stmt_name,
        num_params,
        num_params == 0 ? C_NULL : parameters,
        C_NULL,  # paramLengths is ignored for text format parameters
        num_params == 0 ? C_NULL : zeros(Cint, num_params),  # all parameters in text format
        Cint(binary_format),  # return result in text format
    )
end
