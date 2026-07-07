# Benchmarking script for satellite data processing using Python ODC + Dask

import time

import planetary_computer as pc
from odc.algo import mask_cleanup
from odc.geo.geobox import GeoBox
from odc.geo.xr import write_cog
from odc.stac import configure_rio, load
from pystac_client import Client

# Configure for Planetary Computer
configure_rio(cloud_defaults=True)

# Set up STAC catalog and search parameters
catalog = "https://planetarycomputer.microsoft.com/api/stac/v1/"
collection = "hls2-s30"  # HLS Sentinel-2 30m v2.0
bounds = [144.13, -7.725, 144.47, -7.475]
epsg = 20255
dx = 30
geobox = GeoBox.from_bbox(
    [183060, 9144870, 220830, 9172800], crs=f"epsg:{epsg}", resolution=dx
)
# geobox
date_string = "2023-01-01/2023-12-31"


items = (
    Client.open(catalog, modifier=pc.sign_inplace)
    .search(collections=collection, bbox=bounds, datetime=date_string)
    .items()
)

start = time.time()


# Load data from STAC using odc-stac
data = load(
    items,
    geobox=geobox,
    # bbox=bounds,
    # resolution=30,  # Match R's tr = c(30, 30)
    # chunks={'time': 5, 'x': 600, 'y': 600},
    chunks={"x": 2048, "y": 2048, "time": 1},
    # groupby="solar_day",
    bands=["B04", "B03", "B02", "Fmask"],
    resampling="bilinear",
)


# Apply mask - Fmask values 0, 1, 2, 3 are valid (matching R example)
# Using bitmask approach from notebook
mask_bitfields = [0, 1, 2, 3]
bitmask = 0
for field in mask_bitfields:
    bitmask |= 1 << field

# Get cloud mask
cloud_mask = data["Fmask"].astype(int) & bitmask != 0

# Apply mask cleanup (optional, but good practice)
dilated = mask_cleanup(cloud_mask, [("opening", 2), ("dilation", 3)])

# Mask the data
masked = data.where(~dilated)


# Calculate median over time dimension
composite = masked[["B04", "B03", "B02"]].median(dim="time")


# Trigger computation (matching R's vrt_compute)
composite_result = composite.compute()

# apply offset and scale to match R output
# scale = 0.0001
# composite_result = composite_result * scale

# This version works with Datasets
write_cog(
    composite_result.to_array(dim="band"), fname="composite_python.tif", overwrite=True
)

elapsed = time.time() - start
print(f"Elapsed time (Python/ODC + Dask): {elapsed:.2f} seconds")
