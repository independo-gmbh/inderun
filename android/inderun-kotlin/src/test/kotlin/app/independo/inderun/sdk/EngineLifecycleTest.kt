package app.independo.inderun.sdk

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineLifecycleTest {
    @Test
    fun aThrowingCancelHookDoesNotBreakClose() = runBlocking {
        withTimeout(10_000) {
            val lifecycle = EngineLifecycle()
            var healthyHookRan = false
            lifecycle.register { throw IllegalStateException("hook failed") }
            lifecycle.register { healthyHookRan = true }
            var afterIdleRuns = 0

            lifecycle.close { afterIdleRuns += 1 }
            lifecycle.close { afterIdleRuns += 1 }

            assertTrue("a hook after the throwing one did not run", healthyHookRan)
            assertEquals("the teardown must run exactly once", 1, afterIdleRuns)
            assertTrue(lifecycle.isClosed)
        }
    }
}
