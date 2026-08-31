plugins {
    id("com.android.library")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "app.independo.inderun.providers.onnx"
    compileSdk = 37
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 26

        // No native code of our own: this CMake target exists solely to make the NDK's CMake
        // toolchain copy libc++_shared.so into the build output, because
        // ai.djl.android:tokenizer-native's libdjl_tokenizer.so dynamically links it without
        // shipping it. See docs/architecture/onnx-runtime-provider-family.md#android-implementation.
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
    implementation(project(":inderun-core"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.29.0")
    implementation("ai.djl.huggingface:tokenizers:0.36.0")
    implementation("ai.djl.android:tokenizer-native:0.33.0")
    implementation("org.json:json:20260814")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
