#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ "${1:-}" == "test" ]; then
    echo "🧪 Запуск модульных тестов (Swift Testing)..."
    swift test
    exit 0
fi

# Чтение версии из единого источника истины (VERSION)
if [ -f "VERSION" ]; then
    # shellcheck disable=SC1091
    source "VERSION"
fi
APP_NAME="HiDpiSwitcher"
APP_VERSION="${VERSION:-2.5.1}"
APP_BUILD="${BUILD:-8}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"

echo "⚡️ Собираем ${APP_NAME} v${APP_VERSION} (${APP_BUILD}) в Release режиме (Universal Binary)..."
swift build -c release --arch arm64 --arch x86_64

RELEASE_BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

echo "📦 Формируем структуру ${APP_NAME}.app..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

# Копируем бинарный файл
cp "${RELEASE_BIN}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Копируем иконку приложения
if [ -f "${SCRIPT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Копируем Sparkle.framework (обязательная зависимость автообновлений)
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "${SPARKLE_FRAMEWORK}" ]; then
    echo "❌ Ошибка: Sparkle.framework не найден по пути ${SPARKLE_FRAMEWORK}" >&2
    exit 1
fi
cp -R "${SPARKLE_FRAMEWORK}" "${FRAMEWORKS_DIR}/"

# Настраиваем rpath для поиска Frameworks (без ошибки, если rpath уже прописан)
if ! otool -l "${MACOS_DIR}/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"
fi

# Копируем Info.plist и синхронизируем версию из VERSION
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${CONTENTS_DIR}/Info.plist"

sign_item() {
    local identity="$1"
    local target="$2"
    if [ "$identity" = "-" ]; then
        codesign --force --sign "$identity" "$target"
    else
        codesign --force --options runtime --sign "$identity" "$target"
    fi
}

echo "✍️ Подписываем фреймворки и пакет (inside-out)..."
if [ -n "${CODESIGN_IDENTITY}" ]; then
    SIGN_CERT="${CODESIGN_IDENTITY}"
else
    SIGN_CERT="$(security find-identity -p codesigning -v 2>/dev/null | grep -E "HiDpiSwitcherDev" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [ -n "${SIGN_CERT}" ]; then
    echo "🔐 Подписание сертификатом: ${SIGN_CERT}"
    ACTIVE_IDENTITY="${SIGN_CERT}"
else
    echo "ℹ️ Сертификат HiDpiSwitcherDev не найден, используется ad-hoc подпись..."
    ACTIVE_IDENTITY="-"
fi

# Подписываем вложенные компоненты Sparkle изнутри наружу
SPARKLE_DEST="${FRAMEWORKS_DIR}/Sparkle.framework"
if [ -d "${SPARKLE_DEST}" ]; then
    while IFS= read -r xpc; do
        sign_item "${ACTIVE_IDENTITY}" "${xpc}"
    done < <(find "${SPARKLE_DEST}" -name "*.xpc" -type d)

    if [ -e "${SPARKLE_DEST}/Versions/B/Updater.app" ]; then
        sign_item "${ACTIVE_IDENTITY}" "${SPARKLE_DEST}/Versions/B/Updater.app"
    elif [ -e "${SPARKLE_DEST}/Updater.app" ]; then
        sign_item "${ACTIVE_IDENTITY}" "${SPARKLE_DEST}/Updater.app"
    fi

    if [ -e "${SPARKLE_DEST}/Versions/B/Autoupdate" ]; then
        sign_item "${ACTIVE_IDENTITY}" "${SPARKLE_DEST}/Versions/B/Autoupdate"
    elif [ -e "${SPARKLE_DEST}/Autoupdate" ]; then
        sign_item "${ACTIVE_IDENTITY}" "${SPARKLE_DEST}/Autoupdate"
    fi

    sign_item "${ACTIVE_IDENTITY}" "${SPARKLE_DEST}"
fi

sign_item "${ACTIVE_IDENTITY}" "${APP_DIR}"

# Сброс кэша иконки LaunchServices для Finder
touch "${APP_DIR}"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true

echo "✅ Приложение успешно собрано с Sparkle: ${APP_DIR}"

if [ "${1:-}" == "install" ]; then
    echo "📦 Установка в /Applications..."
    pkill -x "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
    echo "🎉 Установлено в /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
fi
