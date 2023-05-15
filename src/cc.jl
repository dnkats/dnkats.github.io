""" coupled-cluster methods """
module CoupledCluster

try
  using MKL
catch
  #println("MKL package not found, using OpenBLAS.")
end
using LinearAlgebra
#BLAS.set_num_threads(1)
using TensorOperations
# using TSVD
using IterativeSolvers
using Printf
using ..Utils
using ..ECInfos
using ..TensorTools
using ..FciDump
using ..DIIS

export calc_MP2, calc_UMP2, method_name, calc_cc, calc_pertT

include("cc_tests.jl")

""" calculate MP2 energy """

function update_singles(R1, ϵo, ϵv, shift)
  ΔT1 = deepcopy(R1)
  for I ∈ CartesianIndices(ΔT1)
    a,i = Tuple(I)
    ΔT1[I] /= -(ϵv[a] - ϵo[i] + shift)
  end
  return ΔT1
end

function update_singles(EC::ECInfo, R1; spincase::SpinCase=SCα, use_shift=true)
  shift = use_shift ? EC.shifts : 0.0
  if spincase == SCα
    return update_singles(R1, EC.ϵo, EC.ϵv, shift)
  else
    return update_singles(R1, EC.ϵob, EC.ϵvb, shift)
  end
end

function update_doubles(R2, ϵo1, ϵv1, ϵo2, ϵv2, shift, antisymmetrize=false)
  ΔT2 = deepcopy(R2)
  if antisymmetrize
    ΔT2 -= permutedims(R2,(1,2,4,3))
  end
  for I ∈ CartesianIndices(ΔT2)
    a,b,i,j = Tuple(I)
    ΔT2[I] /= -(ϵv1[a] + ϵv2[b] - ϵo1[i] - ϵo2[j] + shift)
  end
  return ΔT2
end

function update_doubles(EC::ECInfo, R2; spincase::SpinCase=SCα, antisymmetrize=false, use_shift=true)
  shift = use_shift ? EC.shiftp : 0.0
  if spincase == SCα
    return update_doubles(R2, EC.ϵo, EC.ϵv, EC.ϵo, EC.ϵv, shift, antisymmetrize)
  elseif spincase == SCβ
    return update_doubles(R2, EC.ϵob, EC.ϵvb, EC.ϵob, EC.ϵvb, shift, antisymmetrize)
  else
    return update_doubles(R2, EC.ϵo, EC.ϵv, EC.ϵob, EC.ϵvb, shift, antisymmetrize)
  end
end

function calc_singles_energy(EC::ECInfo, T1; fock_only=false)
  SP = EC.space
  ET1 = 0.0
  if !fock_only
    @tensoropt ET1 += scalar((2.0*T1[a,i]*T1[b,j]-T1[b,i]*T1[a,j])*ints2(EC,"oovv")[i,j,a,b])
  end
  @tensoropt ET1 += scalar(2.0*T1[a,i] * EC.fock[SP['o'],SP['v']][i,a])
  return ET1
end

function calc_singles_energy(EC::ECInfo, T1a, T1b; fock_only=false)
  SP = EC.space
  ET1 = 0.0
  if !fock_only
    @tensoropt begin
      ET1 += 0.5*scalar((T1a[a,i]*T1a[b,j]-T1a[b,i]*T1a[a,j])*ints2(EC,"oovv")[i,j,a,b])
      ET1 += 0.5*scalar((T1b[a,i]*T1b[b,j]-T1b[b,i]*T1b[a,j])*ints2(EC,"OOVV")[i,j,a,b])
      ET1 += scalar(T1a[a,i]*T1b[b,j]*ints2(EC,"oOvV")[i,j,a,b])
    end
  end
  @tensoropt begin
    ET1 += scalar(T1a[a,i] * EC.fock[SP['o'],SP['v']][i,a])
    ET1 += scalar(T1b[a,i] * EC.fockb[SP['O'],SP['V']][i,a])
  end
  return ET1
end

function calc_doubles_energy(EC::ECInfo, T2)
  @tensoropt ET2 = scalar((2.0*T2[a,b,i,j] - T2[b,a,i,j]) * ints2(EC,"oovv")[i,j,a,b])
  return ET2
end

function calc_doubles_energy(EC::ECInfo, T2a, T2b, T2ab)
  @tensoropt begin
    ET2 = 0.5*scalar(T2a[a,b,i,j] * ints2(EC,"oovv")[i,j,a,b])
    ET2 += 0.5*scalar(T2b[a,b,i,j] * ints2(EC,"OOVV")[i,j,a,b])
    ET2 += scalar(T2ab[a,b,i,j] * ints2(EC,"oOvV")[i,j,a,b])
  end
  return ET2
end

function calc_hylleraas(EC::ECInfo, T1,T2,R1,R2)
  SP = EC.space
  int2 = ints2(EC,"oovv")
  @tensoropt begin
    int2[i,j,a,b] += R2[a,b,i,j]
    ET2 = scalar((2.0*T2[a,b,i,j] - T2[b,a,i,j]) * int2[i,j,a,b])
  end
  if length(T1) > 0
    dfock = load(EC,"dfock"*'o')
    fov = dfock[SP['o'],SP['v']] + EC.fock[SP['o'],SP['v']] # undressed part should be with factor two
    @tensoropt ET1 = scalar((fov[i,a] + 2.0 * R1[a,i])*T1[a,i])
    # ET1 = scalar(2.0*(EC.fock[SP['o'],SP['v']][i,a] + R1[a,i])*T1[a,i])
    # ET1 += scalar((2.0*T1[a,i]*T1[b,j]-T1[b,i]*T1[a,j])*int2[i,j,a,b])
    ET2 += ET1
  end
  return ET2
end

function calc_singles_norm(T1)
  @tensor NormT1 = 2.0*scalar(T1[a,i]*T1[a,i])
  return NormT1
end

function calc_singles_norm(T1a, T1b)
  @tensor begin
    NormT1 = scalar(T1a[a,i]*T1a[a,i])
    NormT1 += scalar(T1b[a,i]*T1b[a,i])
  end
  return NormT1
end

function calc_doubles_norm(T2)
  @tensoropt NormT2 = scalar((2.0*T2[a,b,i,j] - T2[b,a,i,j])*T2[a,b,i,j])
  return NormT2
end

function calc_doubles_norm(T2a, T2b, T2ab)
  @tensoropt begin
    NormT2 = 0.25*scalar(T2a[a,b,i,j]*T2a[a,b,i,j])
    NormT2 += 0.25*scalar(T2b[a,b,i,j]*T2b[a,b,i,j])
    NormT2 += scalar(T2ab[a,b,i,j]*T2ab[a,b,i,j])
  end
  return NormT2
end

""" dress integrals with singles. 
    The singles and orbspaces for first and second electron are T1,o1,v1 and T12,o2,v2, respectively."""
