# `CSV.readline(io::IO, q='"', e='\\', buf::IOBuffer=IOBuffer())` => `String`
str = "field1,field2,\"quoted \\\"field with \n embedded newline\",field3"
io = IOBuffer(str)
@test CSV.readline(io) == str
io = IOBuffer(str * "\n" * str * "\r\n" * str)
@test CSV.readline(io) == str * "\n"
@test CSV.readline(io) == str * "\r\n"
@test CSV.readline(io) == str

# `CSV.readline(source::CSV.Source)` => `String`
strsource = CSV.Source(IOBuffer(str); header=["col1","col2","col3","col4"])
@test CSV.readline(strsource) == str

# `CSV.readsplitline(io, d=',', q='"', e='\\', buf::IOBuffer=IOBuffer())` => `Vector{String}`
spl = [CSV.RawField("field1", false),
       CSV.RawField("field2", false),
       CSV.RawField("quoted \\\"field with \n embedded newline", true),
       CSV.RawField("field3", false)]
io = IOBuffer(str)
@test CSV.readsplitline(io) == spl
io = IOBuffer(str * "\n" * str * "\r\n" * str)
@test CSV.readsplitline(io) == spl
@test CSV.readsplitline(io) == spl
@test CSV.readsplitline(io) == spl

@testset "empty fields" begin
    str2 = "field1,,\"\",field3,"
    spl2 = [CSV.RawField("field1", false),
           CSV.RawField("", false),
           CSV.RawField("", true),
           CSV.RawField("field3", false),
           CSV.RawField("", false)]
    ioo = IOBuffer(str2)
    @test CSV.readsplitline(ioo) == spl2
end

# `CSV.readsplitline(source::CSV.Source)` => `Vector{String}`
strsource = CSV.Source(IOBuffer(str); header=["col1","col2","col3","col4"])
@test CSV.readsplitline(strsource) == spl

# `CSV.countlines(io::IO, quotechar, escapechar)` => `Int`
@test CSV.countlines(IOBuffer(str)) == 1
@test CSV.countlines(IOBuffer(str * "\n" * str)) == 2

# `CSV.countlines(source::CSV.Source)` => `Int`
intsource = CSV.Source(IOBuffer(str); header=["col1","col2","col3","col4"])
@test CSV.countlines(intsource) == 1

@testset "misformatted CSV lines" begin
    @testset "missing quote" begin
        str1 = "field1,field2,\"quoted \\\"field with \n embedded newline,field3"
        io2 = IOBuffer(str1)
        @test_throws CSV.ParsingException CSV.readsplitline(io2)
    end

    @testset "misplaced quote" begin
        str1 = "fi\"eld1\",field2,\"quoted \\\"field with \n embedded newline\",field3"
        io2 = IOBuffer(str1)
        @test_throws CSV.ParsingException CSV.readsplitline(io2)

        str2 = "field1,field2,\"quoted \\\"field with \n\"\" embedded newline\",field3"
        io2 = IOBuffer(str2)
        @test_throws CSV.ParsingException CSV.readsplitline(io2)

        str3 = "\"field\"1,field2,\"quoted \\\"field with \n embedded newline\",field3"
        io2 = IOBuffer(str3)
        @test_throws CSV.ParsingException CSV.readsplitline(io2)
    end
end
