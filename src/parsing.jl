"A wrapper for one value in a PostgreSQL result."
struct PQValue{OID,BinaryFormat}
    "PostgreSQL result"
    jl_result::Result

    "Row index of the result (0-indexed)"
    row::Cint

    "Column index of the result (0-indexed)"
    col::Cint

    function PQValue{OID}(
        jl_result::Result{BinaryFormat}, row::Integer, col::Integer
    ) where {OID,BinaryFormat}
        return new{OID,BinaryFormat}(jl_result, row - 1, col - 1)
    end
end

const PQTextValue{OID} = PQValue{OID,TEXT}
const PQBinaryValue{OID} = PQValue{OID,BINARY}

"""
    PQValue(jl_result::Result, row::Integer, col::Integer) -> PQValue
    PQValue{OID}(jl_result::Result, row::Integer, col::Integer) -> PQValue{OID}

Construct a `PQValue` wrapping one value in a PostgreSQL result.
Row and column positions are provided 1-indexed.
If the `OID` type parameter is not provided, the Oid of the field will be retrieved from
the result.
"""
function PQValue(jl_result::Result, row::Integer, col::Integer)
    oid = libpq_c.PQftype(jl_result.result, col - 1)

    return PQValue{oid}(jl_result, row, col)
end

"""
    isnull(jl_result::Result, row::Integer, col::Integer) -> Bool

Return whether the result value at the specified row and column (1-indexed) is `NULL`.
"""
function isnull(jl_result::Result, row::Integer, col::Integer)
    return libpq_c.PQgetisnull(jl_result.result, row - 1, col - 1) == 1
end

"""
    num_bytes(pqv::PQValue) -> Cint

The length in bytes of the `PQValue`'s corresponding data.
When a query uses `LibPQ.TEXT` format, this is equivalent to C's `strlen`.

See also: [`data_pointer`](@ref)
"""
num_bytes(pqv::PQValue) = libpq_c.PQgetlength(pqv.jl_result.result, pqv.row, pqv.col)

"""
    data_pointer(pqv::PQValue) -> Ptr{UInt8}

Get a raw pointer to the data for one value in a PostgreSQL result.
This data will be freed by libpq when the result is cleared, and should only be used
temporarily.
"""
data_pointer(pqv::PQValue) = libpq_c.PQgetvalue(pqv.jl_result.result, pqv.row, pqv.col)

"""
    unsafe_string(pqv::PQValue) -> String

Construct a `String` from a `PQValue` by copying the data.
"""
function Base.unsafe_string(pqv::PQValue)
    return unsafe_string(data_pointer(pqv), num_bytes(pqv))
end

"""
    string_view(pqv::PQValue) -> String

Wrap a `PQValue`'s underlying data in a `String`.
This function uses [`data_pointer`](@ref) and [`num_bytes`](@ref) and does not copy.

!!! note

    The underlying data will be freed by libpq when the result is cleared, and should only
    be used temporarily.

See also: [`bytes_view`](@ref)
"""
function string_view(pqv::PQValue)
    return String(unsafe_wrap(Vector{UInt8}, data_pointer(pqv), num_bytes(pqv)))
end

"""
    bytes_view(pqv::PQValue) -> Vector{UInt8}

Wrap a `PQValue`'s underlying data in a vector of bytes.
This function uses [`data_pointer`](@ref) and [`num_bytes`](@ref) and does not copy.

This function differs from [`string_view`](@ref) as it keeps the `\0` byte at the end.
`PQValue` parsing functions should use `bytes_view` when the data returned by PostgreSQL
is not in UTF-8.

!!! note

    The underlying data will be freed by libpq when the result is cleared, and should only
    be used temporarily.
"""
bytes_view(pqv::PQValue) = unsafe_wrap(Vector{UInt8}, data_pointer(pqv), num_bytes(pqv) + 1)

