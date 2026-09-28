#!/usr/bin/env bash
#
# build.sh — compile InstaDesk into an unsigned .ipa
#
# REQUIRES A MAC (or a macos-latest GitHub Actions runner) with Xcode
# command line tools. Apple's Swift compiler + iOS SDK are macOS-only;
# there is no supported way to produce an iOS binary on Linux.
#
# Usage:  ./build.sh
# Output: build/InstaDesk.ipa   (unsigned — sign with Sideloadly/AltStore)

set -euo pipefail

APP_NAME="InstaDesk"
MIN_IOS="15.0"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/Payload/${APP_NAME}.app"

echo "==> Cleaning"
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_DIR}"

echo "==> Locating iOS SDK"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "    ${SDK_PATH}"

echo "==> Compiling Swift sources (arm64, min iOS ${MIN_IOS})"
# -parse-as-library is required because we use @main rather than a
# top-level main.swift.
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios${MIN_IOS} \
    -sdk "${SDK_PATH}" \
    -parse-as-library \
    -O \
    -framework UIKit \
    -framework WebKit \
    -framework AVFoundation \
    -o "${APP_DIR}/${APP_NAME}" \
    Sources/AppDelegate.swift \
    Sources/WebViewController.swift

echo "==> Copying Info.plist"
cp Info.plist "${APP_DIR}/Info.plist"

# ---- Icons -----------------------------------------------------------
# iOS wants flattened PNGs at the app bundle root plus CFBundleIconFiles.
# We generate the classic set from a single 1024x1024 Icon.png.
if [ -f "Icon.png" ]; then
    echo "==> Generating icon set"
    PB="/usr/libexec/PlistBuddy"
    $PB -c "Add :CFBundleIconFiles array" "${APP_DIR}/Info.plist" 2>/dev/null || true

    i=0
    for size in 60 120 180 76 152 1024; do
        out="AppIcon${size}.png"
        sips -z ${size} ${size} Icon.png --out "${APP_DIR}/${out}" >/dev/null 2>&1
        $PB -c "Add :CFBundleIconFiles:${i} string ${out}" "${APP_DIR}/Info.plist" 2>/dev/null || true
        i=$((i+1))
    done

    # Primary icon dict so Springboard picks it up reliably.
    $PB -c "Add :CFBundleIcons dict" "${APP_DIR}/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "${APP_DIR}/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "${APP_DIR}/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon120.png" "${APP_DIR}/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:1 string AppIcon180.png" "${APP_DIR}/Info.plist" 2>/dev/null || true
    $PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:2 string AppIcon60.png" "${APP_DIR}/Info.plist" 2>/dev/null || true
else
    echo "==> No Icon.png found, skipping icons (app will show a blank icon)"
fi

echo "==> Packaging .ipa"
cd "${BUILD_DIR}"
zip -qr "${APP_NAME}.ipa" Payload
cd ..

SIZE=$(du -h "${BUILD_DIR}/${APP_NAME}.ipa" | cut -f1)
echo ""
echo "Done -> ${BUILD_DIR}/${APP_NAME}.ipa  (${SIZE}, UNSIGNED)"
echo ""
echo "Next: sign + install with Sideloadly or AltStore using a free"
echo "Apple ID. Free certs expire after 7 days and need re-signing."
