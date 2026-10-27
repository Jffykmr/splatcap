from pathlib import Path

import numpy as np

_DTYPE = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")])


def write_seed_ply(points: np.ndarray, colors: np.ndarray, path: Path) -> None:
    v = np.empty(len(points), dtype=_DTYPE)
    v["x"], v["y"], v["z"] = points[:, 0], points[:, 1], points[:, 2]
    v["r"], v["g"], v["b"] = colors[:, 0], colors[:, 1], colors[:, 2]
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {len(v)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        "end_header\n"
    )
    Path(path).write_bytes(header.encode("ascii") + v.tobytes())
