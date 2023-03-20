module ECInts
export BasisSet, overlap, kinetic, nuclear, ERI_2e4c, ERI_2e3c, ERI_2e2c, nuclear_repulsion
try
  using GaussianBasis
  using Molecules
  #using Lints # package which uses libint

catch
  println("GaussianBasis/Molecules package not installed! Generation of integrals is not available.")
end

# TODO use GaussianBasis.read_basisset("cc-pvtz",atoms[2]) to specify non-default basis

function nuclear_repulsion(gb) 
  try
    return Molecules.nuclear_repulsion(gb.atoms)
  catch
    return 0.0
  end
end
  

end #module