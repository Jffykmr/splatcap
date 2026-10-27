import json
from pathlib import Path

from .frames import Frame

_TOL = 1e-3


def _intrinsics(f: Frame) -> dict:
    return {"fl_x": f.fx, "fl_y": f.fy, "cx": f.cx, "cy": f.cy, "w": f.width, "h": f.height}


def _same(a: dict, b: dict) -> bool:
    return all(abs(a[k] - b[k]) <= _TOL for k in a)


def write_transforms(frames: list[Frame], out_dir: Path) -> Path:
    base = _intrinsics(frames[0])
    shared = all(_same(base, _intrinsics(f)) for f in frames)
    doc = {"camera_model": "PINHOLE"}
    if shared:
        doc.update(base)
    doc["frames"] = []
    for f in frames:
        entry = {"file_path": f"images/{f.name}.jpg", "transform_matrix": f.cam_to_world.tolist()}
        if not shared:
            entry.update(_intrinsics(f))
        doc["frames"].append(entry)
    out = Path(out_dir) / "transforms.json"
    out.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    return out
