package app.independo.inderun.core

import android.os.SystemClock

/**
 * Implementation of [ClockService] using Android's monotonic elapsed realtime clock.
 */
class ClockServiceImpl : ClockService {
    /**
     * {@inheritDoc}
     */
    override fun elapsedRealtimeMillis(): Long {
        return SystemClock.elapsedRealtime()
    }
}
