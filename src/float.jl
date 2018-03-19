const EXPONENTS = [
    1e0,   1e1,   1e2,   1e3,   1e4,   1e5,   1e6,   1e7,   1e8,    1e9,
    1e10,  1e11,  1e12,  1e13,  1e14,  1e15,  1e16,  1e17,  1e18,  1e19,
    1e20,  1e21,  1e22,  1e23,  1e24,  1e25,  1e26,  1e27,  1e28,  1e29,
    1e30,  1e31,  1e32,  1e33,  1e34,  1e35,  1e36,  1e37,  1e38,  1e39,
    1e40,  1e41,  1e42,  1e43,  1e44,  1e45,  1e46,  1e47,  1e48,  1e49,
    1e50,  1e51,  1e52,  1e53,  1e54,  1e55,  1e56,  1e57,  1e58,  1e59,
    1e60,  1e61,  1e62,  1e63,  1e64,  1e65,  1e66,  1e67,  1e68,  1e69,
    1e70,  1e71,  1e72,  1e73,  1e74,  1e75,  1e76,  1e77,  1e78,  1e79,
    1e80,  1e81,  1e82,  1e83,  1e84,  1e85,  1e86,  1e87,  1e88,  1e89,
    1e90,  1e91,  1e92,  1e93,  1e94,  1e95,  1e96,  1e97,  1e98,  1e99,
    1e100, 1e101, 1e102, 1e103, 1e104, 1e105, 1e106, 1e107, 1e108, 1e109,
    1e110, 1e111, 1e112, 1e113, 1e114, 1e115, 1e116, 1e117, 1e118, 1e119,
    1e120, 1e121, 1e122, 1e123, 1e124, 1e125, 1e126, 1e127, 1e128, 1e129,
    1e130, 1e131, 1e132, 1e133, 1e134, 1e135, 1e136, 1e137, 1e138, 1e139,
    1e140, 1e141, 1e142, 1e143, 1e144, 1e145, 1e146, 1e147, 1e148, 1e149,
    1e150, 1e151, 1e152, 1e153, 1e154, 1e155, 1e156, 1e157, 1e158, 1e159,
    1e160, 1e161, 1e162, 1e163, 1e164, 1e165, 1e166, 1e167, 1e168, 1e169,
    1e170, 1e171, 1e172, 1e173, 1e174, 1e175, 1e176, 1e177, 1e178, 1e179,
    1e180, 1e181, 1e182, 1e183, 1e184, 1e185, 1e186, 1e187, 1e188, 1e189,
    1e190, 1e191, 1e192, 1e193, 1e194, 1e195, 1e196, 1e197, 1e198, 1e199,
    1e200, 1e201, 1e202, 1e203, 1e204, 1e205, 1e206, 1e207, 1e208, 1e209,
    1e210, 1e211, 1e212, 1e213, 1e214, 1e215, 1e216, 1e217, 1e218, 1e219,
    1e220, 1e221, 1e222, 1e223, 1e224, 1e225, 1e226, 1e227, 1e228, 1e229,
    1e230, 1e231, 1e232, 1e233, 1e234, 1e235, 1e236, 1e237, 1e238, 1e239,
    1e240, 1e241, 1e242, 1e243, 1e244, 1e245, 1e246, 1e247, 1e248, 1e249,
    1e250, 1e251, 1e252, 1e253, 1e254, 1e255, 1e256, 1e257, 1e258, 1e259,
    1e260, 1e261, 1e262, 1e263, 1e264, 1e265, 1e266, 1e267, 1e268, 1e269,
    1e270, 1e271, 1e272, 1e273, 1e274, 1e275, 1e276, 1e277, 1e278, 1e279,
    1e280, 1e281, 1e282, 1e283, 1e284, 1e285, 1e286, 1e287, 1e288, 1e289,
    1e290, 1e291, 1e292, 1e293, 1e294, 1e295, 1e296, 1e297, 1e298, 1e299,
    1e300, 1e301, 1e302, 1e303, 1e304, 1e305, 1e306, 1e307, 1e308,
]

