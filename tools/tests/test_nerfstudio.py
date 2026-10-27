import json

import numpy as np

from splatcap_tools.frames import Frame
from splatcap_tools.nerfstudio import write_transforms


def _frame(name, tx=0.0, fx=1000.0):
    m = np.eye(4)
    m[:3, 3] = [tx, 0, 0]
    return Frame(name, m, fx, fx, 960.0, 720.0, 1920, 1440, f"{name}_depth.bin", f"{name}_confidence.bin")


def test_write_transforms_pinhole_global_intrinsics(tmp_path):
    frames = [_frame("a", 0), _frame("b", 1), _frame("c", 2)]
    out = write_transforms(frames, tmp_path)
    d = json.loads(out.read_text())
    assert d["camera_model"] == "PINHOLE"
    assert (d["fl_x"], d["fl_y"], d["cx"], d["cy"], d["w"], d["h"]) == (1000.0, 1000.0, 960.0, 720.0, 1920, 1440)
    assert [f["file_path"] for f in d["frames"]] == ["images/a.jpg", "images/b.jpg", "images/c.jpg"]
    assert np.allclose(d["frames"][2]["transform_matrix"], frames[2].cam_to_world)
    assert "fl_x" not in d["frames"][0]


def test_write_transforms_per_frame_when_intrinsics_differ(tmp_path):
    frames = [_frame("a", fx=1000.0), _frame("b", fx=1010.0)]
    d = json.loads(write_transforms(frames, tmp_path).read_text())
    assert "fl_x" not in d
    assert [f["fl_x"] for f in d["frames"]] == [1000.0, 1010.0]
    assert all(f["w"] == 1920 and f["h"] == 1440 for f in d["frames"])
