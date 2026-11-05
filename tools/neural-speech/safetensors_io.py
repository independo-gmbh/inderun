"""Minimal safetensors reader/writer (F32 and I64 only; no `safetensors` dependency)."""
from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

_DTYPES = {"F32": np.dtype("<f4"), "I64": np.dtype("<i8")}
_NAMES = {np.dtype(np.float32): "F32", np.dtype(np.int64): "I64"}


def write_safetensors(path, tensors: dict[str, np.ndarray], metadata: dict[str, str]) -> None:
    header: dict = {"__metadata__": dict(metadata)}
    chunks, offset = [], 0
    for name, arr in tensors.items():
        arr = np.ascontiguousarray(arr)
        if arr.dtype not in _NAMES:
            raise ValueError(f"tensor {name!r}: dtype {arr.dtype} is not F32 or I64")
        raw = arr.astype(_DTYPES[_NAMES[arr.dtype]], copy=False).tobytes()
        header[name] = {"dtype": _NAMES[arr.dtype], "shape": list(arr.shape), "data_offsets": [offset, offset + len(raw)]}
        chunks.append(raw)
        offset += len(raw)
    blob = json.dumps(header, separators=(",", ":")).encode("utf-8")
    blob += b" " * (-len(blob) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(blob)))
        f.write(blob)
        for raw in chunks:
            f.write(raw)


def read_safetensors(path) -> tuple[dict[str, np.ndarray], dict[str, str]]:
    data = Path(path).read_bytes()
    (n,) = struct.unpack("<Q", data[:8])
    header = json.loads(data[8:8 + n])
    base = 8 + n
    metadata = header.pop("__metadata__", {})
    tensors = {}
    for name, entry in header.items():
        if entry["dtype"] not in _DTYPES:
            raise ValueError(f"tensor {name!r}: unsupported dtype {entry['dtype']}")
        lo, hi = entry["data_offsets"]
        tensors[name] = np.frombuffer(data[base + lo:base + hi], _DTYPES[entry["dtype"]]).reshape(entry["shape"]).copy()
    return tensors, metadata
