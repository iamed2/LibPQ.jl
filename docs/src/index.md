![LibPQ.jl Logo](assets/full-logo.svg)

# LibPQ

A Julia wrapper for the PostgreSQL `libpq` [C library](https://www.postgresql.org/docs/current/libpq.html).

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://iamed2.github.io/LibPQ.jl/stable/)
[![In Development](https://img.shields.io/badge/docs-dev-blue.svg)](https://iamed2.github.io/LibPQ.jl/dev/)
[![CI](https://github.com/iamed2/LibPQ.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/iamed2/LibPQ.jl/actions/workflows/CI.yml)
[![CodeCov](https://codecov.io/gh/iamed2/LibPQ.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/iamed2/LibPQ.jl)

## Overview

LibPQ.jl is a Julia wrapper for the PostgreSQL libpq C library. It provides the ability to:

* Build
  * Installs `libpq` via `BinaryBuilder.jl` for MacOS, GNU Linux, and Windows
* Connections
  * Connect via DSN
  * Connect via PostgreSQL connection string
  * UTF-8 client encoding
* Queries
  * Create and execute queries with or without parameters
  * Execute queries asynchronously
  * Stream results using [Tables](https://github.com/JuliaData/Tables.jl)
  * Configurably convert a variety of PostgreSQL types to corresponding Julia types (see the **Type Conversions** section of the docs)
* Prepared Statements
  * Create and execute prepared statements with or without parameters
  * Stream table of parameters to execute the same statement multiple times with different data

You can install `LibPQ.jl` via the Julia REPL by typing:
```julia
] add LibPQ
```

## Examples
The below examples assume you already have a database created. If you don't have one setup yet, you will need to do so for the following snippets to work.

### Selection

```julia
using LibPQ, Tables

conn = LibPQ.Connection("dbname=postgres")
result = execute(conn, "SELECT typname FROM pg_type WHERE oid = 16")
data = columntable(result)

# the same but with parameters
result = execute(conn, "SELECT typname FROM pg_type WHERE oid = \$1", ["16"])
data = columntable(result)

# the same but asynchronously
async_result = async_execute(conn, "SELECT typname FROM pg_type WHERE oid = \$1", ["16"])
# do other things
result = fetch(async_result)
data = columntable(result)

close(conn)
```

### Insertion

```julia
using LibPQ

conn = LibPQ.Connection("dbname=postgres user=$DATABASE_USER")

result = execute(conn, """
    CREATE TEMPORARY TABLE libpqjl_test (
        no_nulls    varchar(10) PRIMARY KEY,
        yes_nulls   varchar(10)
    );
""")

LibPQ.load!(
    (no_nulls = ["foo", "baz"], yes_nulls = ["bar", missing]),
    conn,
    "INSERT INTO libpqjl_test (no_nulls, yes_nulls) VALUES (\$1, \$2);",
)

close(conn)
```

#### A Note on Bulk Insertion

When inserting a large number of rows, wrapping your insert queries in a transaction will greatly increase performance.
See the PostgreSQL documentation [14.4.1. Disable Autocommit](https://www.postgresql.org/docs/10/populate.html#DISABLE-AUTOCOMMIT) for more information.

Concretely, this means surrounding your query like this:

```julia
execute(conn, "BEGIN;")

LibPQ.load!(
    (no_nulls = ["foo", "baz"], yes_nulls = ["bar", missing]),
    conn,
    "INSERT INTO libpqjl_test (no_nulls, yes_nulls) VALUES (\$1, \$2);",
)

execute(conn, "COMMIT;")
```

### `COPY`

An alternative to repeated `INSERT` queries is the PostgreSQL `COPY` query.
`LibPQ.CopyIn` makes it easier to stream data to the server using a `COPY FROM STDIN` query.

```julia
using LibPQ, DataFrames

conn = LibPQ.Connection("dbname=postgres user=$DATABASE_USER")

row_strings = imap(eachrow(df)) do row
    if ismissing(row[:yes_nulls])
        "$(row[:no_nulls]),\n"
    else
        "$(row[:no_nulls]),$(row[:yes_nulls])\n"
    end
end

copyin = LibPQ.CopyIn("COPY libpqjl_test FROM STDIN (FORMAT CSV);", row_strings)

execute(conn, copyin)

close(conn)
```

### `DBInterface Integration`

LibPQ types can also be used with the generic [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl)
package to connect to and query Postgres databases.

```julia
using LibPQ, DBInterface

conn = DBInterface.connect(LibPQ.Connection, "dbname=postgres")
res = DBInterface.execute(con, "SELECT * FROM table")
DBInterface.close!(conn)
```