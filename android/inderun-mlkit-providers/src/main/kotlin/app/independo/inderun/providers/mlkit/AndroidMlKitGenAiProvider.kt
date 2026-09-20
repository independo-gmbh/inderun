package app.independo.inderun.providers.mlkit

import android.content.Context
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.ProviderStreamContext
import app.independo.inderun.core.ProviderStreamEvent
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.StreamingProviderAdapter
import app.independo.inderun.core.createCapabilityMismatch
import app.independo.inderun.core.createInternal
import app.independo.inderun.core.createRateLimited
import app.independo.inderun.core.createUnavailable
import app.independo.inderun.core.toIndeRunException
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Candidate
import com.google.mlkit.genai.prompt.GenerateContentResponse
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.takeWhile

sealed interface AndroidMlKitGenAiAvailability {
    data object Available : AndroidMlKitGenAiAvailability
    data class Downloadable(val reason: String) : AndroidMlKitGenAiAvailability
    data class Downloading(val reason: String) : AndroidMlKitGenAiAvailability
    data class Unavailable(val reason: String) : AndroidMlKitGenAiAvailability
}

data class AndroidMlKitGenAiGenerationOptions(
    val maxOutputTokens: Long? = null,
    val temperature: Double? = null,
    val seed: Long? = null,
)

/**
 * Why generation stopped, as reported by ML Kit.
 *
 * Modelled in repository terms rather than as ML Kit's raw `Int` so the runtime
 * seam stays free of `com.google.mlkit` types — the same reason
 * [AndroidMlKitGenAiAvailability] exists instead of a bare `FeatureStatus`. The
 * magic-int decode lives next to the SDK call in `SystemAndroidMlKitGenAiRuntime`
 * and nowhere else.
 */
enum class AndroidMlKitGenAiFinishReason {
    STOP,
    MAX_TOKENS,
    OTHER,
}

/**
 * One piece of generated text plus the completion reason ML Kit attached to it.
 *
 * The same type carries a whole Mode 1 response and a single Mode 2 chunk, so the
 * two modes cannot end up reporting completion differently. In a stream, [text]
 * is the **increment** since the previous chunk, not the text so far, and
 * [finishReason] is null on every chunk that does not carry one.
 */
data class AndroidMlKitGenAiOutput(
    val text: String,
    val finishReason: AndroidMlKitGenAiFinishReason? = null,
)

/**
 * Injectable seam over the ML Kit GenAI runtime.
 *
 * Everything that touches `com.google.mlkit` sits behind this interface, so the
 * adapter's contract — descriptor, capability gate, event shape, error taxonomy,
 * cancellation — is testable on a plain JVM without an AICore device.
 */
interface AndroidMlKitGenAiRuntime {
    suspend fun availability(): AndroidMlKitGenAiAvailability

    suspend fun generateText(prompt: String, options: AndroidMlKitGenAiGenerationOptions): AndroidMlKitGenAiOutput

    /**
     * Streams the response as incremental text.
     *
     * Deliberately has no default implementation: silently inheriting a stub
     * would let an implementation declare streaming without providing it, which
     * is a routing-visible mistake rather than a harmless one.
     */
    fun generateTextStream(prompt: String, options: AndroidMlKitGenAiGenerationOptions): Flow<AndroidMlKitGenAiOutput>
}

/**
 * On-device text-to-text provider backed by ML Kit GenAI (Gemini Nano), supporting
 * both Mode 1 (`run`) and Mode 2 (`stream`).
 */
