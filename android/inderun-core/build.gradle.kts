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
    // `api`, not `implementation`: every type below appears in this module's public
    // signatures (`ProviderAdapter`/`StreamingProviderAdapter` take and return contract
    // types, `StreamRun.events` and `HttpStreamResponse.body` are `Flow`s), so consumers
    // need them on their *compile* classpath. Gradle keeps `implementation` dependencies
    // off it deliberately, and com.vanniktech.maven.publish maps them to POM `runtime`
    // scope, which would leave a Maven Central consumer unable to name the types our own
    // API hands them. Anything whose types stay `internal` stays `implementation`.
    api(project(":inderun-contracts"))
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    // `HostServices.isOnline()` carries @RequiresPermission, so the annotation is part of
    // the signature a consumer implements against. Declared explicitly rather than leaned
    // on through core-ktx, which stays `implementation` -- only `SecureStorageService`
    // uses it, and nothing from it reaches this module's API.
    api("androidx.annotation:annotation:1.10.0")

    implementation("androidx.core:core-ktx:1.19.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
