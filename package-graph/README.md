# package-graph

Static map of the garry package, built for reasoning about architecture and
external boundaries (notably anvl).

## Usage

```sh
Rscript package-graph/build_graph.R
```

Requires `visNetwork`, `igraph`, `glue` (dev machine only; not package deps).
Pure static analysis of `R/*.R`: files are parsed, never evaluated, so anvl
and XLA are not needed to run it.

## Outputs

- `garry-api-graph.html`: the exported API surface only. Internal call
  chains collapse into direct edges; per-package boundary nodes show
  which verbs ultimately reach anvl, gdalraster, or mirai. Embedded in
  the pkgdown "Architecture" article (`vignettes/articles/`), which the
  script re-syncs on every run.
- `garry-package-graph.html`: self-contained interactive DAG. Nodes are
  top-level definitions (functions, S7 classes, generics and
  `S7::method()` assignments), coloured by subsystem and sized by line
  count. Gold triangles are anvl functions, green squares gdalraster
  functions, grey diamonds other external packages (one node per package).
  Solid grey edges are calls, dashed blue edges S7 dispatch
  (generic to method). Thick borders mark exported functions. Click a node
  to highlight its one-hop neighbourhood; the dropdowns jump to a function
  or filter by module.
- `anvl-surface.md`: every anvl function garry calls and the internal
  functions that call it. Regenerate before anvl API discussions.
- `anvl-meeting.md`: hand-maintained companion to the surface table:
  the contract framing, semantics the parity suite locks, fork patches,
  implicit behaviour garry leans on, and the upstreaming asks. Not
  touched by `build_graph.R`.
- `graph-data.rds`: `list(nodes, edges, defs_meta)` data frames for ad hoc
  queries (degree, dead code, boundary audits).

## Notes

- The file-to-module mapping is curated at the top of `build_graph.R`;
  update it when files are added.
- Call detection walks ASTs for call heads plus bare symbol references
  matching known definitions (so functions passed to `lapply()` etc. count
  as edges). `pkg::fun` references are collected for external edges.
- First definition of a name wins if a name is defined twice.
