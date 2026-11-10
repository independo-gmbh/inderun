"""Tests for the Articulino host-math port (run: python -m unittest discover -s tools/neural-speech -p 'test_*.py')."""
import math
import os
import tempfile
import unittest
from pathlib import Path

import numpy as np

import articulino_math as M
import safetensors_io as S

CHARSET = " abcdefghijklmnopqrstuvwxyzäöüß.,?!-'\":;()0123456789"
CONFIG = {
    "sample_rate": 24000,
    "latent_dim": 2,
    "samples_per_frame": 4,
    "duration_units_per_frame": 4,
    "decoder_lead_in_frames": 1,
    "max_duration_units": 400.0,
    "times": [0.0, 0.25, 0.5, 0.75],
    "charset": CHARSET,
    "languages": {"de": 0, "en": 1},
    "postprocess": {"low_shelf_db": 2.0, "low_shelf_hz": 180.0, "shelf_slope": 0.7, "peak": 0.95},
}
# The downloaded upstream ONNX release directory (the one passed as --models); the graph test skips without it.
ONNX_DIR = os.environ.get("ARTICULINO_ONNX_DIR")
TEXT_ONNX = Path(ONNX_DIR) / "int8" / "text.onnx" if ONNX_DIR else None


class ArticulinoMathTests(unittest.TestCase):
    def test_normalize_folds_accents_and_drops_unknown(self):
        self.assertEqual(M.normalize("Café – „Zitat“ … ø 😀", CHARSET), 'cafe - "zitat" . ö')

    def test_normalize_collapses_whitespace_and_trims(self):
        self.assertEqual(M.normalize("  a \t\n b  ", CHARSET), "a b")

    def test_letters_ids_and_language(self):
        ids, langs = M.letters("Ich habe Hunger.", "de", CONFIG)
        self.assertEqual(ids[:4], [10, 4, 9, 1])  # i c h ' ' with ' ' = 1, a = 2
        self.assertEqual(langs, [0] * len(ids))
        _, en = M.letters("Hi", "en", CONFIG)
        self.assertEqual(en, [1, 1])

    def test_is_letter_counts_digits_not_space_or_punctuation(self):
        ids, _ = M.letters("a 1.", "de", CONFIG)
        self.assertEqual(M.is_letter([0] + ids, CHARSET), [False, True, False, True, False])

    def test_durations_clamp_speed_and_placeholder(self):
        logd = np.log(np.array([5.0, 1000.0, 2.0], np.float32))
        mask = np.array([0, 1, 1])
        d = M.durations(logd, mask, 2.0, CONFIG, 0.0)
        self.assertEqual(d.dtype, np.float32)
        np.testing.assert_allclose(d, [0.0, 200.0, 1.0], rtol=1e-6)
        M.apply_prompt_placeholder(d, 2, 4)
        self.assertEqual(d[0], 8)

    def test_letter_rate_rescales_only_letters(self):
        ids = np.array([0, 2, 1, 3, 4])  # placeholder a ' ' b c
        d = np.array([0.0, 10.0, 7.0, 10.0, 10.0], np.float32)
        rate = M.letter_rate(d, ids, CHARSET, start=1)
        self.assertAlmostEqual(rate, 3 / (30 / 100))
        M.letter_rate(d, ids, CHARSET, start=1, target=20.0)
        self.assertEqual(d[2], 7.0)
        self.assertEqual(d[0], 0.0)
        self.assertAlmostEqual(M.letter_rate(d.copy(), ids, CHARSET, start=1), 20.0, places=4)

    def test_letter_rate_without_letters_is_zero(self):
        self.assertEqual(M.letter_rate(np.array([1.0], np.float32), np.array([1]), CHARSET), 0.0)

    def test_durations_rate_equalisation_hits_target(self):
        ids = [0] + M.letters("hallo du", "de", CONFIG)[0]
        logd = np.log(np.array([1.0, 3, 2, 4, 2, 3, 6, 2, 3], np.float32))
        mask = np.array([0] + [1] * (len(ids) - 1))
        d = M.durations(logd, mask, 1.0, CONFIG, 12.5, ids=ids)
        self.assertAlmostEqual(M.letter_rate(d.copy(), np.array(ids), CHARSET, start=1), 12.5, places=3)

    def test_frame_condition_overlap_weights(self):
        h = np.array([[1.0, 0.0], [0.0, 1.0], [2.0, 2.0]], np.float32)
        cond = M.frame_condition(h, np.array([8, 2, 6], np.float32), 2, 4, 4)
        np.testing.assert_allclose(cond, [[0.5 * 0 + 0.5 * 2, 0.5 * 1 + 0.5 * 2], [2.0, 2.0]], atol=1e-6)

    def test_flow_steps_matches_closed_form(self):
        noise = [np.full((1, 1, 1), v, np.float32) for v in (1.0, 2.0, 3.0, 4.0)]
        out = M.flow_steps(noise, lambda x, t: -x, [0.0, 0.25, 0.5, 0.75])
        x = 1.0
        t_next = [0.25, 0.5, 0.75]
        for k, t in enumerate([0.0, 0.25, 0.5, 0.75]):
            x1 = x + (1 - t) * -x
            if k < 3:
                x = (1 - t_next[k]) * (2.0, 3.0, 4.0)[k] + t_next[k] * x1
        self.assertAlmostEqual(float(out[0, 0, 0]), x1, places=6)
        self.assertEqual(out.dtype, np.float32)

    def test_low_shelf_coefficients_at_180hz(self):
        A = 10 ** (2.0 / 40)
        w = 2 * math.pi * 180 / 24000
        c, s = math.cos(w), 0.7
        q = 2 * math.sqrt(A) * (math.sin(w) / 2) * math.sqrt((A + 1 / A) * (1 / s - 1) + 2)
        a0 = (A + 1) + (A - 1) * c + q
        want = (A * ((A + 1) - (A - 1) * c + q) / a0, 2 * A * ((A - 1) - (A + 1) * c) / a0,
                A * ((A + 1) - (A - 1) * c - q) / a0, -2 * ((A - 1) + (A + 1) * c) / a0,
                ((A + 1) + (A - 1) * c - q) / a0)
        got = M.low_shelf_coefficients(180.0, 2.0, 24000, 0.7)
        for g, w_ in zip(got, want):
            self.assertAlmostEqual(g, w_, places=9)
        # low shelf: DC gain is A^2 (= +2 dB), Nyquist gain is 1
        b0, b1, b2, a1, a2 = got
        self.assertAlmostEqual((b0 + b1 + b2) / (1 + a1 + a2), A * A, places=9)
        self.assertAlmostEqual((b0 - b1 + b2) / (1 - a1 + a2), 1.0, places=9)

    def test_biquad_is_direct_form_two_transposed(self):
        coeffs = (0.5, 0.25, 0.125, -0.3, 0.1)
        x = np.array([1.0, 0.0, 0.0, 2.0, -1.0])
        y = M.biquad(x, coeffs)
        want = []
        for n in range(len(x)):
            acc = sum(c * (x[n - k] if n - k >= 0 else 0) for k, c in enumerate(coeffs[:3]))
            acc -= sum(c * (want[n - 1 - k] if n - 1 - k >= 0 else 0) for k, c in enumerate(coeffs[3:]))
            want.append(acc)
        np.testing.assert_allclose(y, want, atol=1e-12)
        self.assertEqual(y.dtype, np.float64)

    def test_postprocess_cuts_lead_in_limits_and_pads(self):
        wav = np.zeros(20, np.float32)
        wav[14] = 2.0  # after the 12 lead-in samples
        out = M.postprocess(wav, 12, CONFIG, 150)
        self.assertEqual(out.dtype, np.float32)
        self.assertEqual(len(out), 20 - 12 + 3600)
        self.assertTrue(np.all(out[8:] == 0))
        self.assertAlmostEqual(float(np.abs(out[:8]).max()), 0.95, places=6)

    def test_to_int16_rounds_and_clips(self):
        np.testing.assert_array_equal(M.to_int16(np.array([0.0, 0.5, 1.5, -2.0, -1.0], np.float32)),
                                      [0, 16384, 32767, -32767, -32767])

    def test_split_long_sentence_at_comma(self):
        text = ("a" * 119) + ", " + ("b" * 79)
        self.assertEqual(len(text), 200)
        self.assertEqual(M.split_long_sentence(text), [("a" * 119) + ",", "b" * 79])

    def test_split_long_sentence_short_unchanged_and_space_fallback(self):
        self.assertEqual(M.split_long_sentence("kurz."), ["kurz."])
        text = ("a" * 100) + " " + ("b" * 99)
        self.assertEqual(M.split_long_sentence(text), ["a" * 100, "b" * 99])

    def test_safetensors_round_trip(self):
        tensors = {"a": np.arange(6, dtype=np.float32).reshape(2, 3), "b": np.array([1, -2], np.int64)}
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.safetensors"
            S.write_safetensors(p, tensors, {"format": "t"})
            got, meta = S.read_safetensors(p)
        self.assertEqual(meta, {"format": "t"})
        self.assertEqual(got["a"].dtype, np.float32)
        self.assertEqual(got["b"].dtype, np.int64)
        np.testing.assert_array_equal(got["a"], tensors["a"])
        np.testing.assert_array_equal(got["b"], tensors["b"])

    @unittest.skipUnless(TEXT_ONNX is not None and TEXT_ONNX.exists(), "ARTICULINO_ONNX_DIR unset or without int8/text.onnx")
    def test_rewrite_text_graph_makes_text_mask_int64(self):
        import onnxruntime as ort
        from rewrite_text_graph import rewrite_text_mask_to_int64
        with tempfile.TemporaryDirectory() as d:
            dst = Path(d) / "text.onnx"
            rewrite_text_mask_to_int64(TEXT_ONNX, dst)
            types = {i.name: i.type for i in ort.InferenceSession(str(dst), providers=["CPUExecutionProvider"]).get_inputs()}
        for name in ("text_ids", "language", "text_mask"):
            self.assertEqual(types[name], "tensor(int64)")


if __name__ == "__main__":
    unittest.main()
