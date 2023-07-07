module DFMCSCF
using LinearAlgebra, TensorOperations, Printf
using ..ElemCo.ECInfos
using ..ElemCo.ECInts
using ..ElemCo.MSystem
using ..ElemCo.DIIS
using ..ElemCo.TensorTools
using ..ElemCo.DFHF

export dfmcscf

"""
calc density matrix of active electrons
p,q,r,s => t,u,v,w (active orbitals)
D1[p,q] = <E_pq> = <a†_p a_q>
D2[p,q,r,s] = 1/2  <E_pq,rs + E_qp,rs>
in which E_pq,rs = E_pq E_rs - δ_qr E_ps = a†_p a†_r a_s a_q

return as a tuple: D1, D2

"""
function denMatCreate(EC::ECInfo)
    SP = EC.space
    nact = length(SP['o'])- length(SP['O']) # to be modified
    D1 = 1.0 *Matrix(I, nact, nact)
    @tensoropt D2[p,q,r,s] := D1[p,q]*D1[r,s] - 0.5*D1[p,q]*D1[r,s]
    return D1, D2
end

"""
calc fock matrix in Atomic basis
p,q,r,s => μ,ν,σ,ρ

return as matrix fock
saving mudL and muaL, the first index is atomic orbital, the second is in order of molecular orbital
d -> doubly occupied orbital, a -> active orbital

"""
function dffockCAS(EC,cMO,D1)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    occ1O = setdiff(EC.space['O'],occ2)
    CMO2 = cMO[:,occ2]
    CMOa = cMO[:,occ1o] # to be modified
    pqL = load(EC,"munuL")
    hsmall = load(EC,"hsmall")
    @tensoropt pjL[p,j,L] := pqL[p,q,L] * CMO2[q,j]
    save(EC,"mudL",pjL)

    @tensoropt L[L] := pjL[p,j,L] * CMO2[p,j]
    @tensoropt fockClosed[p,q] := hsmall[p,q] - pjL[p,j,L]*pjL[q,j,L]
    @tensoropt fockClosed[p,q] += 2.0*L[L]*pqL[p,q,L]

    fock =  deepcopy(fockClosed)
    @tensoropt puL[p,u,L] := pqL[p,q,L] * CMOa[q,u]

    save(EC,"muaL",puL)
    @tensoropt puLD[p,t,L] := puL[p,u,L] * D1[t,u]
    @tensoropt fock[p,q] += puLD[p,t,L] * puL[q,t,L]
    @tensoropt LD[L] := puLD[r,t,L] * CMOa[r,t]
    @tensoropt fock[p,q] -= 0.5 * LD[L] * pqL[p,q,L]

    return fock, fockClosed
end

"""
calc the A matrix in molecular basis p,q,r,s

return as matrix A

"""
function dfACAS(EC,cMO,D1,D2,fock,fockClosed)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    occ1O = setdiff(EC.space['O'],occ2)
    CMO2 = cMO[:,occ2]
    CMOa = cMO[:,occ1o] # to be modified
    #pqL = load(EC,"munuL")
    puL = load(EC,"muaL")
    #fock = dffockCAS(EC,cMO,D1)
    @tensoropt Apj[p,j] := 2 * (fock[μ,ν] * CMO2[ν,j]) * cMO[μ,p]
    
    @tensoropt Apu[p,u] := ((fockClosed[μ,ν] * CMOa[ν,v]) * cMO[μ,p]) * D1[v,u]
    #@tensoropt intermediate[p,u] := (((puL[ν,v,L] * CMOa[ν,w]) * D2[t,u,v,w]) * puL[μ,t,L]) * cMO[μ,p]
    # here the length of u might equal 0, in that case the using of '@tensoropt ...+=...' should be careful 
    #Apu += intermediate
    @tensoropt Apu[p,u] += (((puL[ν,v,L] * CMOa[ν,w]) * D2[t,u,v,w]) * puL[μ,t,L]) * cMO[μ,p]

    A = zeros((size(cMO,2),size(cMO,2)))
    A[:,occ2] = Apj[:,:]
    A[:,occ1o] = Apu[:,:] # to be modified
    return A
end

"""
to return the g with A given
first index r refer to open orbitals reordered in [occ1o;occv]
second index k refers to occupied orbitals reordered in [occ2;occ1o]

"""
function calc_g(A, EC)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    @tensoropt g[r,s] := A[r,s] - A[s,r]
    occv = setdiff(1:size(A,1), EC.space['o']) # to be modified
    grk = g[[occ1o;occv],[occ2;occ1o]] # to be modified
    grk = reshape(grk, size(grk,1) * size(grk,2))
    return grk
