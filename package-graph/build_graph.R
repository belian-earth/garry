# package-graph/build_graph.R
#
# Static map of the garry package: every top-level function (plus S7
# classes, generics and method() assignments), who calls whom, and where
# the external boundaries sit (anvl per-function, gdalraster per-function,
# other packages collapsed to one node each).
#
# Pure static analysis: files are parsed, never evaluated, so this runs
# without anvl/XLA present. Usage:
#
#   Rscript package-graph/build_graph.R
#
# Outputs (all under package-graph/):
#   garry-package-graph.html  interactive visNetwork DAG
#   anvl-surface.md           which anvl functions we use, from where
#   graph-data.rds            nodes/edges data frames for further analysis

suppressPackageStartupMessages({
  library(visNetwork)
  library(igraph)
  library(glue)
})

`%||%` <- function(x, y) if (length(x) == 0 || is.na(x[1])) y else x
script_path <- sub("--file=", "", grep("--file=",
  commandArgs(trailingOnly = FALSE), value = TRUE)[1])
pkg_root <- if (is.na(script_path)) normalizePath(".") else
  normalizePath(file.path(dirname(script_path), ".."))
out_dir <- file.path(pkg_root, "package-graph")

# ---------------------------------------------------------------------------
# Module map: file -> subsystem. Curated, not inferred.
# ---------------------------------------------------------------------------
modules <- list(
  "IR & graph"       = c("node.R", "ops.R", "generics.R", "graph.R", "passes.R",
                         "plan.R", "gradient.R", "dot.R"),
  "Grid & geometry"  = c("grid.R", "chunk_grid.R", "grid_from.R"),
  "Execution"        = c("collect.R", "executor.R", "scheduler.R", "placement.R",
                         "daemon.R", "pools.R", "composite_direct.R"),
  "IO & GDAL"        = c("gdal_adapter.R", "lazy_raster.R", "materialise.R",
                         "write_tif.R", "stac.R", "dataset.R", "extract_points.R"),
  "Models & kernels" = c("ocm.R", "ocm_blocks.R", "ocm_edgenext.R", "ocm_weights.R",
                         "band_mlp.R", "safetensors.R", "scan_hampel.R",
                         "scan_kalman.R", "reduce_multiband.R", "dequantize.R"),
  "Viz & UX"         = c("draw.R", "preview.R", "task_report.R"),
  "Infra"            = c("options.R", "zzz.R")
)
file_module <- setNames(
  rep(names(modules), lengths(modules)),
  unlist(modules)
)

# External packages we draw per-function (the interesting boundaries) and
# per-package (context only). Everything else (cli, glue, rlang, S7, base
# helpers...) is dropped from the graph as noise.
ext_per_fun <- c("anvl", "gdalraster")
ext_per_pkg <- c("mirai", "wk", "mori", "rstac", "httr2", "terra")

# ---------------------------------------------------------------------------
# Pass 1: parse files, harvest top-level definitions
# ---------------------------------------------------------------------------
r_files <- list.files(file.path(pkg_root, "R"), pattern = "\\.R$", full.names = TRUE)

defs <- list()   # name -> list(file, kind, lines, expr)

is_fun_call <- function(e, names) {
  is.call(e) && (
    (is.symbol(e[[1L]]) && as.character(e[[1L]]) %in% names) ||
    (is.call(e[[1L]]) && identical(e[[1L]][[1L]], as.name("::")) &&
       as.character(e[[1L]][[3L]]) %in% names)
  )
}

harvest_file <- function(path) {
  exprs <- parse(path, keep.source = TRUE)
  srcs  <- attr(exprs, "srcref")
  fname <- basename(path)
  for (i in seq_along(exprs)) {
    e <- exprs[[i]]
    nlines <- if (!is.null(srcs)) srcs[[i]][3L] - srcs[[i]][1L] + 1L else 1L
    if (!(is.call(e) && as.character(e[[1L]]) %in% c("<-", "=", "<<-"))) next
    lhs <- e[[2L]]; rhs <- e[[3L]]
    kind <- NULL; name <- NULL; generic_of <- NULL
    if (is.call(rhs) && identical(rhs[[1L]], as.name("function"))) {
      if (is.symbol(lhs)) {
        name <- as.character(lhs); kind <- "function"
      } else if (is.call(lhs) &&
                 deparse(lhs[[1L]], nlines = 1L) %in% c("method", "S7::method")) {
        gen <- gsub("\"", "", deparse(lhs[[2L]], nlines = 1L))
        cls <- gsub("\"", "", deparse(lhs[[3L]], nlines = 1L))
        cls <- sub("^class_", "", cls)
        gen <- sub("^S7::", "", gen)
        name <- glue("{gen}@{cls}"); kind <- "method"
        generic_of <- gen
      }
    } else if (is_fun_call(rhs, "new_class") && is.symbol(lhs)) {
      name <- as.character(lhs); kind <- "class"
    } else if (is_fun_call(rhs, "new_generic") && is.symbol(lhs)) {
      name <- as.character(lhs); kind <- "generic"
    }
    if (is.null(name)) next
    if (!is.null(defs[[name]])) next  # first definition wins
    defs[[name]] <<- list(file = fname, kind = kind, lines = nlines, expr = rhs,
                          generic_of = generic_of)
  }
}
invisible(lapply(r_files, harvest_file))

