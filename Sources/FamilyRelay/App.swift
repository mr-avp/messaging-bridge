import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func toggleWindow() {
        guard let window = NSApp.windows.first(where: { $0.title.contains("Мост сообщений") }) else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main struct FamilyRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("Мост сообщений (Messaging Bridge)") {
            HSplitView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Мост сообщений").font(.largeTitle.bold())
                    Text("Messaging Bridge · Connecting people").foregroundStyle(.secondary)
                    Text("MAX ↔ Telegram").foregroundStyle(.secondary)
                    Text("1. Создайте бота в Telegram через @BotFather, добавьте его в группу и отправьте там /family.")
                    if model.hasTelegram {
                        Text("Токен сохранён в Связке ключей: ••••••••").foregroundStyle(.secondary)
                    } else {
                        SecureField("Токен Telegram-бота", text: $model.token).disabled(model.running || model.busy)
                    }
                    HStack {
                        Button("Подключить бота") { Task { await model.connectTelegram() } }.disabled(model.running || model.busy)
                        Button("Из Связки ключей") { model.restoreToken() }.disabled(model.running || model.busy)
                        Button("Удалить токен") { model.deleteToken() }.disabled(model.running || model.busy)
                    }
                    Text("Перед поиском добавьте бота в группу Telegram и отправьте там /family.").font(.callout)
                    Button("Найти группу") { Task { await model.discover() } }.disabled(model.running || model.busy)
                    Picker("Группа Telegram", selection: $model.tgID) {
                        Text("Выберите группу").tag("")
                        ForEach(model.tgGroups) { Text($0.title).tag($0.id) }
                    }.disabled(model.running || model.busy)
                    Divider()
                    Text("2. Войдите в MAX справа. Выберите группу-источник и оставьте её открытой.")
                    HStack {
                        Button("Открыть / перезагрузить MAX") { model.openMAX() }.disabled(model.running || model.busy)
                        Button("Обновить группы") { Task { await model.refreshGroups() } }.disabled(!model.maxReady || model.running || model.busy)
                        Button("Копировать диагностику") { model.copyDiagnostics() }
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
                    Divider()
                    Text(model.status).fixedSize(horizontal: false, vertical: true)
                    Text("Перенесено: \(model.count)").monospacedDigit()
                    HStack {
                        Button("Включить для выбранных групп") { Task { await model.start() } }.disabled(!model.canStart || model.running)
                        Button("Стоп") { model.stop() }.disabled(!model.running)
                    }
                    Spacer()
                    Text("Только новые сообщения: текст, фото и видео, без истории и правок. Имена берутся из MAX и Telegram. Оставляйте приложение открытым. MAX использует отдельную веб-сессию; токен бота хранится в Связке ключей. Тексты сообщений не пишутся в логи.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(20).frame(minWidth: 470, idealWidth: 520, maxWidth: 620)
                MaxPanel(web: model.max).frame(minWidth: 680, minHeight: 760)
            }.frame(minWidth: 1240, minHeight: 820)
            .task { await model.restoreAndConnect() }
        }
        MenuBarExtra {
            Button("Показать / скрыть окно") { appDelegate.toggleWindow() }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        } label: {
            Image("TrayIcon").renderingMode(.original)
        }
    }
}
