# Pre-render network/compute-heavy vignettes so they never run on CRAN, CI, or a
# user's machine. Each `<name>.Rmd.orig` is the live source; this knits it to a
# static `<name>.Rmd` with outputs baked in, then rewrites `figure/` image paths
# to GitHub raw URLs so the PNGs are hosted, not bundled in the tarball. Run
# manually on a machine with the data/compute:  Rscript vignettes/precompute.R
#
# The .Rmd.orig and vignettes/figure/ are excluded from the build (.Rbuildignore).

GITHUB_RAW_BASE <-
  "https://raw.githubusercontent.com/belian-earth/garry/main/vignettes/"

# figure/foo.png -> <raw base>figure/foo.png, in ![](...) and src="..."/src='...'
fix_image_paths <- function(filename) {
  rmd <- readLines(filename)
  rmd <- gsub('(src=["\']|]\\()figure/',
              paste0("\\1", GITHUB_RAW_BASE, "figure/"), rmd)
  writeLines(rmd, filename)
}

prerender_it <- function(filename) {
  withr::with_dir("vignettes", {
    if (file.exists(filename)) file.remove(filename)
    knitr::knit(paste0(filename, ".orig"), filename)
    fix_image_paths(filename)
  })
}

prerender_it("hls-harmonized-pca.Rmd")
