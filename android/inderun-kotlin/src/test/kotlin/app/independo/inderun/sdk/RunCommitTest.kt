package app.independo.inderun.sdk

import app.independo.inderun.contracts.ArtifactLifetime
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.CancelSemantics
import app.independo.inderun.contracts.ExecutionProvenanceAttempt
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.PlaybackOutput
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderDynamicCapabilities
import app.independo.inderun.contracts.ProviderSupports
import app.independo.inderun.contracts.ProviderTaskCapability
import app.independo.inderun.contracts.ProviderTaskInteraction
import app.independo.inderun.contracts.ProviderTaskOutput
import app.independo.inderun.contracts.ProviderTransport
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskInputKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.createUnavailable
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Mode 1 (`run()`) half of the explicit commit rule (#245). The stream half is in the shared
 * conformance catalog. A text run never commits, so its fallback is exactly as before; a
 * playback run that committed owns its failure. Mirrors the Web SDK's `engine.outputs.test.ts`.
 */
@RunWith(RobolectricTestRunner::class)
class RunCommitTest {
    private class Outcome(val result: TaskResult?, val error: IndeRunException?, val calls: List<String>)

    private suspend fun runWith(
        providers: List<Pair<String, suspend (RunContext) -> TaskOutput>>,
        request: TaskRequest = speechConformanceRequest(),
        outputs: List<ProviderTaskOutput> = listOf(ProviderTaskOutput(delivery = OutputDelivery.Playback)),
    ): Outcome {
        val calls = mutableListOf<String>()
        val registry = ProviderRegistry().apply {
            providers.forEach { (id, behaviour) -> register(SpeechProvider(id, behaviour, calls, outputs)) }
        }
        return try {
            Outcome(IndeRun(registry, conformanceHostServices()).run(request), null, calls)
        } catch (error: IndeRunException) {
            Outcome(null, error, calls)
        }
    }

    @Test
    fun returnsACommittedPlaybackResultWithItsProvenance() = runTest {
        val outcome = runWith(listOf("p1" to played))

        assertEquals(TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput(durationMs = 900.0)), outcome.result?.output)
        assertEquals(
            listOf(ExecutionProvenanceAttempt(committed = true, outcome = AttemptOutcome.Succeeded, providerId = "p1")),
            outcome.result?.provenance?.attempts,
        )
    }

    @Test
    fun fallsBackWhenPlaybackFailsBeforeCommit() = runTest {
        val outcome = runWith(listOf("p1" to { throw createUnavailable("no audio session") }, "p2" to played))

        assertEquals(listOf("p1", "p2"), outcome.calls)
        assertEquals(
            listOf(
                ExecutionProvenanceAttempt(errorClass = IndeRunErrorClass.Unavailable, outcome = AttemptOutcome.Failed, providerId = "p1"),
                ExecutionProvenanceAttempt(committed = true, outcome = AttemptOutcome.Succeeded, providerId = "p2"),
            ),
            outcome.result?.provenance?.attempts,
        )
    }

    @Test
    fun neverFallsBackOncePlaybackCommittedAndAttributesTheFailure() = runTest {
        val outcome = runWith(
            listOf(
                "p1" to { context ->
                    context.commit()
                    throw createUnavailable("audio device lost")
                },
                "p2" to played,
            ),
        )

        assertEquals(listOf("p1"), outcome.calls)
        val error = checkNotNull(outcome.error)
        assertEquals(IndeRunErrorClass.Unavailable, error.errorClass)
        assertEquals("p1", error.provenance?.providerId)
        assertEquals(
            listOf(Triple("p1", AttemptOutcome.Failed, true)),
            error.provenance?.attempts?.map { Triple(it.providerId, it.outcome, it.committed) },
        )
    }

    @Test
    fun refusesACommitFromAnAttemptTheRunHasAlreadyLeft() = runTest {
        var keptCommit: (() -> Boolean)? = null
        var lateCommit: Boolean? = null
        val outcome = runWith(
            listOf(
                "p1" to { context ->
                    keptCommit = context::commit
                    throw createUnavailable("no audio session")
                },
                "p2" to { context ->
                    // p1's callback fires while p2 runs: p1 must not start audio now.
                    lateCommit = keptCommit?.invoke()
                    played(context)
                },
            ),
        )

        assertEquals(listOf("p1", "p2"), outcome.calls)
        assertEquals(false, lateCommit)
        assertEquals(
            listOf(AttemptOutcome.Failed to null, AttemptOutcome.Succeeded to true),
            outcome.result?.provenance?.attempts?.map { it.outcome to it.committed },
        )
    }

    @Test
    fun treatsAnOutputOfTheWrongKindAsAProviderFault() = runTest {
        val outcome = runWith(listOf("p1" to { TaskOutput(type = TaskOutputType.TEXT, text = "Hallo") }))

        val error = checkNotNull(outcome.error)
        assertEquals(IndeRunErrorClass.Internal, error.errorClass)
        assertEquals("output_mismatch", error.details?.get("code"))
    }

    @Test
    fun rejectsAnArtifactWhoseMediaTypeTheRequestDoesNotAccept() = runTest {
        val artifact = TaskOutput(
            type = TaskOutputType.ARTIFACT,
            artifact = MediaArtifact(
                id = "art_1",
                mediaType = "audio/mpeg",
                owner = ArtifactOwner.Engine,
                lifetime = ArtifactLifetime.UntilDisposed,
            ),
        )

        val outcome = runWith(
            providers = listOf("p1" to { artifact }),
            request = speechConformanceRequest(
                delivery = OutputDeliveryRequest(mode = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav")),
            ),
            outputs = listOf(ProviderTaskOutput(delivery = OutputDelivery.Artifact, mediaTypes = listOf("audio/wav", "audio/mpeg"))),
        )

        assertEquals("output_mismatch", checkNotNull(outcome.error).details?.get("code"))
    }

    private val played: suspend (RunContext) -> TaskOutput = { context ->
        context.commit()
        TaskOutput(type = TaskOutputType.PLAYBACK, playback = PlaybackOutput(durationMs = 900.0))
    }

    /** A run-only speech provider whose output comes from [behaviour], recording each call. */
    private class SpeechProvider(
        private val id: String,
        private val behaviour: suspend (RunContext) -> TaskOutput,
        private val calls: MutableList<String>,
        private val outputs: List<ProviderTaskOutput>,
    ) : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = id,
            type = ProviderType.Local,
            transport = ProviderTransport.SystemService,
            supports = ProviderSupports(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = CancelSemantics.Hard,
            tasks = listOf("text_to_speech"),
            taskCapabilities = listOf(
                ProviderTaskCapability(
                    kind = "text_to_speech",
                    inputs = listOf(TaskInputKind.Text),
                    interaction = ProviderTaskInteraction(run = true, stream = false),
                    cancel = CancelSemantics.Hard,
                    outputs = outputs,
                    locales = listOf("de-AT"),
                ),
            ),
        )

        override suspend fun capabilities(host: HostServices) = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
            calls += id
            return TaskResult(
                schemaVersion = SchemaVersion.V1_0,
                runId = context.runId,
                output = behaviour(context),
                finishReason = FinishReason.STOP,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
            )
        }
    }
}
