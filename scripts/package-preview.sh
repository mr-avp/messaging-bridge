#!/bin/bash
# Локальный превью-артефакт версии 0.1: свежая сборка, ZIP через ditto, SHA-256.
# Ничего не публикует, не меняет dist/, не трогает установленные приложения.
# Архитектуру можно задать явно: MESSAGING_BRIDGE_ARCH=arm64|x86_64. Без неё —
# нативная сборка; результат всегда сверяется с фактическим Mach-O через lipo.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1"
OUT_ROOT="$PWD/release-preview"

# Версия не должна расходиться с Info.plist, который пишет scripts/build.sh.
plist_version=$(sed -n 's#.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*#\1#p' scripts/build.sh)
if [[ "$plist_version" != "$VERSION" ]]; then
  printf 'ERROR: version mismatch: build.sh=%s, packager=%s\n' "$plist_version" "$VERSION" >&2
  exit 1
fi

for tool in swift ditto shasum lipo codesign unzip plutil; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'ERROR: missing tool: %s\n' "$tool" >&2; exit 1; }
done

# Нормализация явного запроса архитектуры (псевдоним x64 -> x86_64).
requested="${MESSAGING_BRIDGE_ARCH:-}"
if [[ -n "$requested" ]]; then
  case "$requested" in
    arm64) requested=arm64 ;;
    x86_64|x64) requested=x86_64 ;;
    *) printf 'ERROR: unsupported MESSAGING_BRIDGE_ARCH=%s (expected arm64 or x86_64)\n' "$requested" >&2; exit 1 ;;
  esac
fi

mkdir -p "$OUT_ROOT"
staging=$(mktemp -d "$OUT_ROOT/.staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT

printf 'Building fresh app into %s\n' "$staging" >&2
built_app=$(MESSAGING_BRIDGE_ARCH="$requested" MESSAGING_BRIDGE_OUTPUT_DIR="$staging" scripts/build.sh 2>&1 | tail -n 1)
[[ -d "$built_app" ]] || { printf 'ERROR: build.sh produced no app at %s\n' "$built_app" >&2; exit 1; }

# Архитектуру берём из фактически собранного Mach-O, а не из uname.
bin="$built_app/Contents/MacOS/MessagingBridge"
[[ -x "$bin" ]] || { printf 'ERROR: executable bit missing on %s\n' "$bin" >&2; exit 1; }
mach_archs=$(lipo -archs "$bin")
arch_label=""
case "$mach_archs" in
  arm64)  arch_label=arm64 ;;
  x86_64) arch_label=x64 ;;
  *) printf 'ERROR: unexpected Mach-O architectures: %s (no universal claim)\n' "$mach_archs" >&2; exit 1 ;;
esac
if [[ -n "$requested" ]]; then
  expected_label=""
  [[ "$requested" == "arm64" ]] && expected_label=arm64
  [[ "$requested" == "x86_64" ]] && expected_label=x64
  [[ "$arch_label" == "$expected_label" ]] || {
    printf 'ERROR: requested %s but Mach-O is %s\n' "$requested" "$mach_archs" >&2
    exit 1
  }
fi
printf 'Detected Mach-O architecture: %s (%s)\n' "$arch_label" "$mach_archs" >&2

# Самопроверка бандла до упаковки: plist, подпись, исполняемый файл.
plutil -lint "$built_app/Contents/Info.plist" >/dev/null || { printf 'ERROR: plutil -lint failed\n' >&2; exit 1; }
codesign --verify --deep --strict "$built_app" >/dev/null 2>&1 || { printf 'ERROR: codesign verification failed\n' >&2; exit 1; }
plist_version=$(plutil -extract CFBundleShortVersionString raw -o - "$built_app/Contents/Info.plist")
[[ "$plist_version" == "$VERSION" ]] || { printf 'ERROR: Info.plist version %s != %s\n' "$plist_version" "$VERSION" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $((RANDOM % 65536)))"
final="$OUT_ROOT/messaging-bridge-${VERSION}-${arch_label}-${stamp}"
archive="$OUT_ROOT/MessagingBridge-${VERSION}-${arch_label}-${stamp}.zip"
if [[ -e "$final" || -e "$archive" || -e "$archive.sha256" ]]; then
  printf 'ERROR: output already exists; refusing to overwrite\n' >&2
  exit 1
fi

mv "$staging" "$final"
trap - EXIT

# В архив попадают только приложение и документация — пользовательских данных нет.
cp LICENSE "$final/LICENSE"
cross_note=""
if [[ "$arch_label" == "x64" ]]; then
  cross_note="
Особенность этой сборки: бинарник x86_64 получен кросс-компиляцией на Mac с Apple
Silicon. Запуск и работа на Intel-Маке НЕ проверялись; совместимость с Intel не
подтверждена. Это не результат сборки на Intel и не сквозной тест на Intel.
"
fi
cat > "$final/INSTALL.ru.txt" <<TXT
Мост сообщений $VERSION — локальный превью (не опубликовано)

Состав: MessagingBridge.app, LICENSE (MIT), этот файл.
Архитектура: $arch_label (определена из собранного Mach-O через lipo: $mach_archs).
Требуется macOS 14.0 или новее. Зависимостей и установщика нет.
$cross_note
Подпись и запуск:
- Сборка подписана ad hoc (codesign --sign -): без Developer ID, без нотаризации Apple.
- macOS может заблокировать первый запуск. Для этого конкретного файла: контекстное меню → «Открыть» или Системные настройки → «Конфиденциальность и безопасность» → «Открыть всё равно».
- Не отключайте SIP/Gatekeeper и не выполняйте spctl --master-disable. Не запускайте сборки неизвестного происхождения.
- После изменения содержимого бандла подпись перестаёт быть действительной — пересоберите приложение.

Честные ограничения:
- Это прототип версии $VERSION, а не стабильный релиз. Приложение не запускалось; сквозной тест с реальными группами MAX/Telegram не выполнялся.
- В архиве нет аккаунтов, токенов, ключей, пользовательских изображений из src/ и журналов.
- Поддержка и обновления не обещаны. Условия использования — MIT, см. LICENSE.

Целостность: рядом с архивом лежит файл .sha256. Проверка:
  shasum -a 256 -c "$(basename "$archive").sha256"
TXT

ditto -c -k --keepParent --norsrc "$final" "$archive"
(
  cd "$OUT_ROOT"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
  shasum -a 256 -c "$(basename "$archive").sha256" >/dev/null
)

printf '\nArtifacts:\n  %s\n  %s\n  %s\n' "$final" "$archive" "$archive.sha256"
printf 'Checksum: %s\n' "$(awk '{print $1}' "$archive.sha256")"
