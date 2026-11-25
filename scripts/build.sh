#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Явный выбор архитектуры — необязателен. Без переменной поведение прежнее:
# нативная сборка SwiftPM без флагов --arch/--scratch-path (на этой машине arm64).
# Поддерживаются arm64 и x86_64 (псевдоним x64); "universal" намеренно не поддерживается.
arch="${MESSAGING_BRIDGE_ARCH:-}"
if [[ -n "$arch" ]]; then
  case "$arch" in
    arm64) arch=arm64 ;;
    x86_64|x64) arch=x86_64 ;;
    *)
      printf 'ERROR: unsupported MESSAGING_BRIDGE_ARCH=%s (expected arm64 or x86_64)\n' "$arch" >&2
      exit 1
      ;;
  esac
  # Независимый кэш для каждой архитектуры: не задеваем .build нативной сборки
  # и не смешиваем артефакты разных архитектур в одном scratch-каталоге.
  scratch="$PWD/.build-arch-$arch"
fi

if [[ -n "$arch" ]]; then
  swift build -c release --arch "$arch" --scratch-path "$scratch"
  bin_dir=$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)
else
  swift build -c release
  bin_dir=$(swift build -c release --show-bin-path)
fi
bin="$bin_dir/MessagingBridge"

# Проверяем фактическую архитектуру готового Mach-O, а не только флаг сборки.
if [[ -n "$arch" ]]; then
  command -v lipo >/dev/null 2>&1 || { printf 'ERROR: missing tool: lipo\n' >&2; exit 1; }
  actual=$(lipo -archs "$bin")
  [[ "$actual" == "$arch" ]] || {
    printf 'ERROR: requested arch %s but Mach-O is %s\n' "$arch" "$actual" >&2
    exit 1
  }
fi

# Default unchanged: dist/MessagingBridge.app. Optional override lets the
# preview packager build into a fresh, uniquely named folder without touching
# any existing dist/ artifact or installed app.
out_dir="${MESSAGING_BRIDGE_OUTPUT_DIR:-$PWD/dist}"
app="$out_dir/MessagingBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MessagingBridge"
cp -R "$bin_dir/MessagingBridge_MessagingBridge.bundle" "$app/Contents/Resources/"
cp "$PWD/Resources/MessagingBridge.icns" "$app/Contents/Resources/MessagingBridge.icns"
cp "$PWD/Sources/MessagingBridge/Resources/TrayIcon.png" "$app/Contents/Resources/TrayIcon.png"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.messaging-bridge</string>
<key>CFBundleName</key><string>MessagingBridge</string>
<key>CFBundleDisplayName</key><string>Мост сообщений</string>
<key>CFBundleExecutable</key><string>MessagingBridge</string>
<key>CFBundleIconFile</key><string>MessagingBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
