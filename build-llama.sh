#!/bin/bash
set -e

# Simplified llama.cpp build - iOS only (device + simulator)
# Creates a DYNAMIC framework for embedding in iOS apps
LLAMA_DIR="$(cd "$(dirname "$0")" && pwd)/Vendor/llama.cpp"
cd "$LLAMA_DIR"

IOS_MIN_OS_VERSION=16.0

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_COMMON=OFF
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DLLAMA_OPENSSL=OFF
)

echo ""
echo "=== Building llama.cpp for iOS ==="
echo ""

# Clean previous builds
rm -rf build-apple build-ios-device build-ios-sim

# 1. Build for iOS device (arm64 - your iPhone 14)
echo "[1/2] Building for iOS device (arm64)..."
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S .
cmake --build build-ios-device --config Release -- -quiet
echo "  Done."

# 2. Build for iOS simulator (arm64 + x86_64 for Mac)
echo "[2/2] Building for iOS simulator..."
cmake -B build-ios-sim -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -S .
cmake --build build-ios-sim --config Release -- -quiet
echo "  Done."

echo ""
echo "=== Creating dynamic framework structures ==="

# We only need the core inference libs (no libcommon.a which is for CLI tools)
# Core libs: libllama.a, libggml*.a
create_dynamic_framework() {
    local BUILD_DIR=$1
    local PLATFORM=$2  # iphoneos or iphonesimulator
    local TARGET_ARCH=$3
    local SDK=$4

    echo "Creating dynamic framework for ${PLATFORM} (${TARGET_ARCH})..."

    local FW_DIR="${BUILD_DIR}/framework/llama.framework"
    mkdir -p "${FW_DIR}/Headers" "${FW_DIR}/Modules"

    # Collect only the core static libs (exclude libcommon.a, libcpp-httplib.a, libbuild_info.a)
    local STATIC_LIBS=""
    for lib in $(find ${BUILD_DIR} -name "*.a" -path "*/${PLATFORM}/*" | sort); do
        local basename=$(basename "$lib")
        case "$basename" in
            libcommon.a|libcpp-httplib.a|libbuild_info.a)
                echo "  Skipping $basename (not needed for inference)"
                ;;
            *)
                STATIC_LIBS="${STATIC_LIBS} ${lib}"
                echo "  Including $basename"
                ;;
        esac
    done

    if [ -z "$STATIC_LIBS" ]; then
        echo "ERROR: No static libraries found for ${PLATFORM}!"
        exit 1
    fi

    # Create dynamic library from static libs
    xcrun clang++ -dynamiclib -all_load \
        ${STATIC_LIBS} \
        -install_name @rpath/llama.framework/llama \
        -isysroot $(xcrun --sdk ${SDK} --show-sdk-path) \
        -target ${TARGET_ARCH}-apple-ios${IOS_MIN_OS_VERSION}${5} \
        -framework Accelerate \
        -framework Metal \
        -framework MetalKit \
        -framework Foundation \
        -lc++ \
        -Wl,-application_extension \
        -o "${FW_DIR}/llama"

    echo "  Dynamic lib created: $(file ${FW_DIR}/llama | head -1)"

    # Copy headers
    cp include/llama.h "${FW_DIR}/Headers/"
    for h in ggml.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h; do
        [ -f "ggml/include/$h" ] && cp "ggml/include/$h" "${FW_DIR}/Headers/"
    done
    # Copy ggml-opt.h if llama.h includes it
    if grep -q "ggml-opt.h" include/llama.h; then
        [ -f "ggml/include/ggml-opt.h" ] && cp "ggml/include/ggml-opt.h" "${FW_DIR}/Headers/"
    fi

    # Create module map
    cat > "${FW_DIR}/Modules/module.modulemap" << 'MODULEMAP'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODULEMAP

    # Create Info.plist
    cat > "${FW_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
</dict>
</plist>
PLIST
}

# Build device framework (arm64)
create_dynamic_framework "build-ios-device" "Release-iphoneos" "arm64" "iphoneos" ""

# Build simulator framework (arm64 + x86_64)
# The simulator static libs are already fat (arm64+x86_64), so link as fat dylib directly
SIM_FW_DIR="build-ios-sim/framework/llama.framework"
mkdir -p "${SIM_FW_DIR}/Headers" "${SIM_FW_DIR}/Modules"

# Collect sim static libs
SIM_STATIC_LIBS=""
for lib in $(find build-ios-sim -name "*.a" -path "*/Release-iphonesimulator/*" | sort); do
    basename=$(basename "$lib")
    case "$basename" in
        libcommon.a|libcpp-httplib.a|libbuild_info.a)
            echo "  Skipping $basename (simulator)"
            ;;
        *)
            SIM_STATIC_LIBS="${SIM_STATIC_LIBS} ${lib}"
            echo "  Including $basename (simulator)"
            ;;
    esac
done

# Build fat (arm64+x86_64) simulator dylib directly
echo "Building universal simulator dylib..."
xcrun clang++ -dynamiclib -all_load \
    ${SIM_STATIC_LIBS} \
    -install_name @rpath/llama.framework/llama \
    -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
    -arch arm64 -arch x86_64 \
    -mios-simulator-version-min=${IOS_MIN_OS_VERSION} \
    -framework Accelerate \
    -framework Metal \
    -framework MetalKit \
    -framework Foundation \
    -lc++ \
    -Wl,-application_extension \
    -o "${SIM_FW_DIR}/llama"

echo "  Simulator dynamic lib: $(file ${SIM_FW_DIR}/llama | head -1)"

# Copy headers and modulemap for simulator (same as device)
cp include/llama.h "${SIM_FW_DIR}/Headers/"
for h in ggml.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h; do
    [ -f "ggml/include/$h" ] && cp "ggml/include/$h" "${SIM_FW_DIR}/Headers/"
done
if grep -q "ggml-opt.h" include/llama.h; then
    [ -f "ggml/include/ggml-opt.h" ] && cp "ggml/include/ggml-opt.h" "${SIM_FW_DIR}/Headers/"
fi

cat > "${SIM_FW_DIR}/Modules/module.modulemap" << 'MODULEMAP'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODULEMAP

cat > "${SIM_FW_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
</dict>
</plist>
PLIST

# Create XCFramework
echo ""
echo "=== Creating XCFramework ==="
rm -rf build-apple/llama.xcframework
xcrun xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-device/framework/llama.framework \
    -framework $(pwd)/build-ios-sim/framework/llama.framework \
    -output $(pwd)/build-apple/llama.xcframework

echo ""
echo "=== Verifying framework binary type ==="
file $(pwd)/build-apple/llama.xcframework/ios-arm64/llama.framework/llama

echo ""
echo "=== Done! ==="
echo "XCFramework created at: $(pwd)/build-apple/llama.xcframework"
echo ""
