"""Generate contracts/fixtures/speech/articulino-pipeline.json from articulino_math.py (deterministic).

    python generate_pipeline_fixture.py [--out <file>]

The fixture pins the Articulino host math for the TypeScript, Swift and Kotlin pipelines: each runs every case through
its own implementation against the scripted executor outputs given here.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

import numpy as np

import articulino_math as M

REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO / "contracts" / "fixtures" / "speech" / "articulino-pipeline.json"

CHARSET = " abcdefghijklmnopqrstuvwxyzäöüß.,?!-'\":;()0123456789"
CONFIG = {
    "sample_rate": 24000,
    "latent_dim": 2,
    "samples_per_frame": 4,
    "duration_units_per_frame": 4,
    "prefix_frames": 3,
    "decoder_lead_in_frames": 1,
    "max_duration_units": 400.0,
    "times": [0.0, 0.25, 0.5, 0.75],
    "charset": CHARSET,
    "languages": {"de": 0, "en": 1},
    "postprocess": {"low_shelf_db": 2.0, "low_shelf_hz": 180.0, "shelf_slope": 0.7, "peak": 0.95},
}
UNITS = CONFIG["duration_units_per_frame"]
HOP = CONFIG["samples_per_frame"]
# The voice's prompt frames, voice_cache shape[4]. Deliberately not the config's prefix_frames, which the pipelines must
# not read: a regression to config.prefix_frames fails every case that depends on P.
P = 2
LETTER_RATE = 40.0
PAUSE_MS = 1

rng = np.random.default_rng(260)


def q(shape, scale=1.0) -> np.ndarray:
    """Random float32 tensor quantised to 4 decimals, so the JSON text and the value computed with are the same."""
    return np.round(rng.standard_normal(shape) * scale, 4).astype(np.float32)


def num(v):
    """Shortest decimal that reads back as the same float32 (or the int itself)."""
    if isinstance(v, (int, np.integer)):
        return int(v)
    return float(str(np.float32(v)))


def tensor(arr) -> dict:
    arr = np.asarray(arr)
    return {"shape": list(arr.shape), "data": [num(v) for v in arr.reshape(-1)]}


def flat(arr) -> list:
    return [num(v) for v in np.asarray(arr).reshape(-1)]


def build_voice() -> dict:
    return {
        "voice_tokens": q((1, 2, 2)), "voice_vector": q((1, 2)), "voice_cache": q((1, 2, 1, 1, P, 1)),
        "prompt_latents": q((1, 1, 2)), "letter_rate": np.array([LETTER_RATE], np.float32),
    }


# ---------------------------------------------------------------------------- the reference pipeline


def model_text_inputs(ids, langs):
    n = len(ids)
    return {"text_ids": np.array([[0] + ids], np.int64),
            "language": np.array([[langs[0]] + langs], np.int64),
            "text_mask": np.array([[0] + [1] * n], np.int64)}


def synthesize(text, language, speed, pause_ms, voice, executor, noise):
    """The sentence pipeline of the plan's host-math section over a scripted executor -> (int16 samples, calls)."""
    ids, langs = M.letters(text, language, CONFIG)
    if not ids:
        return M.to_int16(M.postprocess(np.zeros(0, np.float32), 0, CONFIG, pause_ms)), []
    calls = []
    inputs = model_text_inputs(ids, langs)
    calls.append({"role": "text", "inputs": {**inputs, "voice_vector": voice["voice_vector"]}})
    h = np.array(executor["text"]["text_features"]["data"], np.float32).reshape(executor["text"]["text_features"]["shape"])[0]
    logd = np.array(executor["text"]["log_durations"]["data"], np.float32)
    d = M.durations(logd, inputs["text_mask"][0], speed, CONFIG, float(voice["letter_rate"][0]), ids=inputs["text_ids"][0])
    M.apply_prompt_placeholder(d, P, UNITS)
    frames = M.frames_for(d, UNITS)
    cond = M.frame_condition(h, d, P, frames, UNITS)
    steps = iter(executor["dit_step"])

    def velocity(x, t):
        calls.append({"role": "dit_step", "inputs": {"x": x, "t": np.array([t], np.float32), "frame_cond": cond[None]}})
        out = next(steps)["velocity"]
        return np.array(out["data"], np.float32).reshape(out["shape"])

    x1 = M.flow_steps([np.array(n["data"], np.float32).reshape(n["shape"]) for n in noise], velocity, CONFIG["times"])
    lead = min(voice["prompt_latents"].shape[1], CONFIG["decoder_lead_in_frames"])
    z = np.concatenate([voice["prompt_latents"][:, voice["prompt_latents"].shape[1] - lead:], x1], axis=1)
    calls.append({"role": "decoder", "inputs": {"latents": z}})
    wav = executor["decoder"]["waveform"]
    wav = np.array(wav["data"], np.float32).reshape(wav["shape"])[0]
    return M.to_int16(M.postprocess(wav, lead * HOP, CONFIG, pause_ms)), calls


