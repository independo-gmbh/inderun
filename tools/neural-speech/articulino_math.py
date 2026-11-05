# Adapted from eigenhand/articulino-onnx, Apache License 2.0
# (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).
"""The Articulino host math between the ONNX graphs, in NumPy.

This is the reference the other SDKs are written against: the section "Articulino host math" of
docs/superpowers/plans/2026-11-05-neural-speech-ort-articulino.md fixes the behaviour, this module implements it, and
generate_pipeline_fixture.py pins it as contracts/fixtures/speech/articulino-pipeline.json. Differences from upstream:
the low shelf is applied directly as an IIR in float64 (upstream approximates it with a 1024-tap FIR), `pause_ms` of
silence is appended, and long sentences are split at the last `, ; : -` or space.
"""
from __future__ import annotations

import math
import unicodedata
from typing import Callable, Sequence

import numpy as np

# Neutral sentences the original service uses to measure a voice's own speaking rate.
CALIBRATION = [
    "Guten Morgen, die Systeme laufen stabil und es gibt nichts Dringendes.",
    "Ich habe die Unterlagen geprüft und fasse das Wichtigste kurz zusammen.",
    "Der Termin am Donnerstag wurde auf den Nachmittag verschoben.",
    "Soll ich die Nachricht jetzt abschicken oder noch einmal vorlesen?",
    "Das Training läuft seit gestern Abend ohne Unterbrechung weiter.",
    "Draußen sind es zwölf Grad, und am Abend soll es regnen.",
]

REPLACE = {"’": "'", "‘": "'", "`": "'", "´": "'", "“": '"', "”": '"', "„": '"', "«": '"', "»": '"',
           "–": "-", "—": "-", "…": ".", "ø": "ö", "æ": "ä", "ð": "d", "þ": "th"}
_KEPT = "äöüß"
_SPLIT_CHARS = ",;:- "


def normalize(text: str, charset: str) -> str:
    """Lower case, replacement map, NFKD for code points outside the charset, drop the rest, collapse whitespace."""
    out = []
    for c in text.lower():
        c = REPLACE.get(c, c)
        if c not in charset and c not in _KEPT:
            c = "".join(x for x in unicodedata.normalize("NFKD", c) if not unicodedata.combining(x))
        for x in c:
            if x in charset:
                out.append(x)
            elif x.isspace():
                out.append(" ")
    return " ".join("".join(out).split())


def letters(text: str, language: str, config: dict) -> tuple[list[int], list[int]]:
    """-> (letter ids, language id per letter). Id = 1 + index in the charset; 0 is the prompt placeholder, which the
    caller prefixes (text_ids = [0] + ids, language = [lang] + langs, text_mask = [0] + [1] * n)."""
    charset = config["charset"]
    ids = [1 + charset.index(c) for c in normalize(text, charset)]
    return ids, [int(config["languages"][language])] * len(ids)


def is_letter(ids: Sequence[int], charset: str) -> list[bool]:
    """Letters and digits count for the speaking rate; the placeholder (id 0), spaces and punctuation do not."""
    return [i > 0 and charset[i - 1].isalnum() for i in ids]


def letter_rate(d: np.ndarray, ids: np.ndarray, charset: str, start: int = 0, target: float | None = None) -> float:
    """Letters per second over letters/digits from `start` (single overlong letters capped at 3x the median).
    With `target`, the letter durations in `d` are rescaled in place to exactly that rate."""
    m = np.array(is_letter([int(i) for i in ids], charset), bool)
    m[:start] = False
    if not m.any():
        return 0.0
    x = np.maximum(d[m], np.float32(0.5))
    x = np.minimum(x, 3 * np.median(x))
    rate = float(m.sum()) / (float(x.sum(dtype=np.float32)) / 100)
    if target:
        d[m] = x * np.float32(rate / target)
        rate = target
    return rate


def durations(log_durations, mask, speed: float, config: dict, letter_rate_base: float,
              ids: Sequence[int] | None = None) -> np.ndarray:
    """Durations in 10 ms units (float32): clamp, divide by speed, then equalise the letter rate to
    `letter_rate_base * speed` when that is > 0 (needs `ids`, the model's text_ids including the placeholder).
    The caller then applies apply_prompt_placeholder."""
    mask = np.asarray(mask)
    d = (np.minimum(np.exp(np.asarray(log_durations, np.float32)) * mask, np.float32(config["max_duration_units"]))
         / np.float32(speed)).astype(np.float32)
    if letter_rate_base > 0 and ids is not None:
        letter_rate(d, np.asarray(ids), config["charset"], start=1, target=letter_rate_base * speed)
    return d


