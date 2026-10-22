package app.independo.inderun.core

import app.independo.inderun.contracts.ArtifactLifetime
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.MediaArtifact
import app.independo.inderun.contracts.OutputDelivery
import app.independo.inderun.contracts.OutputDeliveryRequest
import app.independo.inderun.contracts.SchemaVersion
import app.independo.inderun.contracts.SpeechInput
import app.independo.inderun.contracts.TaskKind
import app.independo.inderun.contracts.TaskOutput
import app.independo.inderun.contracts.TaskOutputType
import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskRequestTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A third, non-audio output through the unchanged output check (#245). Kotlin cannot build a
 * request for a task kind the schemas do not define, so the full engine pass-through of a fake
 * image task lives in the Web suite (`engine.third-task.test.ts`) and the planner side in the
 * shared `planner-conformance.json`; this pins that the check itself is delivery-based and
 * carries no audio assumption.
 */
class ThirdTaskOutputTest {
    private val request =
        TaskRequest(
            schemaVersion = SchemaVersion.V1_0,
            task = TaskRequestTask(kind = TaskKind.TEXT_TO_SPEECH),
            speech = SpeechInput(locale = "de-AT", text = "Hallo"),
            delivery = OutputDeliveryRequest(mode = OutputDelivery.Artifact, mediaTypes = listOf("image/png")),
        )

    private fun image(mediaType: String) = TaskOutput(
        type = TaskOutputType.ARTIFACT,
        artifact =
        MediaArtifact(
            id = "art_image",
            mediaType = mediaType,
            owner = ArtifactOwner.Engine,
            lifetime = ArtifactLifetime.UntilDisposed,
            byteLength = 8,
        ),
    )

    @Test
    fun anImageArtifactPassesTheArtifactCheck() {
        assertNull(checkOutput(request, OutputDelivery.Artifact, image("image/png"), "p"))
    }

    @Test
    fun anImageOfAnotherMediaTypeIsAMismatch() {
        val error = checkOutput(request, OutputDelivery.Artifact, image("image/jpeg"), "p")
        assertEquals(IndeRunErrorClass.Internal, error?.errorClass)
        assertEquals("output_mismatch", error?.details?.get("code"))
    }

    @Test
    fun anImageArtifactNeverSatisfiesPlayback() {
        assertNotNull(checkOutput(request, OutputDelivery.Playback, image("image/png"), "p"))
    }
}