Base.String(pqv::PQValue) = unsafe_string(pqv)
Base.parse(::Type{String}, pqv::PQValue) = unsafe_string(pqv)
Base.convert(::Type{String}, pqv::PQValue) = String(pqv)
Base.length(pqv::PQValue) = length(string_view(pqv))
Base.lastindex(pqv::PQValue) = lastindex(string_view(pqv))

# Fallback, because Base requires string iteration state to be indices into the string.
# In an ideal world, PQValue would be an AbstractString and this particular method would
# not be necessary.
"""
    parse(::Type{T}, pqv::PQValue) -> T

Parse a value of type `T` from a `PQValue`.
By default, this uses any existing `parse` method for parsing a value of type `T` from a
`String`.

You can implement default PostgreSQL-specific parsing for a given type by overriding
`pqparse`.
"""
Base.parse(::Type{T}, pqv::PQValue) where T = pqparse(T, string_view(pqv))

"""
    LibPQ.pqparse(::Type{T}, str::AbstractString) -> T

Parse a value of type `T` from any `AbstractString`.
This is used to parse PostgreSQL's output format.
"""
function pqparse end

# Fallback method
pqparse(::Type{T}, str::AbstractString) where T = parse(T, str)

function pqparse(::Type{T}, ptr::Ptr{UInt8}) where T<:Number
    return ntoh(unsafe_load(Ptr{T}(ptr)))
end

# allow parsing as a Symbol anything which works as a String
pqparse(::Type{Symbol}, str::AbstractString) = Symbol(str)

function generate_binary_parser(symbol)
    @eval function Base.parse(
        ::Type{T}, pqv::PQBinaryValue{$(oid(symbol))}
    ) where T<:Number
        return convert(T, pqparse($(_DEFAULT_TYPE_MAP[symbol]), data_pointer(pqv)))
    end
end

## integers
_DEFAULT_TYPE_MAP[:int2] = Int16
_DEFAULT_TYPE_MAP[:int4] = Int32
_DEFAULT_TYPE_MAP[:int8] = Int64

foreach(generate_binary_parser, (:int2, :int4, :int8))

## floating point
_DEFAULT_TYPE_MAP[:float4] = Float32
_DEFAULT_TYPE_MAP[:float8] = Float64

foreach(generate_binary_parser, (:float4, :float8))

## oid
_DEFAULT_TYPE_MAP[:oid] = Oid

generate_binary_parser(:oid)

## numeric
_DEFAULT_TYPE_MAP[:numeric] = Decimal

# no default for monetary; needs lconv and lc_monetary from result/connection

## character
# bpchar is char(n)
function Base.parse(::Type{String}, pqv::PQValue{PQ_SYSTEM_TYPES[:bpchar]})
    return String(rstrip(string_view(pqv), ' '))
end
# char is "char"
_DEFAULT_TYPE_MAP[:char] = PQChar
pqparse(::Type{PQChar}, str::AbstractString) = PQChar(first(str))
pqparse(::Type{Char}, str::AbstractString) = Char(pqparse(PQChar, str))
# varchar, text, and name are all String

## binary data

_DEFAULT_TYPE_MAP[:bytea] = Vector{UInt8}

# Needs it's own `parse` method as it uses bytes_view instead of string_view
function Base.parse(::Type{Vector{UInt8}}, pqv::PQTextValue{PQ_SYSTEM_TYPES[:bytea]})
    return pqparse(Vector{UInt8}, bytes_view(pqv))
end

function pqparse(::Type{Vector{UInt8}}, bytes::Array{UInt8,1})
    byte_length = Ref{Csize_t}(0)

    unescaped_ptr = libpq_c.PQunescapeBytea(bytes, byte_length)

    if unescaped_ptr == C_NULL
        error("Could not unescape byte sequence $(String(bytes))")
    end

    unescaped_vec = copy(unsafe_wrap(Vector{UInt8}, unescaped_ptr, byte_length[]))

    libpq_c.PQfreemem(unescaped_ptr)

    return unescaped_vec
end

## uuid
_DEFAULT_TYPE_MAP[:uuid] = UUID
function Base.parse(::Type{UUID}, pqv::PQBinaryValue{PQ_SYSTEM_TYPES[:uuid]})
    return UUID(pqparse(UInt128, data_pointer(pqv)))
