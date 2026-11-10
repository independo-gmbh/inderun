plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

// The German speech text normalizer lives in the shared Rust crate. It is packaged here as its
// own library, libinderun_speech_text, so apps that never use neural speech do not carry it in
// libinderun_route_core. Built from source like :inderun-core's library; see its build file.
abstract class BuildSpeechTextAndroid : DefaultTask() {
    @get:Internal
    abstract val repoRoot: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @get:Inject
    abstract val execOperations: ExecOperations

    @TaskAction
    fun build() {
        execOperations.exec {
            workingDir = repoRoot.get().asFile
            commandLine(
                "node",
                "scripts/build-route-core-android.mjs",
                "--speech-text",
                "--out",
                outputDirectory.get().asFile.absolutePath
            )
        }
    }
}

val buildSpeechTextAndroid = tasks.register<BuildSpeechTextAndroid>("buildSpeechTextAndroid") {
    group = "build"
    description = "Cross-compiles the speech text library (libinderun_speech_text) for the four Android ABIs into the AAR's jniLibs."
    repoRoot.set(rootProject.layout.projectDirectory.dir(".."))
    // Freshness is cargo's job -- it fingerprints inputs this task cannot see
    // (the lockfile, the compiler version) -- so never skip on Gradle's own
    // up-to-date check. The script is a no-op when cargo has nothing to rebuild.
    outputs.upToDateWhen { false }
}

// addGeneratedSourceDirectory wires both the output location and the task
// dependency, so only the variants that package native libraries pull the ABI
// build in: `./gradlew test` needs neither the NDK nor the Android Rust targets
// (the unit tests load a host build -- see the root build.gradle.kts).
androidComponents {
    onVariants { variant ->
        variant.sources.jniLibs?.addGeneratedSourceDirectory(
            buildSpeechTextAndroid,
            BuildSpeechTextAndroid::outputDirectory
        )
    }
}

android {
    namespace = "app.independo.inderun.providers.neuralspeech"
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
    // The frontend test reads the shared fixture with org.json, which plain Android unit
    // tests only stub.
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
}
