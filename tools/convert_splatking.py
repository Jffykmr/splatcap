"""Converte una capture Splatking in una cartella Nerfstudio per Spirula.

Uso: python convert_splatking.py <capture_dir> <out_dir>
"""
import sys
from pathlib import Path

from splatcap_tools.frames import check_pixel_geometry, neutralize_exif, parse_frame
from splatcap_tools.nerfstudio import write_transforms


def convert(capture: Path, out: Path) -> list:
    images_in = capture / "COLMAP_Text_Model" / "images"
    (out / "images").mkdir(parents=True, exist_ok=True)
    frames = []
    for js in sorted((capture / "sensor_data").glob("*.json")):
        frame = parse_frame(js)
        src = images_in / f"{frame.name}.jpg"
        if not src.exists():
            continue
        check_pixel_geometry(src, frame)
        neutralize_exif(src, out / "images" / src.name)
        frames.append(frame)
    write_transforms(frames, out)
    return frames


if __name__ == "__main__":
    frames = convert(Path(sys.argv[1]), Path(sys.argv[2]))
    print(f"{len(frames)} fotogrammi")
