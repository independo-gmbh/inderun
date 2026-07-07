import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import com.vanniktech.maven.publish.SonatypeHost
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.api.tasks.bundling.Jar
import org.gradle.api.tasks.testing.Test
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.jvm.toolchain.JavaToolchainService
import org.gradle.kotlin.dsl.support.serviceOf

plugins {
    id("com.android.application") version "9.2.1" apply false
    id("com.android.library") version "9.2.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
    id("com.diffplug.spotless") version "7.0.2" apply false
    id("com.vanniktech.maven.publish") version "0.37.0" apply false
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

    // Maven Central publishing for the library modules that apply the plugin
    // (the demo app and Capacitor bridge do not). Coordinates share the repo-wide
    // version from gradle.properties (updated on release by scripts/set-version.mjs).
    plugins.withId("com.vanniktech.maven.publish") {
        // Central requires a javadoc jar, but AGP 9.2's Dokka-backed javadoc task
        // is fragile (it fails on the modules' non-standard source layout). Publish
        // an empty javadoc jar instead — standard practice for Kotlin/Android libs.
        val emptyJavadocJar = tasks.register("emptyJavadocJar", Jar::class.java) {
            archiveClassifier.set("javadoc")
        }

        configure<MavenPublishBaseExtension> {
            // publishJavadocJar = false avoids AGP's Dokka javadoc; we attach our own.
            configure(
                AndroidSingleVariantLibrary(
                    variant = "release",
                    sourcesJar = true,
                    publishJavadocJar = false
                )
            )
            val publishVersion = providers.gradleProperty("inderunVersion").getOrElse("0.0.0")
            coordinates("app.independo.inderun", project.name, publishVersion)
            publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL, automaticRelease = true)

            // Sign only when a key is available (CI). Lets publishToMavenLocal work
            // locally without signing credentials.
            val hasSigningKey = providers.gradleProperty("signingInMemoryKey").isPresent ||
                System.getenv("ORG_GRADLE_PROJECT_signingInMemoryKey") != null
            if (hasSigningKey) {
                signAllPublications()
            }

            pom {
                name.set("IndeRun ${project.name}")
                description.set("IndeRun ${project.name} — Android module of the IndeRun AI execution framework.")
                inceptionYear.set("2026")
                url.set("https://github.com/independo-gmbh/inderun")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://github.com/independo-gmbh/inderun/blob/main/LICENSE")
                        distribution.set("repo")
                    }
                }
                developers {
                    developer {
                        id.set("independo")
                        name.set("Independo GmbH")
                        url.set("https://independo.app")
                    }
                }
                scm {
                    url.set("https://github.com/independo-gmbh/inderun")
                    connection.set("scm:git:https://github.com/independo-gmbh/inderun.git")
                    developerConnection.set("scm:git:ssh://git@github.com/independo-gmbh/inderun.git")
                }
            }
        }

        // Attach the empty javadoc jar to the generated "release" publication.
        afterEvaluate {
            extensions.configure(PublishingExtension::class.java) {
                publications.withType(MavenPublication::class.java).configureEach {
                    artifact(emptyJavadocJar)
                }
            }
        }
    }
}
