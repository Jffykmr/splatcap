"""Converte una capture Splatking in una cartella Nerfstudio per Spirula.

Uso: python convert_splatking.py <capture_dir> <out_dir>
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from splatcap_tools.depth import read_confidence, read_depth, sample_colors, unproject_depth, write_depth_png
from splatcap_tools.frames import check_pixel_geometry, neutralize_exif, parse_frame
from splatcap_tools.nerfstudio import write_transforms
from splatcap_tools.ply import write_seed_ply


def convert(capture: Path, out: Path) -> list:
    images_in = capture / "COLMAP_Text_Model" / "images"
    sensors = capture / "sensor_data"
    (out / "images").mkdir(parents=True, exist_ok=True)
    frames, seed_pts, seed_cols = [], [], []
    for js in sorted(sensors.glob("*.json")):
        frame = parse_frame(js)
        src = images_in / f"{frame.name}.jpg"
        if not src.exists():
            continue
        check_pixel_geometry(src, frame)
        neutralize_exif(src, out / "images" / src.name)
        frames.append(frame)
        if (sensors / frame.depth_file).exists() and (sensors / frame.conf_file).exists():
            depth, conf = read_depth(sensors / frame.depth_file), read_confidence(sensors / frame.conf_file)
            (out / "depths").mkdir(exist_ok=True)
            write_depth_png(depth, conf, out / "depths" / f"{frame.name}.png")
            pts = unproject_depth(depth, conf, frame)
            if len(pts):
                seed_pts.append(pts)
                seed_cols.append(sample_colors(pts, frame, np.asarray(Image.open(src).convert("RGB"))))
    write_transforms(frames, out)
    if seed_pts:
        write_seed_ply(np.vstack(seed_pts), np.vstack(seed_cols), out / "seed.ply")
    return frames


if __name__ == "__main__":
    frames = convert(Path(sys.argv[1]), Path(sys.argv[2]))
    print(f"{len(frames)} fotogrammi")
