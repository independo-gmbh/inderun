plugins {
    id("com.android.library") version "8.13.0"
    kotlin("android") version "2.0.21"
}

android {
    namespace = "app.independo.inderun.capacitor"
    compileSdk = 34

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    implementation("com.capacitorjs:capacitor-android:8.0.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation(project(":inderun-contracts"))
    implementation(project(":inderun-core"))
    implementation(project(":inderun-kotlin"))
    implementation(project(":inderun-mlkit-providers"))
    implementation(project(":inderun-openai-providers"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
