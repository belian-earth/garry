"""Generate the OmniCloudMask golden fixture for garry's native OCM tests.

Run once, offline, on a machine with the OCM weights present:

    uv run --with "omnicloudmask==1.7.1" --with safetensors \
        python tools/ocm_make_fixture.py \
        ~/.local/share/omnicloudmask/1.7.1 \
        tests/testthat/fixtures/ocm/golden-128.safetensors

The fixture holds a deterministic synthetic (3, 128, 128) float32
red/green/NIR array (smooth fields + bright "cloud" blobs + a zero
nodata corner, DN-scaled) and, per model and for the two-model
ensemble, the raw mean logits and the default argmax class map from
`predict_from_array` with a single 128-px patch (so garry's whole-window
channel_norm sees identical geometry).  garry's test compares its own
forward pass against these outputs.
"""

import sys
from pathlib import Path

import numpy as np
import torch
from omnicloudmask.cloud_mask import predict_from_array
from omnicloudmask.model_utils import load_model_from_weights
from safetensors.numpy import save_file

SIZE = 128


def synth_input() -> np.ndarray:
    rng = np.random.default_rng(42)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE] / SIZE
    base = 800 + 400 * np.sin(6 * yy) * np.cos(4 * xx)
    bands = []
    for k, gain in enumerate([1.0, 1.2, 2.5]):  # red, green, NIR
        b = base * gain + 120 * rng.standard_normal((SIZE, SIZE))
        bands.append(b)
    arr = np.stack(bands).astype(np.float32)
    # two bright "cloud" blobs (high in all bands) and a dark "shadow"
    for cy, cx, r, v in [(40, 44, 14, 6000.0), (90, 100, 10, 5000.0)]:
        m = (yy * SIZE - cy) ** 2 + (xx * SIZE - cx) ** 2 < r**2
        arr[:, m] = v + 300 * rng.standard_normal((3, int(m.sum())))
    sh = (yy * SIZE - 70) ** 2 + (xx * SIZE - 30) ** 2 < 12**2
    arr[:, sh] *= 0.25
    arr[:, :10, :12] = 0.0  # nodata corner (no_data_value = 0)
    return np.ascontiguousarray(arr)


def main() -> None:
    weights_dir = Path(sys.argv[1]).expanduser()
    out_path = Path(sys.argv[2])
    out_path.parent.mkdir(parents=True, exist_ok=True)

    device = torch.device("cpu")
    specs = {
        "regnety": ("tu-regnety_004", "regnety_004"),
        "edgenext": ("tu-edgenext_small", "edgenext_small"),
    }
    models = {}
    for key, (enc, pat) in specs.items():
        (wf,) = [p for p in weights_dir.glob(f"*OCM*{pat}*state.safetensors")]
        models[key] = load_model_from_weights(
            model_name=enc, weights_path=wf, model_library="smp", device=device
        )

    arr = synth_input()
    out = {"input": arr}
    runs = {
        "regnety": [models["regnety"]],
        "edgenext": [models["edgenext"]],
        "ensemble": [models["regnety"], models["edgenext"]],
    }
    for key, ms in runs.items():
        logits = predict_from_array(
            arr,
            patch_size=SIZE,
            patch_overlap=0,
            custom_models=ms,
            inference_device=device,
            mosaic_device=device,
            export_confidence=True,
            softmax_output=False,
            apply_no_data_mask=False,
        )
        argmax = predict_from_array(
            arr,
            patch_size=SIZE,
            patch_overlap=0,
            custom_models=ms,
            inference_device=device,
            mosaic_device=device,
            apply_no_data_mask=True,
        )
        out[f"logits_{key}"] = np.asarray(logits, dtype=np.float32)
        out[f"argmax_{key}"] = np.asarray(argmax, dtype=np.float32)
        print(
            key,
            "logits",
            out[f"logits_{key}"].shape,
            "classes",
            np.unique(out[f"argmax_{key}"]),
        )

    save_file(out, str(out_path))
    print("wrote", out_path)


if __name__ == "__main__":
    main()
