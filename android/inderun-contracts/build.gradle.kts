plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "app.independo.inderun.contracts"
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
}
