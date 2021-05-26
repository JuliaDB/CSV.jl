# a RefPool holds our refs as a Dict, along with a lastref field which is incremented when a new ref is found while parsing pooled columns
mutable struct RefPool
    # what? why ::Any here? well, we want flexibility in what kind of refs we stick in here
    # it might be Dict{Union{String, Missing}, UInt32}, but it might be some other string type
    # or it might not allow `missing`; in short, there are too many options to try and type
    # the field concretely; luckily, working with the `refs` field here is limited to
    # a very few specific methods, where we're inspecting the ctx.stringtype and can assert
    # the expected refs type here to help the compiler
    refs::Any
    lastref::UInt32
end

# start lastref at 1, since it's reserved for `missing`, so first ref value will be 2
const Refs{T} = Dict{Union{T, Missing}, UInt32}
RefPool(::Type{T}=String) where {T} = RefPool(Refs{T}(missing => 1), 1)

mutable struct Column
    # fields that are copied per task when parsing
    type::Type # always a single, concrete type; no Union{T, Missing}; missingness is tracked in anymissing field
    anymissing::Bool # whether any missing values have been encountered while parsing
    userprovidedtype::Bool # whether the column type was provided by the user or not
    willdrop::Bool # whether we'll drop this column from the final columnset; computed from select/drop arguments
    maxstringsize::UInt8
    pool::Float64
    # lazily/manually initialized fields
    column::AbstractVector
    refpool::RefPool
    # per top-level column fields (don't need to copy per task when parsing)
    lock::ReentrantLock
    position::Int # transpose column position
    endposition::Int # transpose column ending position
    # options::Parsers.Options

    Column(type::Type, anymissing::Bool, userprovidedtype::Bool, willdrop::Bool, maxstringsize::UInt8, pool::Float64) =
        new(type, anymissing, userprovidedtype, willdrop, maxstringsize, pool)
end

function Column(type::Type)
    T = nonmissingtypeunlessmissingtype(type)
    return Column(type === Missing ? HardMissing : T,
        type >: Missing,
        type !== NeedsTypeDetection,
        false, 0x00, 0.0)
end

# creating a per-task column from top-level column
function Column(x::Column)
    @assert isdefined(x, :lock)
    y = Column(x.type, x.anymissing, x.userprovidedtype, x.willdrop, x.maxstringsize, x.pool)
    y.lock = x.lock # parent and child columns _share_ the same lock
    if isdefined(x, :options)
        y.options = x.options
    end
    if isdefined(x, :refpool)
        # if parent has refpool from sampling, make a copy
        y.refpool = RefPool(copy(x.refpool.refs), x.refpool.lastref)
    end
    # specifically _don't_ copy/re-use x.column; that needs to be allocated fresh per parsing task
    return y
end

struct Context
    transpose::Val
    name::String
    names::Vector{Symbol}
    rowsguess::Int64
    cols::Int
    buf::AbstractVector{UInt8}
    datapos::Int64
    len::Int
    datarow::Int
    options::Parsers.Options
    coloptions::Any # nothing or Parsers.Options []
    columns::Vector{Column}
    pool::Float64
    customtypes::Type
    typemap::Dict{Type, Type}
    stringtype::StringTypes
    limit::Int
    threaded::Bool
    ntasks::Int
    chunkpositions::Vector{Int}
    maxwarnings::Int
    debug::Bool
    streaming::Bool
end

"""
    isvaliddelim(delim)

Whether a character or string is valid for use as a delimiter.
"""
isvaliddelim(delim) = false
isvaliddelim(delim::Char) = delim != '\r' && delim != '\n' && delim != '\0'
isvaliddelim(delim::AbstractString) = all(isvaliddelim, delim)

"""
    checkvaliddelim(delim)

Checks whether a character or string is valid for use as a delimiter.  If
`delim` is `nothing`, it is assumed that the delimiter will be auto-selected.
Throws an error if `delim` is invalid.
"""
function checkvaliddelim(delim)
    delim !== nothing && !isvaliddelim(delim) &&
        throw(ArgumentError("invalid delim argument = '$(escape_string(string(delim)))', "*
                            "the following delimiters are invalid: '\\r', '\\n', '\\0'"))
end


