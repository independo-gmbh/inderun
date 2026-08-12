import Foundation
import OnnxRuntimeBindings

extension LoadedSessionBox {
    /// Auto-detects the decode strategy from the graph's declared input names, so no
    /// `ModelPackage` field or app-facing configuration is needed to pick between the plain and
    /// KV-cache IO contracts. Falls back to `.fullRecompute` -- always supported -- whenever any
    /// KV-cache assumption (naming convention, resolvable `config.json` architecture fields)
    /// doesn't hold, rather than guessing.
    static func detectDecodeStrategy(session: ORTSession, directory: URL) throws -> DecodeStrategy {
        guard let inputNames = try? session.inputNames() else {
            return .fullRecompute
        }
        let hasPastKeyValues = inputNames.contains { $0.hasPrefix("past_key_values.") }
        guard hasPastKeyValues else {
            return .fullRecompute
        }

        guard let layout = try? kvCacheLayout(session: session, inputNames: inputNames, directory: directory) else {
            return .fullRecompute
        }
        return .kvCache(layout)
    }

    private static func kvCacheLayout(session: ORTSession, inputNames: [String], directory: URL) throws -> KvCacheLayout {
        let configPath = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path),
              let configData = try? Data(contentsOf: configPath),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model files missing: 'config.json' not found or unreadable for KV-cache detection."
            )
        }

        // Field names vary by architecture family: Llama-style configs use
        // `num_hidden_layers`/`num_attention_heads`/`hidden_size`; GPT-2-style configs (still
        // common among small quantized decoder-with-past exports) use `n_layer`/`n_head`/`n_embd`
        // instead. Both are read so KV-cache detection isn't silently GPT-2-blind.
        guard let numLayers = intField(config, "num_hidden_layers", "n_layer") else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model package malformed: 'config.json' missing 'num_hidden_layers'/'n_layer'."
            )
        }

        let numAttentionHeads = intField(config, "num_attention_heads", "n_head")
        let numKeyValueHeads = intField(config, "num_key_value_heads") ?? numAttentionHeads
        guard let numKeyValueHeads else {
            throw OnnxRuntimeError(kind: .capability, message: "model package malformed: 'config.json' missing attention head count.")
        }

        let headDim: Int
        if let explicitHeadDim = intField(config, "head_dim") {
            headDim = explicitHeadDim
        } else if let hiddenSize = intField(config, "hidden_size", "n_embd"), let numAttentionHeads, numAttentionHeads > 0 {
            headDim = hiddenSize / numAttentionHeads
        } else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model package malformed: 'config.json' missing 'hidden_size'/'n_embd'/'head_dim'."
            )
        }

        // `use_cache_branch` (some merged Optimum exports' boolean cache-branch selector) needs a
        // `bool`-typed tensor, which this version of the ONNX Runtime Objective-C bindings does not
        // expose an `ORTTensorElementDataType` case for -- conservatively fall back to
        // `.fullRecompute` for such graphs rather than feeding a mistyped tensor.
        guard !inputNames.contains("use_cache_branch") else {
            throw OnnxRuntimeError(
                kind: .capability,
                message: "unsupported model format: 'use_cache_branch' input is not supported by this runtime's KV-cache path."
            )
        }

        let outputNames = (try? session.outputNames()) ?? []
        for layer in 0..<numLayers {
            for part in ["key", "value"] {
                guard inputNames.contains("past_key_values.\(layer).\(part)") else {
                    throw OnnxRuntimeError(
                        kind: .capability,
                        message: "model package malformed: missing 'past_key_values.\(layer).\(part)' input."
                    )
                }
                guard outputNames.contains("present.\(layer).\(part)") else {
                    throw OnnxRuntimeError(
                        kind: .capability,
                        message: "model package malformed: missing 'present.\(layer).\(part)' output."
                    )
                }
            }
        }

        return KvCacheLayout(
            numLayers: numLayers,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim,
            hasPositionIds: inputNames.contains("position_ids")
        )
    }

    private static func intField(_ config: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = config[key] as? Int { return value }
            if let value = config[key] as? NSNumber { return value.intValue }
        }
        return nil
    }
}
