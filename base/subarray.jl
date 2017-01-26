# This file is a part of Julia. License is MIT: http://julialang.org/license

typealias NonSliceIndex Union{Colon, AbstractArray}
typealias ViewIndex Union{Real, NonSliceIndex}
abstract AbstractCartesianIndex{N} # This is a hacky forward declaration for CartesianIndex

# L is true if the view itself supports fast linear indexing
immutable SubArray{T,N,P,I,L} <: AbstractArray{T,N}
    parent::P
    indexes::I
    offset1::Int       # for linear indexing and pointer, only valid when L==true
    stride1::Int       # used only for linear indexing
    function SubArray(parent, indexes, offset1, stride1)
        check_parent_index_match(parent, indexes)
        new(parent, indexes, offset1, stride1)
    end
end
# Compute the linear indexability of the indices, and combine it with the linear indexing of the parent
function SubArray(parent::AbstractArray, indexes::Tuple, dims::Tuple)
    SubArray(linearindexing(viewindexing(indexes), linearindexing(parent)), parent, indexes, dims)
end
function SubArray{P, I, N}(::LinearSlow, parent::P, indexes::I, dims::NTuple{N})
    SubArray{eltype(P), N, P, I, false}(parent, indexes, 0, 0)
end
function SubArray{P, I, N}(::LinearFast, parent::P, indexes::I, dims::NTuple{N})
    # Compute the stride and offset
    stride1 = compute_stride1(parent, indexes)
    SubArray{eltype(P), N, P, I, true}(parent, indexes, compute_offset1(parent, stride1, indexes), stride1)
end

check_parent_index_match{T,N}(parent::AbstractArray{T,N}, indexes::NTuple{N}) = nothing
check_parent_index_match(parent, indexes) = throw(ArgumentError("number of indices ($(length(indexes))) must match the parent dimensionality ($(ndims(parent)))"))

# This computes the linear indexing compatability for a given tuple of indices
viewindexing() = LinearFast()
# Leading scalar indexes simply increase the stride
viewindexing(I::Tuple{Real, Vararg{Any}}) = (@_inline_meta; viewindexing(tail(I)))
# Colons may begin a section which may be followed by any number of Colons
viewindexing(I::Tuple{Colon, Colon, Vararg{Any}}) = (@_inline_meta; viewindexing(tail(I)))
# A UnitRange can follow Colons, but only if all other indices are scalar
viewindexing(I::Tuple{Colon, UnitRange, Vararg{Real}}) = LinearFast()
# In general, ranges are only fast if all other indices are scalar
viewindexing(I::Tuple{Union{Range, Colon}, Vararg{Real}}) = LinearFast()
# All other index combinations are slow
viewindexing(I::Tuple{Vararg{Any}}) = LinearSlow()
# Of course, all other array types are slow
viewindexing(I::Tuple{AbstractArray, Vararg{Any}}) = LinearSlow()

# Simple utilities
size(V::SubArray) = (@_inline_meta; map(n->Int(unsafe_length(n)), indices(V)))

similar(V::SubArray, T::Type, dims::Dims) = similar(V.parent, T, dims)

parent(V::SubArray) = V.parent
parentindexes(V::SubArray) = V.indexes

parent(a::AbstractArray) = a
parentindexes(a::AbstractArray) = ntuple(i->OneTo(size(a,i)), ndims(a))

## SubArray creation
# Drops singleton dimensions (those indexed with a scalar)
function view{T,N}(A::AbstractArray{T,N}, I::Vararg{ViewIndex,N})
    @_inline_meta
    @boundscheck checkbounds(A, I...)
    unsafe_view(A, I...)
end
function view(A::AbstractArray, i::ViewIndex)
    @_inline_meta
    @boundscheck checkbounds(A, i)
    unsafe_view(reshape(A, Val{1}), i)
