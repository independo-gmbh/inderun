package app.independo.inderun.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoCloudEndpointTest {
    @Test
    fun createProbeUrl_rewritesDemoProxyRouteToHealth() {
        assertEquals(
            "http://10.0.2.2:8787/health",
            createProbeUrl("http://10.0.2.2:8787/api/inderun/openai-responses"),
        )
    }

    @Test
    fun unavailableCloudMessage_mentionsLocalProxyForEmulatorDefault() {
        val message = unavailableCloudMessage("http://10.0.2.2:8787/api/inderun/openai-responses")

        assertTrue(message.contains("@independo/inderun-demo-proxy"))
        assertTrue(message.contains("pnpm --filter @independo/inderun-demo-proxy dev"))
    }
}
