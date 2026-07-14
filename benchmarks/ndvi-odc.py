# ODC + Dask NDVI benchmark: mirror of hls-median-composite-odc.py, but two
# bands (B04, B08) -> temporal median each -> NDVI = (B08 - B04) / (B08 + B04).
# Same workload, grid, mask cleanup as the composite baseline.

import time

import planetary_computer as pc
from odc.algo import mask_cleanup
from odc.geo.geobox import GeoBox
from odc.geo.xr import write_cog
from odc.stac import configure_rio, load
from pystac_client import Client

configure_rio(cloud_defaults=True)

catalog = "https://planetarycomputer.microsoft.com/api/stac/v1/"
collection = "hls2-s30"
bounds = [144.13, -7.725, 144.47, -7.475]
epsg = 20255
dx = 30
geobox = GeoBox.from_bbox(
    [183060, 9144870, 220830, 9172800], crs=f"epsg:{epsg}", resolution=dx
)
date_string = "2023-01-01/2023-12-31"

items = (
    Client.open(catalog, modifier=pc.sign_inplace)
    .search(collections=collection, bbox=bounds, datetime=date_string)
    .items()
)

start = time.time()

data = load(
    items,
    geobox=geobox,
    chunks={"x": 2048, "y": 2048, "time": 1},
    bands=["B04", "B08", "Fmask"],
    resampling="bilinear",
)

mask_bitfields = [0, 1, 2, 3]
bitmask = 0
for field in mask_bitfields:
    bitmask |= 1 << field

cloud_mask = data["Fmask"].astype(int) & bitmask != 0
dilated = mask_cleanup(cloud_mask, [("opening", 2), ("dilation", 3)])
masked = data.where(~dilated)

b04 = masked["B04"].median(dim="time")
b08 = masked["B08"].median(dim="time")
ndvi = (b08 - b04) / (b08 + b04)

ndvi_result = ndvi.compute()

write_cog(ndvi_result, fname="ndvi_python.tif", overwrite=True)

elapsed = time.time() - start
print(f"Elapsed time (Python/ODC + Dask NDVI): {elapsed:.2f} seconds")
