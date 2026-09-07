package app.independo.inderun.smoke

import android.content.Context
import app.independo.inderun.contracts.PrivacyEnum
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.StreamEvent
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestConstraints
import app.independo.inderun.contracts.TaskRequestTask
import app.independo.inderun.contracts.TaskResult
import app.independo.inderun.sdk.IndeRun
import kotlinx.coroutines.flow.Flow

/**
 * The quick start from the repository README, verbatim in shape, compiled against
 * nothing but `implementation(project(":inderun-kotlin"))`.
 */
object ReadmeQuickStart {
    fun request(): TaskRequest = TaskRequest(
        schemaVersion = SchemaVersion.V1_0,
        prompt = "Translate 'Hello' to Spanish",
        task = TaskRequestTask(),
        constraints = TaskRequestConstraints(privacy = PrivacyEnum.LocalRequired),
    )

    suspend fun run(context: Context): TaskResult = IndeRun.initialize(context).run(request())

    /**
     * Mode 2. `StreamRun.events` is a `Flow`, so a consumer that cannot see
     * kotlinx-coroutines cannot use the streaming API at all -- naming the type
     * here is the point.
     */
    suspend fun stream(context: Context): Flow<StreamEvent> = IndeRun.initialize(context).stream(request()).events
}