# ---------------------------------------------------------------------------- cases


def letters_case(case_id, text, language):
    ids, langs = M.letters(text, language, CONFIG)
    return {"id": case_id, "kind": "letters", "text": text, "language": language,
            "expect": {"textIds": [0] + ids, "language": [langs[0] if langs else CONFIG["languages"][language]] + langs,
                       "textMask": [0] + [1] * len(ids)}}


def duration_cases():
    mask = [0] + [1] * 6
    logd = np.log(np.array([3.0, 2.0, 900.0, 1.5, 4.0, 0.2, 2.5], np.float32))
    d1 = M.apply_prompt_placeholder(M.durations(logd, mask, 1.25, CONFIG, 0.0), P, UNITS)
    clamp = {"id": "durations_clamp_speed", "kind": "durations",
             "input": {"logDurations": flat(logd), "textMask": mask, "speed": 1.25, "letterRate": 0},
             "expect": {"durations": flat(d1), "frames": M.frames_for(d1, UNITS)}}

    ids = [0] + M.letters("guten tag, welt", "de", CONFIG)[0]
    log2 = np.log(np.array([1.0, 3.0, 2.5, 4.0, 2.0, 30.0, 0.3, 1.0, 5.0, 3.5, 2.0, 1.5, 4.5, 2.5, 3.0, 6.0], np.float32))
    assert len(log2) == len(ids)
    mask2 = [0] + [1] * (len(ids) - 1)
    d2 = M.apply_prompt_placeholder(M.durations(log2, mask2, 1.0, CONFIG, LETTER_RATE, ids=ids), P, UNITS)
    equalised = {"id": "durations_rate_equalised", "kind": "durations",
                 "input": {"logDurations": flat(log2), "textMask": mask2, "speed": 1.0, "letterRate": LETTER_RATE, "textIds": ids},
                 "expect": {"durations": flat(d2), "frames": M.frames_for(d2, UNITS)}}
    return [clamp, equalised]


def frame_condition_case():
    h = q((5, 2))
    d = np.array([8.0, 2.5, 1.0, 4.5, 3.0], np.float32)
    frames = M.frames_for(d, UNITS)
    return {"id": "frame_condition_overlap", "kind": "frameCondition",
            "input": {"features": tensor(h), "durations": flat(d), "first": P, "frames": frames},
            "expect": {"condition": tensor(M.frame_condition(h, d, P, frames, UNITS))}}


def flow_case():
    new_frames = 3
    noise = [q((1, new_frames, 2)) for _ in CONFIG["times"]]
    vel = [q((1, new_frames, 2), 0.5) for _ in CONFIG["times"]]
    it = iter(vel)
    out = M.flow_steps(noise, lambda x, t: next(it), CONFIG["times"])
    return {"id": "flow_steps", "kind": "flowSteps",
            "input": {"noise": [tensor(n) for n in noise], "velocities": [tensor(v) for v in vel], "newFrames": new_frames},
            "expect": {"latents": tensor(out)}}


def scaled_to_peak(wav: np.ndarray, lead_samples: int, peak: float) -> np.ndarray:
    """Scale `wav` so its post-shelf, post-cut peak is `peak` (above the limiter threshold), then re-quantise."""
    shelf = M.low_shelf_coefficients(180.0, 2.0, 24000, 0.7)
    cur = float(np.abs(M.biquad(wav, shelf)[lead_samples:]).max())
    out = np.round(wav * (peak / cur), 4).astype(np.float32)
    assert float(np.abs(M.biquad(out, shelf)[lead_samples:]).max()) > 0.95
    return out


def postprocess_case():
    wav = scaled_to_peak(q(20, 0.4), HOP, 1.4)
    samples = M.to_int16(M.postprocess(wav, HOP, CONFIG, PAUSE_MS))
    return {"id": "postprocess_shelf_cut_limit_pause", "kind": "postprocess",
            "input": {"waveform": flat(wav), "leadInFrames": 1, "pauseMs": PAUSE_MS},
            "expect": {"samples": [int(s) for s in samples]}}


def split_case():
    head = ("lorem ipsum " * 10)[:119] + "x"
    text = head + "," + " " + "y" * 78
    assert text.index(",") == 120 and len(text) == 200
    return {"id": "long_sentence_split", "kind": "split", "text": text, "expect": {"pieces": M.split_long_sentence(text)}}


