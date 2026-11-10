package app.independo.inderun.smoke

import android.content.Context
import app.independo.inderun.contracts.Privacy
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.sdk.GeneratedText
import app.independo.inderun.sdk.IndeRun
import app.independo.inderun.sdk.TextExecutionOptions
import app.independo.inderun.sdk.TextGenerationOptions
import app.independo.inderun.sdk.TextStream
import app.independo.inderun.sdk.generateText
import app.independo.inderun.sdk.streamText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow

/**
 * The quick start from the repository README, verbatim in shape, compiled against
 * nothing but `implementation(project(":inderun-kotlin"))`.
 */
object ReadmeQuickStart {
    fun options(): TextGenerationOptions = TextGenerationOptions(
        prompt = "Translate 'Hello' to Spanish",
        execution = TextExecutionOptions(privacy = Privacy.LocalRequired),
    )

    /** The primary text API, as the README's quick start uses it. */
    suspend fun generate(context: Context): GeneratedText = IndeRun.initialize(context).generateText(options())

    /**
     * `streamText` takes a `CoroutineScope` and returns `Flow`s and a `Deferred`, so it is only
     * usable when kotlinx-coroutines reaches the consumer's compile classpath from this module.
     */
    suspend fun streamText(context: Context, scope: CoroutineScope): Flow<String> {
        val stream: TextStream = IndeRun.initialize(context).streamText(options(), scope)
        return stream.textStream
    }

    /** The advanced API's equivalent request. */
    fun request(): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Translate 'Hello' to Spanish",
        task = TaskRequestTask(),
        constraints = TaskRequestConstraints(privacy = Privacy.LocalRequired),
    )

    suspend fun run(context: Context): TaskResult = IndeRun.initialize(context).run(request())

    /**
     * Mode 2. `StreamRun.events` is a `Flow`, so a consumer that cannot see
     * kotlinx-coroutines cannot use the streaming API at all -- naming the type
     * here is the point.
     */
    suspend fun stream(context: Context): Flow<StreamEvent> = IndeRun.initialize(context).stream(request()).events
}
