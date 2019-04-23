module CSV

# stdlib
using Mmap, Dates, Random, Unicode
using Parsers, Tables, CategoricalArrays, PooledArrays, WeakRefStrings, DataFrames

function validate(fullpath::Union{AbstractString,IO}; kwargs...)
    Base.depwarn("`CSV.validate` is deprecated. `CSV.read` now prints warnings on misshapen files.", :validate)
    Tables.columns(File(fullpath; kwargs...))
    return
end

include("utils.jl")
include("filedetection.jl")

struct Error <: Exception
    error::Parsers.Error
    row::Int
    col::Int
end

function Base.showerror(io::IO, e::Error)
    println(io, "CSV.Error on row=$(e.row), column=$(e.col):")
    showerror(io, e.error)
end

struct File
    name::String
    buf::Vector{UInt8}
    names::Vector{Symbol}
    types::Vector{Type}
    typecodes::Vector{TypeCode}
    escapestrings::Vector{Bool}
    quotedstringtype
    refs::Vector{Dict{Union{Missing, String}, UInt32}}
    pool::Float64
    categorical::Bool
    categoricalpools::Vector{CategoricalPool{String, UInt32, CatStr}}
    rows::Int64
    cols::Int64
    tape::Vector{UInt64}
end

function Base.show(io::IO, f::File)
    println(io, "CSV.File(\"$(f.name)\"):")
    println(io, "Size: $(f.rows) x $(f.cols)")
    show(io, Tables.schema(f))
end

const EMPTY_POSITIONS = Int64[]
const EMPTY_TYPEMAP = Dict{TypeCode, TypeCode}()
const EMPTY_REFS = Dict{Union{Missing, String}, UInt32}[]
const EMPTY_LAST_REFS = UInt32[]
const EMPTY_CATEGORICAL_POOLS = CategoricalPool{String, UInt32, CatStr}[]