def_names <- names(defs)
cat(glue("{length(defs)} top-level definitions across {length(r_files)} files\n\n"))

# ---------------------------------------------------------------------------
# Pass 2: AST walk per definition -> internal + external callees
# ---------------------------------------------------------------------------
collect_refs <- function(expr) {
  internal <- character(); external <- character()
  walk <- function(e) {
    if (missing(e)) return(invisible())
    if (is.call(e)) {
      h <- e[[1L]]
      if (identical(h, as.name("::")) || identical(h, as.name(":::"))) {
        external <<- c(external,
          paste0(deparse(e[[2L]], nlines = 1L), "::", deparse(e[[3L]], nlines = 1L)))
        return(invisible())  # don't descend; symbols inside are the ref itself
      }
      for (a in as.list(e)) tryCatch(walk(a), error = function(err) NULL)
    } else if (is.symbol(e)) {
      nm <- as.character(e)
      if (nzchar(nm) && nm %in% def_names) internal <<- c(internal, nm)
    } else if (is.pairlist(e)) {
      for (a in as.list(e)) tryCatch(walk(a), error = function(err) NULL)
    }
  }
  walk(expr)
  list(internal = unique(internal), external = unique(external))
}

edges_int <- list(); edges_ext <- list()
for (nm in def_names) {
  refs <- collect_refs(defs[[nm]]$expr)
  callees <- setdiff(refs$internal, nm)
  if (length(callees)) {
    edges_int[[nm]] <- data.frame(from = nm, to = callees)
  }
  if (length(refs$external)) {
    ext <- data.frame(
      from = nm,
      pkg  = sub("::.*$", "", refs$external),
      fun  = sub("^.*::", "", refs$external)
    )
    edges_ext[[nm]] <- ext
  }
}
edges_int <- do.call(rbind, edges_int)
edges_ext <- do.call(rbind, edges_ext)

# S7 dispatch edges: generic -> each of its methods
disp <- do.call(rbind, lapply(def_names, function(nm) {
  gen <- defs[[nm]]$generic_of
  if (!is.null(gen) && gen %in% def_names) data.frame(from = gen, to = nm)
}))
edges_disp <- disp

# Keep only the boundaries we care about; collapse per-pkg ones.
edges_ext <- edges_ext[edges_ext$pkg %in% c(ext_per_fun, ext_per_pkg), ]
edges_ext$to <- ifelse(edges_ext$pkg %in% ext_per_fun,
                       paste0(edges_ext$pkg, "::", edges_ext$fun),
                       paste0("pkg:", edges_ext$pkg))
edges_ext <- unique(edges_ext[, c("from", "to", "pkg")])

# ---------------------------------------------------------------------------
# Exports (NAMESPACE) -> user-facing vs daemon-facing vs internal
# ---------------------------------------------------------------------------
ns <- readLines(file.path(pkg_root, "NAMESPACE"))
exports <- sub("^export\\((.*)\\)$", "\\1", grep("^export\\(", ns, value = TRUE))
exports <- gsub("[\"`]", "", exports)

api_of <- function(nm) {
  if (!nm %in% exports) return("internal")
  if (startsWith(nm, ".")) return("daemon API")   # dot-exports exist for mirai daemons
  "exported"
}

# ---------------------------------------------------------------------------
# Node table
# ---------------------------------------------------------------------------
int_nodes <- data.frame(
  id     = def_names,
  file   = vapply(defs, `[[`, "", "file"),
  kind   = vapply(defs, `[[`, "", "kind"),
  lines  = vapply(defs, function(d) as.integer(d$lines), 1L),
  stringsAsFactors = FALSE
)
int_nodes$module <- file_module[int_nodes$file] %||% "Infra"
int_nodes$module[is.na(int_nodes$module)] <- "Infra"
int_nodes$api <- vapply(int_nodes$id, api_of, "")

