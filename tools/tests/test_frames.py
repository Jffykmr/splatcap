from pathlib import Path

import numpy as np
import piexif
import pytest
from PIL import Image

from splatcap_tools.frames import check_pixel_geometry, neutralize_exif, parse_frame

FIXTURE = Path(__file__).parent / "fixtures" / "frame.json"


def test_parse_frame_matches_arkit_layout():
    f = parse_frame(FIXTURE)
    assert np.allclose(f.cam_to_world[:3, 3], [-2.9454567, -0.5109007, -2.1952050], atol=1e-6)
    assert np.allclose(f.cam_to_world[3], [0, 0, 0, 1])
    assert f.fx == pytest.approx(1346.6446533, abs=1e-4)
    assert f.fy == pytest.approx(1346.6446533, abs=1e-4)
    assert f.cx == pytest.approx(957.7692871, abs=1e-4)
    assert f.cy == pytest.approx(721.6481323, abs=1e-4)
    assert (f.width, f.height) == (1920, 1440)
    assert f.name == "wide_20260715_101053_150"
    assert f.depth_file == "wide_20260715_101053_150_depth.bin"
    assert f.conf_file == "wide_20260715_101053_150_confidence.bin"


def _jpeg(path: Path, size, orientation=None):
    img = Image.new("RGB", size, (200, 100, 50))
    kwargs = {}
    if orientation:
        kwargs["exif"] = piexif.dump({"0th": {piexif.ImageIFD.Orientation: orientation}})
    img.save(path, "JPEG", **kwargs)


def test_check_pixel_geometry_rejects_rotated_jpeg(tmp_path):
    f = parse_frame(FIXTURE)
    p = tmp_path / "a.jpg"
    _jpeg(p, (1440, 1920))
    with pytest.raises(ValueError, match=r"1440x1920.*1920x1440"):
        check_pixel_geometry(p, f)


def test_check_pixel_geometry_accepts_matching_jpeg(tmp_path):
    f = parse_frame(FIXTURE)
    p = tmp_path / "a.jpg"
    _jpeg(p, (1920, 1440))
    check_pixel_geometry(p, f)


def test_neutralize_exif_keeps_pixels(tmp_path):
    src, dst = tmp_path / "s.jpg", tmp_path / "d.jpg"
    _jpeg(src, (64, 48), orientation=6)
    neutralize_exif(src, dst)
    assert Image.open(dst).size == (64, 48)
    assert piexif.load(str(dst))["0th"].get(piexif.ImageIFD.Orientation) is None
    assert np.array_equal(np.asarray(Image.open(src)), np.asarray(Image.open(dst)))
