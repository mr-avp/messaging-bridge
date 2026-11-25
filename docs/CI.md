# CI моста сообщений

Workflow [Bridge CI](../.github/workflows/ci.yml) запускается на push в
`main` и на pull request. Он использует образ GitHub Actions `macos-15-intel`
(Intel, x64), Xcode 16.4 и Node.js 24.22.3 (LTS). Версии Xcode и Node.js указаны
в workflow, а версии инструментов выводятся в журнал. Сам образ macOS
обновляется GitHub. Workflow запрашивает разрешение `contents: read`.

## Локальный запуск

Из корня репозитория на macOS с Xcode 16.4 и Node.js 24.22.3:

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
swift test
node scripts/test-max-filter.js
node scripts/test-emoji-gif.js
scripts/build.sh
```

`Package.swift` объявляет исполняемую цель `MessagingBridge`, её ресурсы
и цель `MessagingBridgeTests`. Для пакета нужен Swift 6.0 или новее,
минимальная версия macOS для приложения — 14.0. `swift test` собирает
пакет и запускает тесты Swift. JS-тесты используют встроенные модули Node.js
и сверяют логику relay в `MaxWeb.swift` и `Resources/relay.js` цели Swift,
затем проверяют её на имитациях WebSocket и HTTP. Установка npm-пакетов
не требуется. `test-emoji-gif.js` отдельно проверяет Unicode-эмодзи и GIF.

`scripts/build.sh` выполняет release-сборку SwiftPM и формирует
`dist/MessagingBridge.app`. Внутри находятся бинарник
`Contents/MacOS/MessagingBridge`, пакет ресурсов SwiftPM и иконки в
`Contents/Resources`, а также `Contents/Info.plist`. Скрипт применяет
локальную ad hoc подпись (`codesign --sign -`). Для сборки не нужны
секреты или сертификат Developer ID. Пакет остаётся в рабочем каталоге CI.

Для явного выбора архитектуры служит `MESSAGING_BRIDGE_ARCH`: например,
`MESSAGING_BRIDGE_ARCH=x86_64 scripts/build.sh` кросс-компилирует бинарник
`x86_64` на Apple Silicon в отдельном кэше `.build-arch-x86_64/`, не задевая
`.build/`. Без переменной сборка нативная (как в CI и раньше). Универсальные
сборки не делаются; кросс-сборка под Intel не означает, что она запускалась
на Intel-Маке. Публичная поддержка Intel отложена на неопределённый срок:
образ `macos-15-intel` в CI и необязательная кросс-сборка полезны только как
регрессия сборки. Первый публичный выпуск планируется только для `arm64`.

Для сборки в отдельный каталог служит `MESSAGING_BRIDGE_OUTPUT_DIR`, например
`MESSAGING_BRIDGE_ARCH=arm64 MESSAGING_BRIDGE_OUTPUT_DIR=/path/to/fresh scripts/build.sh`.
Каталог должен быть новым: копирование в существующий бандл может оставить
устаревшие файлы. Переменная не меняет `dist/` по умолчанию и не публикует
артефакты.

## Границы проверок

CI не запускает приложение и не использует пользовательские сессии MAX
или Telegram. Тесты с имитацией сети не проверяют вход и восстановление
реальной сессии WebKit, совместимость с текущим сервером MAX, работу
Telegram Bot API или доставку сообщений и медиа в обе стороны. Для этого
нужен отдельный ручной сквозной тест с тестовыми группами. Отдельно остаются
непроверенными: обратная пересылка голосовых/видеосообщений MAX → Telegram
(реализована только диагностика), воспроизведение пересланных голосовых и
видеосообщений в реальном MAX и работа на реальном Intel-Маке.