function calc_dressed_ints(EC::ECInfo, T1, T12, o1::Char, v1::Char, o2::Char, v2::Char)
  t1 = time_ns()
  SP = EC.space
  mixed = (o1 != o2)
  # first make half-transformed integrals
  if EC.calc_d_vvvv
    # <a\hat c|bd>
    hd_vvvv = ints2(EC,v1*v2*v1*v2)
    vovv = ints2(EC,v1*o2*v1*v2)
    @tensoropt hd_vvvv[a,c,b,d] -= vovv[a,k,b,d] * T12[c,k]
    vovv = nothing
    save(EC,"hd_"*v1*v2*v1*v2,hd_vvvv)
    hd_vvvv = nothing
    t1 = print_time(EC,t1,"dress hd_"*v1*v2*v1*v2,3)
  end
  # <ik|j \hat l>
  hd_oooo = ints2(EC,o1*o2*o1*o2)
  oovo = ints2(EC,o1*o2*v1*o2)
  @tensoropt hd_oooo[j,i,l,k] += oovo[i,j,d,l] * T12[d,k]
  oovo = nothing
  t1 = print_time(EC,t1,"dress hd_"*o1*o2*o1*o2,3)
  if mixed
  end
  if EC.calc_d_vvoo
    # <a\hat c|j \hat l>
    hd_vvoo = ints2(EC,v1*v2*o1*o2)
    voov = ints2(EC,v1*o2*o1*v2)
    vooo = ints2(EC,v1*o2*o1*o2)
    @tensoropt begin
      vooo[a,k,j,l] += voov[a,k,j,d] * T12[d,l]
      voov = nothing
      hd_vvoo[a,c,j,l] -= vooo[a,k,j,l] * T12[c,k]
      vooo = nothing
    end
    vvov = ints2(EC,v1*v2*o1*v2)
    @tensoropt hd_vvoo[a,c,j,l] += vvov[a,c,j,d] * T12[d,l]
    vvov = nothing
    save(EC,"hd_"*v1*v2*o1*o2,hd_vvoo)
    hd_vvoo = nothing
    t1 = print_time(EC,t1,"dress hd_"*v1*v2*o1*o2,3)
  end
  # <\hat a k| \hat j l)
  hd_vooo = ints2(EC,v1*o2*o1*o2)
  vovo = ints2(EC,v1*o2*v1*o2)
  @tensoropt begin
    hd_vooo[a,k,j,l] -= hd_oooo[i,k,j,l] * T1[a,i]
    hd_vooo[a,k,j,l] += vovo[a,k,b,l] * T1[b,j]
  end
  t1 = print_time(EC,t1,"dress hd_"*v1*o2*o1*o2,3)
  # some of the fully dressing moved here...
  # <ki\hat|dj>
  d_oovo = ints2(EC,o1*o2*v1*o2)
  oovv = ints2(EC,o1*o2*v1*v2)
  @tensoropt d_oovo[k,i,d,j] += oovv[k,i,d,b] * T12[b,j]
  save(EC,"d_"*o1*o2*v1*o2,d_oovo)
  t1 = print_time(EC,t1,"dress d_"*o1*o2*v1*o2,3)
  # <ak\hat|jd>
  d_voov = ints2(EC,v1*o2*o1*v2)
  vovv = ints2(EC,v1*o2*v1*v2)
  @tensoropt begin
    d_voov[a,k,j,d] -= d_oovo[k,i,d,j] * T1[a,i] #todo
    d_voov[a,k,j,d] += vovv[a,k,b,d] * T1[b,j]
  end
  save(EC,"d_"*v1*o2*o1*v2,d_voov)
  t1 = print_time(EC,t1,"dress d_"*v1*o2*o1*v2,3)
  # finish half-dressing
  # <ak|b \hat l>
  hd_vovo = ints2(EC,v1*o2*v1*o2)
  @tensoropt hd_vovo[a,k,b,l] += vovv[a,k,b,d] * T12[d,l]
  vovv = nothing
  t1 = print_time(EC,t1,"dress hd_"*v1*o2*v1*o2,3)
  if EC.calc_d_vvvo
    # <a\hat c|b \hat l>
    hd_vvvo = ints2(EC,v1*v2*v1*o2)
    vvvv = ints2(EC,v1*v2*v1*v2)
    @tensoropt begin
      hd_vvvo[a,c,b,l] -= hd_vovo[a,k,b,l] * T12[c,k]
      hd_vvvo[a,c,b,l] += vvvv[a,c,b,d] * T12[d,l]
    end
    vvvv = nothing
    save(EC,"hd_"*v1*v2*v1*o2,hd_vvvo)
    hd_vvvo = nothing
    t1 = print_time(EC,t1,"dress hd_"*v1*v2*v1*o2,3)
  end

  # fully dressed
  if EC.calc_d_vovv
    # <ak\hat|bd>
    d_vovv = ints2(EC,v1*o2*v1*v2)
    @tensoropt d_vovv[a,k,b,d] -= oovv[i,k,b,d] * T1[a,i]
    save(EC,"d_"*v1*o2*v1*v2,d_vovv)
    t1 = print_time(EC,t1,"dress d_"*v1*o2*v1*v2,3)
  end
  oovv = nothing
  if EC.calc_d_vvvv
    # <ab\hat|cd>
    d_vvvv = load(EC,"hd_"*v1*v2*v1*v2)
    if !EC.calc_d_vovv
      error("for calc_d_vvvv calc_d_vovv has to be True")
    end
    @tensoropt d_vvvv[a,c,b,d] -= d_vovv[c,i,d,b] * T1[a,i] #todo
    d_vovv = nothing
    save(EC,"d_"*v1*v2*v1*v2,d_vvvv)
    d_vvvv = nothing
    t1 = print_time(EC,t1,"dress d_"*v1*v2*v1*v2,3)
  end
  # <ak\hat|bl>
  d_vovo = hd_vovo
  @tensoropt d_vovo[a,k,b,l] -= d_oovo[i,k,b,l] * T1[a,i]
  save(EC,"d_"*v1*o2*v1*o2,d_vovo)
  d_vovo = nothing
  t1 = print_time(EC,t1,"dress d_"*v1*o2*v1*o2,3)
  # <aj\hat|kl>
  d_vooo = hd_vooo
  @tensoropt d_vooo[a,k,j,l] += d_voov[a,k,j,d] * T12[d,l]
  save(EC,"d_"*v1*o2*o1*o2,d_vooo)
  t1 = print_time(EC,t1,"dress d_"*v1*o2*o1*o2,3)
  if EC.calc_d_vvvo
    # <ab\hat|cl>
    d_vvvo = load(EC,"hd_"*v1*v2*v1*o2)
    @tensoropt d_vvvo[a,c,b,l] -= d_voov[c,i,l,b] * T1[a,i] #todo
    save(EC,"d_"*v1*v2*v1*o2,d_vvvo)
    d_vvvo = nothing
    t1 = print_time(EC,t1,"dress d_"*v1*v2*v1*o2,3)
  end
  # <ij\hat|kl>
  d_oooo = hd_oooo
  @tensoropt d_oooo[i,k,j,l] += d_oovo[i,k,b,l] * T1[b,j]
  save(EC,"d_"*o1*o2*o1*o2,d_oooo)
  t1 = print_time(EC,t1,"dress d_"*o1*o2*o1*o2,3)
  if EC.calc_d_vvoo
    if !EC.calc_d_vvvo
      error("for calc_d_vvoo calc_d_vvvo has to be True")
    end
    # <ac\hat|jl>
    d_vvoo = load(EC,"hd_"*v1*v2*o1*o2)
    hd_vvvo = load(EC,"hd_"*v1*v2*v1*o2)
    @tensoropt begin
      d_vvoo[a,c,j,l] += hd_vvvo[a,c,b,l] * T1[b,j]
      hd_vvvo = nothing
      d_vvoo[a,c,j,l] -= d_vooo[c,i,l,j] * T1[a,i] #todo
    end
    save(EC,"d_"*v1*v2*o1*o2,d_vvoo)
    t1 = print_time(EC,t1,"dress d_"*v1*v2*o1*o2,3)
  end
  # dress 1-el part
  d_int1 = deepcopy(integ1(EC.fd))
  dinter = ints1(EC,":"*v1)
  @tensoropt d_int1[:,SP[o1]][p,j] += dinter[p,b] * T1[b,j]
  dinter = d_int1[SP[o1],:]
  @tensoropt d_int1[SP[v1],:][b,p] -= dinter[j,p] * T1[b,j]
  save(EC,"dint1"*o1,d_int1)
  t1 = print_time(EC,t1,"dress int1",3)

  # calc dressed fock
  dfock = d_int1
  @tensoropt begin
    foo[i,j] := 2.0*d_oooo[i,k,j,k] - d_oooo[i,k,k,j]
    fvo[a,i] := 2.0*d_vooo[a,k,i,k] - d_vooo[a,k,k,i]
    fov[i,a] := 2.0*d_oovo[i,k,a,k] - d_oovo[k,i,a,k]
    d_vovo = load(EC,"d_"*v1*o2*v1*o2)
    fvv[a,b] := 2.0*d_vovo[a,k,b,k]
    d_vovo = nothing
    fvv[a,b] -= d_voov[a,k,k,b]
  end
  dfock[SP[o1],SP[o1]] += foo
  dfock[SP[v1],SP[o1]] += fvo
  dfock[SP[o1],SP[v1]] += fov
  dfock[SP[v1],SP[v1]] += fvv

  save(EC,"dfock"*o1,dfock)
  t1 = print_time(EC,t1,"dress fock",3)
end

"""dress integrals with singles"""
function calc_dressed_ints(EC::ECInfo, T1a, T1b=Float64[])
  if length(T1b) == 0
    calc_dressed_ints(EC,T1a,T1a,'o','v','o','v')
  else
    calc_dressed_ints(EC,T1a,T1a,'o','v','o','v')
    calc_dressed_ints(EC,T1b,T1b,'O','V','O','V')
    calc_dressed_ints(EC,T1a,T1b,'o','v','O','V')
  end
end