end

"""
to return the h with A given
first index r,s refer to open orbitals reordered in [occ1o;occv]
second index k,l refers to occupied orbitals reordered in [occ2;occ1o]

"""
function calc_h(EC, cMO, D1, D2, fock, fockClosed, A)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    occv = setdiff(1:size(A,1), EC.space['o']) # to be modified
    occ1O = setdiff(EC.space['O'],occ2)
    CMO2 = cMO[:,occ2]
    CMOa = cMO[:,occ1o] # to be modified

    # Gij
    μjL = load(EC,"mudL")
    @tensoropt pjL[p,j,L] := μjL[μ,j,L] * cMO[μ,p] # to transfer the first index from atomic basis to molecular basis
    @tensoropt Gij[r,s,i,j] := 8 * pjL[r,i,L] * pjL[s,j,L]
    @tensoropt Gij[r,s,i,j] -= 2 * pjL[s,i,L] * pjL[r,j,L]

    μνL = load(EC,"munuL")
    ijL = pjL[occ2,:,:]
    @tensoropt pqL[p,q,L] := μνL[μ,ν,L] * cMO[μ,p] * cMO[ν,q]
    @tensoropt Gij[r,s,i,j] -= 2 * ijL[i,j,L] * pqL[r,s,L]

    Iij = 1.0 * Matrix(I, length(occ2), length(occ2))
    @tensoropt Gij[r,s,i,j] += 2 * fock[μ,ν] * cMO[μ,r] * cMO[ν,s] * Iij[i,j] # lower cost?

    # Gtj
    μuL = load(EC,"muaL")
    @tensoropt puL[p,u,L] := μuL[μ,u,L] * cMO[μ,p] #transfer from atomic basis to molecular basis
    @tensoropt testStuff[r,s,v,j] := puL[r,v,L] * pjL[s,j,L]


    @tensoropt multiplier[r,s,v,j] := 4 * puL[r,v,L] * pjL[s,j,L]

    @tensoropt multiplier[r,s,v,j] -= puL[s,v,L] * pjL[r,j,L]
    tjL = pjL[occ1o,:,:]
    @tensoropt multiplier[r,s,v,j] -= pqL[r,s,L] * tjL[v,j,L]
    @tensoropt Gtj[r,s,t,j] := multiplier[r,s,v,j] * D1[t,v]
    
    # Gjt 
    @tensoropt Gjt[r,s,j,t] := Gtj[s,r,t,j] # can we skip this step?
    
    # Gtu 
    @tensoropt Gtu[r,s,t,u] := fockClosed[μ,ν] * cMO[μ,r] * cMO[ν,s] * D1[t,u]
    tuL = pqL[occ1o, occ1o, :]
    @tensoropt Gtu[r,s,t,u] += pqL[r,s,L] * (tuL[v,w,L] * D2[t,u,v,w])
    @tensoropt Gtu[r,s,t,u] += 2 * (puL[r,v,L] * puL[s,w,L]) * D2[t,v,u,w]

    # combine G
    n_AO = size(cMO,2)
    G = zeros((n_AO,n_AO,n_AO,n_AO))
    G[:,:,occ2,occ2] = Gij[:,:,:,:]
    G[:,:,occ1o,occ2] = Gtj[:,:,:,:]
    G[:,:,occ2,occ1o] = Gjt[:,:,:,:]
    G[:,:,occ1o,occ1o] = Gtu[:,:,:,:]

    # calc h
    I_kl = 1.0 * Matrix(I, n_AO, n_AO)
    @tensoropt h[r,k,s,l] := 2 * G[r,s,k,l] - I_kl[k,l] * (A[r,s] + A[s,r])
    @tensoropt h[r,k,s,l] += 2 * G[k,l,r,s] - I_kl[r,s] * (A[k,l] + A[l,k])
    @tensoropt h[r,k,s,l] -= 2 * G[k,s,r,l] - I_kl[r,l] * (A[k,s] + A[s,k])
    @tensoropt h[r,k,s,l] -= 2 * G[r,l,k,s] - I_kl[k,s] * (A[r,l] + A[l,r])
    h_rk_sl = h[[occ1o;occv],[occ2;occ1o],[occ1o;occv],[occ2;occ1o]]
    d = size(h_rk_sl,1) * size(h_rk_sl,2)
    h_rk_sl = reshape(h_rk_sl, d, d)

    save(EC,"h_rk_sl",h_rk_sl)
    return h_rk_sl
