function skiptofield!(buf, pos, len, options, row, header)
    while row < header
        while pos <= len
            _, code, _, _, tlen = Parsers.xparse(String, buf, pos, len, options)
            pos += tlen
            Parsers.delimited(code) && break
        end
        row += 1
    end
    return row, pos
end

function countfields(buf, pos, len, options)
    rows = 0
    while pos <= len
        _, code, _, _, tlen = Parsers.xparse(String, buf, pos, len, options)
        pos += tlen
        rows += 1
        Parsers.delimited(code) && continue
        (Parsers.newline(code) || pos > len) && break
    end
    return rows, pos
end

function columnname(buf, vpos, vlen, code, options, i)
    if Parsers.sentinel(code)
        return "Column$i"
    elseif Parsers.escapedstring(code)
        return unescape(PointerString(pointer(buf, vpos), vlen), options.e)
    else
        return unsafe_string(pointer(buf, vpos), vlen)
    end
end

function datalayout_transpose(header, buf, pos, len, options, datarow, normalizenames)
    if isa(header, Integer) && header > 0
        # skip to header column to read column names
        row, pos = skiptofield!(buf, pos, len, options, 1, header)
        # io now at start of 1st header cell
        _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
        columnnames = [columnname(buf, vpos, vlen, code, options, 1)]
        pos += tlen
        row, pos = skiptofield!(buf, pos, len, options, header+1, datarow)
        columnpositions = [pos]
        datapos = pos
        rows, pos = countfields(buf, pos, len, options)
        
        # we're now done w/ column 1, if EOF we're done, otherwise, parse column 2's column name
        cols = 1
        while pos <= len
            # skip to header column to read column names
            row, pos = skiptofield!(buf, pos, len, options, 1, header)
            cols += 1
            _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
            push!(columnnames, columnname(buf, vpos, vlen, code, options, cols))
            pos += tlen
            row, pos = skiptofield!(buf, pos, len, options, header+1, datarow)
            push!(columnpositions, pos)
            pos = readline!(buf, pos, len, options)
        end
    elseif isa(header, AbstractRange)
        # column names span several columns
        throw(ArgumentError("not implemented for transposed csv files"))
    elseif pos > len
        # emtpy file, use column names if provided
        datapos = pos
        columnpositions = Int[]
        columnnames = header isa Vector && !isempty(header) ? header : []
        rows = 0
    else
        # column names provided explicitly or should be generated, they don't exist in data
        # skip to datarow
        row, pos = skiptofield!(buf, pos, len, options, 1, datarow)
        # io now at start of 1st data cell
        columnnames = [isa(header, Integer) || isempty(header) ? "Column1" : header[1]]
        columnpositions = [pos]
        datapos = pos
        rows, pos = countfields(buf, pos, len, options)
        # we're now done w/ column 1, if EOF we're done, otherwise, parse column 2's column name
        cols = 1
        while pos <= len
            # skip to datarow column
            row, pos = skiptofield!(buf, pos, len, options, 1, datarow)
            cols += 1
            push!(columnnames, isa(header, Integer) || isempty(header) ? "Column$cols" : header[cols])
            push!(columnpositions, pos)
            pos = readline!(buf, pos, len, options)
        end
    end
    return rows, makeunique(map(x->normalizenames ? normalizename(x) : Symbol(x), columnnames)), columnpositions
end

function datalayout(header::Integer, buf, pos, len, options, datarow, normalizenames, cmt)
    # default header = 1
    if header <= 0
        # no header row in dataset; skip to data to figure out # of columns
        pos = skipto!(buf, pos, len, options, 1, datarow)
        datapos = pos
        fields, pos = readsplitline(buf, pos, len, options, cmt)
        columnnames = [Symbol(:Column, i) for i = eachindex(fields)]
    else
        pos = skipto!(buf, pos, len, options, 1, header)
        fields, pos = readsplitline(buf, pos, len, options, cmt)
        columnnames = makeunique([normalizenames ? normalizename(x) : Symbol(x) for (i, x) in enumerate(fields)])
        if datarow != header+1
            pos = skipto!(buf, pos, len, options, header+1, datarow)
        end
        datapos = pos
    end
    return columnnames, datapos
end

function datalayout(header::AbstractVector{<:Integer}, buf, pos, len, options, datarow, normalizenames, cmt)
    pos = skipto!(buf, pos, len, options, 1, header[1])
    columnnames, pos = readsplitline(buf, pos, len, options, cmt)
    for row = 2:length(header)
        pos = skipto!(buf, pos, len, options, 1, header[row] - header[row-1])
        fields, pos = readsplitline(buf, pos, len, options, cmt)
        for (i, x) in enumerate(fields)
            columnnames[i] *= "_" * x
        end
    end
    if datarow != last(header)+1
        pos = skipto!(buf, pos, len, options, last(header)+1, datarow)
    end
    datapos = pos
    return makeunique([normalizenames ? normalizename(nm) : Symbol(nm) for nm in columnnames]), datapos
end

