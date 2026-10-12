#!/bin/bash
set -e

APP_NAME="HiDpiSwitcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "⚡️ Сборка ${APP_NAME}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

# 1. Компиляция CGSBridge (Objective-C)
clang -c -O3 -fmodules -fobjc-arc \
    "${SCRIPT_DIR}/Sources/CGSBridge.m" \
    -o "/tmp/CGSBridge.o"

# 2. Компиляция Swift с оптимизацией
swiftc \
    -O \
    -wmo \
    -parse-as-library \
    -import-objc-header "${SCRIPT_DIR}/Sources/Bridging-Header.h" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework CoreGraphics \
    /tmp/CGSBridge.o \
    "${SCRIPT_DIR}/Sources/DisplayManager.swift" \
    "${SCRIPT_DIR}/Sources/LaunchAtLoginManager.swift" \
    "${SCRIPT_DIR}/Sources/HiDpiApp.swift" \
    -o "${MACOS_DIR}/${APP_NAME}"

# 3. Ресурсы и Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"

# 4. Локальная подпись (Ad-hoc)
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1

echo "✅ Приложение успешно собрано: ${APP_DIR}"

if [ "$1" == "install" ]; then
    echo "📦 Установка в /Applications..."
    pkill "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "🎉 Установлено в /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
fi