end

function calc_realE(EC, fockClosed, D1, D2, cMO)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    hsmall = load(EC,"hsmall")

    # Ec
    E = tr(hsmall[occ2,occ2]) + tr(fockClosed[occ2,occ2])

    # FcD
    E += sum(fockClosed[occ1o,occ1o] .* D1)

    pqL = load(EC,"munuL")
    CMOa = cMO[:,occ1o] 
    @tensoropt tuL[t,u,L] := pqL[p,q,L] * CMOa[p,t] * CMOa[q,u]
    @tensoropt tuvw[t,u,v,w] := tuL[t,u,L] * tuL[v,w,L]

    E += 0.5 * sum(D2 .* tuvw)

    return E
end




function dfmcscf(ms::MSys, EC::ECInfo; direct = false, guess = GUESS_SAD)
    Enuc = generate_integrals(ms, EC; save3idx=!direct)
    cMO = guess_orb(ms,EC,guess)
    D1, D2 = denMatCreate(EC)
    fock, fockClosed = dffockCAS(EC,cMO,D1)
    E0 = calc_realE(EC, fockClosed, D1, D2, cMO)
    occ2 = intersect(EC.space['o'],EC.space['O']) # to be modified
    occ1o = setdiff(EC.space['o'],occ2)
    occv = setdiff(1:size(cMO,2), EC.space['o']) # to be modified
    if size(occ1o,1) == 0
        error("NO ACTIVE ORBITALS, PLEASE USE DFHF")
    end
    iteration_times = 1
    g = [1]
    # calc g
    while sum(g.^2) > 1e-6 && iteration_times < 200
        println("Iter ", iteration_times)

        fock, fockClosed = dffockCAS(EC,cMO,D1)

        A = dfACAS(EC,cMO,D1,D2,fock,fockClosed)
        g = calc_g(A, EC)

        # calc h
        h = calc_h(EC, cMO, D1, D2, fock, fockClosed, A)
        
        λ = 10.0
        maxit = 100
        x = zeros(size(h,1))

        for it=1:maxit
            println("  it ", it)
            println("    λ is ", λ)
            # building working matrix W
            W = zeros(size(h,1)+1, size(h,1)+1) # workng matrix
            W[1, 2:size(h,1)+1] = g[:]
            W[2:size(h,1)+1, 1] = g[:]
            W[2:size(h,1)+1,2:size(h,1)+1] = h[:,:]./λ

            #display("difference to judge the hermitian of W")
            #display(sum((W-permutedims(W,[2,1])).^2))

            # diagnolize W
            vals, vecs = eigen(W)
            x = vecs[2:size(h,1)+1, 1] .* (1/λ/vecs[1, 1])
            #display(vals[1:5])
            #display(vecs[:,1:5])
            println("    square of the norm of x is ", sum(x.^2))

            # norm is the square root of sum(x.^2) 0.3-0.7
            if sum(x.^2)> 0.5
                λ *= 1.1
            elseif sum(x.^2)< 0.1
                λ /= 1.1
            else
                break
            end
        end
        
        # build U matrix (approximately unitary because of the anti-hermitian property of the R)
        N = size(cMO,1)
        R = zeros(N,N)

        # build R_sub1 and R_sub2
        R_sub1 = reshape(x, N-size(occ2,1), size(occ1o,1)+size(occ2,1))
        R_sub1[occ1o,occ1o] = zeros(size(occ1o,1), size(occ1o,1))
        R_sub2 = -1.0 .* transpose(R_sub1)

        R[[occ1o;occv],[occ2;occ1o]] = R_sub1[:,:]
        R[[occ2;occ1o],[occ1o;occv]] = R_sub2[:,:]

        #display("difference to judge the anti-hermitian of R")
        #display(sum((R+permutedims(R,[2,1])).^2))

        #display(R)

        U = 1.0 * Matrix(I,N,N) + R
        U = U + 1/2 .* R*R + 1/6 .* R*R*R

        println("the difference between U and a real unitary matrix is ", sum((U'*U-I).^2))
        cMO = cMO*U
        iteration_times += 1

        println("the norm of g is ", norm(g))

        E = calc_realE(EC, fockClosed, D1, D2, cMO)
        println("the real energy is ", E)


        E = E0 + sum(g .* x) + 0.5*(transpose(x) * h * x)
        println("the second order energy is ", E)

    end


end

end #module