def apply_prompt_placeholder(d: np.ndarray, prompt_frames: int, units: int) -> np.ndarray:
    """The placeholder carries the voice prompt: d[0] = units * P (in place)."""
    d[0] = units * prompt_frames
    return d


def frames_for(d: np.ndarray, units: int) -> int:
    return int(math.ceil(float(d.sum(dtype=np.float32)) / units))


def frame_condition(h: np.ndarray, d: np.ndarray, first: int, frames: int, units: int) -> np.ndarray:
    """Per new frame j = first .. frames-1: sum over letters of overlap([start_l, end_l), [units*j, units*(j+1))) / units * h[l]."""
    d = np.asarray(d, np.float32)
    end = np.cumsum(d, dtype=np.float32)
    start = end - d
    lo = (np.arange(first, frames, dtype=np.float32) * units)[:, None]
    hi = lo + units
    w = np.clip(np.minimum(end[None], hi) - np.maximum(start[None], lo), 0, None) / np.float32(units)
    return (w.astype(np.float32) @ np.asarray(h, np.float32)).astype(np.float32)


def flow_steps(noise: list[np.ndarray], velocity: Callable[[np.ndarray, float], np.ndarray],
               times: Sequence[float]) -> np.ndarray:
    """Four student steps: x1 = x + (1 - t) v(x, t); x = (1 - t2) noise(k+1) + t2 x1. Returns the last x1."""
    x = noise[0].astype(np.float32)
    x1 = x
    for k, t in enumerate(times):
        v = velocity(x, t)
        x1 = x + np.float32(1 - t) * v
        if k + 1 < len(times):
            t2 = times[k + 1]
            x = np.float32(1 - t2) * noise[k + 1] + np.float32(t2) * x1
    return x1.astype(np.float32)


def low_shelf_coefficients(f0: float, db: float, sr: int, slope: float) -> tuple[float, float, float, float, float]:
    """RBJ cookbook low shelf (z = -1) normalised by a0 -> (b0, b1, b2, a1, a2)."""
    A = 10 ** (db / 40)
    w = 2 * math.pi * f0 / sr
    c = math.cos(w)
    q = 2 * math.sqrt(A) * math.sin(w) / 2 * math.sqrt((A + 1 / A) * (1 / slope - 1) + 2)
    z = -1
    b0 = A * ((A + 1) + z * (A - 1) * c + q)
    b1 = -2 * z * A * ((A - 1) + z * (A + 1) * c)
    b2 = A * ((A + 1) + z * (A - 1) * c - q)
    a0 = (A + 1) - z * (A - 1) * c + q
    a1 = 2 * z * ((A - 1) - z * (A + 1) * c)
    a2 = (A + 1) - z * (A - 1) * c - q
    return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0


def biquad(x: np.ndarray, coeffs) -> np.ndarray:
    """Direct form II transposed in float64."""
    b0, b1, b2, a1, a2 = coeffs
    y = np.empty(len(x), np.float64)
    z1 = z2 = 0.0
    for i, v in enumerate(np.asarray(x, np.float64)):
        o = b0 * v + z1
        z1 = b1 * v - a1 * o + z2
        z2 = b2 * v - a2 * o
        y[i] = o
    return y


def postprocess(wav: np.ndarray, lead_samples: int, config: dict, pause_ms: float) -> np.ndarray:
    """Low shelf over the whole waveform (lead-in included), cut the lead-in, limit to `peak`, append silence."""
    p = config["postprocess"]
    shelf = low_shelf_coefficients(p["low_shelf_hz"], p["low_shelf_db"], config["sample_rate"], p["shelf_slope"])
    out = biquad(wav, shelf)[lead_samples:].astype(np.float32)
    peak = float(np.abs(out).max()) if len(out) else 0.0
    if peak > p["peak"]:
        out = (out * np.float32(p["peak"] / peak)).astype(np.float32)
    pause = int(round(pause_ms / 1000 * config["sample_rate"]))
    return np.concatenate([out, np.zeros(pause, np.float32)])


def to_int16(x: np.ndarray) -> np.ndarray:
    return np.round(np.clip(np.asarray(x, np.float32), -1, 1) * 32767).astype(np.int16)


def split_long_sentence(text: str, max_letters: int = 180, min_split: int = 60) -> list[str]:
    """Pieces of at most `max_letters` where possible: cut at the last `, ; : -` or space between letter
    `min_split` and `max_letters` (after the punctuation, at the space). A run without any such character stays whole."""
    pieces = []
    s = text
    while len(s) > max_letters:
        k = max(s.rfind(ch, min_split, max_letters) for ch in _SPLIT_CHARS)
        if k < 0:
            break
        cut = k if s[k] == " " else k + 1
        pieces.append(s[:cut].strip())
        s = s[cut:].strip()
    pieces.append(s)
    return pieces
