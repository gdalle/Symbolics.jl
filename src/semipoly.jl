import SymbolicUtils.Rewriters: RestartedChain
using DataStructures

export semipolynomial_form, semilinear_form, semiquadratic_form, polynomial_coeffs

"""
$(TYPEDEF)

# Attrtibutes
$(TYPEDFIELDS)
"""
struct SemiMonomial
    "monomial"
    p::Union{S, N} where {S <: Symbolic, N <: Real}
    "coefficient"
    coeff::Any
end

Base.:+(a::SemiMonomial) = a
function Base.:+(a::SemiMonomial, b::SemiMonomial)
    Term(+, [a, b])
end
function Base.:+(m::SemiMonomial, t)
    if istree(t) && operation(t) == (+)
        return Term(+, [unsorted_arguments(t); m])
    end
    Term(+, [m, t])
end
Base.:+(t, m::SemiMonomial) = m + t

Base.:*(m::SemiMonomial) = m
function Base.:*(a::SemiMonomial, b::SemiMonomial)
    SemiMonomial(a.p * b.p, a.coeff * b.coeff)
end
Base.:*(m::SemiMonomial, n::Number) = SemiMonomial(m.p, m.coeff * n)
function Base.:*(m::SemiMonomial, t::Symbolic)
    if istree(t)
        op = operation(t)
        if op == (+)
            args = collect(all_terms(t))
            return Term(+, (m,) .* args)
        elseif op == (*)
            return Term(*, [unsorted_arguments(t); m])
        end
    end
    Term(*, [t, m])
end
Base.:*(t, m::SemiMonomial) = m * t

function Base.:/(a::SemiMonomial, b::SemiMonomial)
    SemiMonomial(a.p / b.p, a.coeff / b.coeff)
end

function Base.:^(base::SemiMonomial, exp::Real)
    SemiMonomial(base.p^exp, base.coeff^exp)
end

# return a dictionary of exponents with respect to variables
pdegrees(::Number) = Dict()
pdegrees(x::Union{Sym, Term}) = Dict(x => 1)
pdegrees(x::Mul) = x.dict
function pdegrees(x::Div)
    num_dict = pdegrees(x.num)
    den_dict = pdegrees(x.den)
    inv_den_dict = Dict(keys(den_dict) .=> map(-, values(den_dict)))
    mergewith(+, num_dict, inv_den_dict)
end
function pdegrees(x::Pow)
    dict = pdegrees(x.base)
    degrees = map(degree -> degree * x.exp, values(dict))
    Dict(keys(dict) .=> degrees)
end

pdegree(::Number) = 0
function pdegree(x::Symbolic)
    degree_dict = pdegrees(x)
    if isempty(degree_dict)
        return 0
    end
    sum(values(degree_dict))
end

issemimonomial(x) = x isa SemiMonomial

# Return true is `m` is a `SemiMonomial`, satisfies the definition of a monomial and
# its degree is less than or equal to `degree_bound`.
# If `m` is a constant about `vars`, return true if `consts = true` and return false if
# `consts = false`.
function isboundedmonomial(m, vars, degree_bound::Real; consts = true)::Bool
    if !(m isa SemiMonomial)
        return false
    end
    degree_dict = pdegrees(m.p)
    if isempty(degree_dict)
        return consts && !has_vars(m.coeff, vars)
    end
    degrees = values(degree_dict)
    for degree in degrees
        if !isinteger(degree) || degree < 0
            return false
        end
    end
    if sum(degrees) > degree_bound
        return false
    end
    !has_vars(m.coeff, vars)
end

# Return true if the degrees of `m` are all 0s and its coefficient is a `Real`.
Base.:isreal(m::SemiMonomial) = m.p isa Number && isone(m.p) && unwrap(m.coeff) isa Real
Base.:isreal(::Symbolic) = false

# Transform `m` to a `Real`.
# Assume `isreal(m) == true`, otherwise calling this function does not make sense.
function Base.:real(m::SemiMonomial)::Real
    if isinteger(m.coeff)
        return Int(m.coeff)
    end
    return m.coeff
end

symtype(m::SemiMonomial) = symtype(m.p)

TermInterface.issym(::SemiMonomial) = true

Base.:nameof(m::SemiMonomial) = Symbol(:SemiMonomial, m.p, m.coeff)

isop(x, op) = istree(x) && operation(x) === op
isop(op) = Base.Fix2(isop, op)

bareterm(x, f, args; kw...) = Term{symtype(x)}(f, args)

