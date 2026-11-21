#!/usr/bin/env bash
set -euo pipefail

# Определение корня проекта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Цвета для терминала
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Сначала разбираем флаги, затем позиционные аргументы
AUTO_CONFIRM=false
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                POSITIONAL_ARGS+=("$1")
                shift
            done
            ;;
        -*)
            echo -e "${RED}Ошибка:${NC} Неизвестный флаг: $1" >&2
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

INPUT_VERSION="${POSITIONAL_ARGS[0]:-}"
RELEASE_NOTES="${POSITIONAL_ARGS[1]:-}"

if [ -f "VERSION" ]; then
    # shellcheck disable=SC1091
    source "VERSION"
fi
CURRENT_VERSION="${VERSION:-2.5.1}"
CURRENT_BUILD="${BUILD:-8}"

bump_version() {
    local ver="$1"
    local type="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$ver"
    major=${major:-0}
    minor=${minor:-0}
    patch=${patch:-0}

    case "$type" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
        *) echo "$type"; return ;;
    esac
    echo "${major}.${minor}.${patch}"
}

if [ -z "$INPUT_VERSION" ]; then
    echo -e "${RED}Ошибка:${NC} Укажите тип релиза (patch, minor, major) или номер версии (например, 2.6.0)." >&2
    echo -e "Использование: ${YELLOW}./scripts/release.sh [-y|--yes] <patch|minor|major|версия> [описание]${NC}" >&2
    exit 1
fi

case "$INPUT_VERSION" in
    patch|minor|major)
        NEW_VERSION="$(bump_version "$CURRENT_VERSION" "$INPUT_VERSION")"
        ;;
    *)
        NEW_VERSION="$INPUT_VERSION"
        ;;
esac

if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo -e "${RED}Ошибка:${NC} Некорректный формат версии '$NEW_VERSION' (ожидается SemVer вида X.Y.Z)." >&2
    exit 1
fi

NEW_BUILD=$((CURRENT_BUILD + 1))
TAG="v$NEW_VERSION"

echo -e "\n${BOLD}${CYAN}⚡️ Подготовка релиза HiDpiSwitcher${NC}"
echo -e "  Текущая версия: ${YELLOW}$CURRENT_VERSION${NC} (Build $CURRENT_BUILD)"
echo -e "  Новая версия:   ${GREEN}$NEW_VERSION${NC} (Build ${GREEN}$NEW_BUILD${NC})"
echo -e "  Тег в git:      ${GREEN}$TAG${NC}\n"

# Проверка, нет ли уже такого тега
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo -e "${RED}Ошибка:${NC} Тег $TAG уже существует в git!" >&2
    exit 1
fi

# Проверка чистоты рабочей директории
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}Внимание:${NC} В рабочей директории есть незакоммиченные изменения:"
    git status --short
    if [ "$AUTO_CONFIRM" = false ]; then
        read -r -p "Продолжить релиз без включения посторонних файлов (будут закоммичены только VERSION, Info.plist и appcast.xml)? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "Релиз отменен."
            exit 1
        fi
    fi
fi

# 0. Тесты перед выпуском релиза
echo -e "${BLUE}0. Запуск модульных тестов (swift test)...${NC}"
swift test

# Изолированная временная директория для упаковки и appcast
APPCAST_WORK_DIR="$(mktemp -d)"
ZIP_NAME="HiDpiSwitcher-$TAG-macOS.zip"
cleanup() {
    rm -rf "$APPCAST_WORK_DIR"
}
trap cleanup EXIT

# 1. Обновление VERSION и Info.plist
echo -e "${BLUE}1. Обновление VERSION и Info.plist...${NC}"
cat <<EOF > "VERSION"
VERSION=$NEW_VERSION
BUILD=$NEW_BUILD
EOF
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "Info.plist"
echo -e "  Записано в VERSION: ${GREEN}$NEW_VERSION (Build $NEW_BUILD)${NC}"

# 2. Сборка приложения
echo -e "${BLUE}2. Сборка приложения (.app)...${NC}"
./build.sh

APP_BUNDLE="HiDpiSwitcher.app"
ZIP_PATH="$PROJECT_ROOT/$ZIP_NAME"

# 3. Упаковка в zip
echo -e "${BLUE}3. Упаковка в zip ($ZIP_NAME)...${NC}"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# 4. Обновление и подпись appcast.xml в изолированной директории
echo -e "${BLUE}4. Генерация и Ed25519-подпись appcast.xml...${NC}"
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ -f "$GENERATE_APPCAST" ]; then
    cp "$ZIP_PATH" "$APPCAST_WORK_DIR/"
    if [ -f "$PROJECT_ROOT/appcast.xml" ]; then
        cp "$PROJECT_ROOT/appcast.xml" "$APPCAST_WORK_DIR/appcast.xml"
    fi
    KEY_ARGS=()
    if [ -f "$PROJECT_ROOT/certificates/sparkle_priv.key" ]; then
        KEY_ARGS=(--ed-key-file "$PROJECT_ROOT/certificates/sparkle_priv.key")
    fi
    "$GENERATE_APPCAST" "${KEY_ARGS[@]}" --download-url-prefix "https://github.com/banzaez/hidpi-switcher/releases/download/$TAG/" "$APPCAST_WORK_DIR"
    cp "$APPCAST_WORK_DIR/appcast.xml" "$PROJECT_ROOT/appcast.xml"
    echo -e "  ${GREEN}appcast.xml успешно обновлен и подписан Ed25519!${NC}"
else
    echo -e "  ${YELLOW}generate_appcast не найден, appcast.xml не обновлен.${NC}"
fi

# 5. Фиксация только релизных метаданных в git
echo -e "${BLUE}5. Фиксация изменений VERSION, Info.plist и appcast.xml в git...${NC}"
git add VERSION Info.plist
if [ -f "appcast.xml" ]; then
    git add appcast.xml
fi
if ! git diff --cached --quiet; then
    git commit -m "chore(release): bump version to $TAG ($NEW_BUILD) and update appcast"
fi

# 6. Создание тега
echo -e "${BLUE}6. Создание тега $TAG...${NC}"
git tag -a "$TAG" -m "Release $TAG"

# 7. Отправка в remote (прерываем релиз при ошибке push)
echo -e "${BLUE}7. Отправка ветки и тегов в git remote...${NC}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push origin "$CURRENT_BRANCH" --tags

# 8. GitHub Release
echo -e "${BLUE}8. Публикация GitHub Release...${NC}"
if command -v gh >/dev/null 2>&1; then
    if [ -n "$RELEASE_NOTES" ]; then
        gh release create "$TAG" "$ZIP_PATH" appcast.xml --title "HiDpiSwitcher $TAG" --notes "$RELEASE_NOTES"
    else
        gh release create "$TAG" "$ZIP_PATH" appcast.xml --title "HiDpiSwitcher $TAG" --generate-notes
    fi
    echo -e "  ${GREEN}GitHub Release $TAG успешно опубликован!${NC}"
else
    echo -e "  ${YELLOW}gh CLI не найден. Тег отправлен в git, релиз на GitHub создайте вручную.${NC}"
fi
