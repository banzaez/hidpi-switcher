#!/bin/bash
set -e

APP_NAME="HiDpiSwitcher"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "⚡️ Сборка ${APP_NAME}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${BUILD_DIR}"

# 1. Компиляция CGSBridge (Objective-C)
clang -c -O3 -fmodules -fobjc-arc \
    "${SCRIPT_DIR}/Sources/CGSBridge.m" \
    -o "${BUILD_DIR}/CGSBridge.o"

# 2. Компиляция Swift с оптимизацией
swiftc \
    -O \
    -wmo \
    -parse-as-library \
    -import-objc-header "${SCRIPT_DIR}/Sources/Bridging-Header.h" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework CoreGraphics \
    "${BUILD_DIR}/CGSBridge.o" \
    "${SCRIPT_DIR}/Sources/DisplayManager.swift" \
    "${SCRIPT_DIR}/Sources/LaunchAtLoginManager.swift" \
    "${SCRIPT_DIR}/Sources/HiDpiApp.swift" \
    -o "${MACOS_DIR}/${APP_NAME}"

# 3. Ресурсы, иконка и Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
if [ -f "${SCRIPT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# 4. Локальная подпись (постоянный сертификат для сохранения TCC / fallback на ad-hoc)
if security find-identity -p codesigning -v | grep -q "JustScreenshotDev"; then
    echo "🔏 Подпись постоянным локальным сертификатом: JustScreenshotDev..."
    codesign --force --deep --sign "JustScreenshotDev" "${APP_DIR}"
else
    echo "🔏 Сертификат JustScreenshotDev не найден, используем ad-hoc подпись..."
    codesign --force --deep --sign - "${APP_DIR}"
fi

# 5. Сброс кэша иконки LaunchServices для Finder
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

echo "✅ Приложение успешно собрано: ${APP_DIR}"

if [ "$1" == "install" ]; then
    echo "📦 Установка в /Applications..."
    pkill "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "🎉 Установлено в /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
fi
