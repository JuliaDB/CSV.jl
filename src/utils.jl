newline(code::Parsers.ReturnCode) = (code & Parsers.NEWLINE) === Parsers.NEWLINE
escapestring(code::Parsers.ReturnCode) = (code & Parsers.ESCAPED_STRING) === Parsers.ESCAPED_STRING
quotedstring(code::Parsers.ReturnCode) = (code & Parsers.QUOTED) === Parsers.QUOTED
sentinel(code::Parsers.ReturnCode) = (code & Parsers.SENTINEL) === Parsers.SENTINEL && Parsers.ok(code)

const CatStr = CategoricalString{UInt32}
struct PooledString end
export PooledString

const TypeCode = Int8

# default value to signal that parsing should try to detect a type
const EMPTY       = 0b00000000 % TypeCode

# MISSING is a mask that can be combined w/ any other TypeCode for Union{T, Missing}
const MISSING     = 0b10000000 % TypeCode
missingtype(x::TypeCode) = (x & MISSING) === MISSING

# MISSINGTYPE is for a column like `Vector{Missing}`
# if we're trying to detect a column type and the 1st value of a column is `missing`
# we basically want to still treat it like EMPTY and try parsing other types on each row
const MISSINGTYPE = 0b00000001 % TypeCode

# enum-like type codes for basic supported types
const INT         = 0b00000010 % TypeCode
const FLOAT       = 0b00000011 % TypeCode
const DATE        = 0b00000100 % TypeCode
const DATETIME    = 0b00000101 % TypeCode
const BOOL        = 0b00000110 % TypeCode
const STRING      = 0b00000111 % TypeCode
const POOL        = 0b00001000 % TypeCode
pooled(x::TypeCode) = (x & POOL) == POOL

# a user-provided type; a mask that can be combined w/ basic types
const USER     = 0b00100000 % TypeCode
user(x::TypeCode) = (x & USER) === USER

const TYPEBITS = 0b00001111 % TypeCode
typebits(x::TypeCode) = x & TYPEBITS

typecode(::Type{Missing}) = MISSINGTYPE
typecode(::Type{<:Integer}) = INT
typecode(::Type{<:AbstractFloat}) = FLOAT
typecode(::Type{Date}) = DATE
typecode(::Type{DateTime}) = DATETIME
typecode(::Type{Bool}) = BOOL
typecode(::Type{<:AbstractString}) = STRING
typecode(::Type{Tuple{Ptr{UInt8}, Int}}) = STRING
typecode(::Type{PooledString}) = POOL
typecode(::Type{CatStr}) = POOL
typecode(::Type{Union{}}) = EMPTY
typecode(::Type{Union{T, Missing}}) where {T} = typecode(T) | MISSING
typecode(::Type{T}) where {T} = EMPTY
typecode(x::T) where {T} = typecode(T)

const TYPECODES = Dict(
    EMPTY => Missing,
    MISSINGTYPE => Missing,
    INT => Int64,
    FLOAT => Float64,
    DATE => Date,
    DATETIME => DateTime,
    BOOL => Bool,
    STRING => String,
    INT | MISSING => Union{Int64, Missing},
    FLOAT | MISSING => Union{Float64, Missing},
    DATE | MISSING => Union{Date, Missing},
    DATETIME | MISSING => Union{DateTime, Missing},
    BOOL | MISSING => Union{Bool, Missing},
    STRING | MISSING => Union{String, Missing}
)

gettypecodes(x::Dict) = Dict(typecode(k)=>typecode(v) for (k, v) in x)
gettypecodes(x::Dict{TypeCode, TypeCode}) = x

const MISSING_BIT = 0x8000000000000000
missingvalue(x::UInt64) = (x & MISSING_BIT) == MISSING_BIT

# utilities to convert values to raw UInt64 and back for tape writing
int64(x::UInt64) = Core.bitcast(Int64, x)
float64(x::UInt64) = Core.bitcast(Float64, x)
bool(x::UInt64) = x == 0x0000000000000001
date(x::UInt64) = Date(Dates.UTD(int64(x)))
datetime(x::UInt64) = DateTime(Dates.UTM(int64(x)))
ref(x::UInt64) = unsafe_trunc(UInt32, x)

uint64(x::Int64) = Core.bitcast(UInt64, x)
uint64(x::Float64) = Core.bitcast(UInt64, x)
uint64(x::Bool) = UInt64(x)
uint64(x::Union{Date, DateTime}) = uint64(Dates.value(x))
uint64(x::UInt32) = UInt64(x)

function consumeBOM!(io)
    # BOM character detection
    startpos = position(io)
    if !eof(io) && Parsers.peekbyte(io) == 0xef
        Parsers.readbyte(io)
        (!eof(io) && Parsers.readbyte(io) == 0xbb) || Parsers.fastseek!(io, startpos)
        (!eof(io) && Parsers.readbyte(io) == 0xbf) || Parsers.fastseek!(io, startpos)
    end
    return