end

## bool
# TODO: check whether we ever need this or if PostgreSQL always gives t or f
_DEFAULT_TYPE_MAP[:bool] = Bool
const BOOL_TRUE = r"^\s*(t|true|y|yes|on|1)\s*$"i
const BOOL_FALSE = r"^\s*(f|false|n|no|off|0)\s*$"i
function pqparse(::Type{Bool}, str::AbstractString)
    if occursin(BOOL_TRUE, str)
        return true
    elseif occursin(BOOL_FALSE, str)
        return false
    else
        error("\"$str\" is not a valid boolean")
    end
end

function Base.parse(::Type{Bool}, pqv::PQBinaryValue{oid(:bool)})
    return unsafe_load(Ptr{_DEFAULT_TYPE_MAP[:bool]}(data_pointer(pqv)))
end

## dates and times
# ISO, YMD

# Cut off digits after the third after the decimal point,
# since DateTime in Julia currently handles only milliseconds
# see https://github.com/iamed2/LibPQ.jl/issues/33
_trunc_seconds(str) = replace(str, r"(\.[\d]{3})\d+" => s"\g<1>")

# Utility function for handling "infinity"  strings for datetime types to reduce duplication
function _tryparse_datetime_inf(
    typ::Type{T}, str, f=typ
)::Union{T, Nothing} where T <: Dates.AbstractDateTime
    if str == "infinity"
        depwarn_timetype_inf()
        return f(typemax(DateTime))
    elseif str == "-infinity"
        depwarn_timetype_inf()
        return f(typemin(DateTime))
    end

    return nothing
end

_DEFAULT_TYPE_MAP[:timestamp] = DateTime
const TIMESTAMP_FORMAT = dateformat"y-m-d HH:MM:SS.s"  # .s is optional here
function pqparse(::Type{DateTime}, str::AbstractString)
    parsed = _tryparse_datetime_inf(DateTime, str)
    isnothing(parsed) || return parsed

    parsed = tryparse(DateTime, str, TIMESTAMP_FORMAT)
    isnothing(parsed) || return parsed

    return parse(DateTime, _trunc_seconds(str), TIMESTAMP_FORMAT)
end

# ISO, YMD
_DEFAULT_TYPE_MAP[:timestamptz] = ZonedDateTime
const TIMESTAMPTZ_FORMATS = (
    dateformat"y-m-d HH:MM:SSz",
    dateformat"y-m-d HH:MM:SS.sz",
    dateformat"y-m-d HH:MM:SS.ssz",
    dateformat"y-m-d HH:MM:SS.sssz",
)

function pqparse(::Type{ZonedDateTime}, str::AbstractString)
    parsed = _tryparse_datetime_inf(ZonedDateTime, str, Base.Fix2(ZonedDateTime, tz"UTC"))
    isnothing(parsed) || return parsed

    for fmt in TIMESTAMPTZ_FORMATS[1:(end - 1)]
        parsed = tryparse(ZonedDateTime, str, fmt)
        isnothing(parsed) || return parsed
    end

    return parse(ZonedDateTime, _trunc_seconds(str), TIMESTAMPTZ_FORMATS[end])
end

function pqparse(::Type{UTCDateTime}, str::AbstractString)
    parsed = _tryparse_datetime_inf(UTCDateTime, str)
    isnothing(parsed) || return parsed

    # Postgres should always give us strings ending with +00 if our timezone is set to UTC
    # which is the default
    str = replace(str, "+00" => "")

    parsed = tryparse(UTCDateTime, str, TIMESTAMP_FORMAT)
    isnothing(parsed) || return parsed

    return parse(UTCDateTime, _trunc_seconds(str), TIMESTAMP_FORMAT)
end

_DEFAULT_TYPE_MAP[:date] = Date
function pqparse(::Type{Date}, str::AbstractString)
    if str == "infinity"
        depwarn_timetype_inf()
        return typemax(Date)
    elseif str == "-infinity"
        depwarn_timetype_inf()
        return typemin(Date)
    end

    return parse(Date, str)