"""save non-dressed integrals in files instead of dressed integrals"""
function pseudo_dressed_ints(EC::ECInfo)
  t1 = time_ns()
  save(EC,"d_oovo",ints2(EC,"oovo"))
  save(EC,"d_voov",ints2(EC,"voov"))
  if EC.calc_d_vovv
    save(EC,"d_vovv",ints2(EC,"vovv"))
  end
  if EC.calc_d_vvvv
    save(EC,"d_vvvv",ints2(EC,"vvvv"))
  end
  save(EC,"d_vovo",ints2(EC,"vovo"))
  save(EC,"d_vooo",ints2(EC,"vooo"))
  if EC.calc_d_vvvo
    save(EC,"d_vvvo",ints2(EC,"vvvo"))
  end
  save(EC,"d_oooo",ints2(EC,"oooo"))
  if EC.calc_d_vvoo
    save(EC,"d_vvoo",ints2(EC,"vvoo"))
  end
  save(EC,"dint1"*'o',integ1(EC.fd))
  save(EC,"dfock"*'o',EC.fock)
  t1 = print_time(EC,t1,"pseudo-dressing",3)
end

""" Calculate closed-shell MP2 energy and amplitudes. 
    Return (EMp2, T2) """
function calc_MP2(EC::ECInfo)
  T2 = update_doubles(EC,ints2(EC,"vvoo"), use_shift=false)
  EMp2 = calc_doubles_energy(EC,T2)
  T1 = update_singles(EC.fock[EC.space['v'],EC.space['o']],EC.ϵo,EC.ϵv,0.0)
  EMp2 += calc_singles_energy(EC,T1,fock_only=true)
  return EMp2, T2
end

""" Calculate unrestricted MP2 energy and amplitudes. 
    Return (EMp2, T2a, T2b, T2ab)"""
function calc_UMP2(EC::ECInfo, addsingles=true)
  SP = EC.space
  T2a = update_doubles(EC,ints2(EC,"vvoo"), spincase=SCα, antisymmetrize = true, use_shift=false)
  T2b = update_doubles(EC,ints2(EC,"VVOO"), spincase=SCβ, antisymmetrize = true, use_shift=false)
  T2ab = update_doubles(EC,ints2(EC,"vVoO"), spincase=SCαβ, use_shift=false)
  EMp2 = calc_doubles_energy(EC,T2a,T2b,T2ab)
  if addsingles
    T1a = update_singles(EC,EC.fock[SP['v'],SP['o']], spincase=SCα, use_shift=false)
    T1b = update_singles(EC,EC.fockb[SP['V'],SP['O']], spincase=SCβ, use_shift=false)
    EMp2 += calc_singles_energy(EC, T1a, T1b, fock_only = true)
  end
  return EMp2, T2a, T2b, T2ab
end

function method_name(T1, dc = false)
  if dc
    name = "DC"
  else
    name = "CC"
  end
  if length(T1) == 0
    name *= "D"
  else
    name *= "SD"
  end
  return name
end

""" 
calc D^{ij}_{pq} = T^{ij}_{cd} + T^i_c T^j_d +δ_{ik} T^j_d + T^i_c δ_{jl} + δ_{ik} δ_{jl}

return as D[pqij] 

if `scalepp`: D[ppij] elements are scaled by 0.5 (for triangular summation)
"""
function calc_D2(EC::ECInfo, T1, T2, scalepp = false)
  SP = EC.space
  norb = length(SP[':'])
  nocc = length(SP['o'])
  if length(T1) > 0
    D2 = Array{Float64}(undef,norb,norb,nocc,nocc)
  else
    D2 = zeros(norb,norb,nocc,nocc)
  end
  @tensoropt begin
    D2[SP['v'],SP['v'],:,:][a,b,i,j] = T2[a,b,i,j] 
    D2[SP['o'],SP['o'],:,:][i,k,j,l] = Matrix(I,nocc,nocc)[i,j] * Matrix(I,nocc,nocc)[l,k]
  end
  if length(T1) > 0
    @tensoropt begin
      D2[SP['v'],SP['v'],:,:][a,b,i,j] += T1[a,i] * T1[b,j]
      D2[SP['o'],SP['v'],:,:][j,a,i,k] = Matrix(I,nocc,nocc)[i,j] * T1[a,k]
      D2[SP['v'],SP['o'],:,:][a,j,k,i] = Matrix(I,nocc,nocc)[i,j] * T1[a,k]
    end
  end
  if scalepp
    diagindx = [CartesianIndex(i,i) for i in 1:norb]
    D2[diagindx,:,:] *= 0.5
  end
  return D2
end