end

function getio(source, use_mmap)
    if source isa Vector{UInt8}
        return IOBuffer(source)
    elseif use_mmap && source isa String
        return IOBuffer(Mmap.mmap(source))
    end
    iosource = source isa String ? open(source) : source
    io = IOBuffer()
    while !eof(iosource)
        Base.write(io, iosource)
    end
    A = Mmap.mmap(Vector{UInt8}, io.size)
    copyto!(A, 1, io.data, 1, io.size)
    return IOBuffer(A)
end

getname(buf::Vector{UInt8}) = "<raw buffer>"
getname(str::String) = str
getname(io::I) where {I <: IO} = string("<", I, ">")

getbools(::Nothing, ::Nothing) = nothing
getbools(trues::Vector{String}, falses::Vector{String}) = Parsers.Trie(append!([x=>true for x in trues], [x=>false for x in falses]))
getbools(trues::Vector{String}, ::Nothing) = Parsers.Trie(append!([x=>true for x in trues], ["false"=>false]))
getbools(::Nothing, falses::Vector{String}) = Parsers.Trie(append!(["true"=>true], [x=>false for x in falses]))

getkwargs(df::Nothing, dec::Nothing, bools::Nothing) = NamedTuple()
getkwargs(df::String, dec::Nothing, bools::Nothing) = (dateformat=Dates.DateFormat(df),)
getkwargs(df::Dates.DateFormat, dec::Nothing, bools::Nothing) = (dateformat=df,)

getkwargs(df::Nothing, dec::Union{UInt8, Char}, bools::Nothing) = (decimal=dec % UInt8,)
getkwargs(df::String, dec::Union{UInt8, Char}, bools::Nothing) = (dateformat=Dates.DateFormat(df), decimal=dec % UInt8)
getkwargs(df::Dates.DateFormat, dec::Union{UInt8, Char}, bools::Nothing) = (dateformat=df, decimal=dec % UInt8)

getkwargs(df::Nothing, dec::Nothing, bools::Parsers.Trie) = (bools=bools,)
getkwargs(df::String, dec::Nothing, bools::Parsers.Trie) = (dateformat=Dates.DateFormat(df), bools=bools)
getkwargs(df::Dates.DateFormat, dec::Nothing, bools::Parsers.Trie) = (dateformat=df, bools=bools)

getkwargs(df::Nothing, dec::Union{UInt8, Char}, bools::Parsers.Trie) = (decimal=dec % UInt8, bools=bools)
getkwargs(df::String, dec::Union{UInt8, Char}, bools::Parsers.Trie) = (dateformat=Dates.DateFormat(df), decimal=dec % UInt8, bools=bools)
getkwargs(df::Dates.DateFormat, dec::Union{UInt8, Char}, bools::Parsers.Trie) = (dateformat=df, decimal=dec % UInt8, bools=bools)

const RESERVED = Set(["local", "global", "export", "let",
    "for", "struct", "while", "const", "continue", "import",
    "function", "if", "else", "try", "begin", "break", "catch",
    "return", "using", "baremodule", "macro", "finally",
    "module", "elseif", "end", "quote", "do"])

normalizename(name::Symbol) = name
function normalizename(name::String)
    uname = strip(Unicode.normalize(name))
    id = Base.isidentifier(uname) ? uname : map(c->Base.is_id_char(c) ? c : '_', uname)
    cleansed = string((isempty(id) || !Base.is_id_start_char(id[1]) || id in RESERVED) ? "_" : "", id)
    return Symbol(replace(cleansed, r"(_)\1+"=>"_"))
end

function makeunique(names)
    set = Set(names)
    length(set) == length(names) && return names
    nms = Symbol[]
    for nm in names
        if nm in nms
            k = 1
            newnm = Symbol("$(nm)_$k")
            while newnm in set || newnm in nms
                k += 1
                newnm = Symbol("$(nm)_$k")
            end
            nm = newnm
        end
        push!(nms, nm)
    end
    return nms
end

initialtypes(T, x::AbstractDict{String}, names) = TypeCode[haskey(x, string(nm)) ? typecode(x[string(nm)]) | USER : T for nm in names]
initialtypes(T, x::AbstractDict{Symbol}, names) = TypeCode[haskey(x, nm) ? typecode(x[nm]) | USER : T for nm in names]
initialtypes(T, x::AbstractDict{Int}, names)    = TypeCode[haskey(x, i) ? typecode(x[i]) | USER : T for i = 1:length(names)]

function timetype(df::Dates.DateFormat)
    date = false
    time = false
    for token in df.tokens
        T = typeof(token)
        if T == Dates.DatePart{'H'}
            time = true
        elseif T == Dates.DatePart{'y'} || T == Dates.DatePart{'Y'}
            date = true
        end
    end
    return ifelse(date & time, DateTime, ifelse(time, Time, Date))
end

roundup(a, n) = (a + (n - 1)) & ~(n - 1)