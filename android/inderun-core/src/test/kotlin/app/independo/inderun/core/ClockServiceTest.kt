package app.independo.inderun.core

import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ClockServiceTest {
    @Test
    fun elapsedRealtimeMillis_isMonotonic() {
        val clock = ClockServiceImpl()
        val now = clock.elapsedRealtimeMillis()
        val later = clock.elapsedRealtimeMillis()

        assertTrue(now >= 0)
        assertTrue(later >= now)
    }
}