"""
Calculate CCSD or DCSD residual.
"""
function calc_ccsd_resid(EC::ECInfo, T1,T2,dc)
  t1 = time_ns()
  SP = EC.space
  if length(T1) > 0
    calc_dressed_ints(EC,T1)
    t1 = print_time(EC,t1,"dressing",2)
  else
    pseudo_dressed_ints(EC)
  end
  @tensor T2t[a,b,i,j] := 2.0 * T2[a,b,i,j] - T2[b,a,i,j]
  dfock = load(EC,"dfock"*'o')
  if length(T1) > 0
    if EC.use_kext
      dint1 = load(EC,"dint1"*'o')
      R1 = dint1[SP['v'],SP['o']]
    else
      R1 = dfock[SP['v'],SP['o']]
      if !EC.calc_d_vovv
        error("for not use_kext calc_d_vovv has to be True")
      end
      int2 = load(EC,"d_vovv")
      @tensoropt R1[a,i] += int2[a,k,b,c] * T2t[c,b,k,i]
    end
    int2 = load(EC,"d_oovo")
    fov = dfock[SP['o'],SP['v']]
    @tensoropt begin
      R1[a,i] += T2t[a,b,i,j] * fov[j,b]
      R1[a,i] -= int2[k,j,c,i] * T2t[c,a,k,j]
    end
    t1 = print_time(EC,t1,"singles residual",2)
  else
    R1 = Float64[]
  end

  # <ab|ij>
  if EC.use_kext
    R2 = zeros((length(SP['v']),length(SP['v']),length(SP['o']),length(SP['o'])))
  else
    if !EC.calc_d_vvoo
      error("for not use_kext calc_d_vvoo has to be True")
    end
    R2 = load(EC,"d_vvoo")
  end
  t1 = print_time(EC,t1,"<ab|ij>",2)
  klcd = ints2(EC,"oovv")
  t1 = print_time(EC,t1,"<kl|cd>",2)
  int2 = load(EC,"d_oooo")
  if !dc
    # I_klij = <kl|ij>+<kl|cd>T^ij_cd
    @tensoropt int2[k,l,i,j] += klcd[k,l,c,d] * T2[c,d,i,j]
  end
  # I_klij T^kl_ab
  @tensoropt R2[a,b,i,j] += int2[k,l,i,j] * T2[a,b,k,l]
  t1 = print_time(EC,t1,"I_klij T^kl_ab",2)
  # <kl|cd>\tilde T^ki_ca \tilde T^lj_db
  @tensoropt R2[a,b,i,j] += klcd[k,l,c,d] * T2t[c,a,k,i] * T2t[d,b,l,j]
  t1 = print_time(EC,t1,"<kl|cd> tT^ki_ca tT^lj_db",2)
  if EC.use_kext
    int2 = integ2(EC.fd)
    if ndims(int2) == 4
      if EC.triangular_kext
        trioo = [CartesianIndex(i,j) for j in 1:length(SP['o']) for i in 1:j]
        D2 = calc_D2(EC, T1, T2)[:,:,trioo]
        # <pq|rs> D^ij_rs
        @tensoropt R2pqx[p,r,x] := int2[p,r,q,s] * D2[q,s,x]
        D2 = nothing
        norb = length(SP[':'])
        nocc = length(SP['o'])
        Rpqoo = Array{Float64}(undef,norb,norb,nocc,nocc)
        Rpqoo[:,:,trioo] = R2pqx
        trioor = CartesianIndex.(reverse.(Tuple.(trioo)))
        @tensor Rpqoo[:,:,trioor][p,q,x] = R2pqx[q,p,x]
        R2pqx = nothing
        @tensor R2pq[a,b,i,j] := Rpqoo[a,b,i,j]
        Rpqoo = nothing
      else
        D2 = calc_D2(EC, T1, T2)
        # <pq|rs> D^ij_rs
        @tensoropt R2pq[p,r,i,j] := int2[p,r,q,s] * D2[q,s,i,j]
        D2 = nothing
      end
    else
      # last two indices of integrals are stored as upper triangular 
      tripp = [CartesianIndex(i,j) for j in 1:length(SP[':']) for i in 1:j]
      D2 = calc_D2(EC, T1, T2, true)[tripp,:,:]
      # <pq|rs> D^ij_rs
      @tensoropt rR2pq[p,r,i,j] := int2[p,r,x] * D2[x,i,j]
      D2 = nothing
      # symmetrize R
      @tensoropt R2pq[p,r,i,j] := rR2pq[p,r,i,j] + rR2pq[r,p,j,i]
    end
    R2 += R2pq[SP['v'],SP['v'],:,:]
    if length(T1) > 0
      @tensoropt begin
        R2[a,b,i,j] -= R2pq[SP['o'],SP['v'],:,:][k,b,i,j] * T1[a,k]
        R2[a,b,i,j] -= R2pq[SP['v'],SP['o'],:,:][a,k,i,j] * T1[b,k]
        R2[a,b,i,j] += R2pq[SP['o'],SP['o'],:,:][k,l,i,j] * T1[a,k] * T1[b,l]
        # singles residual contributions
        R1[a,i] +=  2.0 * R2pq[SP['v'],SP['o'],:,:][a,k,i,k] - R2pq[SP['v'],SP['o'],:,:][a,k,k,i]
        x1[k,i] := 2.0 * R2pq[SP['o'],SP['o'],:,:][k,l,i,l] - R2pq[SP['o'],SP['o'],:,:][k,l,l,i]
        R1[a,i] -= x1[k,i] * T1[a,k]
      end
    end
    x1 = nothing
    R2pq = nothing
    t1 = print_time(EC,t1,"kext",2)
  else
    if !EC.calc_d_vvvv
      error("for not use_kext calc_d_vvvv has to be True")
    end
    int2 = load(EC,"d_vvvv")
    # <ab|cd> T^ij_cd
    @tensoropt R2[a,b,i,j] += int2[a,b,c,d] * T2[c,d,i,j]
    t1 = print_time(EC,t1,"<ab|cd> T^ij_cd",2)
  end
  if !dc
    # <kl|cd> T^kj_ad T^il_cb
    @tensoropt R2[a,b,i,j] += klcd[k,l,c,d] * T2[a,d,k,j] * T2[c,b,i,l]
    t1 = print_time(EC,t1,"<kl|cd> T^kj_ad T^il_cb",2)
  end

  fac = dc ? 0.5 : 1.0
  # x_ad = f_ad - <kl|cd> \tilde T^kl_ca
  # x_ki = f_ki + <kl|cd> \tilde T^il_cd
  xad = dfock[SP['v'],SP['v']]
  xki = dfock[SP['o'],SP['o']]
  @tensoropt begin
    xad[a,d] -= fac * klcd[k,l,c,d] * T2t[c,a,k,l]
    xki[k,i] += fac * klcd[k,l,c,d] * T2t[c,d,i,l]
  end
  t1 = print_time(EC,t1,"xad, xki",2)

  # terms for P(ia;jb)
  @tensoropt begin
    # x_ad T^ij_db
    R2r[a,b,i,j] := xad[a,d] * T2[d,b,i,j]
    # -x_ki T^kj_ab
    R2r[a,b,i,j] -= xki[k,i] * T2[a,b,k,j]
  end
  t1 = print_time(EC,t1,"x_ad T^ij_db -x_ki T^kj_ab",2)
  int2 = load(EC,"d_voov")
  # <ak|ic> \tilde T^kj_cb
  @tensoropt R2r[a,b,i,j] += int2[a,k,i,c] * T2t[c,b,k,j]
  t1 = print_time(EC,t1,"<ak|ic> tT^kj_cb",2)
  if !dc
    # -<kl|cd> T^ki_da (T^lj_cb - T^lj_bc)
    T2t -= T2
    @tensoropt R2r[a,b,i,j] -= klcd[k,l,c,d] * T2[d,a,k,i] * T2t[c,b,l,j]
    t1 = print_time(EC,t1,"-<kl|cd> T^ki_da (T^lj_cb - T^lj_bc)",2)
  end
  int2 = load(EC,"d_vovo")
  @tensoropt begin
    # -<ka|ic> T^kj_cb
    R2r[a,b,i,j] -= int2[a,k,c,i] * T2[c,b,k,j]
    # -<kb|ic> T^kj_ac
    R2r[a,b,i,j] -= int2[b,k,c,i] * T2[a,c,k,j]
    t1 = print_time(EC,t1,"-<ka|ic> T^kj_cb -<kb|ic> T^kj_ac",2)

    R2[a,b,i,j] += R2r[a,b,i,j] + R2r[b,a,j,i]
  end
  t1 = print_time(EC,t1,"P(ia;jb)",2)

  return R1,R2
end
"""
Calculate (T) correction for CCSD
"""
function calc_pertT(EC::ECInfo, T1,T2; save_t3 = false)
  # <ab|ck>
  abck = ints2(EC,"vvvo")
  # <ia|jk>
  iajk = ints2(EC,"ovoo")
  # <ij|ab>
  ijab = ints2(EC,"oovv")
  nocc = length(EC.space['o'])
  nvir = length(EC.space['v'])
  ϵo = EC.ϵo
  ϵv = EC.ϵv
  Enb3 = 0.0
  IntX = zeros(nvir,nocc)
  if save_t3
    t3file, T3 = newmmap(EC,"T3abcijk",Float64,(nvir,nvir,nvir,uppertriangular(nocc,nocc,nocc)))
  end
  for k = 1:nocc 
    for j = 1:k
      prefac = (j == k) ? 1.0 : 2.0
      for i = 1:j
        fac = prefac 
        if i == j 
          if j == k
            continue
          end 
          fac = 1.0
        end
        @tensoropt begin
          Kijk[a,b,c] := T2[:,:,i,j][a,d] * abck[:,:,:,k][d,c,b]
          Kijk[a,b,c] += T2[:,:,j,i][b,d] * abck[:,:,:,k][d,c,a]
          Kijk[a,b,c] += T2[:,:,i,k][a,d] * abck[:,:,:,j][d,b,c]
          Kijk[a,b,c] += T2[:,:,k,i][c,d] * abck[:,:,:,j][d,b,a]
          Kijk[a,b,c] += T2[:,:,j,k][b,d] * abck[:,:,:,i][d,a,c]
          Kijk[a,b,c] += T2[:,:,k,j][c,d] * abck[:,:,:,i][d,a,b]

          Kijk[a,b,c] -= T2[:,:,:,i][b,a,l] * iajk[:,:,j,k][l,c]
          Kijk[a,b,c] -= T2[:,:,:,j][a,b,l] * iajk[:,:,i,k][l,c]
          Kijk[a,b,c] -= T2[:,:,:,i][c,a,l] * iajk[:,:,k,j][l,b]
          Kijk[a,b,c] -= T2[:,:,:,k][a,c,l] * iajk[:,:,i,j][l,b]
          Kijk[a,b,c] -= T2[:,:,:,j][c,b,l] * iajk[:,:,k,i][l,a]
          Kijk[a,b,c] -= T2[:,:,:,k][b,c,l] * iajk[:,:,j,i][l,a]
        end
        if save_t3
          ijk = uppertriangular(i,j,k)
          T3[:,:,:,ijk] = Kijk
          for abc ∈ CartesianIndices(Kijk)
            a,b,c = Tuple(abc)
            T3[abc,ijk] /= ϵo[i] + ϵo[j] + ϵo[k] - ϵv[a] - ϵv[b] - ϵv[c]
          end
        end
        @tensoropt  X[a,b,c] := 4.0*Kijk[a,b,c] - 2.0*Kijk[a,c,b] - 2.0*Kijk[c,b,a] - 2.0*Kijk[b,a,c] + Kijk[c,a,b] + Kijk[b,c,a]
        for abc ∈ CartesianIndices(X)
          a,b,c = Tuple(abc)
          X[abc] /= ϵo[i] + ϵo[j] + ϵo[k] - ϵv[a] - ϵv[b] - ϵv[c]
        end

        @tensoropt Enb3 += fac * scalar(Kijk[a,b,c] * X[a,b,c])
      
        # julia 1.9 r1: cannot use @tensoropt begin/end here, since 
        # IntX[:,j] overwrites IntX[:,i] if j == i
        @tensoropt IntX[:,i][a] += fac * X[a,b,c] * ijab[j,k,:,:][b,c]
        @tensoropt IntX[:,j][b] += fac * X[a,b,c] * ijab[i,k,:,:][a,c]
        @tensoropt IntX[:,k][c] += fac * X[a,b,c] * ijab[i,j,:,:][a,b]
      end 
    end
  end
  if save_t3
    closemmap(EC,t3file,T3)
  end
  # singles contribution
  @tensoropt En3 = scalar(T1[a,i] * IntX[a,i])
  En3 += Enb3
  return En3, Enb3
