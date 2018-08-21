function Sink(fullpath::Union{AbstractString, IO};
              delim::Char=',',
              quotechar::Char='"',
              escapechar::Char='\\',
              missingstring::AbstractString="",
              dateformat=nothing,
              header::Bool=true,
              colnames::Vector{String}=String[],
              append::Bool=false,
              quotefields::Bool=false)
    delim = delim % UInt8; quotechar = quotechar % UInt8; escapechar = escapechar % UInt8
    dateformat = isa(dateformat, AbstractString) ? Dates.DateFormat(dateformat) : dateformat
    io = IOBuffer()
    options = CSV.Options(delim=delim, quotechar=quotechar, escapechar=escapechar, missingstring=missingstring, dateformat=dateformat)
    !append && header && !isempty(colnames) && writeheaders(io, colnames, options, Val{quotefields})
    return Sink(options, io, fullpath, position(io), !append && header && !isempty(colnames), colnames, length(colnames), append, Val{quotefields})
end

quoted(::Type{Val{true}},  val, q, e, d) =  string(q, replace(val, q=>string(e, q)), q)
quoted(::Type{Val{false}}, val, q, e, d) = (q in val || d in val) ? string(q, replace(val, q=>string(e, q)), q) : val

function writeheaders(io::IOBuffer, h::Vector{String}, options, quotefields)
    cols = length(h)
    q = Char(options.quotechar); e = Char(options.escapechar); d = Char(options.delim)
    for col = 1:cols
        Base.write(io, quoted(quotefields, h[col], q, e, d), ifelse(col == cols, UInt8('\n'), options.delim))
    end
    return nothing
end

# DataStreams interface
Data.streamtypes(::Type{CSV.Sink}) = [Data.Field]
Data.weakrefstrings(::Type{CSV.Sink}) = true

# Constructors
function Sink(sch::Data.Schema, T, append, file::Union{AbstractString, IO}; reference::Vector{UInt8}=UInt8[], kwargs...)
    sink = Sink(file; append=append, colnames=Data.header(sch), kwargs...)
    return sink
end

function Sink(sink, sch::Data.Schema, T, append; reference::Vector{UInt8}=UInt8[])
    sink.append = append
    sink.cols = size(sch, 2)
    !sink.header && !append && writeheaders(sink.io, Data.header(sch), sink.options, sink.quotefields)
    return sink
end

function Data.streamto!(sink::Sink, ::Type{Data.Field}, val, row, col::Int)
    q = Char(sink.options.quotechar); e = Char(sink.options.escapechar); d = Char(sink.options.delim)
    Base.write(sink.io, quoted(sink.quotefields, string(val), q, e, d), ifelse(col == sink.cols, UInt8('\n'), d))
    return nothing
end

function Data.streamto!(sink::Sink, ::Type{Data.Field}, val::Dates.TimeType, row, col::Int)
    v = Dates.format(val, sink.options.dateformat === nothing ? Dates.default_format(typeof(val)) : sink.options.dateformat)
    Base.write(sink.io, v, ifelse(col == sink.cols, UInt8('\n'), sink.options.delim))
    return nothing
end

const EMPTY_UINT8_ARRAY = UInt8[]
function Data.streamto!(sink::Sink, ::Type{Data.Field}, val::Missing, row, col::Int)
    Base.write(sink.io, sink.options.missingcheck ? sink.options.missingstring : EMPTY_UINT8_ARRAY, ifelse(col == sink.cols, UInt8('\n'), sink.options.delim))
    return nothing
end

function Data.close!(sink::CSV.Sink)
    io = isa(sink.fullpath, AbstractString) ? open(sink.fullpath, sink.append ? "a" : "w") : sink.fullpath
    Base.write(io, take!(sink.io))
    isa(sink.fullpath, AbstractString) && close(io)
    return sink
end

"""
`CSV.write(file_or_io::Union{AbstractString,IO}, source::Type{T}, args...; kwargs...)` => `CSV.Sink`

`CSV.write(file_or_io::Union{AbstractString,IO}, source::Data.Source; kwargs...)` => `CSV.Sink`


write a `Data.Source` out to a `file_or_io`.

Positional Arguments:

* `file_or_io`; can be a file name (string) or other `IO` instance
* `source` can be the *type* of `Data.Source`, plus any required `args...`, or an already constructed `Data.Source` can be passsed in directly (2nd method)

Keyword Arguments:

* `delim::Union{Char,UInt8}`; how fields in the file will be delimited; default is `UInt8(',')`
* `quotechar::Union{Char,UInt8}`; the character that indicates a quoted field that may contain the `delim` or newlines; default is `UInt8('"')`
* `escapechar::Union{Char,UInt8}`; the character that escapes a `quotechar` in a quoted field; default is `UInt8('\\')`
* `missingstring::String`; the ascii string that indicates how missing values will be represented in the dataset; default is the empty string `""`
* `dateformat`; how dates/datetimes will be represented in the dataset; default is ISO-8601 `yyyy-mm-ddTHH:MM:SS.s`
* `header::Bool`; whether to write out the column names from `source`
* `colnames::Vector{String}`; a vector of string column names to be used when writing the header row
* `append::Bool`; start writing data at the end of `io`; by default, `io` will be reset to the beginning or overwritten before writing
* `transforms::Dict{Union{String,Int},Function}`; a Dict of transforms to apply to values as they are parsed. Note that a column can be specified by either number or column name.

A few example invocations include:
```julia
# write out a DataFrame `df` to a file name "out.csv" with all defaults, including comma as delimiter
CSV.write("out.csv", df)

# write out a DataFrame, this time as a tab-delimited file
CSV.write("out.csv", df; delim='\t')

# write out a DataFrame, with missing values represented by the string "NA"
CSV.write("out.csv", df; missingstring="NA")

# write out a "header-less" file, with actual data starting on row 1
CSV.write("out.csv", df; header=false)

# write out a DataFrame `df` twice to a file, the resulting file with have twice the # of rows as the DataFrame
# note the usage of the keyword argument `append=true` in the 2nd call
CSV.write("out.csv", df)
CSV.write("out.csv", df; append=true)

# write a DataFrame out to an IOBuffer instead of a file
io = IOBuffer
CSV.write(io, df)

# write the result of an SQLite query out to a comma-delimited file
db = SQLite.DB()
sqlite_source = SQLite.Source(db, "select * from sqlite_table")
CSV.write("sqlite_table.csv", sqlite_source)
```
"""
function write end

function write(file::Union{AbstractString, IO}, ::Type{T}, args...; append::Bool=false, transforms::Dict=Dict{Int,Function}(), kwargs...) where {T}
    sink = Data.stream!(T(args...), CSV.Sink, file; append=append, transforms=transforms, kwargs...)
    return Data.close!(sink)
end
function write(file::Union{AbstractString, IO}, source; append::Bool=false, transforms::Dict=Dict{Int,Function}(), kwargs...)
    sink = Data.stream!(source, CSV.Sink, file; append=append, transforms=transforms, kwargs...)
    return Data.close!(sink)
end

write(sink::Sink, ::Type{T}, args...; append::Bool=false, transforms::Dict=Dict{Int,Function}()) where {T} = (sink = Data.stream!(T(args...), sink; append=append, transforms=transforms); return Data.close!(sink))
write(sink::Sink, source; append::Bool=false, transforms::Dict=Dict{Int,Function}()) = (sink = Data.stream!(source, sink; append=append, transforms=transforms); return Data.close!(sink))