end

_DEFAULT_TYPE_MAP[:time] = Time
function pqparse(::Type{Time}, str::AbstractString)
    @static if v"1.6.6" <= VERSION < v"1.7.0" || VERSION > v"1.7.2"
        result = tryparse(Time, str)
        # If there's an error we want to see it here
        return isnothing(result) ? parse(Time, _trunc_seconds(str)) : result
    else
        try
            return parse(Time, str)
        catch err
            if !(err isa InexactError)
                rethrow(err)
            end
        end
        return parse(Time, _trunc_seconds(str))
    end
end

# InfExtendedTime support for Dates.TimeType
function pqparse(::Type{InfExtendedTime{T}}, str::AbstractString) where T<:Dates.TimeType
    if str == "infinity"
        return InfExtendedTime{T}(∞)
    elseif str == "-infinity"
        return InfExtendedTime{T}(-∞)
    end

    return InfExtendedTime{T}(pqparse(T, str))
end

# UNIX timestamps
function Base.parse(::Type{DateTime}, pqv::PQValue{PQ_SYSTEM_TYPES[:int8]})
    return unix2datetime(parse(Int64, pqv))
end

function Base.parse(::Type{ZonedDateTime}, pqv::PQValue{PQ_SYSTEM_TYPES[:int8]})
    return TimeZones.unix2zdt(parse(Int64, pqv))
end

function Base.parse(::Type{UTCDateTime}, pqv::PQValue{PQ_SYSTEM_TYPES[:int8]})
    return UTCDateTime(parse(DateTime, pqv))
end

# All postgresql timestamptz are stored in UTC time with the epoch of 2000-01-01.
const POSTGRES_EPOCH_DATE = Date("2000-01-01")
const POSTGRES_EPOCH_DATETIME = DateTime("2000-01-01")

# Note: Because postgresql stores the values as a Microsecond in Int64, the max (infinite)
# value of date time in postgresql when querying binary is 294277-01-09T04:00:54.775
# and the minimum is -290278-12-22T19:59:05.225.
function pqparse(::Type{ZonedDateTime}, ptr::Ptr{UInt8})
    value = ntoh(unsafe_load(Ptr{Int64}(ptr)))
    if value == typemax(Int64)
        depwarn_timetype_inf()
        return ZonedDateTime(typemax(DateTime), tz"UTC")
    elseif value == typemin(Int64)
        depwarn_timetype_inf()
        return ZonedDateTime(typemin(DateTime), tz"UTC")
    end
    dt = POSTGRES_EPOCH_DATETIME + Microsecond(value)
    return ZonedDateTime(dt, tz"UTC"; from_utc=true)
end

function pqparse(::Type{UTCDateTime}, ptr::Ptr{UInt8})
    return UTCDateTime(pqparse(DateTime, ptr))
end

function pqparse(::Type{DateTime}, ptr::Ptr{UInt8})
    value = ntoh(unsafe_load(Ptr{Int64}(ptr)))
    if value == typemax(Int64)
        depwarn_timetype_inf()
        return typemax(DateTime)
    elseif value == typemin(Int64)
        depwarn_timetype_inf()
        return typemin(DateTime)
    end
    return POSTGRES_EPOCH_DATETIME + Microsecond(value)
end

function pqparse(::Type{Date}, ptr::Ptr{UInt8})
    value = ntoh(unsafe_load(Ptr{Int32}(ptr)))
    if value == typemax(Int32)
        depwarn_timetype_inf()
        return typemax(Date)
    elseif value == typemin(Int32)
        depwarn_timetype_inf()
        return typemin(Date)
    end
    return POSTGRES_EPOCH_DATE + Day(value)
end

function pqparse(
    ::Type{InfExtendedTime{T}}, ptr::Ptr{UInt8}
) where T<:Dates.AbstractDateTime
    microseconds = ntoh(unsafe_load(Ptr{Int64}(ptr)))
    if microseconds == typemax(Int64)
        return InfExtendedTime{T}(∞)
    elseif microseconds == typemin(Int64)
        return InfExtendedTime{T}(-∞)
    end

    return InfExtendedTime{T}(pqparse(T, ptr))
