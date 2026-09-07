plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "app.independo.inderun.sdk"
    compileSdk = 37

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    // IndeRun.initialize() registers the ML Kit provider, but no ML Kit or provider
    // type reaches this module's public API. :inderun-openai-providers is not a
    // dependency at all: apps that want cloud execution add it themselves and
    // register OpenAIProvider -- see this module's README.
    implementation(project(":inderun-mlkit-providers"))

    // The ML Kit engine streams below need GenAiException to drive the provider's
    // policy-rejection path; :inderun-mlkit-providers keeps ML Kit off its own API.
    testImplementation("com.google.mlkit:genai-common:1.0.0-beta4")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
