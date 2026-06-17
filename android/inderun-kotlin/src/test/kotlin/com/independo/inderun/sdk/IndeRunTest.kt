package com.independo.inderun.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class IndeRunTest {
    @Test
    fun initialize_exposesHostServices() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val indeRun = IndeRun.initialize(context)

        assertTrue(indeRun.clock.elapsedRealtimeMillis() >= 0)
        assertTrue(indeRun.connectivity.isOnline() || !indeRun.connectivity.isOnline())
    }
}