end
function view{N}(A::AbstractArray, I::Vararg{ViewIndex,N}) # TODO: DEPRECATE FOR #14770
    @_inline_meta
    @boundscheck checkbounds(A, I...)
    unsafe_view(reshape(A, Val{N}), I...)
end

function unsafe_view{T,N}(A::AbstractArray{T,N}, I::Vararg{ViewIndex,N})
    @_inline_meta
    J = to_indexes(I...)
    SubArray(A, J, map(unsafe_length, index_shape(A, J...)))
end
function unsafe_view{T,N}(V::SubArray{T,N}, I::Vararg{ViewIndex,N})
    @_inline_meta
    idxs = reindex(V, V.indexes, to_indexes(I...))
    SubArray(V.parent, idxs, map(unsafe_length, (index_shape(V.parent, idxs...))))
end

# Re-indexing is the heart of a view, transforming A[i, j][x, y] to A[i[x], j[y]]
#
# Recursively look through the heads of the parent- and sub-indexes, considering
# the following cases:
# * Parent index is array  -> re-index that with one or more sub-indexes (one per dimension)
# * Parent index is Colon  -> just use the sub-index as provided
# * Parent index is scalar -> that dimension was dropped, so skip the sub-index and use the index as is

typealias AbstractZeroDimArray{T} AbstractArray{T, 0}
typealias DroppedScalar Union{Real, AbstractCartesianIndex}

reindex(V, ::Tuple{}, ::Tuple{}) = ()

# Skip dropped scalars, so simply peel them off the parent indices and continue
reindex(V, idxs::Tuple{DroppedScalar, Vararg{Any}}, subidxs::Tuple{Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1], reindex(V, tail(idxs), subidxs)...))

# Colons simply pass their subindexes straight through
reindex(V, idxs::Tuple{Colon, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (subidxs[1], reindex(V, tail(idxs), tail(subidxs))...))

# Re-index into parent vectors with one subindex
reindex(V, idxs::Tuple{AbstractVector, Vararg{Any}}, subidxs::Tuple{Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1]], reindex(V, tail(idxs), tail(subidxs))...))

# Parent matrices are re-indexed with two sub-indices
reindex(V, idxs::Tuple{AbstractMatrix, Vararg{Any}}, subidxs::Tuple{Any, Any, Vararg{Any}}) =
    (@_propagate_inbounds_meta; (idxs[1][subidxs[1], subidxs[2]], reindex(V, tail(idxs), tail(tail(subidxs)))...))

# In general, we index N-dimensional parent arrays with N indices
@generated function reindex{T,N}(V, idxs::Tuple{AbstractArray{T,N}, Vararg{Any}}, subidxs::Tuple{Vararg{Any}})
    if length(subidxs.parameters) >= N
        subs = [:(subidxs[$d]) for d in 1:N]
        tail = [:(subidxs[$d]) for d in N+1:length(subidxs.parameters)]
        :(@_propagate_inbounds_meta; (idxs[1][$(subs...)], reindex(V, tail(idxs), ($(tail...),))...))
    else
        :(throw(ArgumentError("cannot re-index $(ndims(V)) dimensional SubArray with fewer than $(ndims(V)) indices\nThis should not occur; please submit a bug report.")))
    end
end

# In general, we simply re-index the parent indices by the provided ones
typealias SlowSubArray{T,N,P,I} SubArray{T,N,P,I,false}
function getindex{T,N}(V::SlowSubArray{T,N}, I::Vararg{Real,N})
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds r = V.parent[reindex(V, V.indexes, to_indexes(I...))...]
    r
end

typealias FastSubArray{T,N,P,I} SubArray{T,N,P,I,true}
function getindex(V::FastSubArray, i::Real)
    @_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + V.stride1*to_index(i)]
    r
end
# We can avoid a multiplication if the first parent index is a Colon or UnitRange
typealias FastContiguousSubArray{T,N,P,I<:Tuple{Union{Colon, UnitRange}, Vararg{Any}}} SubArray{T,N,P,I,true}
function getindex(V::FastContiguousSubArray, i::Real)
    @_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + to_index(i)]
    r
