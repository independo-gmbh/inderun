package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnnxFormatGuardTest {

    /**
     * The format guard runs before anything touches the context, so a constructor-less instance
     * is enough; the plain unit-test android.jar stubs throw from every Context constructor.
     */
    private fun untouchedContext(): Context {
        val unsafeField = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }
        val unsafe = unsafeField.get(null) as sun.misc.Unsafe
        return unsafe.allocateInstance(android.content.ContextWrapper::class.java) as Context
    }

    @Test
    fun availabilityRefusesCoreAiPackages() = runTest {
        val runtime = SystemAndroidOnnxGenAiRuntime(untouchedContext())
        val modelPackage = ModelPackage(
            id = "coreai-model",
            format = Format.Coreai,
            source = Source(sourceType = SourceType.Bundled, ref = "models/coreai"),
        )

        val availability = runtime.availability(modelPackage)

        assertFalse(availability.available)
        assertTrue(availability.reason.orEmpty().contains("unsupported model format"))
    }
}
