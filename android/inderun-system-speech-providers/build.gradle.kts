plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "app.independo.inderun.providers.systemspeech"
    // The consumer compileSdk floor, kept below the newest SDK on purpose; see the root build.gradle.kts.
    //noinspection GradleDependency
    compileSdk = 36

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

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
