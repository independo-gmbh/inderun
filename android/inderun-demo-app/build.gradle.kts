plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The Voices lab reads the model catalog and the utterance corpus (#260) as assets, so the app sees
// the same files the Swift and JS suites read from the repository. Only those two are packaged.
abstract class CopyVoicesLabAssets : DefaultTask() {
    @get:InputDirectory
    abstract val source: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.deleteRecursively()
        out.mkdirs()
        listOf("neural-model-catalog.json", "utterance-corpus.json").forEach {
            source.get().asFile.resolve(it).copyTo(out.resolve(it))
        }
    }
}

androidComponents {
    onVariants { variant ->
        val copyAssets = tasks.register<CopyVoicesLabAssets>("copyVoicesLabAssets${variant.name.replaceFirstChar { it.uppercase() }}") {
            source.set(File(rootProject.projectDir.parentFile, "contracts/fixtures/speech"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(copyAssets, CopyVoicesLabAssets::outputDir)
    }
}

android {
    namespace = "app.independo.inderun.demo"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.independo.inderun.demo"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":inderun-contracts"))
    implementation(project(":inderun-core"))
    implementation(project(":inderun-kotlin"))
    implementation(project(":inderun-mlkit-providers"))
    implementation(project(":inderun-onnx-providers"))
    implementation(project(":inderun-openai-providers"))
    implementation(project(":inderun-system-speech-providers"))

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation:1.7.8")
    implementation("androidx.compose.material3:material3:1.4.0")
    implementation("androidx.compose.runtime:runtime:1.7.8")
    implementation("androidx.compose.ui:ui:1.7.8")
    implementation("androidx.compose.ui:ui-tooling-preview:1.7.8")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.11.0")
    implementation("com.google.android.material:material:1.14.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    debugImplementation("androidx.compose.ui:ui-tooling:1.7.8")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("androidx.compose.ui:ui-test:1.7.8")
    testImplementation("androidx.compose.ui:ui-test-junit4:1.7.8")
    testImplementation("androidx.compose.ui:ui-test-manifest:1.7.8")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