end

function pqparse(::Type{InfExtendedTime{T}}, ptr::Ptr{UInt8}) where T<:Date
    microseconds = ntoh(unsafe_load(Ptr{Int32}(ptr)))
    if microseconds == typemax(Int32)
        return InfExtendedTime{T}(∞)
    elseif microseconds == typemin(Int32)
        return InfExtendedTime{T}(-∞)
    end

    return InfExtendedTime{T}(pqparse(T, ptr))
end

function generate_binary_date_parser(symbol)
    @eval function Base.parse(
        ::Type{T}, pqv::PQBinaryValue{$(oid(symbol))}
    ) where T<:TimeType
        return pqparse(T, data_pointer(pqv))
    end
end

foreach(generate_binary_date_parser, (:timestamptz, :timestamp, :date))

## intervals
# iso_8601
_DEFAULT_TYPE_MAP[:interval] = Dates.CompoundPeriod
const INTERVAL_REGEX = Ref{Regex}()  # set at __init__

function _interval_regex()
    function _field_match(period_type, number_match="-?\\d+")
        name = nameof(period_type)
        letter = first(String(name))
        return "(?:(?<$name>$number_match)$letter)?"
    end

    io = IOBuffer()
    print(io, "^P")
    for long_type in (Year, Month, Day)
        print(io, _field_match(long_type))
    end
    print(io, "(?:T")
    for long_type in (Hour, Minute)
        print(io, _field_match(long_type))
    end
    print(
        io,
        _field_match(Second, "(?<whole_seconds>-?\\d+)(?:\\.(?<frac_seconds>\\d{1,9}))?"),
    )
    print(io, ")?\$")

    return Regex(String(take!(io)))
end

function _split_period(period::T, ::Type{P}) where {T<:Period,P<:Period}
    q, r = divrem(period, convert(T, P(1)))
    return P(q), r
end

# Splits internal interval types into the expected period types from
# https://www.postgresql.org/docs/10/datatype-datetime.html#DATATYPE-INTERVAL-INPUT
function _split_periods(months, days, microseconds)
    periods = Period[]

    push!(periods, _split_period(months, Year)...)
    push!(periods, _split_period(days, Week)...)

    seconds, ms = _split_period(microseconds, Second)
    minutes, seconds = _split_period(seconds, Minute)
    hours, minutes = _split_period(minutes, Hour)

    push!(periods, hours, minutes, seconds, ms)
    filter!(!iszero, periods)

    return Dates.CompoundPeriod(periods)
end

# Parse binary into postgres interval
function Base.parse(
    ::Type{Dates.CompoundPeriod}, pqv::PQBinaryValue{PQ_SYSTEM_TYPES[:interval]}
)
    current_pointer = data_pointer(pqv)

    microsecond = Microsecond(ntoh(unsafe_load(Ptr{Int64}(current_pointer))))
    current_pointer += sizeof(Int64)

    day = Day(ntoh(unsafe_load(Ptr{Int32}(current_pointer))))
    current_pointer += sizeof(Int32)

    month = Month(ntoh(unsafe_load(Ptr{Int32}(current_pointer))))

    # Split combined periods to match the output from text queries
    return _split_periods(Month(month), Day(day), Microsecond(microsecond))
end

