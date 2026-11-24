import SwiftUI
import AppKit

func loadTrayIcon(from bundle: Bundle = .main) -> NSImage? {
    let image = bundle.url(forResource: "TrayIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
        ?? Bundle.module.image(forResource: "TrayIcon")
        ?? Bundle.module.url(forResource: "TrayIcon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    image?.isTemplate = false
    return image
}

private let trayIcon = loadTrayIcon()

let settingsWindowTitle = "Мост сообщений (Messaging Bridge)"
let settingsWindowFrameName = "MessagingBridgeSettingsWindow"

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The single settings window. It is created on demand and reused; closing it only hides it.
    private(set) var settingsWindow: NSWindow?
    /// Production hosts the SwiftUI settings view; tests inject a plain view to avoid touching app state.
    var makeSettingsContent: () -> NSView = { NSHostingView(rootView: MainWindowView()) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            Model.shared.eventLog.record(.appStart)
            Model.shared.openMAX()
            await Model.shared.restoreAndConnect()
            Model.shared.applyStartupSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in Model.shared.eventLog.record(.appQuit) }
        Model.shared.prepareForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === settingsWindow else { return true }
        hideWindow()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
    }

    func showWindow() {
        let window = settingsWindow ?? makeSettingsWindow()
        positionOnVisibleScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        guard let window = settingsWindow else { return }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }

    func toggleWindow() {
        if let window = settingsWindow, window.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = settingsWindowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = makeSettingsContent()
        let restored = window.setFrameUsingName(settingsWindowFrameName)
        window.setFrameAutosaveName(settingsWindowFrameName)
        if !restored { window.center() }
        settingsWindow = window
        return window
    }

    private func positionOnVisibleScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }
}

private struct MenuBarContentView: View {
    let appDelegate: AppDelegate
    @ObservedObject private var model = Model.shared

    private func openBridge() {
        model.selectedSection = .bridge
        appDelegate.showWindow()
    }

    private var pairTitle: String {
        let maxTitle = model.maxGroups.first(where: { $0.id == model.maxID })?.title ?? "—"
        let tgTitle = model.tgGroups.first(where: { $0.id == model.tgID })?.title ?? "—"
        return "\(maxTitle) ↔ \(tgTitle)"
    }

    var body: some View {
        Text(model.recovering ? "Восстановление моста…" : (model.running ? "Мост работает" : "Мост остановлен"))
            .font(.headline)
        Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true)
        Text("Пара: \(pairTitle)").font(.caption).foregroundStyle(.secondary)
        Divider()
        Button("Открыть Мост") { openBridge() }
        Button(model.running || model.recovering ? "Остановить мост" : "Запустить мост") {
            if model.running || model.recovering { model.stopByUser() } else { Task { await model.start() } }
        }.disabled(model.running || model.recovering ? false : (!model.canStart || model.busy))
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }
}

@main struct MessagingBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appDelegate: appDelegate)
        } label: {
            if let trayIcon {
                Image(nsImage: trayIcon)
            } else {
                Image(systemName: "arrow.left.arrow.right")
            }
        }
    }
}

private struct MainWindowView: View {
    @ObservedObject private var model = Model.shared
    @ObservedObject private var eventLog = Model.shared.eventLog

    private var statusColor: Color {
        if model.running { return .green }
        if model.recovering { return .orange }
        return .secondary
    }