anvl_calls_of <- function(nm) {
  hits <- edges_ext[edges_ext$from == nm & edges_ext$pkg == "anvl", "to"]
  if (!length(hits)) return("")
  paste(sub("^anvl::", "", hits), collapse = ", ")
}
int_nodes$anvl <- vapply(int_nodes$id, anvl_calls_of, "")

mod_palette <- c(
  "IR & graph"       = "#4E79A7",
  "Grid & geometry"  = "#59A14F",
  "Execution"        = "#E15759",
  "IO & GDAL"        = "#B07AA1",
  "Models & kernels" = "#F28E2B",
  "Viz & UX"         = "#76B7B2",
  "Infra"            = "#9C9C9C"
)

nodes <- data.frame(
  id    = int_nodes$id,
  label = int_nodes$id,
  group = int_nodes$module,
  value = pmax(2, sqrt(int_nodes$lines)),
  shape = ifelse(int_nodes$kind == "class", "box",
          ifelse(int_nodes$kind == "generic", "ellipse",
          ifelse(int_nodes$kind == "method", "hexagon", "dot"))),
  color = unname(mod_palette[int_nodes$module]),
  borderWidth = ifelse(int_nodes$api == "exported", 3, 1),
  title = glue_data(int_nodes,
    "<b>{id}</b><br>{file} &middot; {lines} lines &middot; {kind}<br>",
    "api: {api}",
    "{ifelse(nzchar(anvl), paste0('<br><b>anvl:</b> ', anvl), '')}"),
  stringsAsFactors = FALSE
)

ext_nodes_needed <- unique(edges_ext$to)
if (length(ext_nodes_needed)) {
  ext_pkg <- sub("::.*$|^pkg:", "", sub("^pkg:", "", ext_nodes_needed))
  ext_pkg <- ifelse(grepl("::", ext_nodes_needed),
                    sub("::.*$", "", ext_nodes_needed),
                    sub("^pkg:", "", ext_nodes_needed))
  ext_col <- c(anvl = "#D4A017", gdalraster = "#2E7D32")
  ext_nodes <- data.frame(
    id    = ext_nodes_needed,
    label = sub("^pkg:", "", sub("^(anvl|gdalraster)::", "", ext_nodes_needed)),
    group = ifelse(ext_pkg == "anvl", "anvl (XLA)",
            ifelse(ext_pkg == "gdalraster", "gdalraster (GDAL)", "other deps")),
    value = 4,
    shape = ifelse(ext_pkg == "anvl", "triangle",
            ifelse(ext_pkg == "gdalraster", "square", "diamond")),
    color = unname(ifelse(ext_pkg %in% names(ext_col), ext_col[ext_pkg], "#BBBBBB")),
    borderWidth = 1,
    title = glue("<b>{ext_nodes_needed}</b>"),
    stringsAsFactors = FALSE
  )
  nodes <- rbind(nodes, ext_nodes)
}

edges <- rbind(
  data.frame(from = edges_int$from, to = edges_int$to,
             color = "#C0C0C080", width = 1, dashes = FALSE),
  data.frame(from = edges_ext$from, to = edges_ext$to,
             color = ifelse(edges_ext$pkg == "anvl", "#D4A017",
                     ifelse(edges_ext$pkg == "gdalraster", "#2E7D32", "#BBBBBB")),
             width = 2, dashes = FALSE)
)
if (!is.null(edges_disp)) {
  edges <- rbind(edges, data.frame(from = edges_disp$from, to = edges_disp$to,
                                   color = "#4E79A780", width = 1, dashes = TRUE))
}
edges <- edges[edges$from %in% nodes$id & edges$to %in% nodes$id, ]

cat(glue("{nrow(nodes)} nodes, {nrow(edges)} edges ",
         "({sum(grepl('^anvl::', nodes$id))} anvl fns, ",
         "{sum(grepl('^gdalraster::', nodes$id))} gdalraster fns)\n\n"))

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
g <- graph_from_data_frame(edges, vertices = nodes$id)
set.seed(42)