# parse the iso_8601 interval output format
# https://www.postgresql.org/docs/10/datatype-datetime.html#DATATYPE-INTERVAL-OUTPUT
function pqparse(::Type{Dates.CompoundPeriod}, str::AbstractString)
    interval_regex = INTERVAL_REGEX[]
    matched = match(interval_regex, str)

    if matched === nothing
        error("Couldn't parse $str as interval using regex $interval_regex")
    end

    periods = Period[]
    sizehint!(periods, 7)
    for period_type in (Year, Month, Day, Hour, Minute)
        period_str = matched[nameof(period_type)]
        if period_str !== nothing
            push!(periods, period_type(parse(Int, period_str)))
        end
    end

    if matched["Second"] !== nothing
        whole_seconds_str = matched["whole_seconds"]
        whole_seconds = parse(Int, whole_seconds_str)
        if whole_seconds != 0
            push!(periods, Second(whole_seconds))
        end

        #=
        We need to parse the fractional seconds as a period.
        Here we try to keep to the largest period type possible for representing the
        fractional seconds.

        For example, 1 is 100 Milliseconds, but 0001 is 100 Microseconds
        =#
        frac_seconds_str = matched["frac_seconds"]
        if frac_seconds_str !== nothing
            len = length(frac_seconds_str)
            frac_periods = [Millisecond, Microsecond, Nanosecond]
            period_coeff = fld1(len, 3)
            period_type = frac_periods[period_coeff]  # field regex prevents BoundsError

            frac_seconds = parse(Int, frac_seconds_str) * 10^(3 * period_coeff - len)
            if frac_seconds != 0
                push!(periods, period_type(frac_seconds))
            end
        end
    end

    return Dates.CompoundPeriod(periods)
end

## ranges
_DEFAULT_TYPE_MAP[:int4range] = Interval{Int32}
_DEFAULT_TYPE_MAP[:int8range] = Interval{Int64}
_DEFAULT_TYPE_MAP[:numrange] = Interval{Decimal}
_DEFAULT_TYPE_MAP[:tsrange] = Interval{DateTime}
_DEFAULT_TYPE_MAP[:tstzrange] = Interval{ZonedDateTime}
_DEFAULT_TYPE_MAP[:daterange] = Interval{Date}

function pqparse(::Type{Interval{T}}, str::AbstractString) where T
    str == "empty" && return Interval{T}()
    return parse(Interval{T}, str; element_parser=pqparse)
end

# How to parse range binary fetch is shown here
# https://github.com/postgres/postgres/blob/31079a4a8e66e56e48bad94d380fa6224e9ffa0d/src/backend/utils/adt/rangetypes.c#L162
const RANGE_EMPTY =                 0b00000001
const RANGE_LOWER_BOUND_INCLUSIVE = 0b00000010
const RANGE_UPPER_BOUND_INCLUSIVE = 0b00000100
const RANGE_LOWER_BOUND_INFINITIY = 0b00001000
const RANGE_UPPER_BOUND_INFINITIY = 0b00010000
const RANGE_LOWER_BOUND_NULL =      0b00100000
const RANGE_UPPER_BOUND_NULL =      0b01000000

function generate_range_binary_parser(symbol)
    @eval function Base.parse(
        ::Type{Interval{T}}, pqv::PQBinaryValue{$(oid(symbol))}
    ) where T
        current_pointer = data_pointer(pqv)
        flags = ntoh(unsafe_load(Ptr{UInt8}(current_pointer)))
        current_pointer += sizeof(UInt8)

        Bool(flags & RANGE_EMPTY) && return Interval{T}()

        lower_value = nothing
        lower_bound = Unbounded
        # if there is a lower bound
        if iszero(flags & (RANGE_LOWER_BOUND_INFINITIY | RANGE_LOWER_BOUND_NULL))
            lower_value_length = ntoh(unsafe_load(Ptr{UInt32}(current_pointer)))
            current_pointer += sizeof(UInt32)
            lower_value = pqparse(T, current_pointer)
            current_pointer += lower_value_length
            lower_bound = !iszero(flags & RANGE_LOWER_BOUND_INCLUSIVE) ? Closed : Open
        end

        upper_value = nothing
        upper_bound = Unbounded
        # if there is a upper bound
        if iszero(flags & (RANGE_UPPER_BOUND_INFINITIY | RANGE_UPPER_BOUND_NULL))
            upper_value_length = ntoh(unsafe_load(Ptr{UInt32}(current_pointer)))
            current_pointer += sizeof(UInt32)
            upper_value = pqparse(T, current_pointer)
            current_pointer += upper_value_length
            upper_bound = !iszero(flags & RANGE_UPPER_BOUND_INCLUSIVE) ? Closed : Open
        end

        return Interval{T,lower_bound,upper_bound}(lower_value, upper_value)
    end