end

"""
Calculate coupled cluster amplitudes.

If length(T1) is 0 on input, no singles will be calculated.
If dc: calculate distinguishable cluster.
"""
function calc_cc(EC::ECInfo, T1, T2, dc = false)
  println(method_name(T1,dc))
  diis = Diis(EC.scr)

  println("Iter     SqNorm      Energy      DE          Res         Time")
  NormR1 = 0.0
  NormT1 = 0.0
  NormT2 = 0.0
  R1 = Float64[]
  Eh = 0.0
  t0 = time_ns()
  for it in 1:EC.maxit
    t1 = time_ns()
    R1, R2 = calc_ccsd_resid(EC,T1,T2,dc)
    t1 = print_time(EC,t1,"residual",2)
    NormT2 = calc_doubles_norm(T2)
    NormR2 = calc_doubles_norm(R2)
    Eh = calc_hylleraas(EC,T1,T2,R1,R2)
    T2 += update_doubles(EC,R2)
    if length(T1) == 0
      T2, = perform(diis,[T2],[R2])
      En = 0.0
    else
      NormT1 = calc_singles_norm(T1)
      NormR1 = calc_singles_norm(R1)
      T1 += update_singles(EC,R1)
      T1,T2 = perform(diis,[T1,T2],[R1,R2])
      En = calc_singles_energy(EC, T1)
    end
    En += calc_doubles_energy(EC,T2)
    ΔE = En - Eh  
    NormR = NormR1 + NormR2
    NormT = 1.0 + NormT1 + NormT2
    tt = (time_ns() - t0)/10^9
    @printf "%3i %12.8f %12.8f %12.8f %10.2e %8.2f \n" it NormT Eh ΔE NormR tt
    if NormR < EC.thr
      break
    end
  end
  println()
  @printf "Sq.Norm of T1: %12.8f Sq.Norm of T2: %12.8f \n" NormT1 NormT2
  println()

  return Eh,T1,T2
end




#Charlotte start
""" calculate DC-CCSDT"""
function calc_ccsdt(EC::ECInfo, T1, T2, useT3 = false, cc3 = false)
  calc_integrals_decomposition(EC)
  if useT3
    calc_triples_decomposition(EC)
  else
    # calc_dressed_3idx(EC,zeros(size(T1)))
    calc_dressed_3idx(EC,T1)
    calc_triples_decomposition_without_triples(EC,T2)
  end
  if cc3
    println("CC3")
  else
    println("DC-CCSDT")
  end
  diis = Diis(EC.scr)

  println("Iter     SqNorm      Energy      DE          Res         Time")
  NormR1 = 0.0
  NormT1 = 0.0
  NormT2 = 0.0
  NormT3 = 0.0
  R1 = Float64[]
  Eh = 0.0
  t0 = time_ns()
  for it in 1:EC.maxit
    t1 = time_ns()
    #get dressed integrals
    calc_dressed_3idx(EC,T1)
    # test_dressed_ints(EC,T1) #DEBUG
    t1 = print_time(EC,t1,"dressed 3-idx integrals",2)
    R1, R2 = calc_ccsd_resid(EC,T1,T2,false)
    t1 = print_time(EC,t1,"ccsd residual",2)
    R1, R2 = add_to_singles_and_doubles_residuals(EC,R1,R2)
    t1 = print_time(EC,t1,"R1(T3) and R2(T3)",2)
    calc_triples_residuals(EC, T1, T2, cc3)
    t1 = print_time(EC,t1,"R3",2)
    NormT1 = calc_singles_norm(T1)
    NormT2 = calc_doubles_norm(T2)
    T3 = load(EC,"T3_XYZ")
    NormT3 = calc_triples_norm(T3)
    NormR1 = calc_singles_norm(R1)
    NormR2 = calc_doubles_norm(R2)
    R3 = load(EC,"R3_decomp")
    NormR3 = calc_triples_norm(R3)
    Eh = calc_hylleraas(EC,T1,T2,R1,R2)
    T1 += update_singles(EC,R1)
    T2 += update_doubles(EC,R2)
    T3 += update_triples(EC,R3)
    T1,T2,T3 = perform(diis,[T1,T2,T3],[R1,R2,R3])
    save(EC,"T3_XYZ",T3)
    En = calc_singles_energy(EC, T1)
    En += calc_doubles_energy(EC,T2)
    ΔE = En - Eh
    NormR = NormR1 + NormR2 + NormR3
    NormT = 1.0 + NormT1 + NormT2 + NormT3
    tt = (time_ns() - t0)/10^9
    @printf "%3i %12.8f %12.8f %12.8f %10.2e %8.2f \n" it NormT Eh ΔE NormR tt
    if NormR < EC.thr
      break
    end
  end
  println()
  @printf "Sq.Norm of T1: %12.8f Sq.Norm of T2: %12.8f Sq.Norm of T3: %12.8f \n" NormT1 NormT2 NormT3
  println()
  
  return Eh,T1,T2
end


"""
generate end-of-block indices for auxiliary basis
"""
function get_endauxblks(naux, blocksize = 100)
  nauxblks = naux ÷ blocksize
  if nauxblks == 0 || naux - nauxblks*blocksize > 0.5*blocksize
    nauxblks += 1
  end
  endauxblks = [ (i == nauxblks) ? naux : i*blocksize for i in 1:nauxblks ]
  return endauxblks
end

"""
calculate dressed integrals for 3-index integrals
"""
function calc_dressed_3idx(EC,T1)
  pqPfile, pqP = mmap(EC, "pqP")
  # println(size(pqP))
  SP = EC.space
  nP = size(pqP,3)
  nocc = length(SP['o'])
  nvirt = length(SP['v'])
  # create mmaps for dressed integrals
  ovPfile, ovP = newmmap(EC,"d_ovP",Float64,(nocc,nvirt,nP))
  voPfile, voP = newmmap(EC,"d_voP",Float64,(nvirt,nocc,nP))
  ooPfile, ooP = newmmap(EC,"d_ooP",Float64,(nocc,nocc,nP))
  vvPfile, vvP = newmmap(EC,"d_vvP",Float64,(nvirt,nvirt,nP))

  PBlks = get_endauxblks(nP)
  sP = 1 # start index of each block
  for eP in PBlks # end index of each block
    P = sP:eP
    ovP[:,:,P] = pqP[SP['o'],SP['v'],P]
    vvP[:,:,P] = pqP[SP['v'],SP['v'],P]
    @tensoropt vvP[:,:,P][a,b,P] -= T1[a,i] * ovP[:,:,P][i,b,P]
    voP[:,:,P] = pqP[SP['v'],SP['o'],P]
    @tensoropt voP[:,:,P][a,i,P] += T1[b,i] * vvP[:,:,P][a,b,P]
    ooP[:,:,P] = pqP[SP['o'],SP['o'],P]
    @tensoropt voP[:,:,P][a,i,P] -= T1[a,j] * ooP[:,:,P][j,i,P]
    @tensoropt ooP[:,:,P][i,j,P] += T1[b,j] * ovP[:,:,P][i,b,P]
    sP = eP + 1
  end
  closemmap(EC,ovPfile,ovP)
  closemmap(EC,voPfile,voP)
  closemmap(EC,ooPfile,ooP)
  closemmap(EC,vvPfile,vvP)
  close(pqPfile)
end

function update_triples(EC,R3, use_shift = true)
  shift = use_shift ? EC.shiftt : 0.0
  ΔT3 = deepcopy(R3)
  ϵX = load(EC,"epsilonX")
  for I ∈ CartesianIndices(ΔT3)
    X,Y,Z = Tuple(I)
    ΔT3[I] /= (ϵX[X] + ϵX[Y] + ϵX[Z] + shift)
  end
  return ΔT3
end

"""
  calculate `simple` norm of triples (without contravariant!)
"""
function calc_triples_norm(T3)
  @tensoropt NormT3 = scalar(T3[X,Y,Z] * T3[X,Y,Z])
  return NormT3
end

