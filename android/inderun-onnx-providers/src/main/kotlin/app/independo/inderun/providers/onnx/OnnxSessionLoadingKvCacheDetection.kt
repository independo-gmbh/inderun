package app.independo.inderun.providers.onnx

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer

/**
 * The decode contract this runtime detected for a loaded graph. [KvCache] is chosen only when
 * every assumption the KV-cache decode path depends on (layer count, head count, head dimension,
 * per-layer `past_key_values`/`present` naming) is resolvable from the graph's declared input
 * names and the model directory's `config.json`; anything unresolvable conservatively falls back
 * to [FullRecompute] rather than guessing.
 */
internal sealed class DecodeStrategy {
    data object FullRecompute : DecodeStrategy()
    data class KvCache(val layout: KvCacheLayout) : DecodeStrategy()
}

/**
 * Static geometry the KV-cache decode path needs to build empty initial `past_key_values` tensors
 * and locate this graph's `present.*` outputs, resolved once at load time.
 */
internal data class KvCacheLayout(
    val numLayers: Int,
    val numKeyValueHeads: Int,
    val headDim: Int,
    val hasPositionIds: Boolean,
) {
    val presentOutputNames: List<String>
        get() = (0 until numLayers).flatMap { layer -> listOf("present.$layer.key", "present.$layer.value") }

    /**
     * Zero-length `past_key_values.*` tensors for the first decode step: shape
     * `[1, numKeyValueHeads, 0, headDim]` -- the sequence-length axis starts empty and grows as
     * `present.*` outputs replace these tensors after each step.
     */
    fun emptyPastKeyValues(environment: OrtEnvironment): Map<String, OnnxTensor> {
        val shape = longArrayOf(1, numKeyValueHeads.toLong(), 0, headDim.toLong())
        val result = mutableMapOf<String, OnnxTensor>()
        for (layer in 0 until numLayers) {
            for (part in listOf("key", "value")) {
                result["past_key_values.$layer.$part"] = OnnxTensor.createTensor(environment, FloatBuffer.allocate(0), shape)
            }
        }
        return result
    }
}

/**
 * Auto-detects the decode strategy from the graph's declared input names, so no [app.independo
 * .inderun.contracts.ModelPackage] field or app-facing configuration is needed to pick between the
 * plain and KV-cache IO contracts. Falls back to [DecodeStrategy.FullRecompute] -- always
 * supported -- whenever any KV-cache assumption (naming convention, resolvable `config.json`
 * architecture fields) doesn't hold, rather than guessing.
 */
internal fun detectDecodeStrategy(session: OrtSession, directory: File): DecodeStrategy = detectDecodeStrategy(session.inputNames, session.outputNames, directory)

/**
 * Pure variant of [detectDecodeStrategy] taking the graph's declared input/output names directly,
 * independent of [OrtSession] -- lets KV-cache detection be exercised in unit tests against
 * synthetic name sets without a real ONNX Runtime native session (unavailable in this module's
 * unit test environment).
 */
internal fun detectDecodeStrategy(inputNames: Set<String>, outputNames: Set<String>, directory: File): DecodeStrategy {
    val hasPastKeyValues = inputNames.any { it.startsWith("past_key_values.") }
    if (!hasPastKeyValues) {
        return DecodeStrategy.FullRecompute
    }

    val layout = try {
        kvCacheLayout(inputNames, outputNames, directory)
    } catch (error: Throwable) {
        null
    }
    return layout?.let { DecodeStrategy.KvCache(it) } ?: DecodeStrategy.FullRecompute
}

private fun kvCacheLayout(inputNames: Set<String>, outputNames: Set<String>, directory: File): KvCacheLayout {
    val configFile = File(directory, "config.json")
    if (!configFile.exists()) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "model files missing: 'config.json' not found for KV-cache detection.",
        )
    }
    val config = JSONObject(configFile.readText())

    // Field names vary by architecture family: Llama-style configs use
    // `num_hidden_layers`/`num_attention_heads`/`hidden_size`; GPT-2-style configs (still common
    // among small quantized decoder-with-past exports) use `n_layer`/`n_head`/`n_embd` instead.
    // Both are read so KV-cache detection isn't silently GPT-2-blind.
    val numLayers = intField(config, "num_hidden_layers", "n_layer")
        ?: throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "model package malformed: 'config.json' missing 'num_hidden_layers'/'n_layer'.",
        )

    val numAttentionHeads = intField(config, "num_attention_heads", "n_head")
    val numKeyValueHeads = intField(config, "num_key_value_heads") ?: numAttentionHeads
        ?: throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "model package malformed: 'config.json' missing attention head count.",
        )

    val headDim = intField(config, "head_dim")
        ?: run {
            val hiddenSize = intField(config, "hidden_size", "n_embd")
            if (hiddenSize != null && numAttentionHeads != null && numAttentionHeads > 0) {
                hiddenSize / numAttentionHeads
            } else {
                throw OnnxRuntimeError(
                    kind = OnnxRuntimeErrorKind.CAPABILITY,
                    message = "model package malformed: 'config.json' missing 'hidden_size'/'n_embd'/'head_dim'.",
                )
            }
        }

    // `use_cache_branch` (some merged Optimum exports' boolean cache-branch selector) needs a
    // dedicated calling convention this runtime does not implement -- conservatively fall back to
    // full recompute for such graphs rather than feeding a mismatched call.
    if (inputNames.contains("use_cache_branch")) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "unsupported model format: 'use_cache_branch' input is not supported by this runtime's KV-cache path.",
        )
    }

    for (layer in 0 until numLayers) {
        for (part in listOf("key", "value")) {
            if (!inputNames.contains("past_key_values.$layer.$part")) {
                throw OnnxRuntimeError(
                    kind = OnnxRuntimeErrorKind.CAPABILITY,
                    message = "model package malformed: missing 'past_key_values.$layer.$part' input.",
                )
            }
            if (!outputNames.contains("present.$layer.$part")) {
                throw OnnxRuntimeError(
                    kind = OnnxRuntimeErrorKind.CAPABILITY,
                    message = "model package malformed: missing 'present.$layer.$part' output.",
                )
            }
        }
    }

    return KvCacheLayout(
        numLayers = numLayers,
        numKeyValueHeads = numKeyValueHeads,
        headDim = headDim,
        hasPositionIds = inputNames.contains("position_ids"),
    )
}

private fun intField(config: JSONObject, vararg keys: String): Int? {
    for (key in keys) {
        if (config.has(key)) {
            return config.optInt(key)
        }
    }
    return null
}
