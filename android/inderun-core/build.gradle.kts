plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

// The shared Rust route core is the only route planner the SDK has; there is no
// Kotlin fallback behind it. It is built from source rather than committed:
// consumers resolve this module from Maven Central, where CI builds the AAR, so
// nothing would be gained by tracking four .so files in git.
abstract class BuildRouteCoreAndroid : DefaultTask() {
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
                "--out",
                outputDirectory.get().asFile.absolutePath
            )
        }
    }
}

val buildRouteCoreAndroid = tasks.register<BuildRouteCoreAndroid>("buildRouteCoreAndroid") {
    group = "build"
    description = "Cross-compiles the Rust route core for the four Android ABIs into the AAR's jniLibs."
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
            buildRouteCoreAndroid,
            BuildRouteCoreAndroid::outputDirectory
        )
    }
}

android {
    namespace = "app.independo.inderun.core"
    compileSdk = 37

    defaultConfig {
        // Kept in sync by hand with MIN_SDK in scripts/build-route-core-android.mjs,
        // which picks the NDK's per-API-level clang wrapper.
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
    implementation(project(":inderun-contracts"))
    implementation("androidx.core:core-ktx:1.19.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
