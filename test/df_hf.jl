@testset "DF-HF Closed-Shell Test" begin
epsilon    =  1.e-6
EHF_test   =      -76.02145513971418
EMP2_test  =      -0.204723138509385
EDCSD_test =      -0.219150244853825
ESVDDCSD_test =   -0.220331906783324
ESVDDCSD_ft_test =-0.219961375476643

try
  using ElemCo.MSystem
  using ElemCo.DFHF
  using ElemCo.DfDump
  using ElemCo.DFCoupledCluster
catch
  #using .MSystem
end

xyz="bohr
     O      0.000000000    0.000000000   -0.130186067
     H1     0.000000000    1.489124508    1.033245507
     H2     0.000000000   -1.489124508    1.033245507"


basis = Dict("ao"=>"cc-pVDZ",
             "jkfit"=>"cc-pvtz-jkfit",
             "mp2fit"=>"cc-pvdz-rifit")

EC = ECInfo(ms=MSys(xyz,basis))

EC.options.scf.direct=true
dfhf(EC)
fcidump = "DF_HF_TEST.FCIDUMP"
EC.options.int.fcidump=fcidump
dfdump(EC)

EHF, EMP2, EDCSD = ECdriver(EC, "dcsd"; fcidump)
@test abs(EHF-EHF_test) < epsilon
@test abs(EMP2-EMP2_test) < epsilon
@test abs(EDCSD-EDCSD_test) < epsilon

rm(fcidump)

ESVDDCSD = calc_svd_dc(EC, "dcsd")
@test abs(ESVDDCSD-ESVDDCSD_test) < epsilon
EC.options.cc.use_full_t2=true
ESVDDCSD_ft = calc_svd_dc(EC, "dcsd")
@test abs(ESVDDCSD_ft-ESVDDCSD_ft_test) < epsilon

end
