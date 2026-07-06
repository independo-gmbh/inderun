plugins {
    id("com.android.application") version "9.2.0" apply false
    id("com.android.library") version "9.2.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20" apply false
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
}
