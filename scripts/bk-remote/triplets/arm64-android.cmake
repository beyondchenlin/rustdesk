# Windows-host Android ARM64 baseline: retain upstream target and optimizations.
include("${CMAKE_CURRENT_LIST_DIR}/../../../res/vcpkg-triplets/arm64-android.cmake")
file(TO_CMAKE_PATH "$ENV{ANDROID_NDK_HOME}" BK_NDK_ROOT)
set(BK_NDK_ASM "${BK_NDK_ROOT}/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe")
if(NOT EXISTS "${BK_NDK_ASM}")
    message(FATAL_ERROR "Pinned Android NDK assembler unavailable")
endif()
list(APPEND VCPKG_CMAKE_CONFIGURE_OPTIONS
    "-DCMAKE_ASM_COMPILER=${BK_NDK_ASM}"
    "-DCMAKE_ASM_COMPILER_TARGET=aarch64-linux-android21")