end

foreach(
    generate_range_binary_parser, (:int4range, :int8range, :tsrange, :tstzrange, :daterange)
)

## arrays
# numeric arrays never have double quotes and always use ',' as a separator
parse_numeric_element(::Type{T}, str) where T = parse(T, str)

function parse_numeric_element(::Type{Union{T,Missing}}, str) where T
    return str == "NULL" ? missing : parse(T, str)
end

function parse_numeric_array(eltype::Type{T}, str::AbstractString) where T
    eq_ind = findfirst(isequal('='), str)

    if eq_ind !== nothing
        offset_str = str[1:(eq_ind - 1)]
        range_strs = split(str[1:(eq_ind - 1)], ['[', ']']; keepempty=false)

        ranges = map(range_strs) do range_str
            lower, upper = split(range_str, ':'; limit=2)
            return parse(Int, lower):parse(Int, upper)
        end

        arr = OffsetArray{T}(undef, ranges...)
        el_iter = eachmatch(r"[^\}\{,]+", str[(eq_ind + 1):end])
    else
        arr = Array{T}(undef, array_size(str)...)
        el_iter = eachmatch(r"[^\}\{,]+", str)
    end

    idx_iter = imap(reverse, product(reverse(axes(arr))...))
    for (idx, num_match) in zip(idx_iter, el_iter)
        arr[idx...] = parse_numeric_element(T, num_match.match)
    end

    return arr
end

function array_size(str)
    ndims = something(findfirst(c -> c != '{', str), 0) - 1
    dims = zeros(Int, ndims)

    curr_dim = ndims
    curr_pos = ndims
    open_braces = ndims
    last_ind = lastindex(str)
    el_count = 0
    while curr_dim > 0 && curr_pos < last_ind
        curr_pos = nextind(str, curr_pos)

        if str[curr_pos] == '}'
            open_braces -= 1

            if open_braces < curr_dim
                dims[curr_dim] = el_count
                curr_dim -= 1
                el_count = 1
            end
        elseif str[curr_pos] == '{'
            open_braces += 1
        elseif str[curr_pos] == ','
            if open_braces == curr_dim
                el_count += 1
            end
        else
            if open_braces == curr_dim && el_count == 0
                el_count = 1
            end
        end
    end

    return dims
end

for pq_eltype in ("int2", "int4", "int8", "float4", "float8", "oid", "numeric", "uuid")
    array_oid = PQ_SYSTEM_TYPES[Symbol("_$pq_eltype")]
    jl_type = _DEFAULT_TYPE_MAP[Symbol(pq_eltype)]
    jl_missingtype = Union{jl_type,Missing}

    # could be an OffsetArray or Array of any dimensionality
    _DEFAULT_TYPE_MAP[array_oid] = AbstractArray{jl_missingtype}

    for jl_eltype in (jl_type, jl_missingtype)
        @eval function pqparse(
            ::Type{A}, str::AbstractString
        ) where A<:AbstractArray{$jl_eltype}
            return parse_numeric_array($jl_eltype, str)::A
        end
    end
end

struct FallbackConversion <: AbstractDict{Tuple{Oid,Type},Base.Callable} end

struct ParseType{T} <: Function end

(::ParseType{typ})(pqv::PQValue) where {typ} = parse(typ, pqv)

function Base.getindex(cmap::FallbackConversion, oid_typ::Tuple{Integer,Type})
    _, typ = oid_typ
    return ParseType{typ}()
end

Base.haskey(cmap::FallbackConversion, oid_typ::Tuple{Integer,Type}) = true

"""
A fallback conversion mapping (like [`PQConversions`](@ref) which holds a single function
for converting PostgreSQL data of a given Oid to a given Julia type, using the [`parse`](@ref)
function.
"""
const _FALLBACK_CONVERSION = FallbackConversion()