    private var pairTitle: String {
        let maxTitle = model.maxGroups.first(where: { $0.id == model.maxID })?.title
        let tgTitle = model.tgGroups.first(where: { $0.id == model.tgID })?.title
        if let maxTitle, let tgTitle { return "\(maxTitle) ↔ \(tgTitle)" }
        return "Пара не выбрана"
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // A single top navigation row: the TabView tabs below are the
                // only section switcher (a segmented Picker here duplicated it).
                TabView(selection: $model.selectedSection) {
                    bridgePane
                        .tabItem { Text("Мост") }
                        .tag(AppSection.bridge)
                    settingsPane
                        .tabItem { Text("Настройки") }
                        .tag(AppSection.settings)
                    informationPane
                        .tabItem { Text("Информация") }
                        .tag(AppSection.information)
                }
            }
            .frame(minWidth: 400)
            MaxPanel(web: model.max)
                .frame(minWidth: model.maxPanelVisible ? 420 : 0, maxWidth: model.maxPanelVisible ? .infinity : 0, minHeight: 500)
                .opacity(model.maxPanelVisible ? 1 : 0)
                .clipped()
        }
        .frame(minWidth: 900, minHeight: 600)
    }


    private var bridgePane: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Мост").font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(model.recovering ? "Восстановление моста…" : (model.running ? "Мост работает" : "Мост остановлен"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Выбранная пара").font(.headline)
                    Text(pairTitle).font(.body)
                    Text("Перенесено за сеанс: \(model.sessionRelayCount)").monospacedDigit()
                    if let last = model.lastSuccessfulRelayAt {
                        Text("Последняя успешная передача: \(last.formatted(date: .numeric, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Успешных передач за сеанс пока нет").font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(model.running || model.recovering ? "Остановить" : "Запустить") {
                        if model.running || model.recovering { model.stopByUser() } else { Task { await model.start() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running || model.recovering ? false : (!model.canStart || model.busy))
                    Button("Изменить подключение") {
                        model.selectedSection = .settings
                        model.settingsPane = .connections
                    }
                    Button(model.maxPanelVisible ? "Скрыть MAX" : "Показать MAX") {
                        model.maxPanelVisible.toggle()
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(20)
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.settingsPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.settingsPane {
                    case .connections:
                        connectionsSettings
                    case .automation:
                        automationSettings
                    case .telegram:
                        telegramSettings
                    }
                }
                .padding(20)
            }
        }
    }

    private var connectionsSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Подключения").font(.title2.bold())
            Text("2. Войдите в MAX справа. Выберите группу-источник и оставьте её открытой.")
                .font(.callout)
            HStack {
                Button("Открыть / перезагрузить MAX") { model.openMAX() }.disabled(model.running || model.busy)
                Button("Обновить группы") { Task { await model.refreshGroups() } }.disabled(!model.maxReady || model.running || model.busy)
            }
            Picker("Группа MAX", selection: $model.maxID) {
                Text("Выберите группу").tag("")
                ForEach(model.maxGroups) { Text($0.title).tag($0.id) }
            }.disabled(model.running || model.busy)
            Divider()
            Text("Подключения").font(.headline)
            Picker("Сохранённое подключение", selection: $model.connectionID) {
                Text("Новое подключение").tag(UUID?.none)
                ForEach(model.connections) { Text($0.title).tag(Optional($0.id)) }
            }.disabled(model.running || model.busy)
                .onChange(of: model.connectionID) { _, newValue in model.selectConnection(newValue) }
            HStack {
                Button("Сохранить текущее") { model.saveConnection() }.disabled(!model.canSaveConnection || model.running || model.busy)
                Button("Новое") { model.newConnection() }.disabled(model.running || model.busy)
                Button("Удалить") { model.deleteConnection() }.disabled(model.connectionID == nil || model.running || model.busy)
            }
            Text("Один бот может работать в нескольких Telegram-группах. Мост переносит выбранную пару групп; для другой пары остановите мост и выберите сохранённое подключение.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Группа Telegram", selection: $model.tgID) {
                Text("Выберите группу").tag("")
                ForEach(model.tgGroups) { Text($0.title).tag($0.id) }
            }.disabled(model.running || model.busy)
            Button("Найти группу") { Task { await model.discover() } }
                .disabled(!model.hasTelegram || model.running || model.busy)
            Text("Перед поиском добавьте бота в группу Telegram и отправьте там /family.")
                .font(.callout)
        }
    }

    private var automationSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Автоматизация").font(.title2.bold())
            Toggle("Автозапуск при входе в систему", isOn: Binding(get: { model.autoStart }, set: { model.setAutoStart($0) }))
            Toggle("Автовключение моста при запуске", isOn: Binding(get: { model.autoRelay }, set: { model.setAutoRelay($0) }))
            Toggle("Автовосстановление после сна и сбоев", isOn: Binding(get: { model.autoRecover }, set: { model.setAutoRecover($0) }))
        }
    }

    private var telegramSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Telegram-бот").font(.title2.bold())
            if model.hasTelegram {
                Text("Бот подключён").foregroundStyle(.green)
                HStack {
                    Button("Восстановить токен") { model.restoreToken() }.disabled(model.running || model.busy)
                    Button("Удалить токен") { model.deleteToken() }.disabled(model.running || model.busy)
                }
                SecureField("Новый токен Telegram-бота", text: $model.token).disabled(model.running || model.busy)
                Button("Заменить токен") { Task { await model.connectTelegram() } }
                    .disabled(model.running || model.busy)
                Text("Токен скрыт и хранится локально. Для замены введите новый токен; текущий токен не показывается.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("1. Создайте бота в Telegram через @BotFather, добавьте его в группу и отправьте там /family.")
                    .font(.callout)
                SecureField("Токен Telegram-бота", text: $model.token).disabled(model.running || model.busy)
                HStack {
                    Button("Подключить бота") { Task { await model.connectTelegram() } }.disabled(model.running || model.busy)
                }
                Text("После подключения бота найдите группу в разделе «Подключения».").font(.callout)
                Text("Отключите Group Privacy в BotFather, если бот не видит сообщения группы.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var informationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.informationPane) {
                ForEach(InformationPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.informationPane {
                    case .about:
                        aboutInformation
                    case .journal:
                        journalInformation
                    case .developer:
                        developerInformation
                    }
                }
                .padding(20)
            }
        }
    }

    private var aboutInformation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("О программе").font(.title2.bold())
            Text("Мост сообщений · Messaging Bridge").foregroundStyle(.secondary)
            Text("Версия: \(AppMetadata.version) (build \(AppMetadata.build))").monospacedDigit()
            Text("MAX ↔ Telegram").foregroundStyle(.secondary)
            Divider()
            Text("Только новые сообщения: текст, фото, видео, GIF и документы, без истории и правок. Имена берутся из MAX и Telegram. Оставляйте приложение открытым. MAX использует отдельную веб-сессию; токен бота хранится в локальном хранилище приложения. Тексты сообщений не пишутся в логи.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Приложение работает локально на macOS 14+, использует официальный веб-клиент MAX в WebKit и официальный Telegram Bot API. Собственного сервера, аналитики и сторонних зависимостей нет.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Токен Telegram хранится в локальном хранилище приложения и подключается автоматически при запуске. Список групп и сохранённые подключения хранятся локально.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Лимиты Telegram Bot API: перенос из Telegram в MAX — до \(TelegramLimits.botDownloadBytes / (1024 * 1024)) МБ на вложение; из MAX в Telegram — фото до \(TelegramLimits.photoBytes / (1024 * 1024)) МБ, видео/медиа и документы до \(TelegramLimits.videoBytes / (1024 * 1024)) МБ.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var journalInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Журнал событий").font(.title2.bold())
            if eventLog.entries.isEmpty {
                Text("Событий пока нет.").foregroundStyle(.secondary)
            } else {
                ForEach(eventLog.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.timestamp.formatted(date: .numeric, time: .standard)) · \(entry.level.rawValue.uppercased())")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(entry.event.displayText)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            HStack {
                Button("Копировать") { model.copyEventLog() }
                Button("Очистить") { model.clearEventLog() }
            }
        }
    }

    private var developerInformation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Для разработчика").font(.title2.bold())
            Text("Безопасная диагностика").foregroundStyle(.secondary)
            Text(model.status).fixedSize(horizontal: false, vertical: true)
            Text("MAX: \(model.maxReady ? "подключён" : "нет"), событий: \(model.maxEvents), ready: \(model.readyCount), групп: \(model.maxGroups.count)")
            Text("JS: старт \(model.jsStart), сокет \(model.jsSocket), авторизация \(model.jsAuth)")
            Text("Хост сокета: \(model.jsHost.isEmpty ? "—" : model.jsHost)")
            Text("Восстановление: \(model.autoRecover ? "включено" : "выключено"), \(model.recovering ? "активно (попытка \(model.recoveryAttempt))" : "нет")")
            Text("Журнал: \(eventLog.count) событий")
            Text("Файл журнала: \(eventLog.url.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Копировать диагностику") { model.copyDiagnostics() }
                Button("Копировать журнал") { model.copyEventLog() }
                Button("Очистить журнал") { model.clearEventLog() }
            }
        }
    }
}