"""
    CSV.File(source::Union{String, IO}; kwargs...) => CSV.File

Read a csv input (a filename given as a String, or any other IO source), returning a `CSV.File` object.
Opens the file and uses passed arguments to detect the number of columns and column types.
The returned `CSV.File` object supports the [Tables.jl](https://github.com/JuliaData/Tables.jl) interface
and can iterate `CSV.Row`s. `CSV.Row` supports `propertynames` and `getproperty` to access individual row values.
Note that duplicate column names will be detected and adjusted to ensure uniqueness (duplicate column name `a` will become `a_1`).
For example, one could iterate over a csv file with column names `a`, `b`, and `c` by doing:

```julia
for row in CSV.File(file)
    println("a=\$(row.a), b=\$(row.b), c=\$(row.c)")
end
```

By supporting the Tables.jl interface, a `CSV.File` can also be a table input to any other table sink function. Like:

```julia
# materialize a csv file as a DataFrame
df = CSV.File(file) |> DataFrame

# load a csv file directly into an sqlite database table
db = SQLite.DB()
tbl = CSV.File(file) |> SQLite.load!(db, "sqlite_table")
```

Supported keyword arguments include:
* File layout options:
  * `header=1`: the `header` argument can be an `Int`, indicating the row to parse for column names; or a `Range`, indicating a span of rows to be combined together as column names; or an entire `Vector of Symbols` or `Strings` to use as column names
  * `normalizenames=false`: whether column names should be "normalized" into valid Julia identifier symbols
  * `datarow`: an `Int` argument to specify the row where the data starts in the csv file; by default, the next row after the `header` row is used
  * `skipto::Int`: similar to `datarow`, specifies the number of rows to skip before starting to read data
  * `footerskip::Int`: number of rows at the end of a file to skip parsing
  * `limit`: an `Int` to indicate a limited number of rows to parse in a csv file
  * `transpose::Bool`: read a csv file "transposed", i.e. each column is parsed as a row
  * `comment`: a `String` that occurs at the beginning of a line to signal parsing that row should be skipped
  * `use_mmap::Bool=!Sys.iswindows()`: whether the file should be mmapped for reading, which in some cases can be faster
* Parsing options:
  * `missingstrings`, `missingstring`: either a `String`, or `Vector{String}` to use as sentinel values that will be parsed as `missing`; by default, only an empty field (two consecutive delimiters) is considered `missing`
  * `delim=','`: a `Char` or `String` that indicates how columns are delimited in a file
  * `ignorerepeated::Bool=false`: whether repeated (consecutive) delimiters should be ignored while parsing; useful for fixed-width files with delimiter padding between cells
  * `quotechar='"'`, `openquotechar`, `closequotechar`: a `Char` (or different start and end characters) that indicate a quoted field which may contain textual delimiters or newline characters
  * `escapechar='"'`: the `Char` used to escape quote characters in a text field
  * `dateformat::Union{String, Dates.DateFormat, Nothing}`: a date format string to indicate how Date/DateTime columns are formatted in a delimited file
  * `decimal`: a `Char` indicating how decimals are separated in floats, i.e. `3.14` used '.', or `3,14` uses a comma ','
  * `truestrings`, `falsestrings`: `Vectors of Strings` that indicate how `true` or `false` values are represented
* Column Type Options:
  * `types`: a Vector or Dict of types to be used for column types; a Dict can map column index `Int`, or name `Symbol` or `String` to type for a column, i.e. Dict(1=>Float64) will set the first column as a Float64, Dict(:column1=>Float64) will set the column named column1 to Float64 and, Dict("column1"=>Float64) will set the column1 to Float64
  * `typemap::Dict{Type, Type}`: a mapping of a type that should be replaced in every instance with another type, i.e. `Dict(Float64=>String)` would change every detected `Float64` column to be parsed as `Strings`
  * `allowmissing=:all`: indicate how missing values are allowed in columns; possible values are `:all` - all columns may contain missings, `:auto` - auto-detect columns that contain missings or, `:none` - no columns may contain missings
  * `categorical::Union{Bool, Float64}=false`: if `true`, columns detected as `String` are returned as a `CategoricalArray`; alternatively, the proportion of unique values below which `String` columns should be treated as categorical (for example 0.1 for 10%)
  * `pool::Union{Bool, Float64}=false`: if `true`, columns detected as `String` are returned as a `PooledArray`; alternatively, the proportion of unique values below which `String` columns should be pooled (for example 0.1 for 10%)
  * `strict::Bool=false`: whether invalid values should throw a parsing error or be replaced with missing values
  * `silencewarnings::Bool=false`: whether invalid value warnings should be silenced (requires `strict=false`)
"""
function File(source::Union{Vector{UInt8}, String, IO};
    # file options
    # header can be a row number, range of rows, or actual string vector
    header::Union{Integer, Vector{Symbol}, Vector{String}, AbstractVector{<:Integer}}=1,
    normalizenames::Bool=false,
    # by default, data starts immediately after header or start of file
    datarow::Int=-1,
    skipto::Union{Nothing, Int}=nothing,
    footerskip::Int=0,
    limit::Int=typemax(Int64),
    transpose::Bool=false,
    comment::Union{String, Nothing}=nothing,
    use_mmap::Bool=!Sys.iswindows(),
    # parsing options
    missingstrings=String[],
    missingstring="",
    delim::Union{Nothing, Char, String}=nothing,
    ignorerepeated::Bool=false,
    quotechar::Union{UInt8, Char}='"',
    openquotechar::Union{UInt8, Char, Nothing}=nothing,
    closequotechar::Union{UInt8, Char, Nothing}=nothing,
    escapechar::Union{UInt8, Char}='"',
    dateformat::Union{String, Dates.DateFormat, Nothing}=nothing,
    decimal::Union{UInt8, Char, Nothing}=UInt8('.'),
    truestrings::Union{Vector{String}, Nothing}=nothing,
    falsestrings::Union{Vector{String}, Nothing}=nothing,
    # type options
    type=nothing,
    types=nothing,
    typemap::Dict=EMPTY_TYPEMAP,
    allowmissing::Symbol=:all,
    categorical::Union{Bool, Real}=false,
    pool::Union{Bool, Real}=false,
    strict::Bool=false,
    silencewarnings::Bool=false,
    debug::Bool=false,
    parsingdebug::Bool=false)

    isa(source, AbstractString) && (isfile(source) || throw(ArgumentError("\"$source\" is not a valid file")))
    (types !== nothing && any(x->!isconcretetype(x) && !(x isa Union), types isa AbstractDict ? values(types) : types)) && throw(ArgumentError("Non-concrete types passed in `types` keyword argument, please provide concrete types for columns: $types"))
    delim !== nothing && ((delim isa Char && iscntrl(delim) && delim != '\t') || (delim isa String && any(iscntrl, delim) && !all(==('\t'), delim))) && throw(ArgumentError("invalid delim argument = '$(escape_string(string(delim)))', must be a non-control character or string without control characters"))
    header = (isa(header, Integer) && header == 1 && (datarow == 1 || skipto == 1)) ? -1 : header
    isa(header, Integer) && datarow != -1 && (datarow > header || throw(ArgumentError("data row ($datarow) must come after header row ($header)")))
    datarow = skipto !== nothing ? skipto : (datarow == -1 ? (isa(header, Vector{Symbol}) || isa(header, Vector{String}) ? 0 : last(header)) + 1 : datarow) # by default, data starts on line after header

    debug && println("header is: $header, datarow computed as: $datarow")
    buf = getsource(source, use_mmap)
    len = length(buf)
    pos = consumeBOM!(buf)

    oq = something(openquotechar, quotechar) % UInt8
    cq = something(closequotechar, quotechar) % UInt8
    eq = escapechar % UInt8
    quotedstringtype = WeakRefStrings.QuotedString{oq, cq, eq}
    cmt = comment === nothing ? nothing : (pointer(comment), sizeof(comment))
    rowsguess, del = guessnrows(buf, oq, cq, eq, source, delim, cmt, debug)
    debug && println("estimated rows: $rowsguess")
    debug && println("detected delimiter: \"$(escape_string(del isa UInt8 ? string(Char(del)) : del))\"")

    wh1 = del == UInt(' ') || delim == " " ? 0x00 : UInt8(' ')
    wh2 = del == UInt8('\t') || delim == "\t" ? 0x00 : UInt8('\t')
    trues = truestrings === nothing ? nothing : truestrings
    falses = falsestrings === nothing ? nothing : falsestrings
    sentinel = isempty(missingstrings) ? (missingstring == "" ? missing : [missingstring]) : missingstrings
    options = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, del, decimal, trues, falses, dateformat, ignorerepeated, true, parsingdebug, strict, silencewarnings)

    if transpose
        # need to determine names, columnpositions (rows), and ref
        rowsguess, names, positions = datalayout_transpose(header, buf, pos, len, options, datarow, normalizenames)
        datapos = positions[1]
    else
        positions = EMPTY_POSITIONS
        names, datapos = datalayout(header, buf, pos, len, options, datarow, normalizenames, cmt, ignorerepeated)
    end
    debug && println("column names detected: $names")
    debug && println("byte position of data computed at: $datapos")

    catg = false
    T = type === nothing ? EMPTY : (typecode(type) | USER)
    if types isa Vector
        typecodes = TypeCode[typecode(T) | USER for T in types]
        catg = any(T->T <: CatStr, types)
    elseif types isa AbstractDict
        typecodes = initialtypes(T, types, names)
        catg = any(T->T <: CatStr, values(types))
    else
        typecodes = TypeCode[T for _ = 1:length(names)]
    end
    debug && println("computed typecodes are: $typecodes")

    # might as well round up to the next largest pagesize, since mmap aligns to it anyway
    ncols = length(names)
    tape = Mmap.mmap(Vector{UInt64}, roundup((rowsguess * ncols * 2), Mmap.PAGESIZE))
    escapestrings = fill(false, ncols)
    catg |= categorical === true || categorical isa Float64
    pool = (pool === true || categorical === true || any(pooled, typecodes)) ? 1.0 :
            pool isa Float64 ? pool : categorical isa Float64 ? categorical : 0.0
    refs = pool > 0.0 ? [Dict{Union{Missing, String}, UInt32}() for i = 1:ncols] : EMPTY_REFS
    lastrefs = pool > 0.0 ? [UInt32(0) for i = 1:ncols] : EMPTY_LAST_REFS
    t = time()
    rows = parsetape(Val(transpose), ncols, gettypecodes(typemap), tape, escapestrings, buf, datapos, len, limit, cmt, positions, pool, refs, lastrefs, rowsguess, typecodes, debug, options)
    debug && println("time for initial parsing to tape: $(time() - t)")
    foreach(1:ncols) do i
        typecodes[i] &= ~USER
    end
    types = [pooled(T) ? catg ? CatStr : PooledString : TYPECODES[T] for T in typecodes]
    debug && println("types after parsing: $types")
    if catg
        foreach(x->delete!(x, missing), refs)
        categoricalpools = [CategoricalPool(convert(Dict{String, UInt32}, r)) for r in refs]
        foreach(x->levels!(x, sort(levels(x))), categoricalpools)
    else
        categoricalpools = EMPTY_CATEGORICAL_POOLS
    end
    return File(getname(source), buf, names, types, typecodes, escapestrings, quotedstringtype, refs, pool, catg, categoricalpools, rows - footerskip, ncols, tape)
