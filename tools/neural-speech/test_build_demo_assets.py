"""Tests for build_demo_assets.py; the voice pipeline and the graph rewrite are stubbed, so no model release is needed."""
import hashlib
import json
import os
import shlex
import tempfile
import unittest
import unittest.mock as mock
from pathlib import Path

import build_demo_assets as tool

BASE = "https://github.com/independo-gmbh/inderun/releases/download/neural-speech-assets-1"
IDS = ["de-at-m-1", "en-us-f-1"]


def fake_prepare(wav, voice_id, target):
    Path(target).write_bytes(b"voice-" + voice_id.encode())
    return {"letter_rate": 1.0, "prompt_frames": 125}


def fake_rewrite(src, dst):
    Path(dst).write_bytes(b"text-int64")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class BuildDemoAssetsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.models = self.root / "models"
        (self.models / "int8").mkdir(parents=True)
        (self.models / "int8" / "text.onnx").write_bytes(b"text-bool")
        (self.models / "LICENSE").write_bytes(b"licence-text")
        (self.models / "NOTICE").write_bytes(b"notice-text")
        self.seeds = self.root / "seeds"
        self.seeds.mkdir()
        for i in IDS:
            (self.seeds / f"{i}.seed.wav").write_bytes(b"wav-" + i.encode())
        self.out = self.root / "out"
        self.catalog = self.root / "catalog.json"
        self.catalog.write_text(json.dumps({"$comment": "c", "entries": [
            {"id": "articulino-de-en-int8",
             "files": [{"role": "config", "path": "config.json", "url": "u", "sha256": "a" * 64, "bytes": 1},
                       {"role": "graph:text", "path": "text.onnx", "url": "", "sha256": "", "bytes": 0}],
             "voices": [{"id": i, "file": {"path": f"voices/{i}.safetensors", "url": "", "sha256": "", "bytes": 0}}
                        for i in IDS]},
            {"id": "articulino-de-en-coreai"},
        ]}), encoding="utf-8")
        for target, stub in (("VoiceTool", mock.MagicMock()), ("rewrite_text_mask_to_int64", fake_rewrite)):
            patcher = mock.patch(f"build_demo_assets.{target}", stub)
            patcher.start()
            self.addCleanup(patcher.stop)
        tool.VoiceTool.return_value.prepare.side_effect = fake_prepare

    def run_tool(self, **kw):
        return tool.build_assets(self.models, kw.get("seeds", self.seeds), self.out, self.catalog)

    def test_writes_every_derived_file_and_sha256sums(self):
        outputs = self.run_tool()
        names = sorted(p.name for p in outputs)
        self.assertEqual(names, ["LICENSE", "NOTICE", "SHA256SUMS", "de-at-m-1.safetensors", "en-us-f-1.safetensors",
                                 "text.onnx"])
        self.assertEqual((self.out / "text.onnx").read_bytes(), b"text-int64")
        sums = (self.out / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual(sums, sorted(sums, key=lambda s: s.split("  ")[1]))
        self.assertIn(f"{digest(b'voice-en-us-f-1')}  en-us-f-1.safetensors", sums)
        self.assertIn(f"{digest(b'text-int64')}  text.onnx", sums)
        self.assertIn(f"{digest(b'licence-text')}  LICENSE", sums)
        self.assertIn(f"{digest(b'notice-text')}  NOTICE", sums)
        self.assertEqual(len(sums), 5)

    def test_licence_and_notice_are_copied_verbatim(self):
        self.run_tool()
        self.assertEqual((self.out / "LICENSE").read_bytes(), b"licence-text")
        self.assertEqual((self.out / "NOTICE").read_bytes(), b"notice-text")

    def test_a_models_directory_without_licence_or_notice_is_refused(self):
        for name in ("LICENSE", "NOTICE"):
            with self.subTest(name=name):
                (self.models / name).rename(self.models / f"{name}.bak")
                with self.assertRaises(ValueError):
                    self.run_tool()
                (self.models / f"{name}.bak").rename(self.models / name)

    def test_catalog_entries_carry_url_sha256_and_bytes(self):
        self.run_tool()
        entries = {e["id"]: e for e in json.loads(self.catalog.read_text(encoding="utf-8"))["entries"]}
        files = {f["path"]: f for f in entries["articulino-de-en-int8"]["files"]}
        self.assertEqual(files["text.onnx"], {"role": "graph:text", "path": "text.onnx", "url": f"{BASE}/text.onnx",
                                              "sha256": digest(b"text-int64"), "bytes": len(b"text-int64")})
        self.assertEqual(files["config.json"]["url"], "u")  # upstream files are not touched
        voice = entries["articulino-de-en-int8"]["voices"][1]["file"]
        self.assertEqual(voice, {"path": "voices/en-us-f-1.safetensors", "url": f"{BASE}/en-us-f-1.safetensors",
                                 "sha256": digest(b"voice-en-us-f-1"), "bytes": len(b"voice-en-us-f-1")})
        self.assertEqual(entries["articulino-de-en-coreai"], {"id": "articulino-de-en-coreai"})

    def test_an_invalid_voice_id_is_refused(self):
        (self.seeds / "..x.seed.wav").write_bytes(b"w")
        (self.seeds / "a b.seed.wav").write_bytes(b"w")
        for bad in ("", ".", "..", "a/b", "a\\b", "A", "a b", "-a"):
            with self.assertRaises(ValueError, msg=repr(bad)):
                tool.check_seed_id(bad)
        self.assertEqual(tool.check_seed_id("de-at-m-1-alt"), "de-at-m-1-alt")
        with self.assertRaises(ValueError):
            self.run_tool()

    def test_a_seed_without_a_catalog_voice_is_refused(self):
        (self.seeds / "xx-yy-m-9.seed.wav").write_bytes(b"w")
        with self.assertRaises(ValueError):
            self.run_tool()

    def test_a_catalog_voice_without_a_seed_is_refused(self):
        (self.seeds / "en-us-f-1.seed.wav").unlink()
        with self.assertRaises(ValueError):
            self.run_tool()

    def test_nothing_outside_the_seeds_directory_is_read(self):
        outside = self.root / "outside.wav"
        outside.write_bytes(b"secret")
        (self.seeds / "en-us-f-1.seed.wav").unlink()
        os.symlink(outside, self.seeds / "en-us-f-1.seed.wav")
        with self.assertRaises(ValueError):
            self.run_tool()
        read = [c.args[0] for c in tool.VoiceTool.return_value.prepare.call_args_list]
        self.assertNotIn(outside, [Path(p).resolve() for p in read])

    def test_voices_are_prepared_from_the_seed_files_only(self):
        self.run_tool()
        used = sorted(Path(c.args[0]).parent.resolve() for c in tool.VoiceTool.return_value.prepare.call_args_list)
        self.assertEqual(set(used), {self.seeds.resolve()})
        tool.VoiceTool.assert_called_once_with(self.models, "int8")

    def test_the_printed_command_lists_every_output_file(self):
        outputs = self.run_tool()
        command = tool.release_command(self.out, outputs)
        self.assertTrue(command.startswith("gh release create neural-speech-assets-1 "))
        for path in outputs:
            self.assertIn(str(path), command)
        self.assertIn("--repo independo-gmbh/inderun", command)
        self.assertIn('--title "Neural speech demo assets 1"', command)
        self.assertIn("--notes ", command)
        self.assertIn("--latest=false", command)

    def test_the_notes_state_the_modification(self):
        command = tool.release_command(self.out, self.run_tool())
        for text in ("text.onnx: the text_mask input changed from bool to int64 by tools/neural-speech/rewrite_text_graph.py",
                     "eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX at revision a760ce8d513534111c7679751869fa4c45ef0e54",
                     "Apache-2.0, NOTICE included"):
            self.assertIn(text, shlex.split(command)[shlex.split(command).index("--notes") + 1])


if __name__ == "__main__":
    unittest.main()
