#!/bin/bash
set -e

APP_NAME="HiDpiSwitcher"
MIN_MACOS="13.0"
# Имя сертификата подписи можно задать через SIGN_IDENTITY=... ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
ARCHS=(arm64 x86_64)

echo "⚡️ Сборка ${APP_NAME}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${BUILD_DIR}"

# 1-2. Компиляция по архитектурам (Objective-C мост + Swift)
SLICES=()
for ARCH in "${ARCHS[@]}"; do
    TARGET="${ARCH}-apple-macos${MIN_MACOS}"
    OBJ="${BUILD_DIR}/CGSBridge-${ARCH}.o"
    OUT="${BUILD_DIR}/${APP_NAME}-${ARCH}"

    clang -c -O3 -fmodules -fobjc-arc -target "${TARGET}" \
        "${SCRIPT_DIR}/Sources/CGSBridge.m" \
        -o "${OBJ}"

    swiftc \
        -O \
        -wmo \
        -parse-as-library \
        -target "${TARGET}" \
        -import-objc-header "${SCRIPT_DIR}/Sources/Bridging-Header.h" \
        -framework SwiftUI \
        -framework ServiceManagement \
        -framework CoreGraphics \
        "${OBJ}" \
        "${SCRIPT_DIR}/Sources/DisplayManager.swift" \
        "${SCRIPT_DIR}/Sources/LaunchAtLoginManager.swift" \
        "${SCRIPT_DIR}/Sources/HiDpiApp.swift" \
        -o "${OUT}"
    SLICES+=("${OUT}")
done
lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"

# 3. Ресурсы, иконка и Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
if [ -f "${SCRIPT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# 4. Подпись (hardened runtime). Без SIGN_IDENTITY — ad-hoc.
if [ -n "${SIGN_IDENTITY}" ] && security find-identity -p codesigning -v | grep -q "${SIGN_IDENTITY}"; then
    echo "🔏 Подпись сертификатом: ${SIGN_IDENTITY}..."
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
    echo "🔏 SIGN_IDENTITY не задан/не найден, используем ad-hoc подпись..."
    codesign --force --sign - "${APP_DIR}"
fi

# 5. Сброс кэша иконки LaunchServices для Finder
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

echo "✅ Приложение успешно собрано: ${APP_DIR}"

if [ "$1" == "install" ]; then
    echo "📦 Установка в /Applications..."
    pkill -x "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "🎉 Установлено в /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
fi
