// Consumer-compilation smoke test. Not published, not shipped, has no tests of its
// own -- it exists so a compile failure here is the same compile failure a real
// consumer would hit.
//
// The point is the dependency block: a single `implementation(project(":inderun-kotlin"))`,
// matching what the README tells an app to add. Gradle applies the same api/implementation
// visibility rules to a project dependency as Maven applies to compile/runtime scope, so if
// a type in inderun-kotlin's public API stops being reachable through an `api(...)` edge,
// this module stops compiling -- here, in this repo, instead of in a consumer's app after
// release. See https://github.com/independo-gmbh/inderun/issues/189.
plugins {
    id("com.android.library")
}

android {
    namespace = "app.independo.inderun.smoke"
    compileSdk = 37

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // Deliberately the only dependency. Do not add :inderun-contracts, :inderun-core
    // or kotlinx-coroutines here -- reaching them through :inderun-kotlin's `api(...)`
    // edges is exactly what this module is checking.
    implementation(project(":inderun-kotlin"))
}