end

function setindex!{T,N}(V::SlowSubArray{T,N}, x, I::Vararg{Real,N})
    @_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds V.parent[reindex(V, V.indexes, to_indexes(I...))...] = x
    V
end
function setindex!(V::FastSubArray, x, i::Real)
    @_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + V.stride1*to_index(i)] = x
    V
end
function setindex!(V::FastContiguousSubArray, x, i::Real)
    @_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + to_index(i)] = x
    V
end

linearindexing{T<:FastSubArray}(::Type{T}) = LinearFast()
linearindexing{T<:SubArray}(::Type{T}) = LinearSlow()

getindex(::Colon, i) = to_index(i)
unsafe_getindex(::Colon, i) = to_index(i)

step(::Colon) = 1
isempty(::Colon) = false
in(::Integer, ::Colon) = true

# Strides are the distance between adjacent elements in a given dimension,
# so they are well-defined even for non-linear memory layouts
strides{T,N,P,I}(V::SubArray{T,N,P,I}) = substrides(V.parent, V.indexes)

substrides(parent, I::Tuple) = substrides(1, parent, 1, I)
substrides(s, parent, dim, ::Tuple{}) = ()
substrides(s, parent, dim, I::Tuple{Real, Vararg{Any}}) = (substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{AbstractCartesianIndex, Vararg{Any}}) = substrides(s, parent, dim, (I[1].I..., tail(I)...))
substrides(s, parent, dim, I::Tuple{Colon, Vararg{Any}}) = (s, substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{Range, Vararg{Any}}) = (s*step(I[1]), substrides(s*size(parent, dim), parent, dim+1, tail(I))...)
substrides(s, parent, dim, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError("strides is invalid for SubArrays with indices of type $(typeof(I[1]))"))

stride(V::SubArray, d::Integer) = d <= ndims(V) ? strides(V)[d] : strides(V)[end] * size(V)[end]

compute_stride1{N}(parent::AbstractArray, I::NTuple{N}) =
    compute_stride1(1, fill_to_length(indices(parent), OneTo(1), Val{N}), I)
compute_stride1(s, inds, I::Tuple{}) = s
compute_stride1(s, inds, I::Tuple{DroppedScalar, Vararg{Any}}) =
    (@_inline_meta; compute_stride1(s*unsafe_length(inds[1]), tail(inds), tail(I)))
compute_stride1(s, inds, I::Tuple{Range, Vararg{Any}}) = s*step(I[1])
compute_stride1(s, inds, I::Tuple{Colon, Vararg{Any}}) = s
compute_stride1(s, inds, I::Tuple{Any, Vararg{Any}}) = throw(ArgumentError("invalid strided index type $(typeof(I[1]))"))

iscontiguous(A::SubArray) = iscontiguous(typeof(A))
iscontiguous{S<:SubArray}(::Type{S}) = false
iscontiguous{F<:FastContiguousSubArray}(::Type{F}) = true

first_index(V::FastSubArray) = V.offset1 + V.stride1 # cached for fast linear SubArrays
function first_index(V::SubArray)
    P, I = parent(V), V.indexes
    s1 = compute_stride1(P, I)
    s1 + compute_offset1(P, s1, I)
end

# Computing the first index simply steps through the indices, accumulating the
# sum of index each multiplied by the parent's stride.
# The running sum is `f`; the cumulative stride product is `s`.
# If the result is one-dimensional and it's a Colon, then linear
# indexing uses the indices along the given dimension. Otherwise
# linear indexing always starts with 1.
compute_offset1(parent, stride1::Integer, I::Tuple) = (@_inline_meta; compute_offset1(parent, stride1, find_extended_dims(I)..., I))
compute_offset1(parent, stride1::Integer, dims::Tuple{Int}, inds::Tuple{Colon}, I::Tuple) = compute_linindex(parent, I) - stride1*first(indices(parent, dims[1]))  # index-preserving case
compute_offset1(parent, stride1::Integer, dims, inds, I::Tuple) = compute_linindex(parent, I) - stride1  # linear indexing starts with 1