pow10(exp) = (@inbounds v = EXPONENTS[exp+1]; return v)

maxexponent(::Type{Int16}) = 4
maxexponent(::Type{Int32}) = 38
maxexponent(::Type{Int64}) = 308

minexponent(::Type{Int16}) = -5
minexponent(::Type{Int32}) = -38
minexponent(::Type{Int64}) = -308

inttype(::Type{Float16}) = Int16
inttype(::Type{Float32}) = Int32
inttype(::Type{Float64}) = Int64

const BIGN = UInt8('N')
const LITTLEN = UInt8('n')
const BIGA = UInt8('A')
const LITTLEA = UInt8('a')
const BIGI = UInt8('I')
const LITTLEI = UInt8('i')
const BIGF = UInt8('F')
const LITTLEF = UInt8('f')
const BIGT = UInt8('T')
const LITTLET = UInt8('t')
const BIGY = UInt8('Y')
const LITTLEY = UInt8('y')
const BIGE = UInt8('E')
const LITTLEE = UInt8('e')

ParsingException(::Type{<:AbstractFloat}, exp::Signed, row, col) = ParsingException("error parsing a `$T` value on column $col, row $row; exponent out of range: $exp")

function scale(exp, v::T, frac, row, col) where T
    if exp >= 0
        max_exp = maxexponent(T)
        exp > max_exp && throw(ParsingException(T, exp, row, col))
        if exp > 15
            return Float64(Base.TwicePrecision{Float64}(v) * Base.TwicePrecision{Float64}(pow10(exp)))
        else
            return v * pow10(exp)
        end
    else
        min_exp = minexponent(T)
        if exp < min_exp
            -exp + min_exp > -min_exp && throw(ParsingException(T, exp, row, col))
            return Float64(Base.TwicePrecision{Float64}(v) / Base.TwicePrecision{Float64}(pow10(-exp + min_exp)))
        else
            if exp > 15
                return Float64(Base.TwicePrecision{Float64}(v) / Base.TwicePrecision{Float64}(pow10(-exp)))
            else
                return v / pow10(-exp)
            end
        end
    end
end

