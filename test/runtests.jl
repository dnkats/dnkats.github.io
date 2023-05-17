using Test

using LinearAlgebra

try
EC = ECInfo()
catch 
using ElemCo.Utils
using ElemCo.ECInfos
using ElemCo.ECMethods
using ElemCo.TensorTools
using ElemCo.Focks
using ElemCo.CoupledCluster
using ElemCo.FciDump
end

@testset verbose = true "FCIDUMP Calculations" begin

include("h2o.jl")
include("h2o_st1.jl")
include("h2o_cation.jl")

end
