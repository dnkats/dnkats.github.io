push!(LOAD_PATH,"../src/")
using Documenter, ElemCo

DocMeta.setdocmeta!(ElemCo, :DocTestSetup, :(using ElemCo); recursive=true)

makedocs(
  modules = [ElemCo],
  format = Documenter.HTML(
    # Use clean URLs, unless built as a "local" build
    prettyurls = !("local" in ARGS),
    assets = ["assets/favicon.ico"],
  ),
  sitename="ElemCo.jl documentation")
