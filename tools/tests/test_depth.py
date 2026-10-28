import shutil
from pathlib import Path

import numpy as np
from PIL import Image

from convert_splatking import convert
from splatcap_tools.depth import read_confidence, read_depth, unproject_depth
from splatcap_tools.frames import Frame

FIXTURE = Path(__file__).parent / "fixtures" / "frame.json"
NAME = "wide_20260715_101053_150"


def _frame(tx=(0.0, 0.0, 0.0)):
    m = np.eye(4)
    m[:3, 3] = tx
    return Frame("f", m, 100.0, 100.0, 128.0, 96.0, 256, 192, "f_depth.bin", "f_confidence.bin")


def _full(value, shape=(192, 256), dtype=np.float32):
    return np.full(shape, value, dtype=dtype)


def test_unproject_principal_point():
    pts = unproject_depth(_full(2.0), _full(2, dtype=np.uint8), _frame(), stride=1)
    centre = pts[np.argmin(np.linalg.norm(pts[:, :2], axis=1))]
    assert np.allclose(centre, [0, 0, -2])
    moved = unproject_depth(_full(2.0), _full(2, dtype=np.uint8), _frame((1, 2, 3)), stride=1)
    c2 = moved[np.argmin(np.linalg.norm(moved[:, :2] - [1, 2], axis=1))]
    assert np.allclose(c2, [1, 2, 1])


def test_unproject_drops_low_confidence():
    conf = _full(2, dtype=np.uint8)
    conf[:, :128] = 1
    conf[:96, :] = 0
    pts = unproject_depth(_full(2.0), conf, _frame(), min_conf=2, stride=1)
    assert len(pts) == 96 * 128
    assert np.all(pts[:, 0] >= 0) and np.all(pts[:, 1] <= 0)


def test_read_depth_and_confidence_roundtrip(tmp_path):
    d = np.arange(192 * 256, dtype=np.float32).reshape(192, 256)
    c = (np.arange(192 * 256) % 3).astype(np.uint8).reshape(192, 256)
    (tmp_path / "d.bin").write_bytes(d.tobytes())
    (tmp_path / "c.bin").write_bytes(c.tobytes())
    assert np.array_equal(read_depth(tmp_path / "d.bin"), d)
    assert np.array_equal(read_confidence(tmp_path / "c.bin"), c)


def test_write_depth_png_millimetres_zero_where_unreliable(tmp_path):
    from splatcap_tools.depth import write_depth_png

    d = _full(1.2345)
    d[0, 0] = np.nan
    d[0, 1] = 100.0  # oltre 65,5 m: non rappresentabile, deve diventare 0
    c = _full(2, dtype=np.uint8)
    c[1, 0] = 1
    p = tmp_path / "d.png"
    write_depth_png(d, c, p)
    img = Image.open(p)
    assert img.mode == "I;16" and img.size == (256, 192)
    a = np.asarray(img)
    assert a[5, 5] == 1234 or a[5, 5] == 1235
    assert a[0, 0] == 0 and a[0, 1] == 0 and a[1, 0] == 0


def test_convert_writes_depths_named_like_images(tmp_path):
    out = tmp_path / "out"
    convert(_synthetic_capture(tmp_path, conf_value=2), out)
    assert (out / "depths" / f"{NAME}.png").exists()


def _synthetic_capture(root: Path, conf_value: int) -> Path:
    cap = root / "cap"
    (cap / "sensor_data").mkdir(parents=True)
    (cap / "COLMAP_Text_Model" / "images").mkdir(parents=True)
    shutil.copy(FIXTURE, cap / "sensor_data" / f"{NAME}.json")
    (cap / "sensor_data" / f"{NAME}_depth.bin").write_bytes(_full(2.0).tobytes())
    (cap / "sensor_data" / f"{NAME}_confidence.bin").write_bytes(_full(conf_value, dtype=np.uint8).tobytes())
    Image.new("RGB", (1920, 1440), (10, 200, 30)).save(cap / "COLMAP_Text_Model" / "images" / f"{NAME}.jpg")
    return cap


def test_empty_seed_not_written(tmp_path):
    out = tmp_path / "out"
    frames = convert(_synthetic_capture(tmp_path, conf_value=0), out)
    assert len(frames) == 1
    assert (out / "transforms.json").exists()
    assert not (out / "sparse_pc.ply").exists()


def test_seed_written_with_colors_when_confident(tmp_path):
    out = tmp_path / "out"
    convert(_synthetic_capture(tmp_path, conf_value=2), out)
    raw = (out / "sparse_pc.ply").read_bytes()
    header, _, body = raw.partition(b"end_header\n")
    assert b"property uchar red" in header and b"format binary_little_endian 1.0" in header
    n = int([l for l in header.decode().splitlines() if l.startswith("element vertex")][0].split()[-1])
    assert n > 0 and len(body) == n * (12 + 3)
    assert tuple(body[12:15]) == (10, 200, 30)


def test_export_world_is_z_up(tmp_path):
    import json

    from splatcap_tools.frames import parse_frame

    out = tmp_path / "out"
    convert(_synthetic_capture(tmp_path, conf_value=2), out)
    t_arkit = parse_frame(FIXTURE).cam_to_world[:3, 3]
    m = np.array(json.loads((out / "transforms.json").read_text())["frames"][0]["transform_matrix"])
    assert np.allclose(m[:3, 3], [t_arkit[0], -t_arkit[2], t_arkit[1]])
