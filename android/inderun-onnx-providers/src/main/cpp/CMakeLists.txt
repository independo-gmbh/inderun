# Not a real native library. Its only purpose is to make the NDK's CMake
# toolchain copy libc++_shared.so into the build output so AGP packages it
# alongside libdjl_tokenizer.so, which links it dynamically but does not ship
# it (ai.djl.android:tokenizer-native). See
# docs/architecture/onnx-runtime-provider-family.md#android-implementation.
cmake_minimum_required(VERSION 3.22.1)
project(inderun_onnx_stl_shim LANGUAGES C)

add_library(inderun_onnx_stl_shim SHARED stl_shim.c)