class AndroidMlKitGenAiProvider(
    private val id: String,
    private val runtime: AndroidMlKitGenAiRuntime,
) : StreamingProviderAdapter {

    constructor(id: String = DEFAULT_ID) : this(
        id = id,
        runtime = SystemAndroidMlKitGenAiRuntime(),
    )

    override fun describe(): ProviderDescriptor = ProviderDescriptor(
        id = id,
        type = ProviderDescriptor.ProviderType.local,
        transport = ProviderDescriptor.TransportType.system_service,
        // `chunks`, not `tokens`: ML Kit hands back incremental text without
        // documenting a token boundary, so claiming `tokens` would assert
        // something the SDK does not.
        streamingStyle = ProviderDescriptor.StreamingStyle.chunks,
        supports = ProviderDescriptor.SupportsCapabilities(
            run = true,
            streaming = true,
            realtime = false,
            tools = false,
            reasoningEvents = false,
            structuredOutput = false,
            multimodal = false,
        ),
        // ML Kit does not document that AICore stops generating when the caller
        // walks away, so the guarantee is `soft`: the adapter stops relaying, and
        // the engine's Event Gate is what makes the caller-visible promise.
        cancel = ProviderDescriptor.CancelSemantics.soft,
        tasks = listOf("text_to_text"),
        privacy = ProviderDescriptor.PrivacyDescriptor(dataLeavesDevice = false),
    )

    /**
     * Host services are accepted to satisfy the provider contract; this provider
     * relies only on ML Kit's own feature status.
     *
     * `streamingAvailable` is deliberately left unset so the static
     * `supports.streaming` declaration is inherited. Both modes sit behind the one
     * `checkStatus()` gate — unlike the HTTP-transport providers, no host service
     * can take streaming away on its own. A downloadable or downloading model is
     * reported as *provider*-unavailable with its specific reason; reporting it as
     * stream-unavailable instead would replace that reason with a generic
     * `streaming_unavailable` rejection and explain less.
     */
    override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = when (val availability = runtime.availability()) {
        AndroidMlKitGenAiAvailability.Available -> ProviderDynamicCapabilities(available = true)
        is AndroidMlKitGenAiAvailability.Downloadable -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
        is AndroidMlKitGenAiAvailability.Downloading -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
        is AndroidMlKitGenAiAvailability.Unavailable -> ProviderDynamicCapabilities(
            available = false,
            reason = availability.reason,
        )
    }

    override suspend fun run(request: TaskRequest, context: RunContext): TaskResult {
        availabilityMismatch(runtime.availability(), context.runId)?.let { throw it }
        return executeAvailableRequest(request, context)
    }

    /**
     * Executes a normalized Mode-2 text-to-text request on Gemini Nano.
     *
     * ML Kit's chunks are **incremental**, so each one is emitted as a
     * [ProviderStreamEvent.Delta] and the engine appends them into the run's
     * partial text. Nothing is diffed or re-accumulated here: treating the chunks
     * as cumulative would double-count, and diffing them would invent a boundary
     * ML Kit never reported.
     *
     * The finish reason is whichever one ML Kit reported last, across the whole
     * stream rather than only on the final chunk — a chunk may carry the reason
     * and no new text. When none ever arrives, completion is `stop`, matching what
     * Mode 1 reports for the same runtime.
     *
     * A policy rejection mid-stream is the one case where content already
     * delivered is taken back: an empty snapshot resets the run's cumulative text
     * before the failure is thrown, because ML Kit says the partial result should
     * not stay on screen. See [isPolicyRejection] and the `content_snapshot`
     * retraction clause in `contracts/schemas/stream-event.schema.json`.
     *
     * Cancellation is two-layer, because either layer alone leaves a gap. The
     * `takeWhile` guard stops the relay when the token flips while chunks are
     * still flowing; the engine cancelling the producing coroutine is what ends a
     * read already blocked waiting for the next chunk. Neither emits a terminal
     * event — the run ends by falling through, and the engine owns the `cancelled`
     * outcome.
     */
    override fun stream(
        request: TaskRequest,
        context: ProviderStreamContext,
    ): Flow<ProviderStreamEvent> = flow {
        // Re-checked here rather than at flow construction, for the same reason
        // `run` re-checks: a stale route decision must surface as
        // CapabilityMismatch instead of as a native ML Kit failure mid-stream.
        availabilityMismatch(runtime.availability(), context.runId)?.let { throw it }

        val accumulated = StringBuilder()
        var finishReason: AndroidMlKitGenAiFinishReason? = null
        try {
            runtime.generateTextStream(normalizedPrompt(request), generationOptions(request))
                .takeWhile { !context.cancellation.isCancelled }
                .collect { output ->
                    output.finishReason?.let { finishReason = it }
                    if (output.text.isNotEmpty()) {
                        accumulated.append(output.text)
                        emit(ProviderStreamEvent.Delta(output.text))
                    }
                }
        } catch (error: CancellationException) {
            // `emit` throws this when the engine cancels the producing coroutine,
            // which is the cancellation mechanism working. Rethrowing must come
            // before the general catch below, or a cancelled run would be
            // normalized into an `Internal` error terminal.
            throw error
        } catch (error: Throwable) {
            if (context.cancellation.isCancelled) return@flow
            if (accumulated.isNotEmpty() && isPolicyRejection(error)) {
                // ML Kit documents its response-side policy failures as able to
                // interrupt streaming with an incomplete result, and advises
                // removing that result from the UI. A snapshot replaces the run's
                // cumulative text instead of appending to it, so an empty one
                // retracts everything delivered so far: the error terminal then
                // carries no rejected content, and a consumer rendering content
                // events clears with it.
                emit(ProviderStreamEvent.Snapshot(""))
                accumulated.setLength(0)
            }
            throw normalizedFailure(error, context.runId)
        }

        if (context.cancellation.isCancelled) return@flow

        emit(
            ProviderStreamEvent.Done(
                finalText = accumulated.toString(),
                finishReason = canonicalFinishReason(finishReason),
            ),
        )
    }

    private suspend fun executeAvailableRequest(
        request: TaskRequest,
        context: RunContext,
    ): TaskResult {
        try {
            val startTime = context.hostServices.clock.elapsedRealtimeMillis()
            val output = runtime.generateText(
                prompt = normalizedPrompt(request),
                options = generationOptions(request),
            )
            val duration = context.hostServices.clock.elapsedRealtimeMillis() - startTime

            return TaskResult(
                finishReason = canonicalFinishReason(output.finishReason),
                output = Output(text = output.text),
                runId = context.runId,
                schemaVersion = SchemaVersion.V1_0,
                telemetry = TaskResultTelemetry(providerUsed = id, totalMs = duration.toDouble()),
            )
        } catch (error: CancellationException) {
            // Structured concurrency: a cancelled caller must stay cancelled rather
            // than be reported as a provider fault.
            throw error
        } catch (error: Throwable) {
            throw normalizedFailure(error, context.runId)
        }
    }

    /**
     * The capability failure for an availability state, or null when the model is
     * ready. Shared by `run` and `stream` so a model that is not ready produces
     * the identical error — message, class and `details` — in both modes.
     */
    private fun availabilityMismatch(
        availability: AndroidMlKitGenAiAvailability,
        runId: String,
    ): IndeRunException? = when (availability) {
        AndroidMlKitGenAiAvailability.Available -> null
        is AndroidMlKitGenAiAvailability.Downloadable -> createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is not ready: ${availability.reason}",
            runId = runId,
            providerId = id,
            details = mapOf("availability" to "downloadable"),
        )
        is AndroidMlKitGenAiAvailability.Downloading -> createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is not ready: ${availability.reason}",
            runId = runId,
            providerId = id,
            details = mapOf("availability" to "downloading"),
        )
        is AndroidMlKitGenAiAvailability.Unavailable -> createCapabilityMismatch(
            message = "Android ML Kit GenAI provider is unavailable: ${availability.reason}",
            runId = runId,
            providerId = id,
            details = mapOf("availability" to availability.reason),
        )
    }

    /**
     * Maps a runtime failure onto the error taxonomy. Shared by `run` and `stream`
     * so one ML Kit failure classifies identically in both modes.
     */
    private fun normalizedFailure(error: Throwable, runId: String): IndeRunException {
        if (error is IndeRunException) {
            return toIndeRunException(error, fallbackRunId = runId, fallbackProviderId = id)
        }

        if (error is GenAiException) {
            return fromGenAiException(error, runId)
        }

        return createInternal(
            message = "Android ML Kit GenAI execution failed.",
            runId = runId,
            providerId = id,
            details = mapOf("originalError" to (error.localizedMessage ?: error.toString())),
        )
    }

    /**
     * Classifies ML Kit's own error codes.
     *
     * Device, OS and storage conditions land on `CapabilityMismatch` — the same
     * class the availability gate uses, because they say the same thing: this
     * device cannot run the feature right now. Policy rejections land there too:
     * the taxonomy has no content-policy class, and "this provider cannot satisfy
     * this request" is what a refused prompt or refused response amounts to.
     * Codes that describe a temporary refusal to serve become `RateLimited` with
     * ML Kit's own retry delay when it gives one (it defaults to `Duration.ZERO`,
     * so a zero delay means "no delay reported" rather than "retry immediately").
     * Everything unclassified stays `Internal`.
     *
     * `Internal` deliberately does not catch the policy codes: the contract
     * defines it as an unexpected *engine-side* failure, and a documented
     * provider policy outcome is neither unexpected nor ours. `details` keeps
     * `mlKitErrorCode` so callers can still separate the causes.
     */
    private fun fromGenAiException(error: GenAiException, runId: String): IndeRunException {
        val message = error.localizedMessage ?: "Android ML Kit GenAI execution failed."
        val details = mapOf<String, Any?>("mlKitErrorCode" to error.errorCode)

        return when (error.errorCode) {
            GenAiException.ErrorCode.NOT_AVAILABLE,
            GenAiException.ErrorCode.NOT_SUPPORTED,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE,
            // The taxonomy has no invalid-request class; "this provider cannot
            // satisfy this request" is the honest fit for a size violation.
            GenAiException.ErrorCode.REQUEST_TOO_LARGE,
            GenAiException.ErrorCode.REQUEST_TOO_SMALL,
            // Policy rejections. ML Kit documents the two response-side codes as
            // able to interrupt streaming mid-output, which is why [stream]
            // retracts what it already delivered before throwing one of these.
            GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR,
            GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
            -> createCapabilityMismatch(
                message = message,
                runId = runId,
                providerId = id,
                details = details,
            )

            GenAiException.ErrorCode.BUSY,
            GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED,
            -> createRateLimited(
                message = message,
                runId = runId,
                providerId = id,
                retryable = true,
                retryAfterMs = error.retryDelay.toMillis().takeIf { it > 0L },
                details = details,
            )

            // Transient app-lifecycle state rather than a device gap or a quota.
            GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED,
            // Reached only when the runtime aborted on its own; a caller-driven
            // cancel never gets here, because the stream returns without a
            // terminal and the engine reports `cancelled`.
            GenAiException.ErrorCode.CANCELLED,
            -> createUnavailable(
                message = message,
                runId = runId,
                providerId = id,
                retryable = true,
                details = details,
            )

            else -> createInternal(
                message = message,
                runId = runId,
                providerId = id,
                details = details,
            )
        }
    }

    /**
     * Normalizes ML Kit's finish reason.
     *
     * `OTHER` is "all other reasons that stopped the generation" — anything but a
     * natural stop or the token limit — which is exactly the contract's `error`:
     * a provider reporting a non-fatal issue on an otherwise completed run.
     * Reporting `stop` for it would claim a natural end the runtime did not.
     *
     * The null branch is defensive rather than expected: ML Kit documents the
     * finish reason as non-null on the final response and null only on
     * intermediate streamed ones, so an absent reason means the stream ended
     * without a final response. `stop` keeps that reading as the completed run it
     * is, rather than inventing a degradation the runtime never reported.
     */
    private fun canonicalFinishReason(reason: AndroidMlKitGenAiFinishReason?): FinishReason = when (reason) {
        AndroidMlKitGenAiFinishReason.MAX_TOKENS -> FinishReason.LENGTH
        AndroidMlKitGenAiFinishReason.OTHER -> FinishReason.ERROR
        AndroidMlKitGenAiFinishReason.STOP, null -> FinishReason.STOP
    }

    /**
     * Whether a failure is ML Kit refusing on policy grounds rather than failing
     * mechanically. Drives both the error class and the content retraction in
     * [stream].
     */
    private fun isPolicyRejection(error: Throwable): Boolean = error is GenAiException && error.errorCode in POLICY_REJECTION_CODES

    private fun generationOptions(request: TaskRequest): AndroidMlKitGenAiGenerationOptions = AndroidMlKitGenAiGenerationOptions(
        maxOutputTokens = request.generation?.maxOutputTokens,
        temperature = request.generation?.temperature,
        seed = request.generation?.seed,
    )

    private fun normalizedPrompt(request: TaskRequest): String {
        val messages = request.messages
        if (!messages.isNullOrEmpty()) {
            return messages.joinToString(separator = "\n") { message ->
                "${message.role.rawValue}: ${message.content}"
            }
        }

        return request.prompt.orEmpty()
    }

    companion object {
        const val DEFAULT_ID = "android_mlkit_genai"

        /**
         * ML Kit's policy-check failures. The two response-side codes are the ones
         * Google documents as able to interrupt streaming with an incomplete
         * result, advising that the result be removed from the app's UI;
         * `REQUEST_PROCESSING_ERROR` refuses before generation starts, so it never
         * has delivered content to retract, and is listed here so "policy
         * rejection" means one thing throughout the adapter.
         */
        private val POLICY_REJECTION_CODES = setOf(
            GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR,
            GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
        )
    }
}

