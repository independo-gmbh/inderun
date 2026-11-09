"""Tests for prepare_coreai_package.py; the voice pipeline is stubbed, so no model release is needed."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import prepare_coreai_package as tool

STATS = {"letter_rate": 1.0, "prompt_frames": 125}


def sha(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def fake_prepare(wav, voice_id, target):
    Path(target).parent.mkdir(parents=True, exist_ok=True)
    Path(target).write_bytes(b"voice-" + voice_id.encode())
    return dict(STATS)


class PrepareCoreAiPackageTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.asset_dir = self.root / "articulino.aimodel"
        (self.asset_dir / "meta").mkdir(parents=True)
        (self.asset_dir / "model.bin").write_bytes(b"weights")
        (self.asset_dir / "meta" / "manifest.json").write_bytes(b"{}")
        self.asset_file = self.root / "single.aimodel"
        self.asset_file.write_bytes(b"one-file-model")
        self.config = self.root / "config.json"
        self.config.write_bytes(b'{"sample_rate": 24000}')
        patcher = mock.patch("prepare_coreai_package.VoiceTool")
        self.voice_tool = patcher.start()
        self.voice_tool.return_value.prepare.side_effect = fake_prepare
        self.addCleanup(patcher.stop)

    def run_tool(self, asset, voices=None, function_names=None, out=None):
        out = out or self.root / "out"
        names = function_names or tool.DEFAULT_FUNCTION_NAMES
        stats = tool.prepare_package(
            asset, self.config, self.root, "int8", voices or [(Path("a.wav"), "anna")], out, "pkg", names
        )
        return out, stats, json.loads((out / "model-package.json").read_text(encoding="utf-8"))

    def test_package_shape_for_a_directory_asset(self):
        out, stats, pkg = self.run_tool(self.asset_dir)
        self.assertEqual(stats, {"anna": STATS})
        self.assertEqual((pkg["id"], pkg["version"], pkg["format"], pkg["variant"]), ("pkg", "1", "coreai", "coreai"))
        self.assertEqual(pkg["tasks"], ["text_to_speech"])
        self.assertEqual(pkg["runtime"], {"minOsVersion": "27.0"})
        speech = pkg["speech"]
        self.assertEqual(speech["pipeline"], "articulino")
        self.assertEqual((speech["sampleRate"], speech["channels"]), (24000, 1))
        self.assertEqual(speech["graphs"], {
            "text": "articulino.aimodel#text",
            "dit_step": "articulino.aimodel#dit_step",
            "decoder": "articulino.aimodel#decoder",
        })
        self.assertEqual(speech["frontend"], {"kind": "grapheme", "assets": {"config": "config.json"}})
        self.assertEqual(speech["voices"][0]["file"], "voices/anna.safetensors")
        self.assertEqual(speech["voices"][0]["license"]["spdx"], "Apache-2.0")
        self.assertTrue((out / "config.json").is_file())

    def test_checksums_list_every_file_recursively(self):
        _, _, pkg = self.run_tool(self.asset_dir)
        self.assertEqual(pkg["integrity"]["checksums"], {
            "config.json": sha(b'{"sample_rate": 24000}'),
            "voices/anna.safetensors": sha(b"voice-anna"),
            "articulino.aimodel/meta/manifest.json": sha(b"{}"),
            "articulino.aimodel/model.bin": sha(b"weights"),
        })

    def test_a_file_asset_is_listed_once_under_its_basename(self):
        out, _, pkg = self.run_tool(self.asset_file)
        self.assertEqual(pkg["speech"]["graphs"]["text"], "single.aimodel#text")
        self.assertEqual(pkg["integrity"]["checksums"]["single.aimodel"], sha(b"one-file-model"))
        self.assertEqual(len(pkg["integrity"]["checksums"]), 3)
        self.assertTrue((out / "single.aimodel").is_file())

    def test_custom_function_names_map_in_order(self):
        _, _, pkg = self.run_tool(self.asset_dir, function_names=["a", "b", "c"])
        self.assertEqual(pkg["speech"]["graphs"]["dit_step"], "articulino.aimodel#b")

    def test_a_rerun_replaces_the_previous_asset(self):
        out, _, _ = self.run_tool(self.asset_dir)
        (out / "articulino.aimodel" / "stale.bin").write_bytes(b"old")
        (self.asset_dir / "model.bin").write_bytes(b"new-weights")
        _, _, pkg = self.run_tool(self.asset_dir, out=out)
        self.assertFalse((out / "articulino.aimodel" / "stale.bin").exists())
        self.assertNotIn("articulino.aimodel/stale.bin", pkg["integrity"]["checksums"])
        self.assertEqual(pkg["integrity"]["checksums"]["articulino.aimodel/model.bin"], sha(b"new-weights"))

    def test_a_file_asset_replaces_a_previous_directory_of_the_same_name(self):
        out = self.root / "out"
        (out / "single.aimodel").mkdir(parents=True)
        (out / "single.aimodel" / "stale.bin").write_bytes(b"old")
        _, _, pkg = self.run_tool(self.asset_file, out=out)
        self.assertTrue((out / "single.aimodel").is_file())
        self.assertEqual(len(pkg["integrity"]["checksums"]), 3)

    def test_an_invalid_voice_id_is_refused(self):
        with self.assertRaises(ValueError):
            self.run_tool(self.asset_dir, voices=[(Path("a.wav"), "a/b")])

    def test_bad_function_names_are_refused(self):
        for bad in (["a", "b"], ["a", "b", "c", "d"], ["a", "b#", "c"], ["a", "", "c"], ["a", "b c", "c"], ["a", " b", "c"]):
            with self.assertRaises(ValueError, msg=str(bad)):
                self.run_tool(self.asset_dir, function_names=bad)

    def test_parse_function_names_rejects_the_wrong_count(self):
        self.assertEqual(tool.parse_function_names("x,y,z"), ["x", "y", "z"])
        self.assertEqual(tool.parse_function_names("x, y ,z"), ["x", "y", "z"])
        with self.assertRaises(SystemExit):
            with mock.patch("sys.stderr"):
                tool.parse_args(["--asset", "a", "--config", "c", "--models", "m", "--voice", "v.wav",
                                 "--out", "o", "--function-names", "x,y"])

    def test_an_unsafe_asset_basename_is_refused(self):
        for bad in ("", ".", "..", "a/b", "a\\b", "a.aimodel#text"):
            with self.assertRaises(ValueError, msg=bad):
                tool.check_asset_name(bad)
        self.assertEqual(tool.check_asset_name("articulino.aimodel"), "articulino.aimodel")

    def test_help_shows_the_default_function_names(self):
        with mock.patch("sys.stdout") as stdout, self.assertRaises(SystemExit):
            tool.parse_args(["--help"])
        printed = "".join(call.args[0] for call in stdout.write.call_args_list)
        self.assertIn("default text,dit_step,decoder", " ".join(printed.split()))

    def test_a_voice_whose_prompt_is_not_125_frames_is_refused(self):
        def short(wav, voice_id, target):
            Path(target).parent.mkdir(parents=True, exist_ok=True)
            Path(target).write_bytes(b"voice")
            return {"letter_rate": 1.0, "prompt_frames": 124}

        self.voice_tool.return_value.prepare.side_effect = short
        with self.assertRaises(ValueError) as caught:
            self.run_tool(self.asset_dir)
        self.assertIn("anna", str(caught.exception))
        self.assertIn("124", str(caught.exception))
        self.assertIn("125", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
