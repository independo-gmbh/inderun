"""Build the derived assets of the demo model catalog and write their url, sha256 and size into the catalog.

    python build_demo_assets.py --models <onnx-release-dir> --seeds voice-seeds --out <dir> \
        [--catalog ../../contracts/fixtures/speech/neural-model-catalog.json]

Copies the upstream LICENSE and NOTICE into <out> (Apache-2.0 redistribution). Writes <out>/text.onnx (the int8 `text` graph with an int64 `text_mask`), <out>/<id>.safetensors for every
`<id>.seed.wav` in --seeds, and <out>/SHA256SUMS. It updates the catalog's `articulino-de-en-int8` entry (the
derived `files` and every voice's `file`) and prints the `gh release create` command that publishes the files.
It never uploads anything. See README.md, "Build the demo assets".
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import shutil
from pathlib import Path

from prepare_articulino_package import validate_voice_id
from prepare_articulino_voice import VoiceTool, sha256_file
from rewrite_text_graph import rewrite_text_mask_to_int64

PRECISION = "int8"
ENTRY_ID = "articulino-de-en-int8"
RELEASE_TAG = "neural-speech-assets-1"
REPO = "independo-gmbh/inderun"
BASE_URL = f"https://github.com/{REPO}/releases/download/{RELEASE_TAG}"
DEFAULT_CATALOG = Path(__file__).resolve().parents[2] / "contracts" / "fixtures" / "speech" / "neural-model-catalog.json"
LICENSE_FILES = ("LICENSE", "NOTICE")
UPSTREAM = "eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX"
UPSTREAM_REVISION = "a760ce8d513534111c7679751869fa4c45ef0e54"
RELEASE_NOTES = (
    "Derived demo assets for the IndeRun Voices lab: int64-mask text graph and seven voice bundles. "
    "Modification: text.onnx: the text_mask input changed from bool to int64 by "
    "tools/neural-speech/rewrite_text_graph.py; "
    f"upstream {UPSTREAM} at revision {UPSTREAM_REVISION}; Apache-2.0, NOTICE included."
)
SEED_SUFFIX = ".seed.wav"
SEED_ID = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")


def check_seed_id(voice_id: str) -> str:
    """A seed's file name gives the voice id, which names `voices/<id>.safetensors` and a release asset."""
    validate_voice_id(voice_id)
    if not SEED_ID.fullmatch(voice_id):
        raise ValueError(f"voice id invalid: {voice_id!r} (lower-case letters, digits and single hyphens only)")
    return voice_id


def find_seeds(seeds: Path) -> dict[str, Path]:
    """`<id>.seed.wav` regular files directly inside `seeds`; a link (which could point outside) is refused."""
    found: dict[str, Path] = {}
    for path in sorted(Path(seeds).iterdir()):
        if not path.name.endswith(SEED_SUFFIX):
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"seed is not a regular file: {path.name}")
        found[check_seed_id(path.name[: -len(SEED_SUFFIX)])] = path
    return found


def asset_record(path: Path) -> dict:
    return {"url": f"{BASE_URL}/{path.name}", "sha256": sha256_file(path), "bytes": path.stat().st_size}


def release_command(out: Path, outputs: list[Path]) -> str:
    files = " ".join(shlex.quote(str(p)) for p in outputs)
    notes = shlex.quote(RELEASE_NOTES)
    return (f"gh release create {RELEASE_TAG} {files} --repo {REPO} "
            f'--title "Neural speech demo assets 1" --latest=false --notes {notes}')


def build_assets(models: Path, seeds: Path, out: Path, catalog_path: Path) -> list[Path]:
    """Builds the files, updates the catalog and returns the output files (SHA256SUMS last)."""
    catalog = json.loads(Path(catalog_path).read_text(encoding="utf-8"))
    entry = next(e for e in catalog["entries"] if e["id"] == ENTRY_ID)
    seed_files = find_seeds(seeds)
    catalog_ids = [v["id"] for v in entry["voices"]]
    if sorted(seed_files) != sorted(catalog_ids):
        raise ValueError(f"seeds and catalog voices differ: seeds {sorted(seed_files)}, catalog {sorted(catalog_ids)}")

    for name in LICENSE_FILES:
        if not (Path(models) / name).is_file():
            raise ValueError(f"{name} missing from the models directory; Apache-2.0 requires it in the release")

    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    text = out / "text.onnx"
    rewrite_text_mask_to_int64(Path(models) / PRECISION / "text.onnx", text)
    tool = VoiceTool(models, PRECISION)
    voice_files = {}
    for voice_id, seed in seed_files.items():
        target = out / f"{voice_id}.safetensors"
        tool.prepare(seed, voice_id, target)
        voice_files[voice_id] = target

    licence_files = []
    for name in LICENSE_FILES:
        shutil.copyfile(Path(models) / name, out / name)
        licence_files.append(out / name)

    text_file = next(f for f in entry["files"] if f["path"] == "text.onnx")
    text_file.update(asset_record(text))
    for voice in entry["voices"]:
        voice["file"].update(asset_record(voice_files[voice["id"]]))

    outputs = [*licence_files, text, *(voice_files[i] for i in sorted(voice_files))]
    sums = out / "SHA256SUMS"
    sums.write_text("".join(f"{sha256_file(p)}  {p.name}\n" for p in sorted(outputs, key=lambda p: p.name)),
                    encoding="utf-8")
    Path(catalog_path).write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return [*outputs, sums]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", required=True, type=Path, help="the upstream release directory")
    ap.add_argument("--seeds", required=True, type=Path, help="directory of <id>.seed.wav files")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    a = ap.parse_args()
    outputs = build_assets(a.models, a.seeds, a.out, a.catalog)
    for path in outputs:
        print(f"{path.name}: {path.stat().st_size} bytes, sha256 {sha256_file(path)}")
    print(f"catalog updated: {a.catalog}")
    print("\nPublish (the owner's step; not run by this tool):\n")
    print(release_command(a.out.resolve(), [p.resolve() for p in outputs]))


if __name__ == "__main__":
    main()
