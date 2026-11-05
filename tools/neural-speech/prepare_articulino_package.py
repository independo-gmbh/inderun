"""Prepare an Articulino model package directory for the IndeRun neural speech provider.

    python prepare_articulino_package.py --models <onnx-release-dir> --precision int8 \
        --voice prompt.wav[:id] [--voice other.wav:other] --out <dir> [--package-id articulino-de-en]

Writes config.json, text.onnx (int64 text_mask), dit_step.onnx, decoder.onnx, voices/<id>.safetensors and
model-package.json. See README.md.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

from prepare_articulino_voice import UPSTREAM_REPO, VoiceTool, sha256_file
from rewrite_text_graph import rewrite_text_mask_to_int64

VOICE_LOCALES = ["de-DE", "de-AT", "en-US"]


def check_model_package(pkg: dict) -> None:
    """A minimal check of the keys contracts/schemas/model-package.schema.json requires for a speech package."""
    missing = [k for k in ("id", "format") if k not in pkg]
    speech = pkg.get("speech", {})
    missing += [f"speech.{k}" for k in ("pipeline", "sampleRate", "graphs", "voices") if k not in speech]
    for v in speech.get("voices", []):
        missing += [f"speech.voices[].{k}" for k in ("id", "name", "locales") if k not in v]
    if "text_to_speech" in pkg.get("tasks", []) and "speech" not in pkg:
        missing.append("speech")
    if missing:
        raise ValueError(f"model-package.json misses required keys: {sorted(set(missing))}")


def validate_voice_id(voice_id: str) -> str:
    """A voice id names `voices/<id>.safetensors`, so it must stay one file name inside the package."""
    if voice_id in ("", ".", "..") or "/" in voice_id or "\\" in voice_id:
        raise ValueError(f"voice id invalid: {voice_id!r} (empty, '.', '..' or a path separator)")
    return voice_id


def parse_voice(arg: str) -> tuple[Path, str]:
    """`<wav>[:<id>]`. The last `:` separates an id only when no path separator follows it, so a Windows drive
    path such as `C:\\voices\\anna.wav` stays one path. Without an id, the file name without its extension is used."""
    path, sep, voice_id = arg.rpartition(":")
    if not sep or re.search(r"[\\/]", voice_id):
        path, voice_id = arg, ""
    if not voice_id:
        name = re.split(r"[\\/]", path)[-1]
        voice_id = name.rsplit(".", 1)[0] if "." in name[1:] else name
    return Path(path), validate_voice_id(voice_id)


def prepare_package(models: Path, precision: str, voices: list[tuple[Path, str]], out: Path, package_id: str) -> dict:
    out = Path(out).resolve()
    (out / "voices").mkdir(parents=True, exist_ok=True)
    files = ["config.json", "text.onnx", "dit_step.onnx", "decoder.onnx"]
    shutil.copyfile(models / "config.json", out / "config.json")
    for graph in ("dit_step", "decoder"):
        shutil.copyfile(models / precision / f"{graph}.onnx", out / f"{graph}.onnx")
    rewrite_text_mask_to_int64(models / precision / "text.onnx", out / "text.onnx")

    tool = VoiceTool(models, precision)
    entries, stats = [], {}
    for wav, voice_id in voices:
        rel = f"voices/{validate_voice_id(voice_id)}.safetensors"
        stats[voice_id] = tool.prepare(wav, voice_id, out / rel)
        files.append(rel)
        entries.append({"id": voice_id, "name": voice_id, "locales": VOICE_LOCALES, "file": rel,
                        "license": {"spdx": "Apache-2.0", "url": f"https://huggingface.co/{UPSTREAM_REPO}"}})
    package = {
        "id": package_id, "version": "1", "format": "onnx", "variant": f"onnx-{precision}", "tasks": ["text_to_speech"],
        "source": {"sourceType": "filesystem", "ref": str(out)},
        "license": {"spdx": "Apache-2.0", "url": f"https://huggingface.co/{UPSTREAM_REPO}"},
        "speech": {
            "pipeline": "articulino", "sampleRate": 24000, "channels": 1,
            "graphs": {"text": "text.onnx", "dit_step": "dit_step.onnx", "decoder": "decoder.onnx"},
            "frontend": {"kind": "grapheme", "assets": {"config": "config.json"}},
            "voices": entries,
        },
        "integrity": {"checksums": {f: f"sha256:{sha256_file(out / f)}" for f in files}},
    }
    check_model_package(package)
    (out / "model-package.json").write_text(json.dumps(package, indent=2) + "\n", encoding="utf-8")
    return stats


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument("--precision", default="int8", choices=["fp32", "fp16", "int8"])
    ap.add_argument("--voice", action="append", required=True, help="<wav>[:<id>], repeatable")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--package-id", default="articulino-de-en")
    a = ap.parse_args()
    stats = prepare_package(a.models, a.precision, [parse_voice(v) for v in a.voice], a.out, a.package_id)
    for voice_id, s in stats.items():
        print(f"voice {voice_id}: letter_rate = {s['letter_rate']:.3f}, P = {s['prompt_frames']}")
    print(f"package written to {a.out.resolve()}")


if __name__ == "__main__":
    main()
