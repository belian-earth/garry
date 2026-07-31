# Note: fixed-point iteration is the one missing engine primitive

Date: 2026-08-02. Status: QUEUED, revisit near-term against the anvl
roadmap.

The capability-gap review (this date) settled garry's scope: a closed
set of array primitives over grid-pinned cubes, expressed in anvl,
with GDAL as the only boundary. Within that scope one primitive class
is missing and cannot be composed from the others: **iterate a
map/focal body until convergence** (a 2-D, data-dependent-iteration
sibling of the scan node, with halo exchange between iterations at
chunk seams).

It unlocks the algorithm class currently out of reach: connected
components / patches, distance and cost-distance transforms, flow
accumulation, watershed / catchment delineation, morphological
reconstruction. XLA carries the While op natively; the loop primitive
is already on the anvl roadmap, so garry's work is the node + planner
semantics (convergence test as a device-side reduction, halo
re-exchange per iteration, admission for a whole-plane iterating
kernel), not the compiler.

Expressibility vs efficiency (settled after challenge): the
priority-queue algorithms (Vincent-Soille watershed, Dijkstra cost
distance) are WORK-EFFICIENCY devices, not semantic necessities. Their
results are fixed points of local recurrences: watershed = "take the
label of my steepest-descent neighbour" iterated to stability (with
deterministic tie and plateau rules); cost distance = iterated focal
min-plus (Bellman-Ford). Both are EXACT at convergence. What is
written off is the work-optimal sequential implementation, never the
result. The practical axis is iteration count: naive relaxation needs
O(longest path) plane sweeps — pathological for river networks —
but pointer-doubling formulations collapse label propagation to
O(log path) iterations and flow accumulation to a parallel prefix
over the same doubling. Kernel-design concern inside While, not a
scope limit. Long-path cost surfaces (geodesic) remain the case where
relaxation may stay practically unattractive; that is an engineering
call per algorithm, not a hard exclusion.

Decisions taken with it (capability review, Hugh):

- NO arbitrary-R escape hatch: extensibility is anvl expressions
  traced through the existing vocabulary, never host R per chunk.
- Whole-raster scalars (global x/y reductions feeding later nodes as
  broadcast scalars, i.e. a mid-graph materialisation barrier) are
  the other accepted engine gap: normalisation, stretch, histogram
  breaks.
- Vector interop stays at the GDAL boundary (rasterize/extract are
  not garry verbs). The one raster-pure candidate to keep in mind:
  reduce-by-key over a zone RASTER (segment-sum zonal stats).
- No aggregate/crop/extend/project verb family: the warper already
  expresses these (GDAL -r med/mode/average/q1/q3 covers factor
  aggregation); the gap is documentation of the warp node's range,
  not API.
- dtype completeness (integer in/out, categorical semantics beyond
  f32/NaN) is agreed scope.
- Sparse/dynamic-shape outputs deprioritised; raster-to-polygons out.