def scripted_executor(voice):
    """Tiny but realistic executor outputs for 'Hallo du.': a duration above 4 units, a waveform that needs limiting."""
    text, language = "Hallo du.", "de"
    ids, _ = M.letters(text, language, CONFIG)
    n = len(ids) + 1  # placeholder included
    letter_units = [2.0, 2.0, 2.5, 2.0, 2.5, 4.7, 1.5, 1.5, 0.5]  # h a l l o ' ' d u .
    assert len(letter_units) == len(ids)
    logd = np.log(np.array([1.0] + letter_units, np.float32))
    features = q((1, n, 2))
    ids_arr = np.array([0] + ids)
    d = M.apply_prompt_placeholder(M.durations(logd, [0] + [1] * len(ids), 1.0, CONFIG, LETTER_RATE, ids=ids_arr), P, UNITS)
    assert d.max() > 4 and d[0] == P * UNITS
    new_frames = M.frames_for(d, UNITS) - P
    noise = [tensor(q((1, new_frames, 2))) for _ in CONFIG["times"]]
    dit = [{"velocity": tensor(q((1, new_frames, 2), 0.5))} for _ in CONFIG["times"]]
    lead = 1
    wav = scaled_to_peak(q((1, (lead + new_frames) * HOP), 0.4)[0], lead * HOP, 1.3)[None]
    executor = {"text": {"text_features": tensor(features), "log_durations": tensor(logd[None])},
                "dit_step": dit, "decoder": {"waveform": tensor(wav)}}
    return text, language, executor, noise


def end_to_end_cases(voice):
    text, language, executor, noise = scripted_executor(voice)
    samples, calls = synthesize(text, language, 1.0, PAUSE_MS, voice, executor, noise)
    expect_calls = []
    for c in calls:
        i = c["inputs"]
        if c["role"] == "text":
            shown = {"text_ids": tensor(i["text_ids"]), "language": tensor(i["language"]), "text_mask": tensor(i["text_mask"]),
                     "voice_vector": {"shape": list(i["voice_vector"].shape)}}
        elif c["role"] == "dit_step":
            shown = {"t": tensor(i["t"]), "x": tensor(i["x"]),
                     "frame_cond": tensor(i["frame_cond"]) if i["t"][0] == 0 else {"shape": list(i["frame_cond"].shape)}}
        else:
            shown = {"latents": tensor(i["latents"])}
        expect_calls.append({"role": c["role"], "inputs": shown})
    assert float(np.abs(np.array(executor["decoder"]["waveform"]["data"])).max()) > 0.95
    e2e = {"id": "end_to_end", "kind": "endToEnd", "text": text, "language": language, "speed": 1.0, "pauseMs": PAUSE_MS,
           "executor": executor, "noise": noise,
           "expect": {"calls": expect_calls, "samples": [int(s) for s in samples], "sampleRate": CONFIG["sample_rate"]}}
    empty = {"id": "empty_after_letters", "kind": "endToEnd", "text": "\U0001F600 \u2728", "language": "de", "pauseMs": PAUSE_MS,
             "executor": {}, "noise": [],
             "expect": {"calls": [], "samples": [0] * int(round(PAUSE_MS / 1000 * CONFIG["sample_rate"])),
                        "sampleRate": CONFIG["sample_rate"]}}
    cancel = {"id": "cancel_between_graphs", "kind": "cancel", "text": text, "language": language, "pauseMs": PAUSE_MS,
              "cancelAfterCalls": 2, "executor": copy.deepcopy(executor), "noise": copy.deepcopy(noise),
              "expect": {"callsAtMost": 2}}
    return [e2e, empty, cancel]


def build() -> dict:
    voice = build_voice()
    cases = [
        letters_case("letters_de", "Ich habe Hunger.", "de"),
        letters_case("letters_en_quotes", "It’s “fine” – OK!", "en"),
        letters_case("letters_accents_and_unknown", "Café ø \U0001F600 1a", "de"),
        *duration_cases(),
        frame_condition_case(),
        flow_case(),
        postprocess_case(),
        split_case(),
        *end_to_end_cases(voice),
    ]
    return {
        "$comment": "Pins the Articulino host math (tools/neural-speech/articulino_math.py generates it; see "
                    "docs/architecture/neural-speech-provider-family.md). Each SDK runs every case through its pipeline "
                    "implementation with the scripted executor outputs given here; floats match within 1e-4, int16 samples "
                    "within +-1. One handler per 'kind' behind a guard test. Tensors are {shape, data} with flat C-order "
                    "data. Model text inputs are [0] + letters (placeholder first), text_mask [0, 1, ...] as int64. "
                    "'durations' and 'frameCondition' use the voice's prompt frames P = voice_cache shape[4] (here 2; the "
                    "config's prefix_frames, 3, is never read) and "
                    "the config's duration_units_per_frame; the voice's letter_rate is the 'letterRate' of the case. "
                    "'flowSteps' draws noise k from input.noise[k] and the velocity of step k from input.velocities[k]. "
                    "'cancel' aborts the pipeline once cancelAfterCalls executor calls have run and expects no further call.",
        "config": CONFIG,
        "voice": {k: tensor(v) for k, v in voice.items()},
        "cases": cases,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    a = ap.parse_args()
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(build(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {a.out} ({a.out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
