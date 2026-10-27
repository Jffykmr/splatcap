import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import piexif
from PIL import Image


@dataclass
class Frame:
    name: str
    cam_to_world: np.ndarray  # 4x4, row-major, ARKit camera axes (+X right, +Y up, camera looks along -Z)
    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int
    depth_file: str
    conf_file: str


def parse_frame(json_path: Path) -> Frame:
    data = json.loads(Path(json_path).read_text(encoding="utf-8"))
    cam = data["metadata"]["camera"]
    k = cam["intrinsics"]  # column-major 3x3
    aux = {a["type"]: a["filename"] for a in data["auxiliaryOutputs"] if "filename" in a}
    res = cam["imageResolution"]
    depth_file = aux.get("depth", "")
    return Frame(
        name=depth_file.removesuffix("_depth.bin") if depth_file else Path(json_path).stem,
        cam_to_world=np.array(cam["transform"], dtype=np.float64).reshape(4, 4).T,
        fx=k[0], fy=k[4], cx=k[6], cy=k[7],
        width=res["width"], height=res["height"],
        depth_file=depth_file,
        conf_file=aux.get("depthConfidence", ""),
    )


def check_pixel_geometry(jpeg: Path, frame: Frame) -> None:
    with Image.open(jpeg) as im:
        size = im.size
    if size != (frame.width, frame.height):
        raise ValueError(
            f"{Path(jpeg).name}: pixels are {size[0]}x{size[1]}, "
            f"pose/intrinsics expect {frame.width}x{frame.height}"
        )


def neutralize_exif(src: Path, dst: Path) -> None:
    piexif.remove(str(src), str(dst))