net <- visNetwork(nodes, edges,
                  main = "garry: package call graph",
                  submain = glue(
                    "{nrow(int_nodes)} internal definitions | ",
                    "gold triangles = anvl (XLA) surface | ",
                    "green squares = gdalraster (GDAL) surface | ",
                    "thick border = exported"),
                  width = "100%", height = "1000px") |>
  visEdges(arrows = "to", smooth = FALSE) |>
  visIgraphLayout(layout = "layout_with_fr", niter = 800) |>
  visOptions(
    highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE,
                            algorithm = "hierarchical"),
    nodesIdSelection = list(enabled = TRUE, main = "jump to function"),
    selectedBy = list(variable = "group", main = "filter by module")
  ) |>
  visLegend(
    useGroups = FALSE, width = 0.14, position = "right", ncol = 1,
    addNodes = c(
      lapply(names(mod_palette), function(m)
        list(label = m, shape = "dot", size = 12, color = mod_palette[[m]])),
      list(
        list(label = "anvl (XLA)", shape = "triangle", size = 12, color = "#D4A017"),
        list(label = "gdalraster (GDAL)", shape = "square", size = 12, color = "#2E7D32"),
        list(label = "other dep (pkg)", shape = "diamond", size = 12, color = "#BBBBBB"),
        list(label = "S7 class", shape = "box", color = "#9C9C9C"),
        list(label = "S7 generic", shape = "ellipse", color = "#9C9C9C"),
        list(label = "S7 method", shape = "hexagon", size = 12, color = "#9C9C9C")
      )
    )) |>
  visInteraction(navigationButtons = TRUE, keyboard = TRUE,
                 tooltipDelay = 100)

visSave(net, file.path(out_dir, "garry-package-graph.html"),
        selfcontained = TRUE)

saveRDS(list(nodes = nodes, edges = edges, defs_meta = int_nodes),
        file.path(out_dir, "graph-data.rds"))

# ---------------------------------------------------------------------------
# API-surface graph: exported user-facing functions only. Internal call
# chains collapse into direct edges (A -> B when B is reachable from A
# through non-exported functions only); external boundaries collapse to
# one node per package so each verb shows which backend it ultimately
# touches.
# ---------------------------------------------------------------------------
api_ids <- int_nodes$id[int_nodes$api == "exported" &
                        !startsWith(int_nodes$id, ".") &
                        int_nodes$kind != "method"]

adj <- split(c(edges_int$to, if (!is.null(edges_disp)) edges_disp$to),
             c(edges_int$from, if (!is.null(edges_disp)) edges_disp$from))
ext_by_fun <- split(edges_ext$pkg, edges_ext$from)

api_edges <- list(); api_ext <- list()
for (a in api_ids) {
  hits <- character(); pkgs <- unique(ext_by_fun[[a]])
  visited <- a
  frontier <- setdiff(adj[[a]], a)
  while (length(frontier)) {
    new <- setdiff(frontier, visited)
    visited <- c(visited, new)
    exp_hits <- intersect(new, api_ids)
    hits <- c(hits, exp_hits)
    inner <- setdiff(new, api_ids)            # expand through internals only
    pkgs <- unique(c(pkgs, unlist(ext_by_fun[inner], use.names = FALSE)))
    frontier <- unlist(adj[inner], use.names = FALSE)
  }
  if (length(hits)) api_edges[[a]] <- data.frame(from = a, to = unique(hits))
  if (length(pkgs)) api_ext[[a]]   <- data.frame(from = a, to = paste0("pkg:", pkgs))
}
api_edges <- do.call(rbind, api_edges)
api_ext   <- do.call(rbind, api_ext)

api_meta <- int_nodes[match(api_ids, int_nodes$id), ]
api_nodes <- data.frame(
  id    = api_meta$id,
  label = api_meta$id,
  group = api_meta$module,
  value = pmax(2, sqrt(api_meta$lines)),
  shape = ifelse(api_meta$kind == "class", "box",
          ifelse(api_meta$kind == "generic", "ellipse", "dot")),
  color = unname(mod_palette[api_meta$module]),
  title = glue_data(api_meta,
    "<b>{id}</b><br>{file} &middot; {lines} lines &middot; {kind}"),
  stringsAsFactors = FALSE
)
pkg_ids <- unique(api_ext$to)
pkg_col <- c(`pkg:anvl` = "#D4A017", `pkg:gdalraster` = "#2E7D32")
api_nodes <- rbind(api_nodes, data.frame(
  id = pkg_ids, label = sub("^pkg:", "", pkg_ids), group = "external package",
  value = 8,
  shape = ifelse(pkg_ids == "pkg:anvl", "triangle",
          ifelse(pkg_ids == "pkg:gdalraster", "square", "diamond")),
  color = unname(ifelse(pkg_ids %in% names(pkg_col), pkg_col[pkg_ids], "#BBBBBB")),
  title = glue("<b>{sub('^pkg:', '', pkg_ids)}</b> (external package)")
))
api_edge_df <- rbind(
  data.frame(from = api_edges$from, to = api_edges$to,
             color = "#C0C0C080", width = 1),
  data.frame(from = api_ext$from, to = api_ext$to,
             color = ifelse(api_ext$to == "pkg:anvl", "#D4A01760",
                     ifelse(api_ext$to == "pkg:gdalraster", "#2E7D3260",
                            "#BBBBBB60")),
             width = 1)
)