function mark_and_exponentiate(expr, vars)
    # Step 1
    # Mark all the interesting variables -- substitute without recursing into nl forms
    expr′ = mark_vars(expr, vars)

    # Step 2
    # Construct and propagate BoundedDegreeMonomial for ^ and * and /

    # does not do fraction simplification
    rules = [@rule (~a::issemimonomial)^(~b::isreal) => (~a)^real(~b)
             @rule (~a::isop(+))^(~b::isreal) => expand((~a)^real(~b))
             @rule (*(~~xs::(xs -> all(issemimonomial, xs)))) => *(~~xs...)
             @rule *(~~xs::(xs -> any(isop(+), xs))) => expand(Term(*, ~~xs))
             @rule (~a::issemimonomial) / (~b::issemimonomial) => (~a) / (~b)]
    expr′ = Postwalk(RestartedChain(rules), similarterm = bareterm)(expr′)
end

function semipolyform_terms(expr, vars)
    expr = mark_and_exponentiate(expr, vars)
    if istree(expr) && operation(expr) == (+)
        args = collect(all_terms(expr))
        return args
    elseif isreal(expr) && iszero(real(expr)) # when `expr` is just a 0
        return []
    else
        return [expr]
    end
end
semipolyform_terms(vars) = Base.Fix2(semipolyform_terms, vars)

"""
$(TYPEDSIGNATURES)

Return true if `expr` contains any variables in `vars`.
"""
function has_vars(expr, vars)::Bool
    if expr in vars
        return true
    elseif istree(expr)
        for arg in unsorted_arguments(expr)
            if has_vars(arg, vars)
                return true
            end
        end
    end
    return false
end