@inline function Context(source,
    # file options
    # header can be a row number, range of rows, or actual string vector
    header,
    normalizenames,
    datarow,
    skipto,
    footerskip,
    transpose,
    comment,
    ignoreemptylines,
    select,
    drop,
    limit,
    threaded,
    tasks,
    lines_to_check,
    # parsing options
    missingstrings,
    missingstring,
    delim,
    ignorerepeated,
    quotechar,
    openquotechar,
    closequotechar,
    escapechar,
    dateformat,
    dateformats,
    decimal,
    truestrings,
    falsestrings,
    # type options
    type,
    types,
    typemap,
    pool,
    lazystrings,
    stringtype,
    strict,
    silencewarnings,
    maxwarnings,
    debug,
    parsingdebug,
    streaming)

    # initial argument validation and adjustment
    @inbounds begin
    !isa(source, IO) && !isa(source, AbstractVector{UInt8}) && !isa(source, Cmd) && !isfile(source) &&
        throw(ArgumentError("\"$source\" is not a valid file"))
    (types !== nothing && any(x->!isconcretetype(x) && !(x isa Union), types isa AbstractDict ? values(types) : types)) && throw(ArgumentError("Non-concrete types passed in `types` keyword argument, please provide concrete types for columns: $types"))
    checkvaliddelim(delim)
    ignorerepeated && delim === nothing && throw(ArgumentError("auto-delimiter detection not supported when `ignorerepeated=true`; please provide delimiter like `delim=','`"))
    if lazystrings && !streaming
        Base.depwarn("`lazystrings` keyword argument is deprecated; use `stringtype=PosLenString` instead", :Context)
        stringtype = PosLenString
    end
    if skipto !== nothing
        if datarow != -1
            @warn "both `skipto` and `datarow` arguments provided, using `skipto`"
        end
        datarow = skipto
    end
    header = (isa(header, Integer) && header == 1 && datarow == 1) ? -1 : header
    isa(header, Integer) && datarow != -1 && (datarow > header || throw(ArgumentError("data row ($datarow) must come after header row ($header)")))
    datarow = datarow == -1 ? (isa(header, Vector{Symbol}) || isa(header, Vector{String}) ? 0 : last(header)) + 1 : datarow # by default, data starts on line after header
    debug && println("header is: $header, datarow computed as: $datarow")
    # getsource will turn any input into a `AbstractVector{UInt8}`
    buf, pos, len = getsource(source)
    if len > 2^42
        throw(ArgumentError("delimited source to parse too large; must be < $(2^42) bytes"))
    end
    # skip over initial BOM character, if present
    pos = consumeBOM(buf, pos)

    oq = something(openquotechar, quotechar) % UInt8
    eq = escapechar % UInt8
    cq = something(closequotechar, quotechar) % UInt8
    trues = truestrings === nothing ? nothing : truestrings
    falses = falsestrings === nothing ? nothing : falsestrings
    sentinel = ((isempty(missingstrings) && missingstring == "") || (length(missingstrings) == 1 && missingstrings[1] == "")) ? missing : isempty(missingstrings) ? [missingstring] : missingstrings

    if delim === nothing
        del = isa(source, AbstractString) && endswith(source, ".tsv") ? UInt8('\t') :
            isa(source, AbstractString) && endswith(source, ".wsv") ? UInt8(' ') :
            UInt8('\n')
    else
        del = (delim isa Char && isascii(delim)) ? delim % UInt8 :
            (sizeof(delim) == 1 && isascii(delim)) ? delim[1] % UInt8 : delim
    end
    cmt = comment === nothing ? nothing : (pointer(comment), sizeof(comment))

    if footerskip > 0 && len > 0
        lastbyte = buf[end]
        endpos = (lastbyte == UInt8('\r') || lastbyte == UInt8('\n')) +
            (lastbyte == UInt8('\n') && buf[end - 1] == UInt8('\r'))
        revlen = skiptorow(ReversedBuf(buf), 1 + endpos, len, oq, eq, cq, cmt, ignoreemptylines, 0, footerskip) - 2
        len -= revlen
        debug && println("adjusted for footerskip, len = $(len + revlen - 1) => $len")
    end

    if !transpose
        # step 1: detect the byte position where the column names start (headerpos)
        # and where the first data row starts (datapos)
        headerpos, datapos = detectheaderdatapos(buf, pos, len, oq, eq, cq, cmt, ignoreemptylines, header, datarow)
        debug && println("headerpos = $headerpos, datapos = $datapos")

        # step 2: detect delimiter (or use given) and detect number of (estimated) rows and columns
        d, rowsguess = detectdelimandguessrows(buf, headerpos, datapos, len, oq, eq, cq, del, cmt, ignoreemptylines)
        debug && println("estimated rows: $rowsguess")
        debug && println("detected delimiter: \"$(escape_string(d isa UInt8 ? string(Char(d)) : d))\"")

        # step 3: build Parsers.Options w/ parsing arguments
        wh1 = d == UInt(' ') ? 0x00 : UInt8(' ')
        wh2 = d == UInt8('\t') ? 0x00 : UInt8('\t')
        if sentinel isa Vector
            for sent in sentinel
                if contains(sent, " ")
                    wh1 = 0x00
                end
                if contains(sent, "\t")
                    wh2 = 0x00
                end
            end
        end
        options = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, d, decimal, trues, falses, dateformat, ignorerepeated, ignoreemptylines, comment, true, parsingdebug, strict, silencewarnings)

        # step 4a: if we're ignoring repeated delimiters, then we ignore any
        # that start a row, so we need to check if we need to adjust our headerpos/datapos
        if ignorerepeated
            if headerpos > 0
                headerpos = Parsers.checkdelim!(buf, headerpos, len, options)
            end
            datapos = Parsers.checkdelim!(buf, datapos, len, options)
        end

        # step 4b: generate or parse column names
        names = detectcolumnnames(buf, headerpos, datapos, len, options, header, normalizenames)
        ncols = length(names)
    else
        # transpose
        d, rowsguess = detectdelimandguessrows(buf, pos, pos, len, oq, eq, cq, del, cmt, ignoreemptylines)
        wh1 = d == UInt(' ') ? 0x00 : UInt8(' ')
        wh2 = d == UInt8('\t') ? 0x00 : UInt8('\t')
        options = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, d, decimal, trues, falses, dateformat, ignorerepeated, ignoreemptylines, comment, true, parsingdebug, strict, silencewarnings)
        rowsguess, names, positions, endpositions = detecttranspose(buf, pos, len, options, header, datarow, normalizenames)
        ncols = length(names)
        datapos = isempty(positions) ? 0 : positions[1]
    end
    debug && println("column names detected: $names")
    debug && println("byte position of data computed at: $datapos")

    # generate initial columns
    # deduce initial column types/flags for parsing based on whether any user-provided types were provided or not
    customtypes = Tuple{}
    if types isa AbstractVector
        length(types) == ncols || throw(ArgumentError("provided `types::AbstractVector` keyword argument doesn't match detected # of columns: `$(length(types)) != $ncols`"))
        columns = Vector{Column}(undef, ncols)
        for i = 1:ncols
            col = Column(types[i])
            columns[i] = col
            if nonstandardtype(col.type) !== Union{}
                customtypes = tupcat(customtypes, nonstandardtype(col.type))
            end
        end
    else
        T = type === nothing ? (streaming ? Union{stringtype, Missing} : NeedsTypeDetection) : type
        columns = Vector{Column}(undef, ncols)
        if types isa AbstractDict
            for i = 1:ncols
                S = getordefault(types, names[i], i, T)
                col = Column(S)
                columns[i] = col
                if nonstandardtype(col.type) !== Union{}
                    customtypes = tupcat(customtypes, nonstandardtype(col.type))
                end
            end
        else
            foreach(i -> columns[i] = Column(T), 1:ncols)
        end
    end
    if transpose
        # set column positions
        for i = 1:ncols
            col = columns[i]
            col.position = positions[i]
            col.endposition = endpositions[i]
        end
    end
    # check for nonstandard types in typemap
    for T in values(typemap)
        if nonstandardtype(T) !== Union{}
            customtypes = tupcat(customtypes, nonstandardtype(T))
        end
    end

    # generate column options if applicable
    if dateformats isa AbstractDict
        coloptions = Vector{Parsers.Options}(undef, ncols)
        for i = 1:ncols
            df = getordefault(dateformats, names[i], i, nothing)
            # devdoc: if we want to add any other column-specific parsing options, this is where we'd at the logic
            # e.g. per-column sentinel, decimal, trues, falses, openquotechar, closequotechar, escapechar, etc.
            if df !== nothing
                coloptions[i] = Parsers.Options(sentinel, wh1, wh2, oq, cq, eq, d, decimal, trues, falses, df, ignorerepeated, ignoreemptylines, comment, true, parsingdebug, strict, silencewarnings)
            else
                coloptions[i] = options
            end
        end
        coloptions = ConcreteEltype(coloptions)
    else
        coloptions = nothing
    end

    # pool keyword
    finalpool = 0.0
    if !streaming
        if pool isa AbstractVector
            length(pool) == ncols || throw(ArgumentError("provided `pool::AbstractVector` keyword argument doesn't match detected # of columns: `$(length(pool)) != $ncols`"))
            for i = 1:ncols
                columns[i].pool = getpool(pool[i])
            end
        elseif pool isa AbstractDict
            for i = 1:ncols
                columns[i].pool = getpool(getordefault(pool, names[i], i, NaN))
            end
        else
            finalpool = getpool(pool)
            for i = 1:ncols
                columns[i].pool = finalpool
            end
        end
    end

    # figure out if we'll drop any columns while parsing
    if select !== nothing && drop !== nothing
        throw(ArgumentError("`select` and `drop` keywords were both provided; only one or the other is allowed"))
    elseif select !== nothing
        if select isa AbstractVector{Int}
            for i = 1:ncols
                i in select || willdrop!(columns, i)
            end
        elseif select isa AbstractVector{Symbol} || select isa AbstractVector{<:AbstractString}
            select = map(Symbol, select)
            for i = 1:ncols
                names[i] in select || willdrop!(columns, i)
            end
        elseif select isa AbstractVector{Bool}
            for i = 1:ncols
                select[i] || willdrop!(columns, i)
            end
        elseif select isa Base.Callable
            for i = 1:ncols
                select(i, names[i]) || willdrop!(columns, i)
            end
        else
            throw(ArgumentError("`select` keyword argument must be an `AbstractVector` of `Int`, `Symbol`, `String`, or `Bool`, or a selector function of the form `(i, name) -> keep::Bool`"))
        end
    elseif drop !== nothing
        if drop isa AbstractVector{Int}
            for i = 1:ncols
                i in drop && willdrop!(columns, i)
            end
        elseif drop isa AbstractVector{Symbol} || drop isa AbstractVector{<:AbstractString}
            drop = map(Symbol, drop)
            for i = 1:ncols
                names[i] in drop && willdrop!(columns, i)
            end
        elseif drop isa AbstractVector{Bool}
            for i = 1:ncols
                drop[i] && willdrop!(columns, i)
            end
        elseif drop isa Base.Callable
            for i = 1:ncols
                drop(i, names[i]) && willdrop!(columns, i)
            end
        else
            throw(ArgumentError("`drop` keyword argument must be an `AbstractVector` of `Int`, `Symbol`, `String`, or `Bool`, or a selector function of the form `(i, name) -> keep::Bool`"))
        end
    end
    debug && println("computed types are: $types")

    # determine if we can use threads while parsing
    limit = something(limit, typemax(Int64))
    minrows = min(limit, rowsguess)
    if threaded === nothing && !streaming && tasks > 1 && !transpose && minrows > (tasks * 5) && (minrows * ncols) >= 5_000
        threaded = true
    elseif threaded === true
        if transpose
            @warn "`threaded=true` not supported on transposed files"
            threaded = false
        elseif tasks == 1
            @warn "`threaded=true` but `tasks=1`; to support threaded parsing, pass `tasks=N` where `N > 1`; `tasks` defaults to `Threads.nthreads()`, so you may consider starting Julia with multiple threads"
            threaded = false
        elseif minrows < (tasks * 5)
            @warn "`threaded=true` but there were not enough estimated rows ($minrows) to justify multithreaded parsing"
            threaded = false
        end
    else
        threaded = false
    end
    # attempt to chunk up a file for multithreaded parsing; there's chance we can't figure out how to accurately chunk
    # due to quoted fields, so threaded might get set to false
    if threaded
        # when limiting w/ multithreaded parsing, we try to guess about where in the file the limit row # will be
        # then adjust our final file len to the end of that row
        # we add some cushion so we hopefully get the limit row correctly w/o shooting past too far and needing to resize! down
        # but we also don't guarantee limit will be exact w/ multithreaded parsing
        origrowsguess = rowsguess
        if limit !== typemax(Int64)
            limitposguess = ceil(Int64, (limit / (origrowsguess * 0.8)) * len)
            newlen = [0, limitposguess, min(limitposguess * 2, len)]
            findrowstarts!(buf, options, newlen, ncols, columns, stringtype, 5)
            len = newlen[2] - 1
            origrowsguess = limit
            debug && println("limiting, adjusting len to $len")
        end
        chunksize = div(len - datapos, tasks)
        chunkpositions = [i == 0 ? datapos : i == tasks ? len : (datapos + chunksize * i) for i = 0:tasks]
        debug && println("initial byte positions before adjusting for start of rows: $chunkpositions")
        avgbytesperrow, successfullychunked = findrowstarts!(buf, options, chunkpositions, ncols, columns, stringtype, lines_to_check)
        if successfullychunked
            origbytesperrow = ((len - datapos) / origrowsguess)
            weightedavgbytesperrow = ceil(Int64, avgbytesperrow * ((tasks - 1) / tasks) + origbytesperrow * (1 / tasks))
            rowsguess = ceil(Int64, ((len - datapos) / weightedavgbytesperrow) * 1.01)
            debug && println("single-threaded estimated rows = $origrowsguess, multi-threaded estimated rows = $rowsguess")
            debug && println("multi-threaded column types sampled as: $columns")
        else
            debug && println("something went wrong chunking up a file for multithreaded parsing, falling back to single-threaded parsing")
            threaded = false
        end
    else
        chunkpositions = EMPTY_INT_ARRAY
    end
    if !threaded && limit < rowsguess
        rowsguess = limit
    end

    end # @inbounds begin
    return Context(
        Val(transpose),
        getname(source),
        names,
        rowsguess,
        ncols,
        buf,
        datapos,
        len,
        datarow,
        options,
        coloptions,
        columns,
        finalpool,
        customtypes,
        typemap,
        stringtype,
        limit,
        threaded,
        tasks,
        chunkpositions,
        maxwarnings,
        debug,
        streaming
    )
end