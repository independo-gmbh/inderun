"""Prepare an Articulino Core AI model package directory for the IndeRun neural speech provider.

    python prepare_coreai_package.py --asset <articulino.aimodel> --config <config.json> \
        --models <onnx-release-dir> --precision int8 --voice prompt.wav[:id] [--voice other.wav:other] \
        --out <dir> [--package-id articulino-de-en-coreai] [--function-names text,dit_step,decoder]

Copies the exported .aimodel (a file or a directory) and config.json, prepares the voices with the ONNX voice
pipeline and writes model-package.json (format coreai). It does not run the export. See README.md.
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from prepare_articulino_package import VOICE_LOCALES, check_model_package, parse_voice, validate_voice_id
from prepare_articulino_voice import UPSTREAM_REPO, VoiceTool, sha256_file

ROLES = ("text", "dit_step", "decoder")
DEFAULT_FUNCTION_NAMES = list(ROLES)
MIN_OS_VERSION = "27.0"
# The export fixes voice_cache to 125 prompt frames; Core AI returns wrong numbers for any other length.
PROMPT_FRAMES = 125


def check_asset_name(name: str) -> str:
    """The asset keeps its basename inside the package, so it must be one real file name."""
    if name in ("", ".", "..") or "/" in name or "\\" in name or "#" in name:
        raise ValueError(f"asset name invalid: {name!r} (empty, '.', '..', a path separator or '#')")
    return name


def check_function_names(names: list[str]) -> list[str]:
    if len(names) != len(ROLES):
        raise ValueError(f"expected {len(ROLES)} function names for {', '.join(ROLES)}, got {len(names)}")
    for name in names:
        if not name or "#" in name or any(c.isspace() for c in name):
            raise ValueError(f"function name invalid: {name!r} (empty, whitespace or contains '#')")
    return names


def parse_function_names(arg: str) -> list[str]:
    try:
        return check_function_names([name.strip() for name in arg.split(",")])
    except ValueError as e:
        raise argparse.ArgumentTypeError(str(e)) from e


def prepare_package(asset: Path, config: Path, models: Path, precision: str, voices: list[tuple[Path, str]],
                    out: Path, package_id: str, function_names: list[str]) -> dict:
    asset = Path(asset)
    asset_name = check_asset_name(asset.name)
    check_function_names(function_names)
    voices = [(wav, validate_voice_id(voice_id)) for wav, voice_id in voices]
    out = Path(out).resolve()
    (out / "voices").mkdir(parents=True, exist_ok=True)

    shutil.copyfile(config, out / "config.json")
    files = ["config.json"]
    # A previous run's asset is replaced, so none of its files is copied or checksummed again.
    previous = out / asset_name
    if previous.is_dir() and not previous.is_symlink():
        shutil.rmtree(previous)
    elif previous.exists() or previous.is_symlink():
        previous.unlink()
    if asset.is_dir():
        shutil.copytree(asset, out / asset_name, dirs_exist_ok=True)
        files += [p.relative_to(out).as_posix() for p in sorted((out / asset_name).rglob("*")) if p.is_file()]
    else:
        shutil.copyfile(asset, out / asset_name)
        files.append(asset_name)

    tool = VoiceTool(models, precision)
    entries, stats = [], {}
    license_ = {"spdx": "Apache-2.0", "url": f"https://huggingface.co/{UPSTREAM_REPO}"}
    for wav, voice_id in voices:
        rel = f"voices/{voice_id}.safetensors"
        stats[voice_id] = tool.prepare(wav, voice_id, out / rel)
        frames = stats[voice_id]["prompt_frames"]
        if frames != PROMPT_FRAMES:
            raise ValueError(f"voice {voice_id}: P = {frames}, the Core AI export needs P = {PROMPT_FRAMES}; "
                             "use a prompt of the length the seed voices have")
        files.append(rel)
        entries.append({"id": voice_id, "name": voice_id, "locales": VOICE_LOCALES, "file": rel, "license": license_})
    package = {
        "id": package_id, "version": "1", "format": "coreai", "variant": "coreai", "tasks": ["text_to_speech"],
        "runtime": {"minOsVersion": MIN_OS_VERSION},
        "source": {"sourceType": "filesystem", "ref": str(out)},
        "license": license_,
        "speech": {
            "pipeline": "articulino", "sampleRate": 24000, "channels": 1,
            "graphs": {role: f"{asset_name}#{fn}" for role, fn in zip(ROLES, function_names)},
            "frontend": {"kind": "grapheme", "assets": {"config": "config.json"}},
            "voices": entries,
        },
        "integrity": {"checksums": {f: f"sha256:{sha256_file(out / f)}" for f in files}},
    }
    check_model_package(package)
    (out / "model-package.json").write_text(json.dumps(package, indent=2) + "\n", encoding="utf-8")
    return stats


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--asset", required=True, type=Path, help="the exported .aimodel, a file or a directory")
    ap.add_argument("--config", required=True, type=Path, help="the release's config.json")
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--precision", default="int8", choices=["fp32", "fp16", "int8"])
    ap.add_argument("--voice", action="append", required=True, help="<wav>[:<id>], repeatable")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--package-id", default="articulino-de-en-coreai")
    ap.add_argument("--function-names", type=parse_function_names, default=DEFAULT_FUNCTION_NAMES,
                    help="three comma-separated function names for text,dit_step,decoder "
                         f"(default {','.join(DEFAULT_FUNCTION_NAMES)})")
    return ap.parse_args(argv)


def main() -> None:
    a = parse_args()
    stats = prepare_package(a.asset, a.config, a.models, a.precision, [parse_voice(v) for v in a.voice], a.out,
                            a.package_id, a.function_names)
    for voice_id, s in stats.items():
        print(f"voice {voice_id}: letter_rate = {s['letter_rate']:.3f}, P = {s['prompt_frames']}")
    print(f"package written to {a.out.resolve()}")


if __name__ == "__main__":
    main()
