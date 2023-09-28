# ElemCo.jl global information

```@docs
ElemCo.ECInfos
ElemCo.ECInfo
ElemCo.setup_space_ms!
ElemCo.setup_space_fd!
ElemCo.setup_space!
ElemCo.save_space
ElemCo.restore_space!
ElemCo.freeze_core!
ElemCo.freeze_nvirt!
ElemCo.freeze_nocc!
ElemCo.set_options!
ElemCo.parse_orbstring
ElemCo.get_occvirt
ElemCo.n_occ_orbs
ElemCo.n_occb_orbs
ElemCo.n_virt_orbs
ElemCo.n_virtb_orbs
ElemCo.n_orbs
```

## File management
```@docs
ElemCo.file_exists
ElemCo.add_file!
ElemCo.copy_file!
ElemCo.delete_file!
ElemCo.delete_files!
ElemCo.delete_temporary_files!
```

## Abstract types
```@docs
ElemCo.AbstractEC
```

## Internal functions
```@docs
ElemCo.ECInfos.symorb2orb
```

