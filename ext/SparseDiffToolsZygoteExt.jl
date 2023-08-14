module SparseDiffToolsZygoteExt

using ADTypes, LinearAlgebra, Zygote
import SparseDiffTools: SparseDiffTools, DeivVecTag, AutoDiffVJP
import ForwardDiff: ForwardDiff, Dual, partials
import SciMLOperators: update_coefficients, update_coefficients!
import Setfield: @set!
import Tricks: static_hasmethod

import SparseDiffTools: numback_hesvec!,
    numback_hesvec, autoback_hesvec!, autoback_hesvec, auto_vecjac!, auto_vecjac

### Jac, Hes products

function numback_hesvec!(dy, f, x, v, cache1 = similar(v), cache2 = similar(v))
    g = let f = f
        (dx, x) -> dx .= first(Zygote.gradient(f, x))
    end
    T = eltype(x)
    # Should it be min? max? mean?
    ϵ = sqrt(eps(real(T))) * max(one(real(T)), abs(norm(x)))
    @. x += ϵ * v
    g(cache1, x)
    @. x -= 2ϵ * v
    g(cache2, x)
    @. x += ϵ * v
    @. dy = (cache1 - cache2) / (2ϵ)
end

function numback_hesvec(f, x, v)
    g = x -> first(Zygote.gradient(f, x))
    T = eltype(x)
    # Should it be min? max? mean?
    ϵ = sqrt(eps(real(T))) * max(one(real(T)), abs(norm(x)))
    x += ϵ * v
    gxp = g(x)
    x -= 2ϵ * v
    gxm = g(x)
    (gxp - gxm) / (2ϵ)
end

@inline function _default_autoback_hesvec_cache(x, v)
    T = typeof(ForwardDiff.Tag(DeivVecTag(), eltype(x)))
    return Dual{T, eltype(x), 1}.(x, ForwardDiff.Partials.(tuple.(reshape(v, size(x)))))
end

function autoback_hesvec!(dy, f, x, v, cache1 = _default_autoback_hesvec_cache(x, v),
    cache2 = _default_autoback_hesvec_cache(x, v))
    g = let f = f
        (dx, x) -> dx .= first(Zygote.gradient(f, x))
    end
    # Reset each dual number in cache1 to primal = dual = 1.
    cache1 .= eltype(cache1).(x, ForwardDiff.Partials.(tuple.(reshape(v, size(x)))))
    g(cache2, cache1)
    dy .= partials.(cache2, 1)
end

function autoback_hesvec(f, x, v)
    g = x -> first(Zygote.gradient(f, x))
    y = _default_autoback_hesvec_cache(x, v)
    return ForwardDiff.partials.(g(y), 1)
end

## VecJac products

# VJP methods
function auto_vecjac!(du, f, x, v)
    !static_hasmethod(f, (typeof(x),)) &&
        error("For inplace function use autodiff = AutoFiniteDiff()")
    du .= reshape(SparseDiffTools.auto_vecjac(f, x, v), size(du))
end

function auto_vecjac(f, x, v)
    y, back = Zygote.pullback(f, x)
    return vec(back(reshape(v, size(y)))[1])
end

# overload operator interface
function SparseDiffTools._vecjac(f, u, autodiff::AutoZygote)
    cache = ()
    pullback = Zygote.pullback(f, u)

    return AutoDiffVJP(f, u, cache, autodiff, pullback)
end

function update_coefficients(L::AutoDiffVJP{<:AutoZygote}, u, p, t; VJP_input = nothing)
    VJP_input !== nothing && (@set! L.u = VJP_input)

    @set! L.f = update_coefficients(L.f, L.u, p, t)
    @set! L.pullback = Zygote.pullback(L.f, L.u)
end

function update_coefficients!(L::AutoDiffVJP{<:AutoZygote}, u, p, t; VJP_input = nothing)
    VJP_input !== nothing && copy!(L.u, VJP_input)

    update_coefficients!(L.f, L.u, p, t)
    L.pullback = Zygote.pullback(L.f, L.u)

    return L
end

# Interpret the call as df/du' * v
function (L::AutoDiffVJP{<:AutoZygote})(v, p, t; VJP_input = nothing)
    # ignore VJP_input as pullback was computed in update_coefficients(...)
    y, back = L.pullback
    V = reshape(v, size(y))

    return vec(first(back(V)))
end

# prefer non in-place method
function (L::AutoDiffVJP{<:AutoZygote, IIP, true})(dv, v, p, t;
    VJP_input = nothing) where {IIP}
    # ignore VJP_input as pullback was computed in update_coefficients!(...)

    _dv = L(v, p, t; VJP_input = VJP_input)
    copy!(dv, _dv)
end

function (L::AutoDiffVJP{<:AutoZygote, true, false})(_, _, _, _; VJP_input = nothing)
    error("Zygote requires an out of place method with signature f(u).")
end

end # module
