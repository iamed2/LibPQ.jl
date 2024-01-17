struct DBConnection <: DBInterface.Connection
    conn::Connection
end

DBInterface.connect(::Type{Connection}, args...; kws...) = DBConnection(Connection(args...; kws...))
DBInterface.prepare(conn::DBConnection, args...; kws...) = prepare(conn.conn, args...; kws...)
DBInterface.execute(conn::DBConnection, args...; kws...) = execute(conn.conn, args...; kws...)
DBInterface.execute(conn::DBConnection, str::AbstractString; kws...) = execute(conn.conn, str; kws...)
DBInterface.execute(conn::DBConnection, str::AbstractString, params; kws...) = execute(conn.conn, str, params; kws...)
DBInterface.execute(stmt::Statement, args...; kws...) = execute(stmt, args...; kws...)
DBInterface.close!(conn::DBConnection) = close(conn)
