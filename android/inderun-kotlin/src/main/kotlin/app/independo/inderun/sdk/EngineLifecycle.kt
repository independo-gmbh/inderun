package app.independo.inderun.sdk

import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async

/**
 * What an engine has in flight, so `close()` can stop and await it (see `IndeRunApi.close`).
 *
 * A `run` holds one unit of work from entry until it returns. A `stream` or `prepare` holds one
 * while it routes, and its producer holds another from first collection until it has delivered its
 * terminal event, or, when a paused collector leaves no room after close, handed it to the flow to
 * emit once the collector drains (`EventOutlet` in `IndeRun.kt`). A stream nobody collects is cold, so it holds nothing: close does not wait for a
 * consumer, and a later collection registers against the closed engine, which cancels it at once so
 * it ends in its one cancelled terminal. Streams and prepares register a cancel hook while their
 * producer runs; runs register none, because Mode 1 has no cancel path and close adds none.
 */
internal class EngineLifecycle {
    private val lock = Any()
    private var closed = false
    private var busy = 0
    private var idle: CompletableDeferred<Unit>? = null
    private val cancels = LinkedHashMap<Int, (String) -> Unit>()
    private var nextCancelId = 0
    private var closing: Deferred<Unit>? = null

    // Owns the close sequence, so a cancelled caller of close() does not abandon it half-way.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Whether `close()` has begun. */
    val isClosed: Boolean get() = synchronized(lock) { closed }

    /** Starts one unit of work; false once the engine is closed, and the caller must then fail. */
    fun begin(): Boolean = synchronized(lock) {
        if (closed) return false
        busy += 1
        true
    }

    /** Starts a unit of work for an already admitted stream or prepare, whose producer may start after close began. */
    fun enter() {
        synchronized(lock) { busy += 1 }
    }

    /** Ends one unit of work started with [begin] or [enter]. */
    fun end() {
        val waiter = synchronized(lock) {
            busy -= 1
            if (busy == 0) idle.also { idle = null } else null
        }
        waiter?.complete(Unit)
    }

    /**
     * Registers a stream or prepare's cancel hook. If close already began, the hook fires at once,
     * so a stream collected after close ends in one cancelled terminal.
     */
    fun register(cancel: (String) -> Unit): Int {
        var id = -1
        val alreadyClosed = synchronized(lock) {
            if (!closed) {
                id = nextCancelId++
                cancels[id] = cancel
            }
            closed
        }
        if (alreadyClosed) cancel(CANCEL_REASON)
        return id
    }

    fun unregister(id: Int) {
        synchronized(lock) { cancels.remove(id) }
    }

    /**
     * Runs the close sequence once: the closed flag is set first, then streams and prepares are
     * cancelled, then the call waits for all work to end, then [afterIdle] runs. A second or
     * concurrent call awaits the first.
     */
    suspend fun close(afterIdle: () -> Unit) {
        val sequence = synchronized(lock) {
            closing ?: run {
                closed = true
                val hooks = cancels.values.toList()
                cancels.clear()
                scope.async {
                    // A throwing hook must not abort the sequence: the wait and the teardown still run.
                    hooks.forEach { hook -> runCatching { hook(CANCEL_REASON) } }
                    awaitIdle()
                    afterIdle()
                }.also { closing = it }
            }
        }
        sequence.await()
    }

    private suspend fun awaitIdle() {
        val waiter = synchronized(lock) {
            if (busy == 0) null else CompletableDeferred<Unit>().also { idle = it }
        }
        waiter?.await()
    }

    companion object {
        const val CLOSED_MESSAGE = "The engine is closed."
        const val CANCEL_REASON = "The engine was closed."

        fun closedError(runId: String? = null): IndeRunException = createUnavailable(
            message = CLOSED_MESSAGE,
            runId = runId,
            retryable = false,
            details = mapOf("code" to "engine_closed"),
        )
    }
}