end

function scan(file)
    buf = Mmap.mmap(file)
    len = length(buf)
    tape = Mmap.mmap(Vector{UInt64}, len >> 1)
    pos = 112
    tapeidx = 1
    for row = 1:1_000_000
        for col = 1:20
            x, code, vpos, vlen, tlen = Parsers.xparse(Int64, buf, pos, len, Parsers.XOPTIONS)
            @inbounds tape[tapeidx] = (Core.bitcast(UInt64, vpos) << 16) | Core.bitcast(UInt64, vlen)
            @inbounds tape[tapeidx+1] = uint64(x)
            tapeidx += 2
            pos += tlen
        end
    end
    return tape
end

function parsetape(::Val{transpose}, ncols, typemap, tape, escapestrings, buf, pos, len, limit, cmt, positions, pool, refs, lastrefs, rowsguess, typecodes, debug, options::Parsers.Options{ignorerepeated}) where {transpose, ignorerepeated}
    row = 0
    tapeidx = 1
    tapelen = length(tape)
    if pos <= len
        while row < limit
            row += 1
            pos = consumecommentedline!(buf, pos, len, cmt)
            if ignorerepeated
                pos = Parsers.checkdelim!(buf, pos, len, options)
            end
            for col = 1:ncols
                if transpose
                    @inbounds pos = positions[col]
                end
                @inbounds T = typecodes[col]
                type = typebits(T)
                if type === EMPTY
                    nT, pos, code = parseempty!(tape, tapeidx, buf, pos, len, options, col, typemap, escapestrings, pool, refs, lastrefs, debug)
                elseif type === MISSINGTYPE
                    nT, pos, code = parsemissing!(tape, tapeidx, buf, pos, len, options, col, typemap, escapestrings, pool, refs, lastrefs, debug)
                elseif type === INT
                    nT, pos, code = parseint!(T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
                elseif type === FLOAT
                    nT, pos, code = parsevalue!(Float64, T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
                elseif type === DATE
                    nT, pos, code = parsevalue!(Date, T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
                elseif type === DATETIME
                    nT, pos, code = parsevalue!(DateTime, T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
                elseif type === BOOL
                    nT, pos, code = parsevalue!(Bool, T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
                elseif type === POOL
                    nT, pos, code = parsepooled!(T, tape, tapeidx, buf, pos, len, options, col, rowsguess, pool, refs[col], lastrefs)
                else # STRING
                    nT, pos, code = parsestring!(T, tape, tapeidx, buf, pos, len, options, col, escapestrings)
                end
                if nT !== T
                    @inbounds typecodes[col] = nT
                end
                tapeidx += 2
                if transpose
                    @inbounds positions[col] = pos
                else
                    if col < ncols
                        if Parsers.newline(code)
                            options.silencewarnings || notenoughcolumns(col, ncols, row)
                            for j = (col + 1):ncols
                                # put in dummy missing values on the tape for missing columns
                                tape[tapeidx] = MISSING_BIT
                                T = typecodes[j]
                                if T > MISSINGTYPE
                                    typecodes[j] |= MISSING
                                end
                                tapeidx += 2
                            end
                            break # from for col = 1:ncols
                        end
                    else
                        if pos <= len && !Parsers.newline(code)
                            options.silencewarnings || toomanycolumns(ncols, row)
                            # ignore the rest of the line
                            pos = readline!(buf, pos, len, options)
                        end
                    end
                end
            end
            pos > len && break
            # eof(io) && break
            if tapeidx > tapelen
                println("WARNING: didn't pre-allocate enough while parsing: preallocated=$(row)")
                break
            end
        end
    end
    return row
end

@noinline notenoughcolumns(cols, ncols, row) = println("warning: only found $cols / $ncols columns on data row: $row. Filling remaining columns with `missing`...")
@noinline toomanycolumns(cols, row) = println("warning: parsed expected $cols columns, but didn't reach end of line on data row: $row. Ignoring any extra columns on this row...")
@noinline stricterror(T, buf, pos, len, code, row, col) = throw(ArgumentError("error parsing $T on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code))"))
@noinline warning(T, buf, pos, len, code, row, col) = println("warnings: error parsing $T on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code))")
@noinline fatalerror(buf, pos, len, code, row, col) = throw(ArgumentError("fatal error, encountered an invalidly quoted field while parsing on row = $row, col = $col: \"$(String(buf[pos:pos+len-1]))\", error=$(Parsers.codes(code)), check your `quotechar` arguments or manually fix the field in the file itself"))

@inline function setposlen!(tape, tapeidx, code, pos, len)
    pos = Parsers.sentinel(code) ? MISSING_BIT : (Core.bitcast(UInt64, pos) << 16)
    @inbounds tape[tapeidx] = pos | Core.bitcast(UInt64, len)
    return
end

function parseempty!(tape, tapeidx, buf, pos, len, options, col, typemap, escapestrings, pool, refs, lastrefs, debug)
    x, code, vpos, vlen, tlen = detecttype(buf, pos, len, options, debug)
    T = Parsers.sentinel(code) ? MISSINGTYPE : typecode(x)
    T = get(typemap, T, T)
    if T == INT
        @inbounds tape[tapeidx] = ((Core.bitcast(UInt64, vpos) | INT_BIT) << 16) | Core.bitcast(UInt64, vlen)
        @inbounds tape[tapeidx + 1] = uint64(x)
    else
        setposlen!(tape, tapeidx, code, vpos, vlen)
        if MISSINGTYPE < T < STRING
            @inbounds tape[tapeidx + 1] = uint64(x)
        elseif T === STRING
            if pool > 0.0
                T = POOL
                ref = getref!(refs[col], (pointer(buf, vpos), vlen), lastrefs, col)
                @inbounds tape[tapeidx + 1] = uint64(ref)
            else
                @inbounds escapestrings[col] |= Parsers.escapedstring(code)
            end
        end
    end
    return T, pos + tlen, code
end

function parsemissing!(tape, tapeidx, buf, pos, len, options, col, typemap, escapestrings, pool, refs, lastrefs, debug)
    x, code, vpos, vlen, tlen = detecttype(buf, pos, len, options, debug)
    T = Parsers.sentinel(code) ? MISSINGTYPE : typecode(x)
    T = get(typemap, T, T)
    if T == INT
        @inbounds tape[tapeidx] = ((Core.bitcast(UInt64, vpos) | INT_BIT) << 16) | Core.bitcast(UInt64, vlen)
        @inbounds tape[tapeidx + 1] = uint64(x)
    else
        setposlen!(tape, tapeidx, code, vpos, vlen)
        if MISSINGTYPE < T < STRING
            @inbounds tape[tapeidx + 1] = uint64(x)
        elseif T === STRING
            if pool > 0.0
                T = POOL
                ref = getref!(refs[col], (pointer(buf, vpos), vlen), lastrefs, col)
                @inbounds tape[tapeidx + 1] = uint64(ref)
            else
                @inbounds escapestrings[col] |= Parsers.escapedstring(code)
            end
        end
    end
    return T === MISSINGTYPE ? T : T | MISSING, pos + tlen, code
end

function detecttype(buf, pos, len, options, debug)
    int, code, vpos, vlen, tlen = Parsers.xparse(Int64, buf, pos, len, options)
    if debug
        println("type detection on: \"$(escape_string(unsafe_string(pointer(buf, pos), tlen)))\"")
        println("attempted Int: $(Parsers.codes(code))")
    end
    Parsers.ok(code) && return int, code, vpos, vlen, tlen
    float, code, vpos, vlen, tlen = Parsers.xparse(Float64, buf, pos, len, options)
    if debug
        println("attempted Float64: $(Parsers.codes(code))")
    end
    Parsers.ok(code) && return float, code, vpos, vlen, tlen
    if options.dateformat === nothing
        try
            date, code, vpos, vlen, tlen = Parsers.xparse(Date, buf, pos, len, options)
            if debug
                println("attempted Date: $(Parsers.codes(code))")
            end 
            Parsers.ok(code) && return date, code, vpos, vlen, tlen
        catch e
        end
        try
            datetime, code, vpos, vlen, tlen = Parsers.xparse(DateTime, buf, pos, len, options)
            if debug
                println("attempted DateTime: $(Parsers.codes(code))")
            end
            Parsers.ok(code) && return datetime, code, vpos, vlen, tlen
        catch e
        end
    else
        # use user-provided dateformat
        T = timetype(options.dateformat)
        dt, code, vpos, vlen, tlen = Parsers.xparse(T, buf, pos, len, options)
        if debug
            println("attempted $T: $(Parsers.codes(code))")
        end
        Parsers.ok(code) && return dt, code, vpos, vlen, tlen
    end
    bool, code, vpos, vlen, tlen = Parsers.xparse(Bool, buf, pos, len, options)
    if debug
        println("attempted Bool: $(Parsers.codes(code))")
    end
    Parsers.ok(code) && return bool, code, vpos, vlen, tlen
    str, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    return "", code, vpos, vlen, tlen
end

function parseint!(T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings)
    x, code, vpos, vlen, tlen = Parsers.xparse(Int64, buf, pos, len, options)
    if Parsers.succeeded(code)
        if !Parsers.sentinel(code)
            @inbounds tape[tapeidx + 1] = uint64(x)
            if !user(T)
                @inbounds tape[tapeidx] = ((Core.bitcast(UInt64, vpos) | INT_BIT) << 16) | Core.bitcast(UInt64, vlen)
            end
        else
            T |= MISSING
            @inbounds tape[tapeidx] = MISSING_BIT
        end
    else
        if Parsers.invalidquotedfield(code)
            # this usually means parsing is borked because of an invalidly quoted field, hard error
            fatalerror(buf, pos, len, code, row, col)
        end
        if user(T)
            if !options.strict
                code |= Parsers.SENTINEL
                options.silencewarnings || warning(Int64, buf, pos, tlen, code, row, col)
                T |= MISSING
                @inbounds tape[tapeidx] = MISSING_BIT
            else
                stricterror(Int64, buf, pos, tlen, code, row, col)
            end
        else
            y, code, vpos, vlen, tlen = Parsers.xparse(Float64, buf, pos, len, options)
            if Parsers.succeeded(code)
                @inbounds tape[tapeidx + 1] = uint64(y)
                T = (T & ~INT) | FLOAT
            else
                _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
                T = (T & ~INT) | STRING
                @inbounds escapestrings[col] |= Parsers.escapedstring(code)
            end
            if !user(T)
                setposlen!(tape, tapeidx, code, vpos, vlen)
            end
        end
    end
    return T, pos + tlen, code
end

function parsevalue!(::Type{type}, T, tape, tapeidx, buf, pos, len, options, row, col, escapestrings) where {type}
    x, code, vpos, vlen, tlen = Parsers.xparse(type, buf, pos, len, options)
    if Parsers.succeeded(code)
        if !Parsers.sentinel(code)
            @inbounds tape[tapeidx + 1] = uint64(x)
        else
            T |= MISSING
        end
    else
        if Parsers.invalidquotedfield(code)
            # this usually means parsing is borked because of an invalidly quoted field, hard error
            fatalerror(buf, pos, len, code, row, col)
        end
        if user(T)
            if !options.strict
                code |= Parsers.SENTINEL
                options.silencewarnings || warning(type, buf, pos, tlen, code, row, col)
                T |= MISSING
                @inbounds tape[tapeidx] = MISSING_BIT
            else
                stricterror(type, buf, pos, tlen, code, row, col)
            end
        else
            T = STRING | (missingtype(T) ? MISSING : EMPTY)
            @inbounds escapestrings[col] |= Parsers.escapedstring(code)
        end
    end
    if !user(T)
        setposlen!(tape, tapeidx, code, vpos, vlen)
    end
    return T, pos + tlen, code
end

@inline function parsestring!(T, tape, tapeidx, buf, pos, len, options, col, escapestrings)
    x, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    setposlen!(tape, tapeidx, code, vpos, vlen)
    @inbounds escapestrings[col] |= Parsers.escapedstring(code)
    T |= ifelse(Parsers.sentinel(code), MISSING, EMPTY)
    return T, pos + tlen, code
end

# argh, fellow pirates beware, this be my stolen treasure
function Base.hash(x::Tuple{Ptr{UInt8},Int}, h::UInt)
    h += Base.memhash_seed
    ccall(Base.memhash, UInt, (Ptr{UInt8}, Csize_t, UInt32), x[1], x[2], h % UInt32) + h
end
Base.isequal(x::Tuple{Ptr{UInt8}, Int}, y::String) =
    x[2] == sizeof(y) && 0 == ccall(:memcmp, Int32, (Ptr{UInt8}, Ptr{UInt8}, UInt), x[1], y, x[2])

@inline function getref!(x::Dict, key::Tuple{Ptr{UInt8}, Int}, lastrefs, col)
    index = Base.ht_keyindex2!(x, key)
    if index > 0
        @inbounds found_key = x.vals[index]
        return found_key::UInt32
    else
        @inbounds new = (lastrefs[col] += UInt32(1))
        @inbounds Base._setindex!(x, new, unsafe_string(key[1], key[2]), -index)
        return new
    end
end

function parsepooled!(T, tape, tapeidx, buf, pos, len, options, col, rowsguess, pool, refs, lastrefs)
    x, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
    setposlen!(tape, tapeidx, code, vpos, vlen)
    if Parsers.sentinel(code)
        T |= MISSING
        ref = UInt32(0)
    else
        ref = getref!(refs, (pointer(buf, vpos), vlen), lastrefs, col)
    end
    if !user(T) && (length(refs) / rowsguess) > pool
        T = STRING | (missingtype(T) ? MISSING : EMPTY)
    else
        @inbounds tape[tapeidx + 1] = uint64(ref)
    end
    return T, pos + tlen, code
end

include("tables.jl")
include("iteration.jl")
include("write.jl")

"""
`CSV.read(source::Union{AbstractString,IO}; kwargs...)` => `DataFrame`

Parses a delimited file into a DataFrame.

Minimal error-reporting happens w/ `CSV.read` for performance reasons; for problematic csv files, try [`CSV.validate`](@ref) which takes exact same arguments as `CSV.read` and provides much more information for why reading the file failed.

Positional arguments:

* `source`: can be a file name (String) of the location of the csv file or `IO` object to read the csv from directly

Supported keyword arguments include:
* File layout options:
  * `header=1`: the `header` argument can be an `Int`, indicating the row to parse for column names; or a `Range`, indicating a span of rows to be combined together as column names; or an entire `Vector of Symbols` or `Strings` to use as column names
  * `normalizenames=false`: whether column names should be "normalized" into valid Julia identifier symbols
  * `datarow`: an `Int` argument to specify the row where the data starts in the csv file; by default, the next row after the `header` row is used
  * `skipto::Int`: similar to `datarow`, specifies the number of rows to skip before starting to read data
  * `footerskip::Int`: number of rows at the end of a file to skip parsing
  * `limit`: an `Int` to indicate a limited number of rows to parse in a csv file
  * `transpose::Bool`: read a csv file "transposed", i.e. each column is parsed as a row
  * `comment`: a `String` that occurs at the beginning of a line to signal parsing that row should be skipped
  * `use_mmap::Bool=!Sys.iswindows()`: whether the file should be mmapped for reading, which in some cases can be faster
* Parsing options:
  * `missingstrings`, `missingstring`: either a `String`, or `Vector{String}` to use as sentinel values that will be parsed as `missing`; by default, only an empty field (two consecutive delimiters) is considered `missing`
  * `delim=','`: a `Char` or `String` that indicates how columns are delimited in a file
  * `ignorerepeated::Bool=false`: whether repeated (consecutive) delimiters should be ignored while parsing; useful for fixed-width files with delimiter padding between cells
  * `quotechar='"'`, `openquotechar`, `closequotechar`: a `Char` (or different start and end characters) that indicate a quoted field which may contain textual delimiters, newline characters, or quote characters
  * `escapechar='\\'`: the `Char` used to escape quote characters in a text field
  * `dateformat::Union{String, Dates.DateFormat, Nothing}`: a date format string to indicate how Date/DateTime columns are formatted in a delimited file
  * `decimal`: a `Char` indicating how decimals are separated in floats, i.e. `3.14` used '.', or `3,14` uses a comma ','
  * `truestrings`, `falsestrings`: `Vectors of Strings` that indicate how `true` or `false` values are represented
* Column Type Options:
  * `types`: a Vector or Dict of types to be used for column types; a Dict can map column index `Int`, or name `Symbol` or `String` to type for a column, i.e. Dict(1=>Float64) will set the first column as a Float64, Dict(:column1=>Float64) will set the column named column1 to Float64 and, Dict("column1"=>Float64) will set the column1 to Float64
  * `typemap::Dict{Type, Type}`: a mapping of a type that should be replaced in every instance with another type, i.e. `Dict(Float64=>String)` would change every detected `Float64` column to be parsed as `Strings`
  * `allowmissing=:all`: indicate how missing values are allowed in columns; possible values are `:all` - all columns may contain missings, `:auto` - auto-detect columns that contain missings or, `:none` - no columns may contain missings
  * `categorical::Union{Bool, Real}=false`: if `true`, columns detected as `String` are returned as a `CategoricalArray`; alternatively, the proportion of unique values below which `String` columns should be treated as categorical (for example 0.1 for 10%)
  * `strict::Bool=false`: whether invalid values should throw a parsing error or be replaced with missing values
"""
read(source::Union{AbstractString, IO}; kwargs...) = CSV.File(source; kwargs...) |> DataFrame

function __init__()
    Threads.resize_nthreads!(VALUE_BUFFERS)
    return
end

end # module
