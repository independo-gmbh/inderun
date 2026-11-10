"""Tests for the package and voice preparation CLIs that need no model release."""
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

from prepare_articulino_package import parse_voice, validate_voice_id
from prepare_articulino_voice import load_prompt

CONFIG = {"sample_rate": 24000, "samples_per_frame": 960, "max_voice_seconds": 8.0}


class ParseVoiceTests(unittest.TestCase):
    def test_wav_and_id(self):
        self.assertEqual(parse_voice("prompt.wav:anna"), (Path("prompt.wav"), "anna"))

    def test_id_defaults_to_the_file_stem(self):
        self.assertEqual(parse_voice("dir/prompt.wav"), (Path("dir/prompt.wav"), "prompt"))
        self.assertEqual(parse_voice("prompt.wav:"), (Path("prompt.wav"), "prompt"))

    def test_a_windows_drive_path_without_an_id_is_one_path(self):
        self.assertEqual(parse_voice(r"C:\voices\anna.wav"), (Path(r"C:\voices\anna.wav"), "anna"))
        self.assertEqual(parse_voice("C:/voices/anna.wav"), (Path("C:/voices/anna.wav"), "anna"))

    def test_an_id_that_would_leave_the_voices_directory_is_refused(self):
        for arg in ("prompt.wav:..", "prompt.wav:."):
            with self.assertRaises(ValueError, msg=arg):
                parse_voice(arg)

    def test_validate_voice_id(self):
        validate_voice_id("anna-1")
        for bad in ("", ".", "..", "a/b", "a\\b"):
            with self.assertRaises(ValueError, msg=bad):
                validate_voice_id(bad)


class LoadPromptTests(unittest.TestCase):
    def _wav(self, d: str, seconds: float) -> Path:
        path = Path(d) / "p.wav"
        sf.write(str(path), np.zeros(int(seconds * 24000), np.float32), 24000)
        return path

    def test_a_prompt_shorter_than_3_s_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, "at least 3 s"):
                load_prompt(self._wav(d, 2.9), CONFIG)

    def test_a_prompt_of_3_s_is_cut_to_whole_frames(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(len(load_prompt(self._wav(d, 3.0), CONFIG)), 72000)
            self.assertEqual(len(load_prompt(self._wav(d, 9.0), CONFIG)), 8 * 24000)


if __name__ == "__main__":
    unittest.main()
