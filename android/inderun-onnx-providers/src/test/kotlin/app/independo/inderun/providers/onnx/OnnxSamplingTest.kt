package app.independo.inderun.providers.onnx

import app.independo.inderun.contracts.Generation
import org.junit.Assert.assertEquals
import org.junit.Test

class OnnxSamplingTest {

    @Test
    fun selectTokenIsDeterministicArgmaxWithoutTemperature() {
        val sampling = SamplingConfig(generation = null)
        val logits = floatArrayOf(0.1f, 5.0f, -2.0f, 3.0f)

        assertEquals(1L, sampling.selectToken(logits))
    }

    @Test
    fun selectTokenWithSeedIsReproducibleAcrossInstances() {
        val generation = Generation(seed = 42L, temperature = 0.8)
        val logits = floatArrayOf(1.0f, 2.0f, 3.0f, 0.5f, 4.0f)

        val first = SamplingConfig(generation).selectToken(logits)
        val second = SamplingConfig(generation).selectToken(logits)

        assertEquals(first, second)
    }

    @Test
    fun selectTokenWithTopPNarrowsToDominantCandidate() {
        // A single overwhelmingly likely logit plus low-probability noise: after softmax and a
        // tight topP, only the dominant index should remain in the candidate set regardless of
        // the (seeded, reproducible) random draw.
        val generation = Generation(seed = 7L, temperature = 1.0, topP = 0.5)
        val logits = floatArrayOf(-10f, -10f, 20f, -10f, -10f)

        val sampling = SamplingConfig(generation)
        assertEquals(2L, sampling.selectToken(logits))
    }
}
