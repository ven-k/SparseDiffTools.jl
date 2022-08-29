struct ForwardColorHesCache{THS,THC,TI<:Integer,TD,TGF,TGC,TG}
    sparsity::THS
    colors::THC
    ncolors::TI
    D::TD
    buffer::TD
    grad!::TGF
    grad_config::TGC
    G1::TG
    G2::TG
end

function make_hessian_buffers(colorvec, x)
    ncolors = maximum(colorvec)
    D = hcat([float.(i .== colorvec) for i in 1:ncolors]...)
    buffer = similar(D)
    G1 = similar(x)
    G2 = similar(x)
    return (; ncolors, D, buffer, G1, G2)
end

function ForwardColorHesCache(f,
    x::AbstractVector{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing,
    (g!)=(G, x, grad_config) -> ForwardDiff.gradient!(G, f, x, grad_config))
    ncolors, D, buffer, G, G2 = make_hessian_buffers(colorvec, x)
    grad_config = ForwardDiff.GradientConfig(f, x)

    # If user supplied their own gradient function, make sure it has the right
    # signature (i.e. g!(G, x) or g!(G, x, grad_config::ForwardDiff.GradientConfig))
    if !hasmethod(g!, (typeof(G), typeof(G), typeof(grad_config)))
        if !hasmethod(g!, (typeof(G), typeof(G)))
            throw(ArgumentError("Signature of `g!` must be either `g!(G, x)` or `g!(G, x, grad_config::ForwardDiff.GradientConfig)`"))
        end
        # define new method that takes a GradientConfig but doesn't use it
        g1!(G, x, grad_config) = g!(G, x)
    else
        g1! = g!
    end

    if sparsity === nothing
        sparsity = sparse(ones(length(x), length(x)))
    end
    return ForwardColorHesCache(sparsity, colorvec, ncolors, D, buffer, g1!, grad_config, G, G2)
end

function numauto_color_hessian!(H::AbstractMatrix{<:Number},
    f,
    x::AbstractArray{<:Number},
    hes_cache::ForwardColorHesCache;
    safe=true)
    ϵ = cbrt(eps(eltype(x)))
    for j in 1:hes_cache.ncolors
        x .+= ϵ .* @view hes_cache.D[:, j]
        hes_cache.grad!(hes_cache.G2, x, hes_cache.grad_config)
        x .-= 2ϵ .* @view hes_cache.D[:, j]
        hes_cache.grad!(hes_cache.G1, x, hes_cache.grad_config)
        hes_cache.buffer[:, j] .= (hes_cache.G2 .- hes_cache.G1) ./ 2ϵ
        x .+= ϵ .* @view hes_cache.D[:, j] #reset to original value
    end
    ii, jj, vv = findnz(hes_cache.sparsity)
    if safe
        fill!(H, false)
    end
    for (i, j) in zip(ii, jj)
        H[i, j] = hes_cache.buffer[i, hes_cache.colors[j]]
    end
    return H
end

function numauto_color_hessian!(H::AbstractMatrix{<:Number},
    f,
    x::AbstractArray{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing)
    hes_cache = ForwardColorHesCache(f, x, colorvec, sparsity)
    numauto_color_hessian!(H, f, x, hes_cache)
    return H
end

function numauto_color_hessian(f,
    x::AbstractArray{<:Number},
    hes_cache::ForwardColorHesCache)
    H = convert.(eltype(x), hes_cache.sparsity)
    numauto_color_hessian!(H, f, x, hes_cache)
    return H
end

function numauto_color_hessian(f,
    x::AbstractArray{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing)
    hes_cache = ForwardColorHesCache(f, x, colorvec, sparsity)
    H = convert.(eltype(x), hes_cache.sparsity)
    numauto_color_hessian!(H, f, x, hes_cache)
    return H
end



## autoauto_color_hessian

mutable struct ForwardAutoColorHesCache{TS,TC}
    jac_cache::Any
    grad!::Any
    sparsity::TS
    colorvec::TC
end

function ForwardAutoColorHesCache(f,
    x::AbstractVector{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing)

    if sparsity === nothing
        sparsity = sparse(ones(length(x), length(x)))
    end

    jac_cache = nothing
    g! = nothing
    
    return ForwardAutoColorHesCache(jac_cache, g!, sparsity, colorvec)
end

function autoauto_color_hessian!(H::AbstractMatrix{<:Number},
    f,
    x::AbstractArray{<:Number},
    hes_cache::ForwardAutoColorHesCache)

    if hes_cache.jac_cache === nothing
        grad_config = nothing
        g! = function (G, x)
            if grad_config === nothing
                grad_config = ForwardDiff.GradientConfig(f, x)
            end
            ForwardDiff.gradient!(G, f, x, grad_config)
        end
        hes_cache.grad! = g!
        hes_cache.jac_cache = ForwardColorJacCache(hes_cache.grad!, x; hes_cache.colorvec, hes_cache.sparsity)
    end
    forwarddiff_color_jacobian!(H, hes_cache.grad!, x, hes_cache.jac_cache)
end

function autoauto_color_hessian!(H::AbstractMatrix{<:Number},
    f,
    x::AbstractArray{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing)
    hes_cache = ForwardAutoColorHesCache(f, x, colorvec, sparsity)
    autoauto_color_hessian!(H, f, x, hes_cache)
    return H
end

function autoauto_color_hessian(f,
    x::AbstractArray{<:Number},
    hes_cache::ForwardColorHesCache)
    H = convert.(eltype(x), hes_cache.sparsity)
    autoauto_color_hessian!(H, f, x, hes_cache)
    return H
end

function autoauto_color_hessian(f,
    x::AbstractArray{<:Number},
    colorvec::AbstractVector{<:Integer}=eachindex(x),
    sparsity::Union{AbstractMatrix,Nothing}=nothing)
    hes_cache = ForwardAutoColorHesCache(f, x, colorvec, sparsity)
    H = convert.(eltype(x), hes_cache.sparsity)
    autoauto_color_hessian!(H, f, x, hes_cache)
    return H
end