function mark_vars(expr, vars)
    if expr in vars
        return SemiMonomial(expr, 1)
    elseif !istree(expr)
        return SemiMonomial(1, expr)
    end
    op = operation(expr)
    if op === (^) || op == (/)
        args = arguments(expr)
        @assert length(args) == 2
        return Term{symtype(expr)}(op, map(mark_vars(vars), args))
    end
    args = unsorted_arguments(expr)
    if op === (+) || op === (*)
        return Term{symtype(expr)}(op, map(mark_vars(vars), args))
    elseif length(args) == 1
        if op == sqrt
            return mark_vars(args[1]^(1//2), vars)
        elseif linearity_1(op)
            return Term{symtype(expr)}(op, mark_vars(args[1], vars))
        end
    end
    return SemiMonomial(1, expr)
end
mark_vars(vars) = Base.Fix2(mark_vars, vars)

function bifurcate_terms(terms, vars, degree::Real; consts = true)
    # Step 4: Bifurcate polynomial and nonlinear parts:
    monomials = filter(t -> isboundedmonomial(t, vars, degree; consts = consts), terms)
    polys_dict = Dict()
    sizehint!(polys_dict, length(monomials))
    for m in monomials
        if haskey(polys_dict, m.p)
            polys_dict[m.p] += m.coeff
        else
            polys_dict[m.p] = m.coeff
        end
    end
    if length(monomials) == length(terms)
        return polys_dict, 0
    end
    nl_terms = setdiff(terms, monomials)
    nl = cautious_sum(nl_terms)
    return polys_dict, nl
end

function init_semipoly_vars(vars)
    set = OrderedSet(unwrap.(vars))
    @assert length(set) == length(vars) # vars passed to semi-polynomial form must be unique
    set
end

"""
$(TYPEDSIGNATURES)

Returns a tuple of two objects:

1. A dictionary of coefficients keyed by monomials in `vars` upto the given `degree`,
2. A residual expression which has all terms not represented as a product of monomial and a coefficient

`degree` should be a nonnegative number.

If  `consts` is set to `true`, then the returned dictionary will contain
a key `1` and the corresponding value will be the constant term. If `false`, the constant term will be part of the residual.
"""
function semipolynomial_form(expr, vars, degree::Real; consts = true)
    if degree < 0
        @warn "Degree for semi-polynomial form should be ≥ 0"
        return Dict(), expr
    end
    vars = init_semipoly_vars(vars)
    expr = unwrap(expr)
    terms = semipolyform_terms(expr, vars)
    bifurcate_terms(terms, vars, degree; consts = consts)
end

"""
$(TYPEDSIGNATURES)

For every expression in `exprs` computes the semi-polynomial form and
returns a tuple of two objects -- a vector of coefficient dictionaries,
and a vector of residual terms.

If  `consts` is set to `true`, then the returned dictionary will contain
a key `1` and the corresponding value will be the constant term. If `false`, the constant term will be part of the residual.
"""
function semipolynomial_form(exprs::AbstractArray, vars, degree::Real; consts = true)
    if degree < 0
        @warn "Degree for semi-polynomial form should be ≥ 0"
        return fill(Dict(), length), exprs
    end
    vars = init_semipoly_vars(vars)
    exprs = unwrap.(exprs)
    matches = map(semipolyform_terms(vars), exprs)
    tmp = map(match -> bifurcate_terms(match, vars, degree; consts = consts), matches)
    map(first, tmp), map(last, tmp)
end

"""
$(SIGNATURES)

Find coefficients of a polynomial in `vars`.

Returns a tuple of two elements:
1. A dictionary of coefficients keyed by monomials in `vars`
2. A residual expression which is the constant term

(Same as `semipolynomial_form(expr, vars, Inf)`)
"""
polynomial_coeffs(expr, vars) = semipolynomial_form(expr, vars, Inf)

"""
$(TYPEDSIGNATURES)

Returns a tuple of a sparse matrix `A`, and a residual vector `c` such that,
`A * vars + c` is the same as `exprs`.
"""
function semilinear_form(exprs::AbstractArray, vars)
    exprs = unwrap.(exprs)
    vars = init_semipoly_vars(vars)
    ds, nls = semipolynomial_form(exprs, vars, 1; consts = false)

    idxmap = Dict(v=>i for (i, v) in enumerate(vars))

    I = Int[]
    J = Int[]
    V = Num[]

    for (i, d) in enumerate(ds)
        for (k, v) in d
            push!(I, i)
            push!(J, idxmap[k])
            push!(V, v)
        end
    end

    sparse(I,J,V, length(exprs), length(vars)), wrap.(nls)
end

"""
$(TYPEDSIGNATURES)

Returns a tuple of 4 objects:

1. a matrix `A` of dimensions (m x n)
2. a matrix `B` of dimensions (m x (n+1)*n/2)
3. a vector `v2` of length (n+1)*n/2 containing monomials of `vars` upto degree 2 and zero where they are not required.
4. a residual vector `c` of length m.

where `n == length(exprs)` and `m == length(vars)`.


The result is arranged such that, `A * vars + B * v2 + c` is the same as `exprs`.
"""
function semiquadratic_form(exprs, vars)
    exprs = unwrap.(exprs)
    vars = init_semipoly_vars(vars)
    ds, nls = semipolynomial_form(exprs, vars, 2; consts = false)

    idxmap = Dict(v=>i for (i, v) in enumerate(vars))

    m, n = length(exprs), length(vars)
    I1 = Int[]
    J1 = Int[]
    V1 = Num[]

    I2 = Int[]
    J2 = Int[]
    V2 = Num[]

    v2_I = Int[]
    v2_V = Num[]

    for (i, d) in enumerate(ds)
        for (k, v) in d
            if pdegree(k) == 1
                push!(I1, i)
                push!(J1, idxmap[k])
                push!(V1, v)
            elseif pdegree(k) == 2
                push!(I2, i)
                if isop(k, ^)
                    b, e = arguments(k)
                    @assert e == 2
                    q = idxmap[b]
                    j = div(q*(q+1), 2)
                    push!(J2, j) # or div(q*(q-1), 2) + q
                    push!(V2, v)
                else
                    @assert isop(k, *)
                    a, b = unsorted_arguments(k)
                    p, q = extrema((idxmap[a], idxmap[b]))
                    j = div(q*(q-1), 2) + p
                    push!(J2, j)
                    push!(V2, v)
                end
                push!(v2_I, j)
                push!(v2_V, k)
            else
                error("This should never happen")
            end
        end
    end


    #v2 = SparseVector(div(n * (n + 1), 2), v2_I, v2_V) # When it works in the future
    # until then
    v2 = zeros(Num, div(n * (n + 1), 2))
    v2[v2_I] .= v2_V

    tuple(sparse(I1,J1,V1, m, n),
          sparse(I2,J2,V2, m, div(n * (n + 1), 2)),
          v2,
          wrap.(nls))
end

## Utilities

all_terms(x) = istree(x) && operation(x) == (+) ? collect(Iterators.flatten(map(all_terms, unsorted_arguments(x)))) : (x,)

function unwrap_sp(m::SemiMonomial)
    degree_dict = pdegrees(m.p)
    # avoid making negative exponent in `Mul` dict
    positive_dict = Dict()
    negative_dict = Dict()
    for (var, degree) in degree_dict
        if isinteger(degree)
            degree = Int(degree)
        end
        if degree > 0
            positive_dict[var] = degree
        else
            negative_dict[var] = -degree
        end
    end
    m.coeff * Mul(symtype(m.p), 1, positive_dict) / Mul(symtype(m.p), 1, negative_dict)
end
function unwrap_sp(x)
    x = unwrap(x)
    istree(x) ? similarterm(x, operation(x), map(unwrap_sp, unsorted_arguments(x))) : x
end

function cautious_sum(nls)
    if isempty(nls)
        return 0
    end
    sum(unwrap_sp, nls)
end
