package app.independo.inderun.core

import app.independo.inderun.contracts.Candidate
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.Explanation
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.OptimizeFor
import app.independo.inderun.contracts.Output
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestPreferences
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.contracts.TaskResultTelemetry
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Runs under Robolectric because routing now goes through the shared Rust core,
 * and the planner input is serialized with `org.json` -- which is a stub in the
 * plain `android.jar` these unit tests otherwise compile against.
 */
@RunWith(RobolectricTestRunner::class)
class ProviderEngineTest {
    @Test
    fun registryRejectsDuplicateIds() {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a"))

        try {
            registry.register(FakeProvider("provider_a"))
        } catch (error: IllegalStateException) {
            assertTrue(error.message!!.contains("already registered"))
            return
        }

        throw AssertionError("Expected duplicate provider registration to fail.")
    }

    @Test
    fun routerSelectsAvailableLocalProviderDeterministically() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_b", available = true))
        registry.register(FakeProvider("provider_a", available = true))

        val selection = Router(registry).selectRoute(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            ),
            hostServices = fakeHostServices(),
        )

        assertEquals("provider_a", selection.provider.describe().id)
    }

    @Test
    fun routerUsesSharedPlannerSelectionWhenAvailable() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a", available = true))
        registry.register(FakeProvider("provider_b", available = true))

        val planner = object : RoutePlanner {
            override fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan = SharedPlannerRoutePlan(
                candidates = listOf(
                    Candidate(providerId = "provider_b", order = 0),
                    Candidate(providerId = "provider_a", order = 1),
                ),
                selectedProviderId = "provider_b",
                fallbackProviderIds = listOf("provider_a"),
                failureCode = null,
                explanation = Explanation(
                    summary = "Selected provider 'provider_b' from shared Rust planner.",
                    selectedProviderId = "provider_b",
                ),
                rejectedProviders = emptyList(),
            )
        }

        val selection = Router.withPlanner(registry, planner).selectRoute(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            ),
            hostServices = fakeHostServices(),
        )

        assertEquals("provider_b", selection.provider.describe().id)
        assertEquals(listOf("provider_a"), selection.fallbackProviders.map { it.describe().id })
        assertTrue(selection.explanation.contains("shared Rust planner"))
    }

    /**
     * The mirror planner this replaced applied the privacy filter only when
     * picking the primary and then built the chain from the unfiltered list, so a
     * `localRequired` run could fall through to a cloud provider. The shared core
     * filters once, and this pins that: a cloud provider must appear nowhere in
     * the selection, not merely not first.
     */
    @Test
    fun routingLocalRequiredNeverFallsBackToCloudProvider() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_local", available = true))
        registry.register(
            FakeProvider("provider_cloud", available = true, type = ProviderDescriptor.ProviderType.cloud),
        )

        val selection = Router(registry).selectRoute(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
            ),
            hostServices = fakeHostServices(),
        )

        assertEquals("provider_local", selection.provider.describe().id)
        assertEquals(emptyList<String>(), selection.fallbackProviders.map { it.describe().id })
        assertEquals(
            listOf(Code.PrivacyConstraint),
            selection.routePlan.rejectedProviders
                .single { it.providerId == "provider_cloud" }
                .reasons
                .map { it.code },
        )
    }

    /**
     * Ordering is the planner's, not the registry's: the Kotlin mirror ignored
     * `optimizeFor` entirely, which is the drift this test exists to catch.
     */
    @Test
    fun routerOrdersCandidatesByOptimizeFor() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_local", available = true))
        registry.register(
            FakeProvider("provider_cloud", available = true, type = ProviderDescriptor.ProviderType.cloud),
        )

        val selection = Router(registry).selectRoute(
            request = TaskRequest(
                schemaVersion = SchemaVersion.V1_0,
                prompt = "Hello",
                task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                preferences = TaskRequestPreferences(optimizeFor = OptimizeFor.Latency),
            ),
            hostServices = fakeHostServices(),
        )

        assertEquals("provider_cloud", selection.provider.describe().id)
        assertEquals(listOf("provider_local"), selection.fallbackProviders.map { it.describe().id })
    }

    /**
     * There is no second planner, so an unusable core is an `Internal` failure
     * that names itself rather than a silent switch to different routing rules.
     */
    @Test
    fun plannerFailureSurfacesAsInternalError() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a", available = true))

        val planner = object : RoutePlanner {
            override fun planRoute(input: SharedPlannerInput): SharedPlannerRoutePlan = throw RoutePlannerUnavailableException(RoutePlannerUnavailableReason.LibraryUnavailable)
        }

        try {
            Router.withPlanner(registry, planner).selectRoute(
                request = TaskRequest(
                    schemaVersion = SchemaVersion.V1_0,
                    prompt = "Hello",
                    task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                ),
                hostServices = fakeHostServices(),
            )
        } catch (error: IndeRunException) {
            assertEquals(app.independo.inderun.contracts.IndeRunErrorClass.Internal, error.errorClass)
            assertEquals("library_unavailable", error.details?.get("plannerUnavailableReason"))
            return@runTest
        }

        throw AssertionError("Expected an Internal error when the route planner is unavailable.")
    }

    @Test
    fun routerThrowsCapabilityMismatchWhenOnDeviceProviderUnavailable() = runTest {
        val registry = ProviderRegistry()
        registry.register(FakeProvider("provider_a", available = false))

        try {
            Router(registry).selectRoute(
                request = TaskRequest(
                    schemaVersion = SchemaVersion.V1_0,
                    prompt = "Hello",
                    task = TaskRequestTask(TaskKind.TEXT_TO_TEXT),
                    constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
                ),
                hostServices = fakeHostServices(),
            )
        } catch (error: IndeRunException) {
            assertEquals(app.independo.inderun.contracts.IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            return@runTest
        }

        throw AssertionError("Expected CapabilityMismatch for unavailable on-device provider.")
    }

    @Test
    fun errorStandardizationPreservesFallbackContext() {
        val exception = toIndeRunException(
            IllegalStateException("boom"),
            fallbackRunId = "run_123",
            fallbackProviderId = "provider_a",
        )

        assertEquals("run_123", exception.runId)
        assertEquals("provider_a", exception.providerId)
        assertNotNull(exception.details?.get("originalError"))
    }

    private fun fakeHostServices(): HostServices = HostServices(
        connectivity = object : ConnectivityService {
            override fun isOnline(): Boolean = true
        },
        secureStorage = object : SecureStorageService {
            override fun get(authContextRef: String): String? = null
            override fun put(authContextRef: String, value: String) = Unit
            override fun remove(authContextRef: String) = Unit
        },
        clock = object : ClockService {
            override fun elapsedRealtimeMillis(): Long = 1_000L
        },
    )

    private class FakeProvider(
        private val id: String,
        private val available: Boolean = true,
        private val type: ProviderDescriptor.ProviderType = ProviderDescriptor.ProviderType.local,
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

        override suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities = ProviderDynamicCapabilities(available = available)

        override suspend fun run(request: TaskRequest, context: RunContext): TaskResult = TaskResult(
            finishReason = FinishReason.STOP,
            output = Output(text = "Hello"),
            runId = context.runId,
            schemaVersion = SchemaVersion.V1_0,
            telemetry = TaskResultTelemetry(providerUsed = id, totalMs = 0.0),
        )
    }
}
