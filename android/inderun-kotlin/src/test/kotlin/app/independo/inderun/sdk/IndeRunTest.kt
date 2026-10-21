package app.independo.inderun.sdk

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import app.independo.inderun.contracts.TelemetryEvent
import app.independo.inderun.contracts.TelemetryEventType
import app.independo.inderun.core.ClockService
import app.independo.inderun.core.ConnectivityService
import app.independo.inderun.core.HostServices
import app.independo.inderun.core.IndeRunException
import app.independo.inderun.core.ModelProfiles
import app.independo.inderun.core.ProviderAdapter
import app.independo.inderun.core.ProviderDescriptor
import app.independo.inderun.core.ProviderDynamicCapabilities
import app.independo.inderun.core.ProviderRegistry
import app.independo.inderun.core.RunContext
import app.independo.inderun.core.SecureStorageService
import app.independo.inderun.core.TelemetryService
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class IndeRunTest {
    @Test
    fun emitsTelemetryEventsThroughInjectedSink() = runTest {
        val events = mutableListOf<TelemetryEvent>()
        val telemetry = object : TelemetryService {
            override fun emit(event: TelemetryEvent) {
                events += event
            }
        }
        val hostServices = HostServices(
            connectivity = object : ConnectivityService {
                override fun isOnline(): Boolean = false
            },
            secureStorage = object : SecureStorageService {
                override fun get(authContextRef: String): String? = null
                override fun put(authContextRef: String, value: String) = Unit
                override fun remove(authContextRef: String) = Unit
            },
            clock = object : ClockService {
                override fun elapsedRealtimeMillis(): Long = 0L
            },
        )
        val registry = ProviderRegistry().apply {
            register(FakeProvider())
        }
        val indeRun = IndeRun(registry, hostServices, telemetry)

        indeRun.run(
            TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            ),
        )

        assertTrue(events.any { it.type == TelemetryEventType.RouteDecided })
        assertTrue(events.any { it.type == TelemetryEventType.AttemptSucceeded })
    }

    @Test
    fun runRoutesThroughRegisteredProvider() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val registry = ProviderRegistry().apply {
            register(FakeProvider())
        }
        val indeRun = IndeRun.initialize(context, registry)

        val result = indeRun.run(
            TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            ),
        )

        assertEquals("sdk-provider", result.telemetry.providerUsed)
        assertEquals(FinishReason.STOP, result.finishReason)
        assertEquals("Hello from sdk provider", result.output.text)
    }

    @Test
    fun checkCapabilitiesReturnsSnapshotsWithoutExecutingRun() = runTest {
        val hostServices = HostServices(
            connectivity = object : ConnectivityService {
                override fun isOnline(): Boolean = true
            },
            secureStorage = object : SecureStorageService {
                override fun get(authContextRef: String): String? = null
                override fun put(authContextRef: String, value: String) = Unit
                override fun remove(authContextRef: String) = Unit
            },
            clock = object : ClockService {
                override fun elapsedRealtimeMillis(): Long = 0L
            },
        )
        val unavailable = object : ProviderAdapter {
            override fun describe(): ProviderDescriptor = ProviderDescriptor(
                id = "unavailable-provider",
                type = ProviderDescriptor.ProviderType.cloud,
                transport = ProviderDescriptor.TransportType.http,
                supports = ProviderDescriptor.SupportsCapabilities(
                    run = true,
                    streaming = false,
                    realtime = false,
                    tools = false,
                    reasoningEvents = false,
                    structuredOutput = false,
                    multimodal = false,
                ),
                cancel = ProviderDescriptor.CancelSemantics.none,
                tasks = listOf("text_to_text"),
            )

            override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = false, reason = "not configured")

            override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = error("run() should not be called by checkCapabilities()")
        }
        val registry = ProviderRegistry().apply {
            register(FakeProvider())
            register(unavailable)
        }
        val indeRun = IndeRun(registry, hostServices)

        val snapshots = indeRun.checkCapabilities()

        assertEquals(2, snapshots.size)
        assertEquals("sdk-provider", snapshots[0].providerId)
        assertEquals(true, snapshots[0].capabilities.available)
        assertEquals("unavailable-provider", snapshots[1].providerId)
        assertEquals(false, snapshots[1].capabilities.available)
        assertEquals("not configured", snapshots[1].capabilities.reason)
    }

    private fun profileHostServices() = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis(): Long = 0L
        },
    )

    private fun profileEngine(
        profiles: Map<String, List<String>>,
        telemetry: TelemetryService? = null,
    ): IndeRun {
        val registry = ProviderRegistry().apply {
            register(NamedProvider("local_a", ProviderDescriptor.ProviderType.local))
            register(NamedProvider("cloud_a", ProviderDescriptor.ProviderType.cloud))
            register(NamedProvider("cloud_b", ProviderDescriptor.ProviderType.cloud))
        }
        return IndeRun(registry, profileHostServices(), telemetry, ModelProfiles(profiles))
    }

    private fun profileRequest(modelProfile: String? = null) = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Hello",
        task = TaskRequestTask(),
        modelProfile = modelProfile,
    )

    @Test
    fun requestWithoutModelProfileRoutesAcrossEveryTarget() = runTest {
        val result = profileEngine(mapOf("smart" to listOf("cloud_b"))).run(profileRequest())

        assertEquals("local_a", result.telemetry.providerUsed)
    }

    @Test
    fun autoModelProfileBehavesLikeAnAbsentOne() = runTest {
        val result = profileEngine(mapOf("smart" to listOf("cloud_b"))).run(profileRequest("auto"))

        assertEquals("local_a", result.telemetry.providerUsed)
    }

    @Test
    fun namedModelProfileRoutesOnlyWithinTheProfileInProfileOrder() = runTest {
        val events = mutableListOf<TelemetryEvent>()
        val telemetry = object : TelemetryService {
            override fun emit(event: TelemetryEvent) {
                events += event
            }
        }
        val engine = profileEngine(mapOf("smart" to listOf("cloud_b", "cloud_a")), telemetry)

        val result = engine.run(profileRequest("smart"))

        assertEquals("cloud_b", result.telemetry.providerUsed)
        val routeDecided = events.first { it.type == TelemetryEventType.RouteDecided }
        assertEquals("smart", routeDecided.payload["modelProfile"])
        assertEquals(listOf("cloud_a"), routeDecided.payload["fallbackProviderIds"])
        assertEquals(listOf("local_a"), routeDecided.payload["rejectedProviderIds"])
    }

    @Test
    fun unknownModelProfileIsAValidationFailureInRunAndStream() = runTest {
        val engine = profileEngine(mapOf("smart" to listOf("cloud_b")))

        val runError = runCatching { engine.run(profileRequest("fast")) }.exceptionOrNull()
        assertTrue(runError is IndeRunException)
        assertEquals(IndeRunErrorClass.Internal, (runError as IndeRunException).errorClass)
        assertTrue(runError.message.contains("modelProfile"))

        val streamError = runCatching { engine.stream(profileRequest("fast")) }.exceptionOrNull()
        assertTrue(streamError is IndeRunException)
        assertTrue((streamError as IndeRunException).message.contains("modelProfile"))
    }

    @Test
    fun malformedModelProfilesAreRefusedAtConfiguration() {
        listOf(
            mapOf("auto" to listOf("cloud_a")),
            mapOf("smart" to emptyList()),
            mapOf("smart" to listOf("cloud_a", "cloud_a")),
        ).forEach { profiles ->
            assertTrue(runCatching { ModelProfiles(profiles) }.exceptionOrNull() is IllegalArgumentException)
        }
    }

    private class NamedProvider(
        private val id: String,
        private val type: ProviderDescriptor.ProviderType,
    ) : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = id,
            type = type,
            transport = ProviderDescriptor.TransportType.in_process,
            supports = ProviderDescriptor.SupportsCapabilities(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = ProviderDescriptor.CancelSemantics.soft,
            tasks = listOf("text_to_text"),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = Output(text = "Hello from $id"),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }

    private class FakeProvider : ProviderAdapter {
        override fun describe(): ProviderDescriptor = ProviderDescriptor(
            id = "sdk-provider",
            type = ProviderDescriptor.ProviderType.local,
            transport = ProviderDescriptor.TransportType.in_process,
            supports = ProviderDescriptor.SupportsCapabilities(
                run = true,
                streaming = false,
                realtime = false,
                tools = false,
                reasoningEvents = false,
                structuredOutput = false,
                multimodal = false,
            ),
            cancel = ProviderDescriptor.CancelSemantics.soft,
            tasks = listOf("text_to_text"),
        )

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = true)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = Output(text = "Hello from sdk provider"),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = "sdk-provider", totalMs = 0.0),
        )
    }
}
