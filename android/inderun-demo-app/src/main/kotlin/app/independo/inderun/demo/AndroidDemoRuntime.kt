package app.independo.inderun.demo

import android.content.Context
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.Files
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.Generation
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.PrepareRequest
import app.independo.inderun.contracts.ProviderCapabilitySnapshot
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.HostServicesFactory
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.TelemetryService
import app.independo.inderun.providers.mlkit.AndroidMlKitGenAiProvider
import app.independo.inderun.providers.onnx.AndroidOnnxRuntimeProvider
import app.independo.inderun.providers.onnx.createFixtureOnnxRuntime
import app.independo.inderun.providers.openai.OpenAIAuthMode
import app.independo.inderun.providers.openai.OpenAIProvider
import app.independo.inderun.providers.openai.OpenAIProviderOptions
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import app.independo.inderun.sdk.GenerateSpeechOptions
import app.independo.inderun.sdk.IndeRun
import app.independo.inderun.sdk.SpeakOptions
import app.independo.inderun.sdk.SpeechPlayback
import app.independo.inderun.sdk.SpeechVoiceInfo
import app.independo.inderun.sdk.generateSpeech
import app.independo.inderun.sdk.listVoices
import app.independo.inderun.sdk.prepare
import app.independo.inderun.sdk.speak
import kotlinx.coroutines.CoroutineScope
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Registered providers this demo drives IndeRun's capability-based routing across: Android ML Kit
 * GenAI on-device, an ONNX Runtime local provider, and an OpenAI-compatible cloud endpoint. Routing
 * is automatic -- IndeRun picks among these per the selected [PrivacyPreference] and each
 * provider's reported capabilities, not a manual per-provider toggle.
 */
internal interface DemoRuntime {
    suspend fun checkCapabilities(settings: DemoSettings): List<ProviderCapabilitySnapshot>
    suspend fun run(prompt: String, privacy: PrivacyPreference, settings: DemoSettings): DemoExecutionOutcome
    suspend fun stream(prompt: String, privacy: PrivacyPreference, settings: DemoSettings): DemoStreamStart
    suspend fun listVoices(locale: String, settings: DemoSettings): List<SpeechVoiceInfo>
    suspend fun prepareSpeech(request: PrepareRequest, settings: DemoSettings, scope: CoroutineScope)
    suspend fun speak(options: SpeakOptions, settings: DemoSettings, scope: CoroutineScope): SpeechPlayback
    suspend fun synthesizeSpeech(options: SpeakOptions, settings: DemoSettings): String
    fun lastRouteDecision(): RouteDecision?
}