function add_to_singles_and_doubles_residuals(EC,R1,R2)
  SP = EC.space
  ooPfile, ooP = mmap(EC,"d_ooP")
  ovPfile, ovP = mmap(EC,"d_ovP")
  Txyz = load(EC,"T3_XYZ")
  
  U = load(EC,"UvoX")
  # println(size(U))

  @tensoropt Boo[i,j,P,X] := ovP[i,a,P] * U[a,j,X]
  @tensoropt A[P,X] := Boo[i,i,P,X] 
  @tensoropt BBU[Z,d,j] := (ovP[j,c,P] * ovP[k,d,P]) * U[c,k,Z]
  @tensoropt R1[a,i] += U[a,i,X] *(Txyz[X,Y,Z] *( 2.0*A[P,Y] * A[P,Z] - Boo[j,k,P,Z] * Boo[k,j,P,Y] ))
  @tensoropt R1[a,i] -= U[a,j,Y] *( 2.0*Boo[j,i,P,X]*(Txyz[X,Y,Z] * A[P,Z]) - Txyz[X,Y,Z] *(U[d,i,X]*BBU[Z,d,j] ))

  BBU = nothing

  @tensoropt Bov[i,a,P,X] := ooP[j,i,P] * U[a,j,X]
  vvPfile, vvP = mmap(EC,"d_vvP")
  @tensoropt Bvo[a,i,P,X] := vvP[a,b,P] * U[b,i,X]
  close(vvPfile)
  vvP = nothing
  dfock = load(EC,"dfock"*'o')
  fov = dfock[SP['o'],SP['v']]
  # R2[abij] = RR2[abij] + RR2[baji]  
  @tensoropt RR2[a,b,i,j] := U[a,i,X] * (U[b,j,Y] * (Txyz[X,Y,Z] * (fov[k,c]*U[c,k,Z])) - (Txyz[X,Y,Z] * U[b,k,Z])* (fov[k,c]*U[c,j,Y]))
  @tensoropt RR2[a,b,i,j] += 2.0*U[b,j,Y] * ((Bvo[a,i,P,Z] - Bov[i,a,P,Z])*(Txyz[X,Y,Z] * A[P,X]))
  @tensoropt RR2[a,b,i,j] += (Bov[i,a,P,Z]  - Bvo[a,i,P,Z])*(Boo[k,j,P,Y] * (Txyz[X,Y,Z] * U[b,k,X]))
  @tensoropt RR2[a,b,i,j] -= U[b,j,Z] * (Txyz[X,Y,Z] * (Bvo[a,k,P,X] * Boo[k,i,P,Y] - U[a,k,Y] * (Bov[i,c,P,X] * ovP[k,c,P])))
  @tensoropt R2[a,b,i,j] += RR2[a,b,i,j] + RR2[b,a,j,i]
  close(ovPfile)
  close(ooPfile)

  return R1,R2
end

