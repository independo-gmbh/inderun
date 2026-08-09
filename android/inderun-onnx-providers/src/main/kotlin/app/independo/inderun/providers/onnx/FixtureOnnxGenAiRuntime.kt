package app.independo.inderun.providers.onnx

import app.independo.inderun.contracts.MessageRole
import app.independo.inderun.contracts.ModelPackage
import kotlinx.coroutines.delay

/** Configuration for the deterministic fixture runtime. */
data class FixtureOnnxRuntimeOptions(
    /** Availability snapshot returned by `prepare`. Defaults to `{ available: true }`. */
    val availability: AndroidOnnxRuntimeAvailability = AndroidOnnxRuntimeAvailability(available = true),
    /** Text or full output produced by `generate`. Defaults to a deterministic echo. */
    val respond: ((AndroidOnnxGenerationInput) -> AndroidOnnxGenerationOutput)? = null,
    /** Error thrown by `generate` instead of producing output. */
    val failWith: OnnxRuntimeError? = null,
    /** Artificial generation delay, used to exercise timeouts via coroutine cancellation. */
    val delayMs: Long? = null,
)

/**
 * Creates a deterministic in-memory ONNX runtime.
 *
 * This is the test seam mandated by the ONNX Runtime provider family specification: it proves the
 * model package contract, capability checks, routing, and error normalization without depending on
 * a real ONNX runtime, and it lets apps exercise the on-device route in demos without bundling a
 * model. It is deliberately public/importable, matching the Web and Apple members'
 * `createFixtureOnnxRuntime` rather than keeping fixtures private to the test source set.
 */
fun createFixtureOnnxRuntime(options: FixtureOnnxRuntimeOptions = FixtureOnnxRuntimeOptions()): AndroidOnnxGenAiRuntime = FixtureOnnxGenAiRuntime(options)

private class FixtureOnnxGenAiRuntime(
    private val options: FixtureOnnxRuntimeOptions,
) : AndroidOnnxGenAiRuntime {
    override suspend fun prepare(modelPackage: ModelPackage): AndroidOnnxRuntimeAvailability = options.availability

    override suspend fun generate(input: AndroidOnnxGenerationInput): AndroidOnnxGenerationOutput {
        options.delayMs?.let { delay(it) }

        options.failWith?.let { throw it }

        options.respond?.let { return it(input) }

        return AndroidOnnxGenerationOutput(text = createFixtureText(input))
    }
}

private fun createFixtureText(input: AndroidOnnxGenerationInput): String {
    val lastUserMessage = input.messages.lastOrNull { it.role == MessageRole.USER }
    val prompt = lastUserMessage?.content.orEmpty()
    return "[fixture:${input.modelPackage.id}] $prompt"
}
