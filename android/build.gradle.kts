import org.gradle.api.tasks.testing.Test
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.jvm.toolchain.JavaToolchainService
import org.gradle.kotlin.dsl.support.serviceOf

plugins {
    id("com.android.application") version "9.2.1" apply false
    id("com.android.library") version "9.2.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
    id("com.diffplug.spotless") version "7.0.2" apply false
}

subprojects {
    apply(plugin = "com.diffplug.spotless")
    configure<com.diffplug.gradle.spotless.SpotlessExtension> {
        kotlin {
            target("src/**/*.kt")
            ktlint("1.5.0").editorConfigOverride(
                mapOf(
                    // Jetpack Compose @Composable functions use PascalCase by convention.
                    "ktlint_function_naming_ignore_when_annotated_with" to "Composable",
                    // The repo groups related classes per file by design.
                    "ktlint_standard_filename" to "disabled",
                    // Enum entries mirror the canonical schema string values (e.g. in_process).
                    "ktlint_standard_enum-entry-name-case" to "disabled"
                )
            )
        }
    }

    // Robolectric's bundled ASM cannot instrument bytecode from very new JDKs
    // (e.g. JDK 26), so pin unit tests to a Java 21 toolchain that matches CI,
    // regardless of the developer's default JDK. Compilation still targets 17.
    tasks.withType<Test>().configureEach {
        javaLauncher.set(
            serviceOf<JavaToolchainService>().launcherFor {
                languageVersion.set(JavaLanguageVersion.of(21))
            }
        )
    }
}