function compute_linindex{N}(parent, I::NTuple{N})
    IP = fill_to_length(indices(parent), OneTo(1), Val{N})
    compute_linindex(1, 1, IP, I)
end
function compute_linindex(f, s, IP::Tuple, I::Tuple{Real, Vararg{Any}})
    @_inline_meta
    Δi = I[1]-first(IP[1])
    compute_linindex(f + Δi*s, s*unsafe_length(IP[1]), tail(IP), tail(I))
end
# Just splat out the cartesian indices and continue
compute_linindex(f, s, IP::Tuple, I::Tuple{AbstractCartesianIndex, Vararg{Any}}) =
    (@_inline_meta; compute_linindex(f, s, IP, (I[1].I..., tail(I)...)))
compute_linindex(f, s, IP::Tuple, I::Tuple{Colon, Vararg{Any}}) =
    (@_inline_meta; compute_linindex(f, s*unsafe_length(IP[1]), tail(IP), tail(I)))
function compute_linindex(f, s, IP::Tuple, I::Tuple{Any, Vararg{Any}})
    @_inline_meta
    Δi = first(I[1])-first(IP[1])
    compute_linindex(f + Δi*s, s*unsafe_length(IP[1]), tail(IP), tail(I))
end
compute_linindex(f, s, IP::Tuple, I::Tuple{}) = f

find_extended_dims(I) = (@_inline_meta; _find_extended_dims((), (), 1, I...))
_find_extended_dims(dims, inds, dim) = dims, inds
_find_extended_dims(dims, inds, dim, ::Real, I...) = _find_extended_dims(dims, inds, dim+1, I...)
_find_extended_dims(dims, inds, dim, i1::AbstractCartesianIndex, I...) = _find_extended_dims(dims, inds, dim, i1.I..., I...)
_find_extended_dims(dims, inds, dim, i1, I...) = _find_extended_dims((dims..., dim), (inds..., i1), dim+1, I...)

unsafe_convert{T,N,P,I<:Tuple{Vararg{RangeIndex}}}(::Type{Ptr{T}}, V::SubArray{T,N,P,I}) =
    unsafe_convert(Ptr{T}, V.parent) + (first_index(V)-1)*sizeof(T)

pointer(V::FastSubArray, i::Int) = pointer(V.parent, V.offset1 + V.stride1*i)
pointer(V::FastContiguousSubArray, i::Int) = pointer(V.parent, V.offset1 + i)
pointer(V::SubArray, i::Int) = _pointer(V, i)
_pointer{T}(V::SubArray{T,1}, i::Int) = pointer(V, (i,))
_pointer(V::SubArray, i::Int) = pointer(V, ind2sub(indices(V), i))

function pointer{T,N,P<:Array,I<:Tuple{Vararg{RangeIndex}}}(V::SubArray{T,N,P,I}, is::Tuple{Vararg{Int}})
    index = first_index(V)
    strds = strides(V)
    for d = 1:length(is)
        index += (is[d]-1)*strds[d]
    end
    return pointer(V.parent, index)
end

# indices of the parent are preserved for ::Colon indices, otherwise
# they are taken from the range/vector
# Since bounds-checking is performance-critical and uses
# indices, it's worth optimizing these implementations thoroughly
indices(S::SubArray) = (@_inline_meta; _indices_sub(S, indices(S.parent), S.indexes...))
_indices_sub(S::SubArray, pinds) = ()
function _indices_sub(S::SubArray, pinds, ::Real, I...)
    @_inline_meta
    _indices_sub(S, tail(pinds), I...)
end
function _indices_sub(S::SubArray, pinds, ::Colon, I...)
    @_inline_meta
    (pinds[1], _indices_sub(S, tail(pinds), I...)...)
