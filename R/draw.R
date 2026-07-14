#' @include dataset.R lazy_raster.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Terminal rendering of lazy objects: compact `print()` cards and `draw()`,
# a visual of the pipeline BEFORE execution. A LazyDataset draws as its step
# pipeline (source -> mask -> reduce ...); a LazyRaster draws as its IR tree,
# with structurally identical sibling branches collapsed to "xN" so a 250-node
# composite graph stays readable.
# ---------------------------------------------------------------------------

# kind -> colour / glyph. ASCII fallback when the terminal is not UTF-8.
.kind_col <- c(source = "blue", map = "green", focal = "magenta",
               reduce = "yellow", stack = "cyan", warp = "red",
               fused = "grey", mask = "red", math = "green",
               derive = "green", node = "grey")
.kind_glyph_u <- c(source = "◈", map = "ƒ", focal = "◫",
                   reduce = "▸", stack = "⬚", warp = "→",
                   fused = "▣", mask = "✕", math = "±",
                   derive = "⊕", node = "•")
.kind_glyph_a <- c(source = "o", map = "f", focal = "#", reduce = ">",
                   stack = "=", warp = "~", fused = "@", mask = "x",
                   math = "+", derive = "+", node = "*")

.style <- function(kind, text) cli::make_ansi_style(.kind_col[[kind]] %||% "grey")(text)
.kind_glyph <- function(kind) {
  g <- if (cli::is_utf8_output()) .kind_glyph_u else .kind_glyph_a
  .style(kind, g[[kind]] %||% "*")
}
.box_chars <- function() {
  if (cli::is_utf8_output())
    list(v = "│", t = "├─ ", l = "└─ ", g = "│  ")
  else list(v = "|", t = "+- ", l = "\\- ", g = "|  ")
}

# ---------------------------------------------------------------------------
# IR node labels
# ---------------------------------------------------------------------------

.node_kind <- function(node) {
  if (S7::S7_inherits(node, SourceNode)) "source"
  else if (S7::S7_inherits(node, FocalNode)) "focal"
  else if (S7::S7_inherits(node, MapNode)) "map"
  else if (S7::S7_inherits(node, ReduceNode)) "reduce"
  else if (S7::S7_inherits(node, StackNode)) "stack"
  else if (S7::S7_inherits(node, WarpNode)) "warp"
  else if (S7::S7_inherits(node, FusedNode)) "fused"
  else "node"
}

.dims_str <- function(grid) {
  d <- grid@dims
  paste0(paste(unname(d), collapse = cli::symbol$times %||% "x"), " ", grid@dtype)
}

.node_label <- function(node) {
  k <- .node_kind(node)
  body <- switch(k,
    source = paste0("source  ", cli::col_grey(.dims_str(node@grid))),
    focal  = sprintf("focal  r=%d", node@radius),
    map    = if (length(node@parents) > 1L)
               sprintf("map  (%d inputs)", length(node@parents)) else "map",
    reduce = sprintf("%s  over %s",
                     if (length(node@fn)) "custom reduce" else node@op,
                     paste(node@over, collapse = ",")),
    stack  = sprintf("stack  along %s", node@along),
    warp   = "warp",
    fused  = "fused",
    "node")
  .style(k, body)
}

# ---------------------------------------------------------------------------
# Build a collapsed tree from the IR: identical sibling subgraphs fold to one
# branch carrying a multiplicity.
# ---------------------------------------------------------------------------

.ir_tree <- function(graph, id) {
  node <- graph_get(graph, id)
  kids <- lapply(node@parents, function(p) .ir_tree(graph, p))
  list(kind = .node_kind(node), label = .node_label(node),
       children = .collapse_children(kids), mult = 1L)
}

.tree_sig <- function(n) paste0(
  n$kind, "|", n$label, "(",
  paste(vapply(n$children, .tree_sig, character(1)), collapse = ","), ")")

.collapse_children <- function(kids) {
  if (!length(kids)) return(kids)
  sigs <- vapply(kids, .tree_sig, character(1))
  keep <- !duplicated(sigs)
  counts <- as.integer(table(sigs)[sigs[keep]])
  Map(function(r, m) { r$mult <- m; r }, kids[keep], counts)
}

.render_tree <- function(node, prefix = "", is_last = TRUE, is_root = TRUE,
                         box = .box_chars()) {
  conn <- if (is_root) "" else if (is_last) box$l else box$t
  mult <- if (node$mult > 1L)
    cli::col_grey(sprintf("  %s%d", if (cli::is_utf8_output()) "×" else "x",
                          node$mult)) else ""
  line <- paste0(prefix, conn, .kind_glyph(node$kind), " ", node$label, mult)
  child_prefix <- paste0(prefix, if (is_root) "" else if (is_last) "   " else box$g)
  lines <- line
  n <- length(node$children)
  for (i in seq_len(n))
    lines <- c(lines, .render_tree(node$children[[i]], child_prefix,
                                   i == n, FALSE, box))
  lines
}

# ---------------------------------------------------------------------------
# Compact print cards
# ---------------------------------------------------------------------------

.card <- function(title, rows, hint = NULL) {
  cat(cli::rule(left = title, line_col = "grey"), "\n", sep = "")
  w <- max(nchar(vapply(rows, `[[`, character(1), 1L)))
  for (r in rows)
    cat("  ", cli::style_bold(formatC(r[[1L]], width = -w)), "  ", r[[2L]],
        "\n", sep = "")
  if (!is.null(hint))
    cat(cli::col_grey(paste0("  ", cli::symbol$info %||% "i", " ", hint)),
        "\n", sep = "")
  invisible(NULL)
}

