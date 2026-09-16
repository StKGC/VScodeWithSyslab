# -----------------------------------------------------------------------------
#  生成 Julia 代码补全索引（供 VS Code 桥接扩展离线使用）
#
#  用法（由 scripts/Build-CompletionIndex.ps1 调用，也可手动跑）：
#    julia --project=<Syslab默认环境> build-completion-index.jl <输出json> <包名,逗号分隔> [--no-docs]
#
#  产出结构：
#    {
#      "generatedAt": "...", "julia": "1.10.10", "project": "...",
#      "packages": ["TyBase", "TyMath", "TyPlot"],
#      "items": [ { "n": "plot", "k": "function", "p": "TyPlot", "d": "一行文档" } ]
#    }
# -----------------------------------------------------------------------------

using Dates

const OUT = length(ARGS) >= 1 ? ARGS[1] : error("需要输出路径")
const PKGS = length(ARGS) >= 2 ? split(ARGS[2], ',') : ["TyBase", "TyMath", "TyPlot"]
const WITH_DOCS = !(length(ARGS) >= 3 && ARGS[3] == "--no-docs")
const SKIP = Set(["eval", "include", "include_dependency"])

esc(s) = replace(string(s),
    "\\" => "\\\\", "\"" => "\\\"",
    "\n" => " ", "\r" => " ", "\t" => " ")

"""把包名安全地载入 Main，返回模块对象；失败返回 nothing"""
function load_package(name::AbstractString)
    try
        Base.eval(Main, Meta.parse("using $(name)"))
        return Base.eval(Main, Symbol(name))
    catch err
        @warn "跳过 $(name)：$(sprint(showerror, err))"
        return nothing
    end
end

function kind_of(value)
    value isa Function && return "function"
    (value isa UnionAll || value isa DataType) && return "type"
    value isa Module && return "module"
    (value isa Number || value isa AbstractString || value isa Symbol || value isa Tuple ||
        value isa AbstractArray || value isa Char) && return "const"
    return "value"
end

"""取一行文档（截断、压平空白）"""
function brief_doc(mod::Module, name::Symbol)
    WITH_DOCS || return ""
    try
        text = sprint(show, MIME("text/plain"), Base.Docs.doc(Base.Docs.Binding(mod, name)))
        text = strip(replace(text, r"\s+" => " "))
        return length(text) > 240 ? string(text[1:237], "...") : text
    catch
        return ""
    end
end

"""收集一个包的导出符号，返回 [Dict("n"=>名字,"k"=>种类,"p"=>包名,"d"=>文档)]"""
function collect_package(package::AbstractString)
    mod = load_package(package)
    mod === nothing && return Any[]
    entries = Any[]
    try
        for sym in names(mod; all = false, imported = false)
            text = String(sym)
            (startswith(text, "#") || text in SKIP) && continue
            value = try
                getfield(mod, sym)
            catch
                continue
            end
            push!(entries, Dict(
                "n" => text,
                "k" => kind_of(value),
                "p" => String(package),
                "d" => brief_doc(mod, sym),
            ))
        end
    catch err
        @warn "读取 $(package) 导出符号失败：$(sprint(showerror, err))"
    end
    sort!(entries; by = item -> item["n"])
    return entries
end

function main()
    items = Any[]
    loaded = String[]
    for raw in PKGS
        package = strip(raw)
        isempty(package) && continue
        entries = collect_package(package)
        if !isempty(entries)
            push!(loaded, package)
            append!(items, entries)
            println(stderr, "  $(package): $(length(entries)) 个导出符号")
        end
    end

    project = try
        Base.active_project()
    catch
        ""
    end

    open(OUT, "w") do io
        println(io, "{")
        println(io, "  \"generatedAt\": \"", Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS"), "\",")
        println(io, "  \"julia\": \"", esc(VERSION), "\",")
        println(io, "  \"project\": \"", esc(something(project, "")), "\",")
        println(io, "  \"packages\": [", join(["\"$(esc(p))\"" for p in loaded], ", "), "],")
        println(io, "  \"items\": [")
        for (index, item) in enumerate(items)
            comma = index < length(items) ? "," : ""
            print(io, "    {\"n\": \"", esc(item["n"]),
                "\", \"k\": \"", item["k"],
                "\", \"p\": \"", esc(item["p"]),
                "\", \"d\": \"", esc(item["d"]), "\"}", comma, "\n")
        end
        println(io, "  ]")
        println(io, "}")
    end
    println(stderr, "索引已写入：$(OUT)（共 $(length(items)) 项，$(length(loaded)) 个包）")
end

main()