api_net <- visNetwork(api_nodes, api_edge_df,
                      main = "garry: the exported API surface",
                      submain = glue(
                        "{length(api_ids)} exported functions | an edge means ",
                        "the target is reached through internal code | ",
                        "gold triangle = anvl (XLA), green square = gdalraster (GDAL)"),
                      width = "100%", height = "850px") |>
  visEdges(arrows = "to", smooth = FALSE) |>
  visIgraphLayout(layout = "layout_with_fr", niter = 800) |>
  visOptions(
    highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE,
                            algorithm = "hierarchical"),
    nodesIdSelection = list(enabled = TRUE, main = "jump to function"),
    selectedBy = list(variable = "group", main = "filter by module")
  ) |>
  visLegend(
    useGroups = FALSE, width = 0.14, position = "right", ncol = 1,
    addNodes = c(
      lapply(names(mod_palette), function(m)
        list(label = m, shape = "dot", size = 12, color = mod_palette[[m]])),
      list(
        list(label = "anvl (XLA)", shape = "triangle", size = 12, color = "#D4A017"),
        list(label = "gdalraster (GDAL)", shape = "square", size = 12, color = "#2E7D32"),
        list(label = "other dep (pkg)", shape = "diamond", size = 12, color = "#BBBBBB")
      )
    )) |>
  visInteraction(navigationButtons = TRUE, keyboard = TRUE, tooltipDelay = 100)

visSave(api_net, file.path(out_dir, "garry-api-graph.html"), selfcontained = TRUE)
cat(glue("API graph: {length(api_ids)} exported nodes, ",
         "{nrow(api_edge_df)} edges\n\n"))

# ---------------------------------------------------------------------------
# anvl surface report (meeting prep)
# ---------------------------------------------------------------------------
anvl_edges <- edges_ext[edges_ext$pkg == "anvl", ]
anvl_funs <- sort(unique(sub("^anvl::", "", anvl_edges$to)))
md <- c(
  "# garry's anvl surface",
  "",
  glue("Generated by package-graph/build_graph.R on {Sys.Date()}. ",
       "Static analysis of R/*.R."),
  "",
  glue("garry calls **{length(anvl_funs)} distinct anvl functions**, ",
       "from **{length(unique(anvl_edges$from))} internal functions** in ",
       "{paste(sort(unique(int_nodes$file[int_nodes$id %in% anvl_edges$from])), collapse = ', ')}."),
  "",
  "## anvl functions used, and by whom",
  "",
  "| anvl function | called from |",
  "|---|---|",
  vapply(anvl_funs, function(f) {
    callers <- sort(unique(anvl_edges$from[anvl_edges$to == paste0("anvl::", f)]))
    glue("| `{f}` | {paste0('`', callers, '`', collapse = ', ')} |")
  }, ""),
  "",
  "## Internal functions that touch anvl",
  "",
  "| garry function | file | anvl calls |",
  "|---|---|---|",
  {
    touchers <- int_nodes[nzchar(int_nodes$anvl), ]
    touchers <- touchers[order(touchers$file, touchers$id), ]
    glue_data(touchers, "| `{id}` | {file} | {anvl} |")
  }
)
writeLines(md, file.path(out_dir, "anvl-surface.md"))

cat(glue("Wrote {file.path(out_dir, 'garry-package-graph.html')}\n"))
cat(glue("Wrote {file.path(out_dir, 'anvl-surface.md')}\n"))

# Keep the pkgdown architecture article's embedded copies in sync.
art_dir <- file.path(pkg_root, "vignettes", "articles")
if (dir.exists(art_dir)) {
  file.copy(
    file.path(out_dir, c("garry-package-graph.html", "garry-api-graph.html")),
    art_dir, overwrite = TRUE
  )
  cat(glue("Synced graph HTML into {art_dir}\n"))
}
