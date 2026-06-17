package com.independo.inderun.providers.mlkit

import com.independo.inderun.contracts.ExecutionPolicy
import com.independo.inderun.contracts.IndeRunErrorClass
import com.independo.inderun.contracts.Message
import com.independo.inderun.contracts.MessageRole
import com.independo.inderun.contracts.Policy
import com.independo.inderun.contracts.TaskRequest
import com.independo.inderun.core.HostServices
import com.independo.inderun.core.IndeRunException
import com.independo.inderun.core.RunContext
import com.independo.inderun.core.SecureStorageService
import com.independo.inderun.core.ClockService
import com.independo.inderun.core.ConnectivityService
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMlKitGenAiProviderTest {
    @Test
    fun capabilitiesReflectAvailableRuntime() = runTest {
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = FakeRuntime(availability = AndroidMlKitGenAiAvailability.Available)
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertTrue(capabilities.available)
    }

    @Test
    fun capabilitiesReportUnavailableReason() = runTest {
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = FakeRuntime(
                availability = AndroidMlKitGenAiAvailability.Unavailable("not supported")
            )
        )

        val capabilities = provider.capabilities(fakeHostServices())

        assertFalse(capabilities.available)
        assertEquals("not supported", capabilities.reason)
    }

    @Test
    fun runReturnsCanonicalTaskResult() = runTest {
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = FakeRuntime(
                availability = AndroidMlKitGenAiAvailability.Available,
                outputText = "Generated response"
            )
        )

        val result = provider.run(
            request = TaskRequest(
                prompt = "Hello",
                policy = Policy(ExecutionPolicy.ON_DEVICE)
            ),
            context = RunContext("run_123", fakeHostServices())
        )

        assertEquals("Generated response", result.output.text)
        assertEquals("run_123", result.runId)
    }

    @Test
    fun runUsesNormalizedMessagesPrompt() = runTest {
        val runtime = FakeRuntime(availability = AndroidMlKitGenAiAvailability.Available)
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = runtime
        )

        provider.run(
            request = TaskRequest(
                messages = listOf(
                    Message(MessageRole.SYSTEM, "Be concise"),
                    Message(MessageRole.USER, "Hello")
                ),
                policy = Policy(ExecutionPolicy.ON_DEVICE)
            ),
            context = RunContext("run_123", fakeHostServices())
        )

        assertEquals("system: Be concise\nuser: Hello", runtime.lastPrompt)
    }

    @Test
    fun runMapsUnavailableStateToCapabilityMismatch() = runTest {
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = FakeRuntime(
                availability = AndroidMlKitGenAiAvailability.Downloadable("download pending")
            )
        )

        try {
            provider.run(
                request = TaskRequest(
                    prompt = "Hello",
                    policy = Policy(ExecutionPolicy.ON_DEVICE)
                ),
                context = RunContext("run_123", fakeHostServices())
            )
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.CapabilityMismatch, error.errorClass)
            return@runTest
        }

        throw AssertionError("Expected CapabilityMismatch when model is not ready.")
    }

    @Test
    fun runMapsUnexpectedRuntimeFailureToInternal() = runTest {
        val provider = AndroidMlKitGenAiProvider(
            id = AndroidMlKitGenAiProvider.DEFAULT_ID,
            runtime = FakeRuntime(
                availability = AndroidMlKitGenAiAvailability.Available,
                failure = IllegalStateException("boom")
            )
        )

        try {
            provider.run(
                request = TaskRequest(
                    prompt = "Hello",
                    policy = Policy(ExecutionPolicy.ON_DEVICE)
                ),
                context = RunContext("run_123", fakeHostServices())
            )
        } catch (error: IndeRunException) {
            assertEquals(IndeRunErrorClass.Internal, error.errorClass)
            return@runTest
        }

        throw AssertionError("Expected Internal when runtime throws.")
    }

    private fun fakeHostServices(): HostServices {
        return HostServices(
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
            }
        )
    }

    private class FakeRuntime(
        private val availability: AndroidMlKitGenAiAvailability,
        private val outputText: String = "OK",
        private val failure: Throwable? = null
    ) : AndroidMlKitGenAiRuntime {
        var lastPrompt: String? = null

        override suspend fun availability(): AndroidMlKitGenAiAvailability = availability

        override suspend fun generateText(
            prompt: String,
            options: AndroidMlKitGenAiGenerationOptions
        ): String {
            lastPrompt = prompt
            failure?.let { throw it }
            return outputText
        }
    }
}
