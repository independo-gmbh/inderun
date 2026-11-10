package app.independo.inderun.providers.onnx

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch

/**
 * The cache behind [LoadedSessionBox]: what it drops is released once, and only after the callers
 * using it have returned, so `close()` never pulls a session out from under a generation.
 */
class LeasedCacheTest {
    private class Loads {
        var count = 0
        val released = mutableListOf<String>()

        fun cache() = LeasedCache<String> { released += it }

        suspend fun load(value: String): String {
            count += 1
            return value
        }
    }

    @Test
    fun theSameKeyLoadsOnce() = runTest {
        val loads = Loads()
        val cache = loads.cache()

        cache.use("a", { loads.load("A1") }) {}
        val value = cache.use("a", { loads.load("A2") }) { it }

        assertEquals("A1", value)
        assertEquals(1, loads.count)
        assertEquals(emptyList<String>(), loads.released)
    }

    @Test
    fun closeReleasesAnIdleValueOnceAndTheNextUseLoadsAgain() = runTest {
        val loads = Loads()
        val cache = loads.cache()
        cache.use("a", { loads.load("A1") }) {}

        cache.close()
        cache.close()

        assertEquals(listOf("A1"), loads.released)
        assertEquals("A2", cache.use("a", { loads.load("A2") }) { it })
        assertEquals(2, loads.count)
    }

    @Test
    fun closeDuringUseReleasesOnlyWhenTheUserReturns() = runTest {
        val loads = Loads()
        val cache = loads.cache()
        val inUse = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()

        val user = async {
            cache.use("a", { loads.load("A1") }) {
                inUse.complete(Unit)
                finish.await()
            }
        }
        inUse.await()
        cache.close()
        assertEquals(emptyList<String>(), loads.released)

        finish.complete(Unit)
        user.await()
        assertEquals(listOf("A1"), loads.released)
    }

    @Test
    fun aNewKeyEvictsTheOldValueAfterItsUserReturns() = runTest {
        val loads = Loads()
        val cache = loads.cache()
        val inUse = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()

        val user = async {
            cache.use("a", { loads.load("A1") }) {
                inUse.complete(Unit)
                finish.await()
            }
        }
        inUse.await()
        cache.use("b", { loads.load("B1") }) {}
        assertEquals(emptyList<String>(), loads.released)

        finish.complete(Unit)
        user.await()
        assertEquals(listOf("A1"), loads.released)
        cache.close()
        assertEquals(listOf("A1", "B1"), loads.released)
    }

    @Test
    fun aLoadRunningAtCloseIsNotCachedAndIsReleasedAfterItsCaller() = runTest {
        val loads = Loads()
        val cache = loads.cache()
        val loading = CompletableDeferred<Unit>()
        val loaded = CompletableDeferred<Unit>()

        val user = async {
            cache.use("a", {
                loading.complete(Unit)
                loaded.await()
                loads.load("A1")
            }) { it }
        }
        loading.await()
        cache.close()
        loaded.complete(Unit)

        assertEquals("A1", user.await())
        assertEquals(listOf("A1"), loads.released)
        assertEquals("A2", cache.use("a", { loads.load("A2") }) { it })
    }

    @Test
    fun aCallerCancelledDuringALoadDoesNotLeakTheLoadedValue() = runTest {
        val loads = Loads()
        val cache = loads.cache()
        val started = CompletableDeferred<Unit>()
        val gate = CountDownLatch(1)

        // Blocking work on another thread, as an ORT session load is: it runs to the end even after
        // its caller is cancelled.
        val user = async {
            cache.use("a", {
                withContext(Dispatchers.IO) {
                    started.complete(Unit)
                    gate.await()
                    loads.load("A1")
                }
            }) { it }
        }
        started.await()
        user.cancel()
        gate.countDown()
        try {
            user.await()
            fail("Expected the cancelled caller to see its cancellation.")
        } catch (_: CancellationException) {
        }

        // The loaded value is the cache's, not lost: a later use reuses it and close releases it.
        assertEquals("A1", cache.use("a", { loads.load("A2") }) { it })
        assertEquals(1, loads.count)
        cache.close()
        assertEquals(listOf("A1"), loads.released)
    }
}
