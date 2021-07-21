![LibPQ.jl Logo](docs/src/assets/full-logo.svg "LibPQ.jl logo")

# LibPQ

LibPQ.jl is a Julia wrapper for the PostgreSQL `libpq` [C library](https://www.postgresql.org/docs/current/libpq.html).

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://invenia.github.io/LibPQ.jl/stable/)
[![In Development](https://img.shields.io/badge/docs-dev-blue.svg)](https://invenia.github.io/LibPQ.jl/dev/)
[![Build Status](https://travis-ci.com/invenia/LibPQ.jl.svg?branch=master)](https://travis-ci.com/invenia/LibPQ.jl)
[![CodeCov](https://codecov.io/gh/invenia/LibPQ.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/invenia/LibPQ.jl)

## Features

### Current

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

### Goals

*Note that these are goals and do not represent the current state of this package*

LibPQ.jl aims to wrap `libpq` as documented in the PostgreSQL documentation, including all non-deprecated functionality and handling all documented error conditions.
Where possible, asynchronous functionality will be wrapped in idiomatic Julia control flow.
All Oids returned in query results will have type conversions (to String by default) defined, as long as I can find documentation on their structure.
Some effort will be made to integrate with other packages (e.g., Tables, already implemented) to facilitate conversion from query results to a malleable format.

### Non-Goals

LibPQ.jl will not attempt to conform to a standard database interface, though anyone is welcome to write a PostgreSQL.jl library to wrap this package.

This package will not:

* parse SQL
* emit SQL
* provide an interface for handling transactions or cursors
* provide abstractions over common SQL patterns

### Possible Goals

This package may not:

* test on multiple install configurations
* aim to support any particular versions of libpq or PostgreSQL
* support conversion from some Oid to some type
* provide easy access to every possible connection method
* be as memory-efficient as possible

While I may never get to any of these, I welcome tested, documented contributions!

## Licenses

### `libpq` Source and PostgreSQL Documentation

```
PostgreSQL is Copyright © 1996-2017 by the PostgreSQL Global Development Group.

Postgres95 is Copyright © 1994-5 by the Regents of the University of California.

Permission to use, copy, modify, and distribute this software and its
documentation for any purpose, without fee, and without a written agreement is
hereby granted, provided that the above copyright notice and this paragraph
and the following two paragraphs appear in all copies.

IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING
LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
EVEN IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING,
BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN “AS-IS” BASIS,
AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE,
SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
```

### Everything Else

The license for the remainder of this package appears in [LICENSE](./LICENSE).
