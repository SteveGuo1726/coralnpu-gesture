"""Profile TFLite operator shapes for Coral NPU microbenchmark mapping."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Input .tflite model.")
    parser.add_argument("--out", required=True, help="Output JSON report.")
    parser.add_argument(
        "--backend",
        choices=["auto", "tensorflow", "flatbuffer"],
        default="auto",
        help="Parser backend. auto uses TensorFlow if available, otherwise tflite flatbuffer schema.",
    )
    parser.add_argument(
        "--tensorflow_op_resolver",
        choices=["builtin", "builtin_ref"],
        default="builtin",
        help=(
            "TensorFlow interpreter kernel set. builtin_ref avoids optional CPU delegates "
            "when profiling a valid model that an optimized delegate rejects."
        ),
    )
    return parser.parse_args()


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Create a venv under "
            "gesture_project/algorithms and run: pip install -r requirements.txt"
        ) from exc
    return tf


def require_tflite_schema():
    try:
        import tflite  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "Neither TensorFlow nor tflite schema package is installed. "
            "Install a lightweight parser with: pip install flatbuffers tflite"
        ) from exc
    return tflite


def shape_list(tensor_detail: dict) -> list[int]:
    shape = tensor_detail.get("shape")
    if shape is None:
        return []
    return [int(dim) for dim in shape]


def estimate_conv_macs(op_name: str, input_shape: list[int], weight_shape: list[int],
                       output_shape: list[int]) -> int | None:
    if len(input_shape) != 4 or len(weight_shape) != 4 or len(output_shape) != 4:
        return None
    out_h, out_w, out_c = output_shape[1], output_shape[2], output_shape[3]
    if op_name == "CONV_2D":
        kernel_h, kernel_w, in_c = weight_shape[1], weight_shape[2], weight_shape[3]
        return int(out_h * out_w * out_c * kernel_h * kernel_w * in_c)
    if op_name == "DEPTHWISE_CONV_2D":
        kernel_h, kernel_w = weight_shape[1], weight_shape[2]
        return int(out_h * out_w * out_c * kernel_h * kernel_w)
    return None


def make_empty_report(model_path: Path, backend: str) -> dict:
    report = {
        "model": str(model_path.resolve()),
        "backend": backend,
        "operators": [],
        "conv2d_total_macs": 0,
        "depthwise_conv2d_total_macs": 0,
        "total_estimated_macs": 0,
    }
    return report


def profile_with_tensorflow(model_path: Path, resolver_name: str) -> dict:
    tf = require_tensorflow()
    resolver_type = (
        tf.lite.experimental.OpResolverType.BUILTIN_REF
        if resolver_name == "builtin_ref"
        else tf.lite.experimental.OpResolverType.BUILTIN
    )
    interpreter = tf.lite.Interpreter(
        model_path=str(model_path), experimental_op_resolver_type=resolver_type
    )
    interpreter.allocate_tensors()
    tensor_details = {item["index"]: item for item in interpreter.get_tensor_details()}
    report = make_empty_report(model_path, f"tensorflow_{resolver_name}")

    for op_index, op in enumerate(interpreter._get_ops_details()):  # pylint: disable=protected-access
        op_name = op["op_name"]
        inputs = [tensor_details[idx] for idx in op["inputs"] if idx in tensor_details]
        outputs = [tensor_details[idx] for idx in op["outputs"] if idx in tensor_details]
        input_shapes = [shape_list(item) for item in inputs]
        output_shapes = [shape_list(item) for item in outputs]

        macs = None
        if op_name in {"CONV_2D", "DEPTHWISE_CONV_2D"} and len(inputs) >= 2 and outputs:
            macs = estimate_conv_macs(op_name, input_shapes[0], input_shapes[1], output_shapes[0])
            if macs is not None:
                if op_name == "CONV_2D":
                    report["conv2d_total_macs"] += macs
                else:
                    report["depthwise_conv2d_total_macs"] += macs
                report["total_estimated_macs"] += macs

        report["operators"].append(
            {
                "index": op_index,
                "op_name": op_name,
                "input_tensors": [item["name"] for item in inputs],
                "output_tensors": [item["name"] for item in outputs],
                "input_shapes": input_shapes,
                "output_shapes": output_shapes,
                "estimated_macs": macs,
            }
        )
    return report


def builtin_operator_names(tflite) -> dict[int, str]:
    return {
        value: name
        for name, value in tflite.BuiltinOperator.__dict__.items()
        if name.isupper() and isinstance(value, int)
    }


def tensor_shape(tensor) -> list[int]:
    return [int(tensor.Shape(index)) for index in range(tensor.ShapeLength())]


def tensor_name(tensor) -> str:
    raw_name = tensor.Name()
    return raw_name.decode("utf-8", errors="replace") if raw_name else ""


def profile_with_flatbuffer(model_path: Path) -> dict:
    tflite = require_tflite_schema()
    operator_names = builtin_operator_names(tflite)
    model = tflite.Model.GetRootAsModel(model_path.read_bytes(), 0)
    if model.SubgraphsLength() == 0:
        raise SystemExit(f"No subgraph found in {model_path}")
    subgraph = model.Subgraphs(0)
    tensors = [subgraph.Tensors(index) for index in range(subgraph.TensorsLength())]
    report = make_empty_report(model_path, "flatbuffer")

    for op_index in range(subgraph.OperatorsLength()):
        op = subgraph.Operators(op_index)
        opcode = model.OperatorCodes(op.OpcodeIndex())
        op_name = operator_names.get(opcode.BuiltinCode(), f"BUILTIN_{opcode.BuiltinCode()}")
        input_indices = [op.Inputs(index) for index in range(op.InputsLength())]
        output_indices = [op.Outputs(index) for index in range(op.OutputsLength())]
        inputs = [tensors[index] for index in input_indices if index >= 0]
        outputs = [tensors[index] for index in output_indices if index >= 0]
        input_shapes = [tensor_shape(item) for item in inputs]
        output_shapes = [tensor_shape(item) for item in outputs]

        macs = None
        if op_name in {"CONV_2D", "DEPTHWISE_CONV_2D"} and len(inputs) >= 2 and outputs:
            macs = estimate_conv_macs(op_name, input_shapes[0], input_shapes[1], output_shapes[0])
            if macs is not None:
                if op_name == "CONV_2D":
                    report["conv2d_total_macs"] += macs
                else:
                    report["depthwise_conv2d_total_macs"] += macs
                report["total_estimated_macs"] += macs

        report["operators"].append(
            {
                "index": op_index,
                "op_name": op_name,
                "input_tensors": [tensor_name(item) for item in inputs],
                "output_tensors": [tensor_name(item) for item in outputs],
                "input_shapes": input_shapes,
                "output_shapes": output_shapes,
                "estimated_macs": macs,
            }
        )

    return report


def profile_model(model_path: Path, backend: str, resolver_name: str) -> dict:
    if backend == "tensorflow":
        return profile_with_tensorflow(model_path, resolver_name)
    if backend == "flatbuffer":
        return profile_with_flatbuffer(model_path)
    try:
        return profile_with_tensorflow(model_path, resolver_name)
    except SystemExit:
        return profile_with_flatbuffer(model_path)


def main() -> None:
    args = parse_args()
    model_path = Path(args.model).resolve()
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    report = profile_model(model_path, args.backend, args.tensorflow_op_resolver)
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")
    print(
        "Estimated MACs: "
        f"conv2d={report['conv2d_total_macs']} "
        f"depthwise={report['depthwise_conv2d_total_macs']} "
        f"total={report['total_estimated_macs']}"
    )


if __name__ == "__main__":
    main()
