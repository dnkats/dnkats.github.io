""" tensor tools, 
    e.g., access to integrals, load/save intermediates... 
"""
module TensorTools
using LinearAlgebra
using ..ElemCo.ECInfos
using ..ElemCo.FciDump
using ..ElemCo.MyIO

export save, load, mmap, newmmap, closemmap, ints1, ints2, sqrtinvchol, invchol, rotate_eigenvectors_to_real!

function save(EC::ECInfo, fname::String, a::AbstractArray)
  miosave(joinpath(EC.scr, fname*".bin"), a)
end

function load(EC::ECInfo, fname::String)
  return mioload(joinpath(EC.scr, fname*".bin"))
end

# create a new mmap file for writing (overwrites existing file)
# returns a pointer to the file and the mmaped array
function newmmap(EC::ECInfo, fname::String, Type, dims::Tuple{Vararg{Int}})
  return mionewmmap(joinpath(EC.scr, fname*".bin"), Type, dims)
end

function closemmap(EC::ECInfo, file, array)
  mioclosemmap(file, array)
end

# mmap an existing file for reading
# returns a pointer to the file and the mmaped array
function mmap(EC::ECInfo, fname::String)
  return miommap(joinpath(EC.scr, fname*".bin"))
end

"""guess spin of an electron: lowcase α, uppercase β, non-letters skipped.
Returns true for α spin.  Throws an error if cannot decide"""
function isalphaspin(sp1::Char,sp2::Char)
  if isletter(sp1)
    return islowercase(sp1)
  elseif isletter(sp2)
    return islowercase(sp2)
  else
    error("Cannot guess spincase for $sp1 $sp2 . Specify the spincase explicitly!")
  end
end

""" return subset of 1e⁻ integrals according to spaces. The spincase can explicitly
    been given, or will be deduced from upper/lower case of spaces specification. 
"""
function ints1(EC::ECInfo, spaces::String, spincase = nothing)
  sc = spincase
  if isnothing(sc)
    if isalphaspin(spaces[1],spaces[2])
      sc = SCα
    else
      sc = SCβ
    end
  end
  return integ1(EC.fd, sc)[EC.space[spaces[1]],EC.space[spaces[2]]]
end

""" generate set of CartesianIndex for addressing the lhs and 
    a bitmask for the rhs for transforming a triangular index from ':' 
    to two original indices in spaces sp1 and sp2.
    If `reverse`: the cartesian indices are reversed 
"""
function triinds(EC::ECInfo, sp1::AbstractArray{Int}, sp2::AbstractArray{Int}, reverseCartInd = false)
  norb = length(EC.space[':'])
  # triangular index (TODO: save in EC or FDump)
  tripp = [CartesianIndex(i,j) for j in 1:norb for i in 1:j]
  mask = falses(norb,norb)
  mask[sp1,sp2] .= true
  trimask = falses(norb,norb)
  trimask[tripp] .= true
  ci=CartesianIndices((length(sp1),length(sp2)))
  if reverseCartInd
    return CartesianIndex.(reverse.(Tuple.(ci[trimask[sp1,sp2]]))), mask[tripp]
  else
    return ci[trimask[sp1,sp2]], mask[tripp]
  end
end

""" return subset of 2e⁻ integrals according to spaces. The spincase can explicitly
    been given, or will be deduced from upper/lower case of spaces specification.
    if the last two indices are stored as triangular and detri - make them full,
    otherwise return as a triangular cut.
"""
function ints2(EC::ECInfo, spaces::String, spincase = nothing, detri = true)
  if isnothing(spincase)
    second_el_alpha = isalphaspin(spaces[2],spaces[4])
    if isalphaspin(spaces[1],spaces[3])
      if second_el_alpha
        sc = SCα
      else
        sc = SCαβ
      end
    else
      !second_el_alpha || error("Use αβ integrals to get the βα block "*spaces)
      sc = SCβ
    end
  else 
    sc = spincase
  end
  allint = integ2(EC.fd, sc)
  if ndims(allint) == 4
    return allint[EC.space[spaces[1]],EC.space[spaces[2]],EC.space[spaces[3]],EC.space[spaces[4]]]
  elseif detri
    # last two indices as a triangular index, desymmetrize
    @assert ndims(allint) == 3
    out = Array{Float64}(undef,length(EC.space[spaces[1]]),length(EC.space[spaces[2]]),length(EC.space[spaces[3]]),length(EC.space[spaces[4]]))
    cio, maski = triinds(EC,EC.space[spaces[3]],EC.space[spaces[4]])
    out[:,:,cio] = allint[EC.space[spaces[1]],EC.space[spaces[2]],maski]
    cio, maski = triinds(EC,EC.space[spaces[4]],EC.space[spaces[3]],true)
    out[:,:,cio] = permutedims(allint[EC.space[spaces[2]],EC.space[spaces[1]],maski],(2,1,3))
    return out
  else
    cio, maski = triinds(EC,EC.space[spaces[3]],EC.space[spaces[4]])
    return allint[EC.space[spaces[1]],EC.space[spaces[2]],maski]
  end
end

""" return NON-SYMMETRIC (pseudo)sqrt-inverse of a hermitian matrix using cholesky decomposition 
    A^-1 = A^-1 L (A^-1 L)† = M M†
    with A = L L†
    by solving the equation L† M = I (for low-rank: using QR decomposition) 
    returns M
"""
function sqrtinvchol(A::AbstractMatrix; tol = 1e-8, verbose = false)
  CA = cholesky(A, RowMaximum(), check = false, tol = tol)
  if CA.rank < size(A,1)
    if verbose
      redund = size(A,1) - CA.rank
      println("$redund vectors removed using Cholesky decomposition")
    end
    Umat = CA.U[1:CA.rank,:]
  else
    Umat = CA.U
  end
  return (Umat \ Matrix(I,CA.rank,CA.rank))[invperm(CA.p),:]
end

""" return (pseudo)inverse of a hermitian matrix using cholesky decomposition 
    A^-1 = A^-1 L (A^-1 L)† = M M†
    with A = L L†
    by solving the equation L† M = I (for low-rank: using QR decomposition) 
"""
function invchol(A::AbstractMatrix; tol = 1e-8, verbose = false)
  M = sqrtinvchol(A, tol = tol, verbose = verbose)
  return M * M'
end

""" transform complex eigenvectors of a real matrix to a real space 
    such that they block-diagonalize the matrix
"""
function rotate_eigenvectors_to_real!(evecs::AbstractMatrix, evals::AbstractVector)
  npairs = 0
  skip = false
  for i = 1:length(evals)
    if skip 
      skip = false
      continue
    end
    if abs(imag(evals[i])) > 0.0
      println("complex: ",evals[i], " ",i)
      if evals[i] == conj(evals[i+1])
        evecs[:,i] = real.(evecs[:,i])
        @assert  evecs[:,i] == real.(evecs[:,i+1])
        evecs[:,i+1] = imag.(evecs[:,i+1])
        normalize!(evecs[:,i])
        normalize!(evecs[:,i+1])
        npairs += 1
        skip = true
      else
        error("eigenvalue pair expected but not found: conj(",evals[i], ") != ",evals[i+1])
      end
    end
  end
  if npairs > 0
    println("$npairs eigenvector pairs rotated to the real space")
  end
end

end #module
