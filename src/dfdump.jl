module DfDump
using LinearAlgebra, TensorOperations
using ..ElemCo.ECInfos
using ..ElemCo.ECInts
using ..ElemCo.MSystem
using ..ElemCo.FciDump
using ..ElemCo.TensorTools

export dfdump

function generate_basis(ms::MSys)
  # TODO: use element-specific basis!
  aobasis = lowercase(ms.atoms[1].basis["ao"].name)
  mp2fit = lowercase(ms.atoms[1].basis["mp2fit"].name)
  bao = BasisSet(aobasis,genxyz(ms,bohr=false))
  bfit = BasisSet(mp2fit,genxyz(ms,bohr=false))
  return bao,bfit
end

function generate_integrals(ms::MSys, EC::ECInfo, fdump::FDump, cMO)
  @assert !fdump.uhf # TODO: uhf
  bao,bfit = generate_basis(ms)
  hAO = kinetic(bao) + nuclear(bao)
  fdump.int1 = cMO' * hAO * cMO

  PQ = ERI_2e2c(bfit)
  M = sqrtinvchol(PQ, tol = EC.options.cholesky.thr, verbose = true)
  μνP = ERI_2e3c(bao,bfit)
  @tensoropt μνL[p,q,L] := μνP[p,q,P] * M[P,L]
  μνP = nothing
  M = nothing
  @tensoropt pqL[p,q,L] := cMO[μ,p] * μνL[μ,ν,L] * cMO[ν,q]
  μνL = nothing
  @assert fdump.triang # store only upper triangle
  # <pr|qs> = sum_L pqL[p,q,L] * pqL[r,s,L]
  fdump.int2 = zeros(size(cMO,1),size(cMO,1),(size(cMO,1)+1)*size(cMO,1)÷2)
  for s = 1:size(pqL,1), q = 1:s # only upper triangle
    I = uppertriangular(q,s)
    @tensoropt fdump.int2[:,:,I][p,r] = pqL[:,q,:][p,L] * pqL[:,s,:][r,L]
  end
  fdump.int0 = nuclear_repulsion(ms)
end

""" generate fcidump using df integrals and store in dumpfile """
function dfdump(ms::MSys, EC::ECInfo, cMO, dumpfile = "FCIDUMP")
  println("generating fcidump $dumpfile")
  nelec = guess_nelec(ms)
  fdump = FDump(size(cMO,2), nelec)
  generate_integrals(ms, EC, fdump, cMO)
  println("writing fcidump $dumpfile")
  write_fcidump(fdump, dumpfile, -1.0)  
end

end