object AndroidProviderRegistryFactory {
    fun makeDefaultRegistry(context: Context): ProviderRegistry {
        val registry = ProviderRegistry()
        registry.register(
            AndroidMlKitGenAiProvider(
                id = AndroidMlKitGenAiProvider.DEFAULT_ID,
                runtime = SystemAndroidMlKitGenAiRuntime(context),
            ),
        )
        return registry
    }
}

private class SystemAndroidMlKitGenAiRuntime(
    @Suppress("UNUSED_PARAMETER") private val context: Context? = null,
) : AndroidMlKitGenAiRuntime {
    private val generativeModel = Generation.getClient()

    override suspend fun availability(): AndroidMlKitGenAiAvailability = try {
        when (generativeModel.checkStatus()) {
            FeatureStatus.AVAILABLE -> AndroidMlKitGenAiAvailability.Available
            FeatureStatus.DOWNLOADABLE -> AndroidMlKitGenAiAvailability.Downloadable(
                "Gemini Nano can be downloaded on this device, but is not currently installed.",
            )
            FeatureStatus.DOWNLOADING -> AndroidMlKitGenAiAvailability.Downloading(
                "Gemini Nano is currently downloading.",
            )
            FeatureStatus.UNAVAILABLE -> AndroidMlKitGenAiAvailability.Unavailable(
                "Gemini Nano is unsupported on this device or AICore is not ready.",
            )
            else -> AndroidMlKitGenAiAvailability.Unavailable(
                "ML Kit returned an unknown availability status.",
            )
        }
    } catch (error: CancellationException) {
        // checkStatus() is a suspending call, so the blanket catch below would
        // otherwise swallow the caller's cancellation into an Unavailable result.
        throw error
    } catch (error: Throwable) {
        AndroidMlKitGenAiAvailability.Unavailable(
            error.localizedMessage ?: "Failed to query ML Kit GenAI availability.",
        )
    }

    override suspend fun generateText(
        prompt: String,
        options: AndroidMlKitGenAiGenerationOptions,
    ): AndroidMlKitGenAiOutput = generativeModel
        .generateContent(buildRequest(prompt, options))
        .toOutput()

    /**
     * Relays `GenerativeModel.generateContentStream` chunk for chunk.
     *
     * ML Kit's chunks are incremental — its own sample concatenates them — so each
     * one is forwarded as-is. Cancelling the collector cancels this flow, which is
     * how the adapter stops generation.
     */
    override fun generateTextStream(
        prompt: String,
        options: AndroidMlKitGenAiGenerationOptions,
    ): Flow<AndroidMlKitGenAiOutput> = generativeModel
        .generateContentStream(buildRequest(prompt, options))
        .map { response -> response.toOutput() }

    private fun buildRequest(prompt: String, options: AndroidMlKitGenAiGenerationOptions) = generateContentRequest(TextPart(prompt)) {
        temperature = options.temperature?.toFloat()
        seed = options.seed?.toInt()
        maxOutputTokens = options.maxOutputTokens?.toInt()
    }

    private fun GenerateContentResponse.toOutput(): AndroidMlKitGenAiOutput {
        val candidate = candidates.firstOrNull()
        return AndroidMlKitGenAiOutput(
            text = candidate?.text.orEmpty(),
            finishReason = candidate?.finishReason?.toFinishReason(),
        )
    }

    /** The only place ML Kit's finish-reason ints are interpreted. */
    private fun Int.toFinishReason(): AndroidMlKitGenAiFinishReason = when (this) {
        Candidate.FinishReason.STOP -> AndroidMlKitGenAiFinishReason.STOP
        Candidate.FinishReason.MAX_TOKENS -> AndroidMlKitGenAiFinishReason.MAX_TOKENS
        else -> AndroidMlKitGenAiFinishReason.OTHER
    }
}
