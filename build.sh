#!/bin/bash
set -euo pipefail

APP_NAME="HiDpiSwitcher"
MIN_MACOS="14.0"
# Имя сертификата подписи можно задать через SIGN_IDENTITY=... ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build/app-slices"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
ARCHS=(arm64 x86_64)

if [ "${1:-}" == "test" ]; then
    echo "🧪 Запуск модульных тестов (Swift Testing)..."
    swift test
    exit 0
fi

echo "⚡️ Сборка ${APP_NAME} (Swift 6, Universal Binary, macOS ${MIN_MACOS}+)..."
rm -rf "${APP_DIR}" "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_DIR}"

# Собираем список всех исходников по слоям
SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
    SWIFT_SOURCES+=("$file")
done < <(find "${SCRIPT_DIR}/Sources" -name "*.swift" -print0)

# 1. Компиляция срезов под arm64 и x86_64 (чистый Swift 6 без Objective-C моста)
SLICES=()
for ARCH in "${ARCHS[@]}"; do
    TARGET="${ARCH}-apple-macos${MIN_MACOS}"
    OUT="${BUILD_DIR}/${APP_NAME}-${ARCH}"

    swiftc \
        -O \
        -wmo \
        -swift-version 6 \
        -parse-as-library \
        -target "${TARGET}" \
        -framework SwiftUI \
        -framework AppKit \
        -framework ServiceManagement \
        -framework CoreGraphics \
        -framework Carbon \
        "${SWIFT_SOURCES[@]}" \
        -o "${OUT}"
    SLICES+=("${OUT}")
done

lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"
strip -x "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true

# 2. Ресурсы, иконка и Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
if [ -f "${SCRIPT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# 3. Подпись (hardened runtime). Без SIGN_IDENTITY — ad-hoc.
if [ -n "${SIGN_IDENTITY}" ] && security find-identity -p codesigning -v | grep -q "${SIGN_IDENTITY}"; then
    echo "🔏 Подпись сертификатом: ${SIGN_IDENTITY}..."
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
    echo "🔏 SIGN_IDENTITY не задан/не найден, используем ad-hoc подпись..."
    codesign --force --sign - "${APP_DIR}"
fi

# 4. Сброс кэша иконки LaunchServices для Finder
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

echo "✅ Приложение успешно собрано: ${APP_DIR}"

if [ "${1:-}" == "install" ]; then
    echo "📦 Установка в /Applications..."
    pkill -x "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "🎉 Установлено в /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
fi