end
function _indices_sub(S::SubArray, pinds, i1::AbstractArray, I...)
    @_inline_meta
    (unsafe_indices(i1)..., _indices_sub(S, tail(pinds), I...)...)
end

## Compatability
# deprecate?
function parentdims(s::SubArray)
    nd = ndims(s)
    dimindex = Array{Int}(nd)
    sp = strides(s.parent)
    sv = strides(s)
    j = 1
    for i = 1:ndims(s.parent)
        r = s.indexes[i]
        if j <= nd && (isa(r,Union{Colon,Range}) ? sp[i]*step(r) : sp[i]) == sv[j]
            dimindex[j] = i
            j += 1
        end
    end
    dimindex
end

"""
    replace_ref_end!(ex)

Recursively replace occurrences of the symbol :end in a "ref" expression (i.e. A[...]) `ex`
with the appropriate function calls (`endof`, `size` or `trailingsize`). Replacement uses
the closest enclosing ref, so

    A[B[end]]

should transform to

    A[B[endof(B)]]

"""
replace_ref_end!(ex) = replace_ref_end_!(ex, nothing)[1]
# replace_ref_end_!(ex,withex) returns (new ex, whether withex was used)
function replace_ref_end_!(ex, withex)
    used_withex = false
    if isa(ex,Symbol) && ex == :end
        withex === nothing && error("Invalid use of end")
        return withex, true
    elseif isa(ex,Expr)
        if ex.head == :ref
            ex.args[1], used_withex = replace_ref_end_!(ex.args[1],withex)
            S = isa(ex.args[1],Symbol) ? ex.args[1]::Symbol : gensym(:S) # temp var to cache ex.args[1] if needed
            used_S = false # whether we actually need S
            # new :ref, so redefine withex
            nargs = length(ex.args)-1
            if nargs == 0
                return ex, used_withex
            elseif nargs == 1
                # replace with endof(S)
                ex.args[2], used_S = replace_ref_end_!(ex.args[2],:($endof($S)))
            else
                n = 1
                J = endof(ex.args)
                for j = 2:J-1
                    exj, used = replace_ref_end_!(ex.args[j],:($size($S,$n)))
                    used_S |= used
                    ex.args[j] = exj
                    if isa(exj,Expr) && exj.head == :...
                        # splatted object
                        exjs = exj.args[1]
                        n = :($n + length($exjs))
                    elseif isa(n, Expr)
                        # previous expression splatted
                        n = :($n + 1)
                    else
                        # an integer
                        n += 1
                    end
                end
                ex.args[J], used = replace_ref_end_!(ex.args[J],:($trailingsize($S,$n)))
                used_S |= used
            end
            if used_S && S !== ex.args[1]
                S0 = ex.args[1]
                ex.args[1] = S
                ex = Expr(:let, ex, :($S = $S0))
            end
        else
            # recursive search
            for i = eachindex(ex.args)
                ex.args[i], used = replace_ref_end_!(ex.args[i],withex)
                used_withex |= used
            end
        end
    end
    ex, used_withex
end

"""
    @view A[inds...]

Creates a `SubArray` from an indexing expression. This can only be applied directly to a
reference expression (e.g. `@view A[1,2:end]`), and should *not* be used as the target of
an assignment (e.g. `@view(A[1,2:end]) = ...`).
"""
macro view(ex)
    if Meta.isexpr(ex, :ref)
        ex = replace_ref_end!(ex)
        if Meta.isexpr(ex, :ref)
            ex = Expr(:call, view, ex.args...)
        else # ex replaced by let ...; foo[...]; end
            assert(Meta.isexpr(ex, :let) && Meta.isexpr(ex.args[1], :ref))
            ex.args[1] = Expr(:call, view, ex.args[1].args...)
        end
        Expr(:&&, true, esc(ex))
    else
        throw(ArgumentError("Invalid use of @view macro: argument must be a reference expression A[...]."))
    end
end
