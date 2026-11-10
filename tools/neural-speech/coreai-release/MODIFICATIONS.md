# Modifications (Apache-2.0, section 4(b))

`main.mlirb`, `main.hash` and `metadata.json` together form `articulino.aimodel`, an Apple Core AI asset. It was
derived from Articulino-DE-EN-Realtime-Stream-TTS, Copyright 2026 eigenhand, licensed under the Apache License 2.0
(see LICENSE and NOTICE).

Source:
- PyTorch code `github.com/eigenhand/articulino` at commit 66f79f602d3421aee7a7f8cfb8990faa0e88cc2a;
- weights `huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS` at revision
  38ad5471d4e6a20b70ce708f0f3c35e3d2e86523.

Changes made by Independo GmbH (IndeRun, issue #279), 2026-11-09:

1. **Re-traced stages.** The three per-sentence stages (`text`, `dit_step`, `decoder`) were re-traced with
   `torch.export` and converted with Apple coreai-torch 0.4.3 (commit 7a18c005), torch 2.13.0, into one asset with
   three entrypoints. Shapes are bounded: text N ≤ 257, dit_step L ≤ 1024, decoder F ≤ 1036, batch 1, voice prefix
   P = 125.
2. **Integer inputs.** `text_mask` takes 0/1 integers and is cast to bool inside the graph. The converter narrows
   the integer inputs to int32.
3. **Time embedding.** The `dit_step` time-embedding frequencies are a precomputed float32 constant instead of being
   computed in the graph.
4. **iSTFT.** The decoder's `torch.istft` is replaced by a real-valued matmul against a windowed inverse-rDFT
   basis, followed by an overlap-add of shifted chunks.

The weights are unchanged (float32). Numerically, the asset matches the upstream ONNX fp32 release at
112–125 dB SNR per stage.