function datalayout(header::Union{Vector{Symbol}, Vector{String}}, buf, pos, len, options, datarow, normalizenames, cmt)
    pos = skipto!(buf, pos, len, options, 1, datarow)
    datapos = pos
    if pos > len
        columnnames = makeunique([normalizenames ? normalizename(nm) : Symbol(nm) for nm in header])
    else
        fields, pos = readsplitline(buf, pos, len, options, cmt)
        if isempty(header)
            columnnames = [Symbol("Column$i") for i in eachindex(fields)]
        else
            length(header) == length(fields) || throw(ArgumentError("The length of provided header ($(length(header))) doesn't match the number of columns at row $datarow ($(length(fields)))"))
            columnnames = makeunique([normalizenames ? normalizename(nm) : Symbol(nm) for nm in header])
        end
    end
    return columnnames, datapos
end

# readline! is used for implementation of skipto!
function readline!(buf, pos, len, options)
    while pos <= len
        _, code, _, _, tlen = Parsers.xparse(String, buf, pos, len, options)
        pos += tlen
        (Parsers.newline(code) || pos > len) && break
    end
    return pos
end

function skipto!(buf, pos, len, options, cur, dest)
    cur >= dest && return pos
    for _ = 1:(dest-cur)
        pos = readline!(buf, pos, len, options)
    end
    return pos
end

function readsplitline(buf, pos, len, options::Parsers.Options{ignorerepeated}, cmt) where {ignorerepeated}
    vals = String[]
    pos > len && return vals, pos
    col = 1
    while true
        pos = consumecommentedline!(buf, pos, len, cmt)
        if ignorerepeated
            pos = Parsers.checkdelim!(buf, pos, len, options)
        end
        _, code, vpos, vlen, tlen = Parsers.xparse(String, buf, pos, len, options)
        push!(vals, columnname(buf, vpos, vlen, code, options, col))
        pos += tlen
        col += 1
        Parsers.delimited(code) && continue
        (Parsers.newline(code) || pos > len) && break
    end
    return vals, pos
end

consumecommentedline!(buf, pos, len, ::Nothing) = pos
function consumecommentedline!(buf, pos, len, (cmtptr, cmtlen))
    ptr = pointer(buf, pos)
    while (pos + cmtlen - 1) <= len
        match = Parsers.memcmp(ptr, cmtptr, cmtlen)
        if match
            pos += cmtlen
            pos > len && break
            @inbounds b = buf[pos]
            while b != UInt8('\n') && b != UInt8('\r')
                pos += 1
                pos > len && break
                @inbounds b = buf[pos]
            end
            pos += 1
        else
            break
        end
        ptr = pointer(buf, pos)
    end
    return pos
end

struct ByteValueCounter
    counts::Vector{Int64}
    ByteValueCounter() = new(zeros(Int64, 256))
end

function incr!(c::ByteValueCounter, b::UInt8)
    @inbounds c.counts[b] += 1
    return
end

function guessnrows(buf, oq::UInt8, cq::UInt8, eq::UInt8, source, delim, comment, debug)
    len = fs = length(buf)
    pos = 1
    nbytes = 0
    lastbytenewline = false
    nlines = 0
    bvc = ByteValueCounter()
    b = 0x00
    pos = consumecommentedline!(buf, pos, len, comment)
    while pos <= len && nlines < 10
        @inbounds b = buf[pos]
        pos += 1
        nbytes += 1
        if b === oq
            while pos <= len
                @inbounds b = buf[pos]
                pos += 1
                nbytes += 1
                if b === eq
                    if pos > len
                        break
                    elseif eq === cq && buf[pos] !== cq
                        break
                    end
                    @inbounds b = buf[pos]
                    pos += 1
                    nbytes += 1
                elseif b === cq
                    break
                end
            end
        elseif b === UInt8('\n')
            consumecommentedline!(buf, pos, len, comment)
            nlines += 1
            lastbytenewline = true
        elseif b === UInt8('\r')
            pos <= len && buf[pos] == UInt8('\n') && (pos += 1)
            consumecommentedline!(buf, pos, len, comment)
            nlines += 1
            lastbytenewline = true
        else
            lastbytenewline = false
            incr!(bvc, b)
        end
    end
    nlines += !lastbytenewline

     if delim === nothing
        if isa(source, AbstractString) && endswith(source, ".tsv")
            d = UInt8('\t')
        elseif isa(source, AbstractString) && endswith(source, ".wsv")
            d = UInt8(' ')
        elseif nlines > 1
            d = nothing
            for attempted_delim in (UInt8(','), UInt8('\t'), UInt8(' '), UInt8('|'), UInt8(';'), UInt8(':'))
                debug && @show Char(attempted_delim)
                debug && @show bvc.counts[Int(attempted_delim)]
                debug && @show nlines
                cnt = bvc.counts[Int(attempted_delim)]
                if cnt > 0 && cnt % nlines == 0
                    d = attempted_delim
                    break
                end
            end
            d = something(d, UInt8(','))
        else
            d = UInt8(',')
        end
    else
        d = (delim isa Char && isascii(delim)) ? delim % UInt8 :
            (sizeof(delim) == 1 && isascii(delim)) ? delim[1] % UInt8 : delim
    end
    guess = fs / (nbytes / nlines) * 1.25
    rowsguess = isfinite(guess) ? ceil(Int, guess) : 0
    return rowsguess, d
end
