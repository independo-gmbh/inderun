"""Rewrite the upstream `text` graph so every input is int64 (the ORT Objective-C binding cannot feed bool)."""
from __future__ import annotations

from pathlib import Path

import onnx
from onnx import TensorProto, helper


def rewrite_text_mask_to_int64(src: Path, dst: Path) -> None:
    """`text_mask` (bool) becomes `text_mask_bool`, fed by a Cast(to=BOOL) from a new int64 graph input `text_mask`."""
    model = onnx.load(str(src), load_external_data=True)
    graph = model.graph
    old = next(i for i in graph.input if i.name == "text_mask")
    dims = [d for d in old.type.tensor_type.shape.dim]
    for node in graph.node:
        for k, name in enumerate(node.input):
            if name == "text_mask":
                node.input[k] = "text_mask_bool"
    new = helper.make_tensor_value_info("text_mask", TensorProto.INT64, [d.dim_param or d.dim_value for d in dims])
    cast = helper.make_node("Cast", ["text_mask"], ["text_mask_bool"], name="text_mask_to_bool", to=TensorProto.BOOL)
    position = list(graph.input).index(old)
    graph.input.remove(old)
    graph.input.insert(position, new)
    graph.node.insert(0, cast)
    onnx.checker.check_model(model)
    onnx.save(model, str(dst))

    import onnxruntime as ort
    types = {i.name: i.type for i in ort.InferenceSession(str(dst), providers=["CPUExecutionProvider"]).get_inputs()}
    for name in ("text_ids", "language", "text_mask"):
        if types.get(name) != "tensor(int64)":
            raise RuntimeError(f"rewritten text graph: input {name} is {types.get(name)}, expected tensor(int64)")
