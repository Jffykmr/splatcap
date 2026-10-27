from pathlib import Path

import numpy as np
from PIL import Image

from .frames import Frame


def read_depth(path: Path, w: int = 256, h: int = 192) -> np.ndarray:
    return np.frombuffer(Path(path).read_bytes(), dtype="<f4").reshape(h, w)


def read_confidence(path: Path, w: int = 256, h: int = 192) -> np.ndarray:
    return np.frombuffer(Path(path).read_bytes(), dtype=np.uint8).reshape(h, w)


def write_depth_png(depth: np.ndarray, conf: np.ndarray, path: Path, min_conf: int = 2) -> None:
    """PNG 16 bit in millimetri; 0 = nessuna misura (convenzione di Spirula per depths/)."""
    mm = np.zeros(depth.shape, dtype=np.float64)
    ok = (conf >= min_conf) & np.isfinite(depth) & (depth > 0) & (depth < 65.535)
    mm[ok] = np.rint(depth[ok].astype(np.float64) * 1000.0)
    Image.fromarray(mm.astype(np.uint16)).save(path)


def unproject_depth(depth: np.ndarray, conf: np.ndarray, frame: Frame, min_conf: int = 2, stride: int = 4) -> np.ndarray:
    h, w = depth.shape
    s = w / frame.width
    fx, fy, cx, cy = frame.fx * s, frame.fy * s, frame.cx * s, frame.cy * s
    v, u = np.mgrid[0:h:stride, 0:w:stride]
    d, c = depth[::stride, ::stride], conf[::stride, ::stride]
    ok = (c >= min_conf) & np.isfinite(d) & (d > 0)
    u, v, d = u[ok].astype(np.float64), v[ok].astype(np.float64), d[ok].astype(np.float64)
    cam = np.stack([(u - cx) * d / fx, -(v - cy) * d / fy, -d, np.ones_like(d)], axis=1)
    return (cam @ frame.cam_to_world.T)[:, :3]


def sample_colors(points: np.ndarray, frame: Frame, image: np.ndarray) -> np.ndarray:
    """Colore dell'immagine nel punto in cui ogni punto mondo proietta (indici limitati ai bordi)."""
    pc = np.hstack([points, np.ones((len(points), 1))]) @ np.linalg.inv(frame.cam_to_world).T
    z = np.maximum(-pc[:, 2], 1e-9)
    u = np.clip(np.rint(frame.fx * pc[:, 0] / z + frame.cx), 0, image.shape[1] - 1).astype(int)
    v = np.clip(np.rint(frame.cy - frame.fy * pc[:, 1] / z), 0, image.shape[0] - 1).astype(int)
    return image[v, u]