function parsefield(io::IO, ::Type{T}, opt::CSV.Options, row, col, state, ifnull::Function) where {T <: Union{Float16, Float32, Float64}}
    mark(io)
    @checknullstart()
    minussign = plussign = false
    if b == MINUS # check for leading '-' or '+'
        minussign = true
        c = peekbyte(io)
        if (NEG_ONE < c < TEN) || c == opt.decimal
            b = readbyte(io)
        end
    elseif b == PLUS
        plussign = true
        c = peekbyte(io)
        if (NEG_ONE < c < TEN) || c == opt.decimal
            b = readbyte(io)
        end
    end
    # float digit parsing
    iT = inttype(T)
    v = zero(iT)
    parseddigits = false
    while NEG_ONE < b < TEN
        parseddigits = true
        # process digits
        v *= iT(10)
        v += iT(b - ZERO)
        eof(io) && (state[] = EOF; result = T(v); @goto done)
        b = readbyte(io)
    end
    # if we didn't get any digits and character isn't leading dot, check for NaN/Inf
    if !parseddigits && b != opt.decimal
        if minussign || plussign # skip sign character, if any
            eof(io) && @goto checknullend
            b = readbyte(io)
        end
        if b == LITTLEN || b == BIGN
            eof(io) && @goto checknullend
            b = readbyte(io)
            (!(b == LITTLEA || b == BIGA) || eof(io)) && (reset(io); b = readbyte(io); @goto checknullend)
            b = readbyte(io)
            !(b == LITTLEN || b == BIGN) && (reset(io); b = readbyte(io); @goto checknullend)
            result = T(NaN)
            eof(io) && (state[] = EOF; @goto done)
            b = readbyte(io)
            @goto checkdone
        elseif b == LITTLEI || b == BIGI
            eof(io) && @goto checknullend
            b = readbyte(io)
            (!(b == LITTLEN || b == BIGN) || eof(io)) && (reset(io); b = readbyte(io); @goto checknullend)
            b = readbyte(io)
            !(b == LITTLEF || b == BIGF) && (reset(io); b = readbyte(io); @goto checknullend)
            result = T(Inf)
            eof(io) && (state[] = EOF; @goto done)
            b = readbyte(io)
            if b == LITTLEI || b == BIGI
                # read the rest of INFINITY
                eof(io) && (state[] = EOF; @goto done)
                b = readbyte(io)
                b == LITTLEN || b == BIGN || @goto checkdone
                eof(io) && (state[] = EOF; @goto done)
                b = readbyte(io)
                b == LITTLEI || b == BIGI || @goto checkdone
                eof(io) && (state[] = EOF; @goto done)
                b = readbyte(io)
                b == LITTLET || b == BIGT || @goto checkdone
                eof(io) && (state[] = EOF; @goto done)
                b = readbyte(io)
                b == LITTLEY || b == BIGY || @goto checkdone
                eof(io) && (state[] = EOF; @goto done)
                b = readbyte(io)
            end
            @goto checkdone
        else
            @goto checknullend
        end
    end
    # parse fractional part
    frac = 0
    result = T(v)
    if b == opt.decimal
        eof(io) && (state[] = EOF; parseddigits ? @goto(done) : @goto(error))
        b = readbyte(io)
    elseif b == LITTLEE || b == BIGE
        @goto parseexp
    else
        @goto checkdone
    end

    while NEG_ONE < b < TEN
        frac += 1
        # process digits
        v *= iT(10)
        v += iT(b - ZERO)
        eof(io) && (state[] = EOF; result = scale(-frac, v, 0, row, col); @goto done)
        b = readbyte(io)
    end
    # parse potential exp
    if b == LITTLEE || b == BIGE
        @label parseexp
        eof(io) && (state[] = EOF; result = scale(-frac, v, 0, row, col); @goto done)
        b = readbyte(io)
        exp = zero(iT)
        negativeexp = false
        if b == MINUS
            negativeexp = true
            b = readbyte(io)
        elseif b == PLUS
            b = readbyte(io)
        end
        parseddigits = false
        while NEG_ONE < b < TEN
            parseddigits = true
            # process digits
            exp *= iT(10)
            exp += iT(b - ZERO)
            eof(io) && (state[] = EOF; result = scale(ifelse(negativeexp, -exp, exp) - frac, v, frac, row, col); @goto done)
            b = readbyte(io)
        end
        result = parseddigits ? scale(ifelse(negativeexp, -exp, exp) - frac, v, frac, row, col) : scale(-frac, v, 0, row, col)
    else
        result = scale(-frac, v, 0, row, col)
    end

    @label checkdone
    @checkdone(done)
    @goto checknullend

    @label checknullend
    @checknullend()
    @goto error

    @label done
    return T(ifelse(minussign, -result, result))

    @label null
    return ifnull(row, col)

    @label error
    throw(ParsingException(T, b, row, col))
end


# (-73.99378204345703, -73.99378204345702)
#  (-73.95227813720703, -73.95227813720702)
#  (-73.98616027832031, -73.98616027832033)
#  (-74.00163269042969, -74.00163269042967)
#  (-73.96940612792969, -73.9694061279297)
#  (-73.96797943115234, -73.96797943115236)
#  (-73.95426940917969, -73.95426940917967)
#  (-73.97286224365234, -73.97286224365236)
#  (-73.99149322509766, -73.99149322509767)
#  (-73.97639465332031, -73.97639465332033)
#  (-73.97297668457031, -73.97297668457033)
#  (-73.98991394042969, -73.98991394042967)
#  (-73.98424530029297, -73.98424530029298)
#  (-73.97872161865234, -73.97872161865236)
#  (-73.99348449707031, -73.99348449707033)
#  (-73.96598815917969, -73.96598815917967)
#  (-73.98743438720703, -73.98743438720702)