S7::method(print, LazyRaster) <- function(x, ...) {
  node <- graph_get(x@graph, x@node_id)
  g <- x@grid
  .card(
    sprintf("<LazyRaster> %s", .node_label(node)),
    list(
      c("grid", sprintf("%s %s %s", paste(unname(g@dims), collapse = " x "),
                        cli::symbol$bullet %||% "-", g@dtype)),
      c("crs",  .crs_label(g@crs)),
      c("graph", sprintf("%d nodes %s lazy", length(graph_ids(x@graph)),
                         cli::symbol$bullet %||% "-"))
    ),
    hint = "draw(x) to see the pipeline")
  invisible(x)
}

S7::method(print, LazyDataset) <- function(x, ...) {
  g  <- .ds_grid(x)
  nl <- vapply(x@bands, length, integer(1))
  val <- .ds_value_bands(x)
  bands_txt <- paste(val, collapse = " ")
  if (length(x@mask_asset))
    bands_txt <- paste0(bands_txt, cli::col_grey(sprintf("  (+%s)", x@mask_asset)))
  .card(
    "<LazyDataset>",
    list(
      c("bands", bands_txt),
      c("time",  .slices_txt(.ds_n_slices(x))),
      c("grid",  sprintf("%s x %s %s %s", g@dims[["x"]], g@dims[["y"]],
                         cli::symbol$bullet %||% "-", g@dtype)),
      c("crs",   .crs_label(g@crs)),
      c("graph", sprintf("%d nodes %s lazy", length(graph_ids(x@graph)),
                         cli::symbol$bullet %||% "-"))
    ),
    hint = "draw(x) to see the pipeline")
  invisible(x)
}

# Original slice count: from the stored source step (survives reduce), else the
# current per-band layer count.
.ds_n_slices <- function(x) {
  src <- Find(function(s) identical(s$kind, "source"), x@steps)
  if (!is.null(src) && is.numeric(src$detail)) src$detail
  else max(vapply(x@bands, length, integer(1)))
}
.slices_txt <- function(n) sprintf("%d slice%s", n, if (n == 1L) "" else "s")

# Short human CRS label: an EPSG code if the WKT carries one, else the name.
.crs_label <- function(crs) {
  if (!nzchar(crs)) return("(none)")
  if (grepl("^EPSG:[0-9]+$", crs, ignore.case = TRUE)) return(toupper(crs))
  m <- regmatches(crs, regexpr('EPSG","[0-9]+"\\]\\]\\s*$', crs, perl = TRUE))
  if (length(m) == 1L && nzchar(m))
    return(paste0("EPSG:", sub('.*?([0-9]+).*', "\\1", m)))
  nm <- tryCatch(gdalraster::srs_get_name(crs), error = function(e) "")
  if (length(nm) == 1L && nzchar(nm) && !identical(tolower(nm), "unknown"))
    return(nm)
  # Bespoke CRS (e.g. a centred LAEA): name the projection method instead.
  pm <- regmatches(crs, regexpr('PROJECTION\\["[^"]+"', crs))
  if (length(pm) == 1L && nzchar(pm))
    return(gsub("_", " ", gsub('PROJECTION\\["|"$', "", pm)))
  "(custom)"
}

# ---------------------------------------------------------------------------
# draw(): the pipeline visual
# ---------------------------------------------------------------------------

#' Draw the pipeline of a lazy object.
#'
#' Prints a terminal visual of the computation a lazy object will run, before
#' any reading or compute happens. A `LazyDataset` draws as its step pipeline
#' (source, mask, reduce, ...); a `LazyRaster` draws as its IR tree, with
#' structurally identical sibling branches folded to a single `xN` branch so a
#' large composite graph stays readable.
#'
#' @param x A `LazyRaster` or `LazyDataset`.
#' @param ... Unused.
#' @return `x`, invisibly.
#' @export
draw <- S7::new_generic("draw", "x")

S7::method(draw, LazyRaster) <- function(x, ...) {
  g <- x@grid
  cat(cli::rule(left = sprintf("<LazyRaster> %s x %s %s %s",
                               g@dims[["x"]], g@dims[["y"]],
                               cli::symbol$bullet %||% "-", g@dtype),
                line_col = "grey"), "\n", sep = "")
  cat(.render_tree(.ir_tree(x@graph, x@node_id)), sep = "\n")
  cat("\n")
  invisible(x)
}

S7::method(draw, LazyDataset) <- function(x, ...) {
  g  <- .ds_grid(x)
  nl <- vapply(x@bands, length, integer(1))
  cat(cli::rule(left = "<LazyDataset> pipeline", line_col = "grey"), "\n",
      sep = "")
  # Each stored step is one row; the source step is synthesised live so the
  # band list stays current.
  steps <- x@steps
  if (!length(steps) || steps[[1L]]$kind != "source")
    steps <- c(list(.step("source", "source", detail = max(nl))), steps)
  for (s in steps) {
    detail <- if (identical(s$kind, "source")) {
      val <- .ds_value_bands(x)
      bt <- paste(val, collapse = " ")
      if (length(x@mask_asset)) bt <- paste0(bt, sprintf(" (+%s)", x@mask_asset))
      sprintf("%s  %s  %s %s %s", bt, cli::symbol$bullet %||% "-",
              .slices_txt(s$detail), cli::symbol$bullet %||% "-", .dims_str(g))
    } else s$detail %||% ""
    cat("  ", .kind_glyph(s$kind), " ", .style(s$kind, formatC(s$label, width = -8)),
        "  ", cli::col_grey(detail), "\n", sep = "")
  }
  cat("  ", cli::col_grey(sprintf("%s %d nodes %s crs %s",
      cli::symbol$line %||% "-", length(graph_ids(x@graph)),
      cli::symbol$bullet %||% "-", .crs_label(g@crs))), "\n", sep = "")
  invisible(x)
}
