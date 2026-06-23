package app.independo.inderun.demo

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoUiStateTest {
    @Test
    fun cloudMode_requiresValidEndpointAndModelBeforeRun() {
        val invalidEndpointState = DemoUiState(
            executionMode = DemoExecutionMode.Cloud,
            cloudEndpointUrl = "not-a-url"
        )
        assertFalse(invalidEndpointState.canRun)

        val blankModelState = DemoUiState(
            executionMode = DemoExecutionMode.Cloud,
            cloudEndpointUrl = DemoDefaults.defaultCloudEndpointUrl,
            cloudModel = ""
        )
        assertFalse(blankModelState.canRun)

        val validCloudState = DemoUiState(
            executionMode = DemoExecutionMode.Cloud,
            cloudEndpointUrl = DemoDefaults.defaultCloudEndpointUrl,
            cloudModel = DemoDefaults.defaultCloudModel
        )
        assertTrue(validCloudState.canRun)
    }

    @Test
    fun onDeviceMode_allowsRunWithoutCloudConfiguration() {
        val state = DemoUiState(
            executionMode = DemoExecutionMode.OnDevice,
            cloudEndpointUrl = "",
            cloudModel = ""
        )

        assertTrue(state.canRun)
    }
}
