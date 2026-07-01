plugins {
    id("com.android.library") version "9.2.0"
}

android {
    namespace = "app.independo.inderun.capacitor"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
    compileOnly("com.capacitorjs:core:8.0.0")
    testImplementation("com.capacitorjs:core:8.0.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation(project(":inderun-contracts"))
    implementation(project(":inderun-core"))
    implementation(project(":inderun-kotlin"))
    implementation(project(":inderun-mlkit-providers"))
    implementation(project(":inderun-openai-providers"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20260522")
}