internal class AndroidDemoRuntime(
    private val context: Context,
    private val onnxDownloader: DemoOnnxDownloader,
    private val hostServices: HostServices = HostServicesFactory.create(context.applicationContext),
) : DemoRuntime {
    private val telemetryService = DemoTelemetryService()
    private val speechProvider = AndroidSystemSpeechProvider(context)

    override suspend fun listVoices(locale: String, settings: DemoSettings): List<SpeechVoiceInfo> = makeIndeRun(settings).listVoices(locale)

    override suspend fun prepareSpeech(request: PrepareRequest, settings: DemoSettings, scope: CoroutineScope) {
        makeIndeRun(settings).prepare(scope, request).result.await()
    }

    override suspend fun speak(options: SpeakOptions, settings: DemoSettings, scope: CoroutineScope): SpeechPlayback = makeIndeRun(settings).speak(options, scope)

    override suspend fun synthesizeSpeech(options: SpeakOptions, settings: DemoSettings): String {
        val inderun = makeIndeRun(settings)
        val started = System.nanoTime()
        val speech = inderun.generateSpeech(GenerateSpeechOptions(options))
        val renderedMs = (System.nanoTime() - started) / 1_000_000
        val first = inderun.readArtifact(ArtifactReadRequest(artifactId = speech.artifact.id))
        val header = first.bytes.copyOf(4).decodeToString()
        inderun.disposeArtifact(speech.artifact)
        return "${speech.artifact.mediaType} · $header · ${first.totalBytes} bytes · ${speech.artifact.durationMs} ms · " +
            "rendered in $renderedMs ms · ${speech.provenance?.locality?.rawValue}"
    }

    override suspend fun checkCapabilities(settings: DemoSettings): List<ProviderCapabilitySnapshot> = makeIndeRun(settings).checkCapabilities()

    override suspend fun run(prompt: String, privacy: PrivacyPreference, settings: DemoSettings): DemoExecutionOutcome {
        val request = makeRequest(prompt, privacy)

        return try {
            val result = makeIndeRun(settings).run(request)
            DemoExecutionOutcome.Success(
                outputText = result.output.text.orEmpty(),
                metadata = AttemptMetadata(
                    runId = result.runId,
                    providerUsed = result.telemetry.providerUsed,
                    totalMs = result.telemetry.totalMs,
                    providerId = result.telemetry.providerUsed,
                    retryAfterMs = null,
                ),
            )
        } catch (error: IndeRunException) {
            DemoExecutionOutcome.Failure(
                DemoErrorState(
                    title = "Normalized Error",
                    body = "${error.errorClass.rawValue}\n\n${error.message}",
                    metadata = AttemptMetadata(
                        runId = error.runId ?: "n/a",
                        providerUsed = error.providerId ?: "n/a",
                        totalMs = error.details?.get("totalMs").toDoubleOrNull(),
                        providerId = error.providerId,
                        retryAfterMs = error.retryAfterMs,
                    ),
                ),
            )
        } catch (error: Throwable) {
            DemoExecutionOutcome.Failure(
                DemoErrorState(
                    title = "Unexpected Error",
                    body = error.localizedMessage ?: error.toString(),
                    metadata = null,
                ),
            )
        }
    }

    /**
     * Starts a Mode 2 stream, or reports the routing refusal that stopped it from
     * starting. Only the refusal is handled here -- a failure once the stream is
     * running arrives as a terminal `error` event, which the caller renders from
     * the event sequence like any other outcome.
     */
    override suspend fun stream(prompt: String, privacy: PrivacyPreference, settings: DemoSettings): DemoStreamStart = try {
        DemoStreamStart.Started(makeIndeRun(settings).stream(makeRequest(prompt, privacy)))
    } catch (error: IndeRunException) {
        DemoStreamStart.Refused(
            DemoErrorState(
                title = "Normalized Error",
                body = "${error.errorClass.rawValue}\n\n${error.message}",
                metadata = AttemptMetadata(
                    runId = error.runId ?: "n/a",
                    providerUsed = error.providerId ?: "n/a",
                    totalMs = error.details?.get("totalMs").toDoubleOrNull(),
                    providerId = error.providerId,
                    retryAfterMs = error.retryAfterMs,
                ),
            ),
        )
    } catch (error: Throwable) {
        DemoStreamStart.Refused(
            DemoErrorState(
                title = "Unexpected Error",
                body = error.localizedMessage ?: error.toString(),
                metadata = null,
            ),
        )
    }

    override fun lastRouteDecision(): RouteDecision? = telemetryService.lastRouteDecision()

    private fun makeRequest(prompt: String, privacy: PrivacyPreference) = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = prompt,
        task = TaskRequestTask(),
        // SystemAndroidOnnxGenAiRuntime recomputes the full sequence on every decode step (no
        // KV-cache reuse -- see docs/architecture/onnx-runtime-provider-family.md and
        // https://github.com/independo-gmbh/inderun/issues/126), so the default 256-token
        // budget is heavy enough to risk memory pressure on-device. Cap it low for this demo.
        generation = Generation(maxOutputTokens = 32),
        constraints = privacy.constraints,
    )

    private fun makeIndeRun(settings: DemoSettings): IndeRun {
        val registry = ProviderRegistry()
        registry.register(AndroidMlKitGenAiProvider())
        registry.register(speechProvider)
        registry.register(makeOnnxProvider(settings.onnxModelSelection))
        registry.register(
            OpenAIProvider(
                OpenAIProviderOptions(
                    id = "openai_compatible_cloud",
                    model = settings.model.trim(),
                    endpointUrl = settings.endpointUrl.trim(),
                    auth = OpenAIAuthMode.none,
                ),
            ),
        )
        return IndeRun(registry, hostServices, telemetryService)
    }

    private fun makeOnnxProvider(selection: DemoOnnxModelSelection): AndroidOnnxRuntimeProvider {
        val model = selection.modelOption
        if (model != null && onnxDownloader.isDownloaded(model)) {
            val modelPackage = ModelPackage(
                files = Files(
                    required = listOf("model.onnx"),
                    tokenizer = "tokenizer.json",
                    config = "config.json",
                ),
                format = Format.Onnx,
                id = model.id,
                source = Source(ref = onnxDownloader.relativeRef(model), sourceType = SourceType.AppManaged),
                tasks = listOf("text_to_text"),
            )
            // No runtime override: defaults to SystemAndroidOnnxGenAiRuntime(context), real ONNX
            // Runtime inference.
            return AndroidOnnxRuntimeProvider(context = context, modelPackage = modelPackage, id = AndroidOnnxRuntimeProvider.DEFAULT_ID)
        }

        // Fixture (either selected explicitly, or the real model hasn't finished downloading yet)
        // -- it echoes the prompt, it does not generate text -- so the demo still works out of the
        // box while a real model downloads in the background.
        val fixturePackage = ModelPackage(
            format = Format.Onnx,
            id = "demo-fixture-model",
            source = Source(sourceType = SourceType.Programmatic),
            tasks = listOf("text_to_text"),
        )
        return AndroidOnnxRuntimeProvider(
            modelPackage = fixturePackage,
            runtime = createFixtureOnnxRuntime(),
            id = AndroidOnnxRuntimeProvider.DEFAULT_ID,
        )
    }
}

/**
 * Captures the last `route_decided` telemetry event so the UI can show a routing transparency
 * panel, mirroring the web demo's `RouteDecisionTelemetryService` and the iOS demo's
 * `DemoTelemetryService`.
 */
internal class DemoTelemetryService : TelemetryService {
    private val lock = ReentrantLock()
    private var lastEvent: TelemetryEvent? = null

    override fun emit(event: TelemetryEvent) {
        if (event.type != TelemetryEventType.RouteDecided) return
        lock.withLock { lastEvent = event }
    }

    fun lastRouteDecision(): RouteDecision? {
        val event = lock.withLock { lastEvent } ?: return null
        return RouteDecision(
            selectedProviderId = event.payload["selectedProviderId"] as? String,
            explanation = event.payload["explanation"] as? String ?: "",
            rejectedProviderIds = (event.payload["rejectedProviderIds"] as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
            fallbackProviderIds = (event.payload["fallbackProviderIds"] as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
        )
    }
}

private fun Any?.toDoubleOrNull(): Double? = when (this) {
    is Double -> this
    is Float -> toDouble()
    is Int -> toDouble()
    is Long -> toDouble()
    is String -> toDoubleOrNull()
    else -> null
}