"""
  decompose (pq|rs) as (pq|P)(P|rs)
"""
function calc_integrals_decomposition(EC::ECInfo)
  pqrs = permutedims(ints2(EC,"::::",SCα),(1,3,2,4))
  n = size(pqrs,1)
  B, S, Bt = svd(reshape(pqrs, (n^2,n^2)))
  # display(S)
  pqrs = nothing

  naux1 = 0
  for s in S
    if s > EC.choltol
      naux1 += 1
    else
      break
    end
  end
  #println(naux1)
  
  #get integral decomposition
  pqP = B[:,1:naux1].*sqrt.(S[1:naux1]')
  save(EC, "pqP", reshape(pqP, (n,n,naux1)))
  #B_comparison = pqP * pqP'
  #println( B_comparison ≈ reshape(pqrs, (n^2,n^2)) )
end

"""
  eigen decompose symmetric doubles T2[ai,bj] matrix: 
  T^ij_ab = U^iX_a * S_XY * U^jY_b δ_XY
  return U^iX_a for S > tol
"""
function eigen_decompose(T2mat, nvirt, nocc, tol = 1e-6)
  Sval, U = eigen(Symmetric(-T2mat))
  naux = 0
  for s in Sval
    if -s < tol
      break
    end
    naux += 1
  end
  # display(Sval[1:naux])
  # println(naux)
  return reshape(U[:,1:naux], (nvirt,nocc,naux))
end

"""
  decompose A as U^iX_a * S * Vt
  return U^iX_a for S > tol
"""
function svd_decompose(Amat, nvirt, nocc, tol = 1e-6)
  U, S, = svd(Amat)
  # display(S)
  naux = 0
  for s in S
    if s > tol
      naux += 1
    else
      break
    end
  end
  # display(S[1:naux])
  println("SVD-basis size: ",naux)
  return reshape(U[:,1:naux], (nvirt,nocc,naux))
end

"""
  iteratively decompose A as U^iX_a * S * Vt
  return U^iX_a for first naux S
"""
function iter_svd_decompose(Amat, nvirt, nocc, naux)
  # U, S2, Vt = tsvd(Amat, naux )
  # UaiX = reshape(U[:,1:naux], (nvirt,nocc,naux))
  # U = nothing
  # S2 = nothing
  # Vt = nothing
  S2, L = svdl(Amat, nsv = naux )
  # display(S2[1:naux])
  return reshape(L.P[:,1:naux], (nvirt,nocc,naux))
  # display(UaiX)
end

""" 
  diagonalize ϵv - ϵo transformed with UaiX (for update)
  return eigenvalues and rotated UaiX
"""
function rotate_U2pseudocanonical(EC::ECInfo, UaiX)
  SP = EC.space
  nocc = length(SP['o'])
  nvirt = length(SP['v'])
  UaiX2 = deepcopy(UaiX)
  for a in 1:nvirt
    for i in 1:nocc
      UaiX2[a,i,:] *= EC.ϵv[a] - EC.ϵo[i]
    end
  end

  @tensoropt Fdiff[X,Y] := UaiX[a,i,X] * UaiX2[a,i,Y]
  diagFdiff = eigen(Symmetric(Fdiff))

  @tensoropt UaiX2[a,i,Y] = diagFdiff.vectors[X,Y] * UaiX[a,i,X]
  return diagFdiff.values, UaiX2
end

"""
  decompose T^ijk_abc as U^iX_a * U^jY_b * U^kZ_c * T_XYZ
  compute T^i_aXY and decompose D^ij_ab = (T^i_aXY T^j_bXY) to get U^iX_a
"""
function calc_triples_decomposition_without_triples(EC::ECInfo, T2)
  println("T^ijk_abc-free-decomposition")
  nocc = length(EC.space['o'])
  nvirt = length(EC.space['v'])

  # first approx for U^iX_a from doubles decomposition
  tol2 = EC.ampsvdtol*0.01
  UaiX = svd_decompose(reshape(permutedims(T2,(1,3,2,4)), (nocc*nvirt, nocc*nvirt)), nvirt, nocc, tol2)
  ϵX,UaiX = rotate_U2pseudocanonical(EC, UaiX)
  D2 = calc_4idx_T3T3_XY(EC, T2, UaiX, ϵX) 
  UaiX = svd_decompose(reshape(D2, (nocc*nvirt, nocc*nvirt)), nvirt, nocc, EC.ampsvdtol^2)
  # UaiX = eigen_decompose(reshape(D2, (nocc*nvirt, nocc*nvirt)), nvirt, nocc, EC.ampsvdtol^2)
  ϵX,UaiX = rotate_U2pseudocanonical(EC, UaiX)
  save(EC, "epsilonX", ϵX)
  #display(UaiX)
  naux = length(ϵX)
  save(EC,"UvoX",UaiX)
  # TODO: calc starting guess for T3_XYZ from T2 and UvoX
  save(EC,"T3_XYZ",zeros(naux,naux,naux))
end

"""
  decompose T^ijk_abs as U^iX_a * U^jY_b * U^kZ_c * T_XYZ
"""
function calc_triples_decomposition(EC::ECInfo)
  println("T^ijk_abc-decomposition")
  use_svd = true 
  nocc = length(EC.space['o'])
  nvirt = length(EC.space['v'])

  Triples_Amplitudes = zeros(nvirt,nocc,nvirt,nocc,nvirt,nocc)
  t3file, T3 = mmap(EC, "T3abcijk")
  trippp = [CartesianIndex(i,j,k) for k in 1:nocc for j in 1:k for i in 1:j]
  for ijk in axes(T3,4)
    i,j,k = Tuple(trippp[ijk])                                            #trippp is giving the indices according to the joint index ijk as a tuple
    Triples_Amplitudes[:,i,:,j,:,k] = T3[:,:,:,ijk]
    Triples_Amplitudes[:,j,:,i,:,k] = permutedims(T3[:,:,:,ijk],(2,1,3))
    Triples_Amplitudes[:,i,:,k,:,j] = permutedims(T3[:,:,:,ijk],(1,3,2))
    Triples_Amplitudes[:,k,:,j,:,i] = permutedims(T3[:,:,:,ijk],(3,2,1))
    Triples_Amplitudes[:,j,:,k,:,i] = permutedims(T3[:,:,:,ijk],(2,3,1))
    Triples_Amplitudes[:,k,:,i,:,j] = permutedims(T3[:,:,:,ijk],(3,1,2))
  end
  close(t3file)
  if use_svd
    UaiX = svd_decompose(reshape(Triples_Amplitudes, (nocc*nvirt, nocc*nocc*nvirt*nvirt)), nvirt, nocc, EC.ampsvdtol)
  else
    naux = nvirt * 2 
    UaiX = iter_svd_decompose(reshape(Triples_Amplitudes, (nocc*nvirt, nocc*nocc*nvirt*nvirt)), nvirt, nocc, naux)
  end
  ϵX,UaiX = rotate_U2pseudocanonical(EC, UaiX)
  save(EC, "epsilonX", ϵX)
  #display(UaiX)
  save(EC,"UvoX",UaiX)

  @tensoropt begin
    T3_decomp_starting_guess[X,Y,Z] := (((Triples_Amplitudes[a,i,b,j,c,k] * UaiX[a,i,X]) * UaiX[b,j,Y]) * UaiX[c,k,Z])
  end
  save(EC,"T3_XYZ",T3_decomp_starting_guess)
  #display(T3_decomp_starting_guess)

  # @tensoropt begin
  #  T3_decomp_check[a,i,b,j,c,k] := T3_decomp_starting_guess[X,Y,Z] * UaiX2[a,i,X] * UaiX2[b,j,Y] * UaiX2[c,k,Z]
  # end
  # test_calc_pertT_from_T3(EC,T3_decomp_check)
end

"""
  calculate D^ij_ab = T^i_aXY T^j_bXY using half-decomposed perturbative triple amplitudes 
  T^i_aXY from T2 (and UvoX)
"""
function calc_4idx_T3T3_XY(EC::ECInfo, T2, UvoX, ϵX)
  voPfile, voP = mmap(EC,"d_voP")
  ooPfile, ooP = mmap(EC,"d_ooP")
  vvPfile, vvP = mmap(EC,"d_vvP")

  @tensoropt TXai[X,a,i] := UvoX[b,j,X] * T2[a,b,i,j]
  @tensoropt dU[P,X] := voP[c,k,P] * UvoX[c,k,X]

  @tensoropt RR[X,Y,a,i] := ((TXai[X,c,j] * vvP[b,c,P]) * UvoX[b,j,Y]) * voP[a,i,P]
  @tensoropt RR[X,Y,a,i] -= ((TXai[X,b,l] * ooP[l,j,P]) * UvoX[b,j,Y]) * voP[a,i,P]
  @tensoropt ddUv[a,d,X] := vvP[a,d,P] * dU[P,X]
  @tensoropt ddUo[l,j,X] := ooP[l,j,P] * dU[P,X]
  @tensoropt RR[X,Y,a,i] += ddUv[a,d,X] * TXai[Y,d,i]
  @tensoropt RR[X,Y,a,i] -= ddUo[l,i,X] * TXai[Y,a,l]
  TXai = nothing
  dU = nothing
  @tensoropt ddUU[X,Y,d,l] := ddUv[a,d,X] * UvoX[a,l,Y]
  @tensoropt ddUU[X,Y,d,l] -= ddUo[l,i,X] * UvoX[d,i,Y]
  @tensoropt RR[X,Y,a,i] += ddUU[X,Y,d,l] * T2[a,d,i,l]
  ddUU = nothing
  @tensoropt R[X,Y,a,i] := RR[X,Y,a,i] + RR[Y,X,a,i]
  RR = nothing
  close(voPfile)
  close(ooPfile)
  close(vvPfile)
  for I ∈ CartesianIndices(R)
    X,Y,a,i = Tuple(I)
    R[I] /= -(ϵX[X] + ϵX[Y] + EC.ϵv[a] - EC.ϵo[i])
  end
  nocc = length(EC.space['o'])
  naux = length(ϵX)
  # @tensoropt T3_decomp_check[a,i,b,j,c,k] := R[X,Y,a,i] * UvoX[c,k,X] * UvoX[b,j,Y]
  # for i = 1:nocc
  #   T3_decomp_check[:,i,:,i,:,i] .= 0.0
  # end
  # test_calc_pertT_from_T3(EC,T3_decomp_check)
  @tensoropt D2[a,i,b,j] := R[X,Y,a,i] * R[X,Y,b,j]
  # remove T^iii contributions from D2
  UU = zeros(naux,naux,nocc)
  for i = 1:nocc
    @tensoropt UU[:,:,i][X,Y] = UvoX[:,i,:][a,X] * UvoX[:,i,:][a,Y]
  end
  TUU4i = zeros(naux,naux,size(UvoX,1))
  ΔD2 = zeros(size(D2,1),size(D2,3))
  for i = 1:nocc
    @tensoropt TUU4i[X',Y',a] = (R[:,:,:,i][X,Y,a] * UU[:,:,i][X,X']) * UU[:,:,i][Y,Y']
    for j = 1:nocc
      @tensoropt ΔD2[a,b] = TUU4i[X,Y,a] * R[:,:,:,j][X,Y,b]
      @tensoropt D2[:,i,:,j][a,b] -= ΔD2[a,b]
      if i != j
        @tensoropt D2[:,j,:,i][b,a] -= ΔD2[a,b]
      end
    end
  end
  # display(D2)
  return D2
end

function calc_triples_residuals(EC::ECInfo, T1, T2, cc3 = false)
  t1 = time_ns()
  UvoX = load(EC,"UvoX")
  #display(UvoX)

  #load decomposed amplitudes
  T3_XYZ = load(EC, "T3_XYZ")
  #display(T3_XYZ)

  #load df coeff
  ovPfile, ovP = mmap(EC,"d_ovP")
  voPfile, voP = mmap(EC,"d_voP")
  ooPfile, ooP = mmap(EC,"d_ooP")
  vvPfile, vvP = mmap(EC,"d_vvP")

  #load dressed fock matrices
  SP = EC.space
  dfock = load(EC,"dfock"*'o')    
  dfoo = dfock[SP['o'],SP['o']]
  dfov = dfock[SP['o'],SP['v']]
  dfvv = dfock[SP['v'],SP['v']]
  
  @tensoropt Thetavirt[b,d,Z] := vvP[b,d,Q] * (voP[c,k,Q] * UvoX[c,k,Z]) #virt1
  @tensoropt Thetavirt[b,d,Z] += UvoX[c,k,Z] * (T2[c,b,l,m] * (ooP[l,k,Q] * ovP[m,d,Q])) #virt3
  @tensoropt Thetavirt[b,d,Z] -= ovP[l,d,Q] * (T2[b,e,l,k] * (UvoX[c,k,Z] * vvP[c,e,Q])) #virt6
  t1 = print_time(EC,t1,"1 Theta terms in R3(T3)",2)
  
  @tensoropt Thetaocc[l,j,Z] := ooP[l,j,Q] * (voP[c,k,Q] * UvoX[c,k,Z]) #occ1
  @tensoropt Thetaocc[l,j,Z] -= UvoX[c,k,Z] * (T2[c,d,m,j] * (ovP[l,d,Q] * ooP[m,k,Q])) #occ4
  @tensoropt Thetaocc[l,j,Z] += UvoX[c,k,Z] * (T2[d,e,k,j]* (ovP[l,e,Q] * vvP[c,d,Q])) #occ5
  t1 = print_time(EC,t1,"2 Theta terms in R3(T3)",2)
  if !cc3
    @tensoropt BooQX[i,j,Q,X] := ovP[i,a,Q] * UvoX[a,j,X]
    @tensoropt Thetavirt[b,d,Z] += 0.5* T3_XYZ[X',Y',Z] * (UvoX[b,m,Y'] * (ovP[l,d,Q] * BooQX[m,l,Q,X'])) #virt9
    @tensoropt Thetaocc[l,j,Z] -= 0.5 * T3_XYZ[X',Z,Z'] * (BooQX[l,m,Q,X'] * BooQX[m,j,Q,Z']) #occ8
    BooQX = nothing
    t1 = print_time(EC,t1,"3 Theta terms in R3(T3)",2)

    @tensoropt A[Q,X] := ovP[i,a,Q] * UvoX[a,i,X]
    @tensoropt Thetavirt[b,d,Z] -= ovP[l,d,Q] * (UvoX[b,l,Z'] * (T3_XYZ[X',Z,Z'] * A[Q,X'])) #virt7
    @tensoropt Thetaocc[l,j,Z] += ovP[l,d,Q] * (UvoX[d,j,Z']* (T3_XYZ[X',Z,Z'] * A[Q,X']))   #occ6
    A = nothing
    t1 = print_time(EC,t1,"4 Theta terms in R3(T3)",2)

    @tensoropt IntermediateTheta[Q,Z',Z] := ovP[m,e,Q] * (UvoX[e,k,Y'] * (T3_XYZ[X',Y',Z'] * (UvoX[c,m,X'] * UvoX[c,k,Z])))
    @tensoropt Thetavirt[b,d,Z] += 0.5* ovP[l,d,Q] * (UvoX[b,l,Z'] * IntermediateTheta[Q,Z',Z]) #virt8
    @tensoropt Thetaocc[l,j,Z] -= 0.5 * ovP[l,d,Q] * (UvoX[d,j,Z'] * IntermediateTheta[Q,Z',Z]) #occ7
    IntermediateTheta = nothing
    t1 = print_time(EC,t1,"5 Theta terms in R3(T3)",2)
  end

  @tensoropt TaiX[a,i,X] := UvoX[b,j,X] * T2[a,b,i,j]
  @tensoropt TStrich[a,i,X] := 2* TaiX[a,i,X] - UvoX[b,j,X] * T2[b,a,i,j] 
  @tensoropt Thetavirt[b,d,Z] += vvP[b,d,Q] * (ovP[l,e,Q] * TStrich[e,l,Z]) #virt4
  @tensoropt Thetaocc[l,j,Z] += ooP[l,j,Q] * (ovP[m,d,Q] * TStrich[d,m,Z]) #occ2
  TStrich = nothing
  t1 = print_time(EC,t1,"6 Theta terms in R3(T3)",2)

  @tensoropt Thetavirt[b,d,Z] -= dfov[l,d] * TaiX[b,l,Z] #virt2
  @tensoropt Thetavirt[b,d,Z] -= ovP[l,d,Q] * (vvP[b,e,Q] * TaiX[e,l,Z]) #virt5
  @tensoropt Thetaocc[l,j,Z] -= ooP[m,j,Q] * (ovP[l,d,Q] * TaiX[d,m,Z]) #occ3
  t1 = print_time(EC,t1,"7 Theta terms in R3(T3)",2)
  
  @tensoropt Term1[X,Y,Z] := (TaiX[b,l,X] * Thetaocc[l,j,Z] - Thetavirt[b,d,Z] * TaiX[d,j,X]) * UvoX[b,j,Y]
  Thetaocc = nothing
  Thetavirt = nothing
  TaiX = nothing
  t1 = print_time(EC,t1,"Theta terms in R3(T3)",2)

  @tensoropt R3decomp[X,Y,Z] := Term1[X,Y,Z] + Term1[Y,X,Z] + Term1[X,Z,Y] + Term1[Z,Y,X] + Term1[Z,X,Y] + Term1[Y,Z,X]
  Term1 = nothing
  t1 = print_time(EC,t1,"Symmetrization of Theta terms in R3(T3)",2)


  @tensor TTilde[a,b,i,j] := 2.0 * T2[a,b,i,j] - T2[b,a,i,j]
  if cc3
    @tensoropt Term2[X,Y,Z] := T3_XYZ[X',Y,Z] * (UvoX[a,l,X'] * (dfoo[l,i]  * UvoX[a,i,X])) #1
    @tensoropt Term2[X,Y,Z] -= T3_XYZ[X',Y,Z] * (UvoX[a,i,X] *( dfvv[a,d] * UvoX[d,i,X'])) #2
  else
    @tensoropt Intermediate1Term2[l,d,m,e] := ovP[l,d,P] * ovP[m,e,P]
    @tensoropt Term2[X,Y,Z] := T3_XYZ[X',Y,Z] * (UvoX[a,l,X'] * ( (dfoo[l,i] + 0.5 * Intermediate1Term2[l,d,m,e] * TTilde[d,e,i,m]) * UvoX[a,i,X])) #1
    @tensoropt Term2[X,Y,Z] -= T3_XYZ[X',Y,Z] * (UvoX[a,i,X] *( (dfvv[a,d] - 0.5 * Intermediate1Term2[l,d,m,e] * TTilde[a,e,l,m]) * UvoX[d,i,X'])) #2
    Intermediate1Term2 = nothing
    t1 = print_time(EC,t1,"1 Chi terms in R3(T3)",2)
    @tensoropt Term2[X,Y,Z] += (UvoX[a,i,X] * ((ooP[l,i,P] * vvP[a,d,P]) * UvoX[d,l,X'])) * (T3_XYZ[X',Y',Z] * (UvoX[b,j,Y] * UvoX[b,j,Y'])) #3
    @tensoropt Term2[X,Y,Z] -= 2* (T3_XYZ[X',Y,Z] *((voP[a,i,P] + ovP[m,e,P] * TTilde[a,e,i,m]) * UvoX[a,i,X]) * (ovP[l,d,P] * UvoX[d,l,X'])) #4
    @tensoropt Term2[X,Y,Z] -= T3_XYZ[X,Y',Z'] * (((UvoX[c,k,Z] * UvoX[c,m,Z']) * ooP[m,k,P]) * (UvoX[b,j,Y] * (ooP[l,j,P] * UvoX[b,l,Y']))) #5
    @tensoropt Intermediate2Term2[Y,Y',P] :=  UvoX[b,j,Y] * (vvP[b,d,P] * UvoX[d,j,Y'])
    @tensoropt Intermediate3Term2[X',Y,Z,P] :=  T3_XYZ[X',Y',Z] * (Intermediate2Term2[Y,Y',P])
    @tensoropt Term2[X,Y,Z] -= (T3_XYZ[X,Y',Z'] * Intermediate2Term2[Y,Y',P]) * (UvoX[e,k,Z'] * (UvoX[c,k,Z] * vvP[c,e,P])) #6
    Intermediate2Term2 = nothing
    t1 = print_time(EC,t1,"2 Chi terms in R3(T3)",2)
    @tensoropt Term2[X,Y,Z] += (ooP[l,i,P] * (UvoX[a,i,X] * UvoX[a,l,X'])) * (Intermediate3Term2[X',Y,Z,P] + Intermediate3Term2[X',Z,Y,P]) #7
    Intermediate3Term2 = nothing
    t1 = print_time(EC,t1,"3 Chi terms in R3(T3)",2)
    @tensoropt Intermediate4Term2[l,d,a,i] := ovP[l,d,P] * (voP[a,i,P] + ovP[m,e,P] * TTilde[a,e,i,m])
    @tensoropt Term2[X,Y,Z] += UvoX[c,k,Z] * ((T3_XYZ[X',Y',Y] * UvoX[c,l,X']) * (UvoX[d,k,Y'] * (UvoX[a,i,X] * Intermediate4Term2[l,d,a,i]))) #8
    @tensoropt Term2[X,Y,Z] += UvoX[b,j,Y] * ((T3_XYZ[X',Y',Z] * UvoX[b,l,X']) * (UvoX[d,j,Y'] * (UvoX[a,i,X] * Intermediate4Term2[l,d,a,i]))) #9
    Intermediate4Term2 = nothing
    t1 = print_time(EC,t1,"4 Chi terms in R3(T3)",2)
  end

  @tensoropt R3decomp[X,Y,Z] += Term2[X,Y,Z] + Term2[Y,X,Z] + Term2[Z,Y,X]
  Term2 = nothing
  t1 = print_time(EC,t1,"Symmetrization of Chi terms in R3(T3)",2)

  #display(R3decomp)

  close(ovPfile)
  close(voPfile)
  close(ooPfile)
  close(vvPfile)

  save(EC,"R3_decomp",R3decomp)
  
end


#Erklärung für save Funktion: save(EC, NamedesFiles,dasgespeichertwerdensoll, zuspeichernder Tensor)

#Charlotte end

end #module
