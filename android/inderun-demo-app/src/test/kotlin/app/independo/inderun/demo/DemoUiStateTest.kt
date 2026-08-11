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
}
