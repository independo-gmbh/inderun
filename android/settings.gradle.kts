pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "inderun-android"

include(":inderun-contracts")
include(":inderun-core")
include(":inderun-demo-app")
include(":inderun-mlkit-providers")
include(":inderun-openai-providers")
include(":inderun-kotlin")
