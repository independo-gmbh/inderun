plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

// The real-audio instrumented tests read the shared utterance corpus (#251) and the audio output
// catalog (ADR 021) as assets, so the device sees the same files the Swift and JS suites read
// from the repository.
androidComponents {
    onVariants { variant ->
        variant.androidTest?.sources?.assets?.addStaticSourceDirectory(
            File(rootProject.projectDir.parentFile, "contracts/fixtures/speech").path
        )
        variant.androidTest?.sources?.assets?.addStaticSourceDirectory(
            File(rootProject.projectDir.parentFile, "contracts/fixtures/host").path
        )
    }
}

android {
    namespace = "app.independo.inderun.sdk"
    compileSdk = 37

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Catalog handlers shared by the JVM and the instrumented audio output runs.
    sourceSets {
        getByName("test") { kotlin.srcDir("src/sharedTest/kotlin") }
        getByName("androidTest") { kotlin.srcDir("src/sharedTest/kotlin") }
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    // `api`, not `implementation` -- these types appear in this module's public
    // signatures, so consumers need them on their compile classpath. See the note
    // in :inderun-core's build file.
    api(project(":inderun-contracts"))
    api(project(":inderun-core"))

    // Coroutines are `api`: the text facade's public signatures take a
    // `CoroutineScope` and return `Flow` and `Deferred` (TextGeneration.kt), so they
    // are this module's own API commitment, not only :inderun-core's.
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    // IndeRun.initialize() registers the ML Kit provider, but no ML Kit or provider
    // type reaches this module's public API. :inderun-openai-providers is not a
    // dependency at all: apps that want cloud execution add it themselves and
    // register OpenAIProvider -- see this module's README.
    implementation(project(":inderun-mlkit-providers"))

    // The ML Kit engine streams below need GenAiException to drive the provider's
    // policy-rejection path; :inderun-mlkit-providers keeps ML Kit off its own API.
    testImplementation("com.google.mlkit:genai-common:1.0.0-beta4")
    // Speech is opt-in, so this is a test dependency only: the provider's engine runs here
    // because this module is the one wired to the native route core.
    testImplementation(project(":inderun-system-speech-providers"))
    // Neural speech is opt-in too: the lifecycle catalog runs its provider through this engine.
    testImplementation(project(":inderun-neural-speech"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")

    // Real TextToSpeech on an emulator or device: `connectedAndroidTest` (docs/ci.md).
    androidTestImplementation(project(":inderun-system-speech-providers"))
    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
