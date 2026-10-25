"""Patches an MLX checkout so it cross-compiles for any Apple SDK.

Upstream compiles its kernels with the macOS SDK only, enables Metal only for
macOS and iOS, and builds mlx.core with LTO, whose bitcode an app's linker
would have to finish. Run with the checkout's path; patching twice is a no-op.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def patch(path, old, new, count=1):
    file = root / path
    text = file.read_text()
    # Already applied: the new text is there, and the old only inside it.
    if new in text and text.count(old) == text.count(new) * new.count(old):
        return
    if text.count(old) < count:
        sys.exit(f"patch-mlx: {path} no longer contains {old!r}")
    file.write_text(text.replace(old, new))


# The SDK and minimum OS come from the build script, for every metal call.
for path in ["mlx/backend/metal/kernels/CMakeLists.txt", "cmake/extension.cmake"]:
    patch(path, "xcrun -sdk macosx metal", "xcrun -sdk ${MLX_METAL_SDK} metal", 2)
patch("mlx/backend/metal/kernels/CMakeLists.txt",
      '"-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"', '"${MLX_METAL_TARGET_OS}"')
patch("mlx/backend/metal/kernels/CMakeLists.txt",
      'set(METAL_LINK_FLAGS "-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")',
      'set(METAL_LINK_FLAGS "${MLX_METAL_TARGET_OS}")')

patch("CMakeLists.txt",
      'elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")',
      'elseif(CMAKE_SYSTEM_NAME MATCHES "^(iOS|visionOS)$")')
# Off macOS the Metal version was left at 0, which drops kernels the SDK has.
patch("CMakeLists.txt",
      "  else()\n    set(MLX_METAL_VERSION 0)\n  endif()",
      "  elseif(MLX_BUILD_METAL)\n"
      "    execute_process(\n"
      "      COMMAND\n"
      "        zsh \"-c\"\n"
      "        \"echo \\\"__METAL_VERSION__\\\" | xcrun -sdk ${MLX_METAL_SDK} metal ${MLX_METAL_TARGET_OS} -E -x metal -P - | tail -1\"\n"
      "      OUTPUT_VARIABLE MLX_METAL_VERSION\n"
      "      OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)\n"
      "  else()\n    set(MLX_METAL_VERSION 0)\n  endif()")

# Look for default.metallib in the resource bundle the Swift package ships.
patch("mlx/backend/metal/CMakeLists.txt",
      'PRIVATE METAL_PATH="${MLX_METAL_PATH}/mlx.metallib")',
      'PRIVATE METAL_PATH="${MLX_METAL_PATH}/mlx.metallib")\n'
      'if(MLX_SWIFTPM_BUNDLE)\n'
      '  target_compile_definitions(mlx PRIVATE SWIFTPM_BUNDLE="${MLX_SWIFTPM_BUNDLE}")\n'
      'endif()')

patch("python/src/CMakeLists.txt", "  FREE_THREADED\n  LTO\n", "  FREE_THREADED\n")
