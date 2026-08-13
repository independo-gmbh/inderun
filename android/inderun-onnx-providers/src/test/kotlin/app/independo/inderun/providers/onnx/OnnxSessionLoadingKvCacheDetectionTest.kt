package app.independo.inderun.providers.onnx

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OnnxSessionLoadingKvCacheDetectionTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun detectDecodeStrategyFallsBackToFullRecomputeWithoutPastKeyValuesInputs() {
        val strategy = detectDecodeStrategy(
            inputNames = setOf("input_ids", "attention_mask"),
            outputNames = setOf("logits"),
            directory = tempFolder.root,
        )

        assertEquals(DecodeStrategy.FullRecompute, strategy)
    }

    @Test
    fun detectDecodeStrategySelectsKvCacheWhenEveryAssumptionResolves() {
        writeConfig(numHiddenLayers = 2, numAttentionHeads = 4, hiddenSize = 32)
        val inputNames = kvCacheInputNames(numLayers = 2) + setOf("input_ids", "attention_mask", "position_ids")
        val outputNames = kvCachePresentOutputNames(numLayers = 2) + setOf("logits")

        val strategy = detectDecodeStrategy(inputNames, outputNames, tempFolder.root)

        assertTrue(strategy is DecodeStrategy.KvCache)
        val layout = (strategy as DecodeStrategy.KvCache).layout
        assertEquals(2, layout.numLayers)
        assertEquals(4, layout.numKeyValueHeads)
        assertEquals(8, layout.headDim)
        assertTrue(layout.hasPositionIds)
    }

    @Test
    fun detectDecodeStrategyFallsBackWhenConfigJsonMissing() {
        val inputNames = kvCacheInputNames(numLayers = 1) + setOf("input_ids", "attention_mask")
        val outputNames = kvCachePresentOutputNames(numLayers = 1) + setOf("logits")

        val strategy = detectDecodeStrategy(inputNames, outputNames, tempFolder.root)

        assertEquals(DecodeStrategy.FullRecompute, strategy)
    }

    @Test
    fun detectDecodeStrategyFallsBackWhenPresentOutputMissing() {
        writeConfig(numHiddenLayers = 1, numAttentionHeads = 2, hiddenSize = 16)
        val inputNames = kvCacheInputNames(numLayers = 1) + setOf("input_ids", "attention_mask")
        val outputNames = setOf("logits") // missing present.0.key/value

        val strategy = detectDecodeStrategy(inputNames, outputNames, tempFolder.root)

        assertEquals(DecodeStrategy.FullRecompute, strategy)
    }

    @Test
    fun detectDecodeStrategyFallsBackForMergedUseCacheBranchGraphs() {
        writeConfig(numHiddenLayers = 1, numAttentionHeads = 2, hiddenSize = 16)
        val inputNames = kvCacheInputNames(numLayers = 1) + setOf("input_ids", "attention_mask", "use_cache_branch")
        val outputNames = kvCachePresentOutputNames(numLayers = 1) + setOf("logits")

        val strategy = detectDecodeStrategy(inputNames, outputNames, tempFolder.root)

        assertEquals(DecodeStrategy.FullRecompute, strategy)
    }

    @Test
    fun detectDecodeStrategyReadsGpt2StyleConfigFieldNames() {
        writeConfig(numHiddenLayers = null, numAttentionHeads = null, hiddenSize = null, extra = """"n_layer": 1, "n_head": 2, "n_embd": 16""")
        val inputNames = kvCacheInputNames(numLayers = 1) + setOf("input_ids", "attention_mask")
        val outputNames = kvCachePresentOutputNames(numLayers = 1) + setOf("logits")

        val strategy = detectDecodeStrategy(inputNames, outputNames, tempFolder.root)

        assertTrue(strategy is DecodeStrategy.KvCache)
        val layout = (strategy as DecodeStrategy.KvCache).layout
        assertEquals(1, layout.numLayers)
        assertEquals(2, layout.numKeyValueHeads)
        assertEquals(8, layout.headDim)
    }

    private fun kvCacheInputNames(numLayers: Int): Set<String> = (0 until numLayers).flatMap { layer -> listOf("past_key_values.$layer.key", "past_key_values.$layer.value") }.toSet()

    private fun kvCachePresentOutputNames(numLayers: Int): Set<String> = (0 until numLayers).flatMap { layer -> listOf("present.$layer.key", "present.$layer.value") }.toSet()

    private fun writeConfig(numHiddenLayers: Int?, numAttentionHeads: Int?, hiddenSize: Int?, extra: String? = null) {
        val fields = mutableListOf<String>()
        numHiddenLayers?.let { fields += """"num_hidden_layers": $it""" }
        numAttentionHeads?.let { fields += """"num_attention_heads": $it""" }
        hiddenSize?.let { fields += """"hidden_size": $it""" }
        extra?.let { fields += it }
        tempFolder.newFile("config.json").writeText("{${fields.joinToString(separator = ",")}}")
    }
}
