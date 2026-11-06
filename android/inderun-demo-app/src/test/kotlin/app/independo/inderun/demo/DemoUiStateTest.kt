package app.independo.inderun.demo

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoUiStateTest {
    @Test
    fun canRun_requiresNonBlankPrompt() {
        val blankPromptState = DemoUiState(prompt = "   ")
        assertFalse(blankPromptState.canRun)

        val validState = DemoUiState(prompt = "Tell me a story.")
        assertTrue(validState.canRun)
    }

    @Test
    fun canRun_isFalseWhileRunning() {
        val state = DemoUiState(prompt = "Tell me a story.", isRunning = true)
        assertFalse(state.canRun)
    }

    @Test
    fun canRun_isFalseWhileStreaming() {
        val state = DemoUiState(prompt = "Tell me a story.", isStreaming = true)
        assertFalse(state.canRun)
    }

    @Test
    fun canStream_requiresNonBlankPromptAndNoRunInFlight() {
        assertFalse(DemoUiState(prompt = "   ").canStream)
        assertFalse(DemoUiState(prompt = "Tell me a story.", isRunning = true).canStream)
        assertTrue(DemoUiState(prompt = "Tell me a story.").canStream)
    }
}

class MegabytesTest {
    @Test
    fun megabytes_isWholeDecimalMegabytesRoundedHalfUp() {
        org.junit.Assert.assertEquals("113 MB", megabytes(113_011_812L))
        org.junit.Assert.assertEquals("1 MB", megabytes(500_000L))
        org.junit.Assert.assertEquals("0 MB", megabytes(499_999L))
    }
}
