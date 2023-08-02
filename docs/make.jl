push!(LOAD_PATH,"../src/")
using Documenter, ElemCo

makedocs(
  modules = [ElemCo],
  format = Documenter.HTML(
    # Use clean URLs, unless built as a "local" build
    prettyurls = !("local" in ARGS),
    assets = ["assets/favicon.ico"],
  ),
  sitename="ElemCo.jl documentation")
