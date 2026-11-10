# Adapted from eigenhand/articulino-onnx, Apache License 2.0
# (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).
"""Prepare one Articulino voice bundle (.safetensors) from a voice-prompt WAV, offline.

    python prepare_articulino_voice.py --models <onnx-release-dir> --precision {fp32,fp16,int8} \
        --wav prompt.wav --out voice.safetensors [--voice-id prompt]

Runs the upstream `encoder` and `voice` graphs, which never ship on a device, and measures the voice's base
letter rate through the `text` graph. See README.md for the bundle format.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf

import articulino_math as M
import safetensors_io

TOOL_VERSION = "1"
VOICE_FORMAT = "inderun.articulino.voice/1"
UPSTREAM_REPO = "eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX"
PROMPT_TAIL_FRAMES = 12
MIN_PROMPT_SECONDS = 3


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def session(path: Path) -> ort.InferenceSession:
    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    so.inter_op_num_threads = 1
    so.add_session_config_entry("session.intra_op.allow_spinning", "0")
    return ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])


def resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """Band-limited FFT resampling."""
    if sr_in == sr_out:
        return x.astype(np.float32)
    n_out = int(round(len(x) * sr_out / sr_in))
    spec = np.fft.rfft(x.astype(np.float64))
    keep = min(len(spec), n_out // 2 + 1)
    out = np.zeros(n_out // 2 + 1, complex)
    out[:keep] = spec[:keep]
    return (np.fft.irfft(out, n_out) * (n_out / len(x))).astype(np.float32)


def load_prompt(wav_path: Path, config: dict) -> np.ndarray:
    """Mono, 24 kHz, at least MIN_PROMPT_SECONDS and at most max_voice_seconds, whole frames."""
    data, sr = sf.read(str(wav_path), dtype="float32", always_2d=True)
    wav = resample(data.mean(axis=1), sr, config["sample_rate"])
    hop = config["samples_per_frame"]
    wav = wav[: min(len(wav), int(config["max_voice_seconds"] * config["sample_rate"])) // hop * hop]
    if len(wav) < MIN_PROMPT_SECONDS * config["sample_rate"]:
        raise ValueError(f"voice prompt too short (need at least {MIN_PROMPT_SECONDS} s of audio, "
                         f"got {len(wav) / config['sample_rate']:.2f} s)")
    return wav


def base_letter_rate(text_session: ort.InferenceSession, voice_vector: np.ndarray, config: dict) -> float:
    """Median speaking rate of the six calibration sentences: no prompt placeholder, speed 1, as Engine.base_rate."""
    mask_type = {i.name: i.type for i in text_session.get_inputs()}["text_mask"]
    mask_dtype = np.bool_ if mask_type == "tensor(bool)" else np.int64
    rates = []
    for sentence in M.CALIBRATION:
        ids, _ = M.letters(sentence, "de", config)
        arr = np.array([ids], np.int64)
        _, logd = text_session.run(["text_features", "log_durations"], {
            "text_ids": arr, "language": np.zeros_like(arr), "text_mask": np.ones(arr.shape, mask_dtype),
            "voice_vector": voice_vector})
        rates.append(M.letter_rate(np.exp(logd[0]).astype(np.float32), arr[0], config["charset"]))
    return float(np.median(rates))


class VoiceTool:
    """The offline graphs of one release directory and precision, loaded once for any number of voices."""

    def __init__(self, models: Path, precision: str):
        self.models = Path(models)
        self.precision = precision
        self.config = json.loads((self.models / "config.json").read_text(encoding="utf-8"))
        self.graph_dir = self.models / precision
        self.encoder_path = self.graph_dir / "encoder.onnx"
        self.voice_path = self.graph_dir / "voice.onnx"
        self.encoder = session(self.encoder_path)
        self.voice = session(self.voice_path)
        self.text = session(self.graph_dir / "text.onnx")
        self.encoder_sha256 = sha256_file(self.encoder_path)
        self.voice_sha256 = sha256_file(self.voice_path)

    def prepare(self, wav_path: Path, voice_id: str, out: Path) -> dict:
        """Write the bundle to `out`; returns {"letter_rate", "prompt_frames"}."""
        wav = load_prompt(Path(wav_path), self.config)
        latents = self.encoder.run(["latents"], {"waveform": wav[None]})[0]
        tokens, vector, cache = self.voice.run(["voice_tokens", "voice_vector", "voice_cache"], {"latents": latents})
        prompt_frames = int(cache.shape[4])
        prompt = latents[:, :prompt_frames][:, -PROMPT_TAIL_FRAMES:]
        rate = base_letter_rate(self.text, vector, self.config)
        safetensors_io.write_safetensors(Path(out), {
            "voice_tokens": tokens.astype(np.float32), "voice_vector": vector.astype(np.float32),
            "voice_cache": cache.astype(np.float32), "prompt_latents": prompt.astype(np.float32),
            "letter_rate": np.array([rate], np.float32),
        }, {
            "format": VOICE_FORMAT, "voice_id": voice_id, "source_wav_sha256": sha256_file(Path(wav_path)),
            "encoder_sha256": self.encoder_sha256, "voice_sha256": self.voice_sha256,
            "upstream_repo": UPSTREAM_REPO, "tool_version": TOOL_VERSION,
        })
        return {"letter_rate": rate, "prompt_frames": prompt_frames}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument("--precision", required=True, choices=["fp32", "fp16", "int8"])
    ap.add_argument("--wav", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--voice-id", default=None)
    a = ap.parse_args()
    result = VoiceTool(a.models, a.precision).prepare(a.wav, a.voice_id or a.wav.stem, a.out)
    print(f"letter_rate = {result['letter_rate']:.3f}, P = {result['prompt_frames']}")


if __name__ == "__main__":
    main()
