import SwiftUI

// Профиль → Копия в iCloud (docs/icloud-backup.md §8).
struct ICloudBackupView: View {
    @ObservedObject private var backup = ICloudBackup.shared
    @State private var enabled = ICloudBackup.shared.enabled
    @State private var confirmDisable = false
    @State private var showSetPin = false
    @State private var showEnterPin = false
    @State private var mediaMode = BackupMediaSettings.mode
    @State private var maxMB = BackupMediaSettings.maxMB
    @State private var cellular = BackupMediaSettings.cellular
    @State private var chargingOnly = BackupMediaSettings.chargingOnly
    @State private var confirmPrune = false
    @State private var confirmReset = false
    @State private var askCellular = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                toggleCard
                if enabled {
                    statusCard
                    mediaCard
                }
                explanation
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L("Копия в iCloud"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await backup.refreshStatus() }
        .confirmationDialog(L("Удалить уже сохранённую копию из iCloud?"), isPresented: $confirmDisable,
                            titleVisibility: .visible) {
            Button(L("Удалить из iCloud"), role: .destructive) {
                Task { await backup.setEnabled(false, deleteRemote: true) }
            }
            Button(L("Оставить в iCloud")) {
                Task { await backup.setEnabled(false) }
            }
            Button(L("Отмена"), role: .cancel) { enabled = true }
        }
        // исключили медиа или снизили лимит — спросить про уже сохранённое (§2)
        .confirmationDialog(L("Удалить из iCloud уже сохранённые медиа, которые теперь не подходят?"),
                            isPresented: $confirmPrune, titleVisibility: .visible) {
            Button(L("Удалить из iCloud"), role: .destructive) { Task { await backup.pruneMedia() } }
            Button(L("Оставить в iCloud")) {}     // не .cancel: в поповере iOS такую кнопку прячет
        }
        .confirmationDialog(L("Сбросить копию в iCloud?"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L("Сбросить копию"), role: .destructive) {
                Task {
                    await backup.resetCopy()
                    showSetPin = true
                }
            }
        } message: {
            Text(L("Текущая копия будет удалена из iCloud, новая создастся из переписки на этом устройстве. Понадобится задать новый PIN."))
        }
        .sheet(isPresented: $showSetPin, onDismiss: refresh) { BackupPinView() }
        .sheet(isPresented: $showEnterPin, onDismiss: refresh) { ICloudPinSheet() }
    }

    private func refresh() {
        Task {
            await backup.refreshStatus()
            await backup.restoreIfAvailable()
            await backup.backupNow()
        }
    }

    private var toggleCard: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.fill").foregroundStyle(AppColor.subtext).frame(width: 22)
                Text(L("Копия переписки в iCloud")).foregroundStyle(AppColor.text)
            }
        }
        .tint(.blue)
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: enabled) { on in
            guard on != backup.enabled else { return }
            if on { Task { await backup.setEnabled(true) } } else { confirmDisable = true }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch backup.status {
            case .off:
                line(L("Копия выключена"))
            case .noAccount:
                line(L("Войдите в iCloud в настройках iPhone и разрешите iCloud для Ringly — без этого копия не делается."), warning: true)
            case .waitingPin(let hasPin):
                line(hasPin
                     ? L("Введите PIN, чтобы защитить копию. Без него в iCloud ничего не сохраняется.")
                     : L("Задайте PIN, чтобы включить копию. Без него в iCloud ничего не сохраняется."), warning: true)
                Button(hasPin ? L("Ввести PIN") : L("Задать PIN")) {
                    if hasPin { showEnterPin = true } else { showSetPin = true }
                }
                if hasPin {
                    Button(L("Забыли PIN?")) { confirmReset = true }
                }
            case .noKeychainKey:
                line(L("В iCloud есть копия, но ключа к ней на этом устройстве нет. Включите Связку ключей iCloud: Настройки → ваше имя → iCloud → Пароли и Связка ключей."), warning: true)
                resetButton
            case .keyMismatch:
                line(L("Копия в iCloud зашифрована другим ключом. Если PIN меняли на другом устройстве — введите новый PIN."), warning: true)
                Button(L("Ввести PIN")) { showEnterPin = true }
                resetButton
            case .notRestored(let count):
                line(count > 0
                     ? String(format: L("В iCloud есть копия: %d сообщений. Восстановите её, чтобы это устройство продолжило её обновлять."), count)
                     : L("В iCloud есть копия. Восстановите её, чтобы это устройство продолжило её обновлять."))
                Button(L("Восстановить из iCloud")) { Task { await backup.restore() } }
                    .disabled(backup.restoring)
            case .otherWriter(let name, let at):
                line(String(format: L("Копию делает «%@», последняя копия: %@."), name, format(at)))
                Button(L("Делать копию на этом устройстве")) { Task { await backup.takeOverWriting() } }
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("Создаётся копия…")).foregroundStyle(AppColor.text)
                }
            case .idle(let last):
                line(last.map { String(format: L("Последняя копия: %@"), format($0)) } ?? L("Копия ещё не создана"))
                nowButton
            case .failed(let message):
                line(message, warning: true)
                nowButton
            }
            if let p = backup.mediaProgress {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(String(format: p.downloading ? L("Загрузка медиа из iCloud: %d из %d") : L("Медиа в копию: %d из %d"),
                                p.done, p.total))
                        .foregroundStyle(AppColor.subtext)
                }
            }
            if let sum = backup.summary {
                Text(String(format: L("В копии: сообщений — %d, медиа — %d (%@)"), sum.messages, sum.mediaFiles,
                            ByteCountFormatter.string(fromByteCount: Int64(sum.mediaBytes), countStyle: .file)))
                    .font(.footnote)
                    .foregroundStyle(AppColor.subtext)
            }
            if backup.restoring {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("Восстановление из iCloud…")).foregroundStyle(AppColor.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // Настройки медиа. Сужение (меньше типов или меньший лимит) — с вопросом про уже сохранённое.
    private var mediaCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Медиа"))
                Spacer()
                Picker(L("Медиа"), selection: $mediaMode) {
                    ForEach(BackupMediaSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.vertical, 6)
            .onChange(of: mediaMode) { old, new in
                BackupMediaSettings.mode = new
                if narrows(old: old, new: new) { confirmPrune = true }
            }

            if mediaMode != .none {
                Divider()
                HStack {
                    Text(L("Размер файла"))
                    Spacer()
                    Picker(L("Размер файла"), selection: $maxMB) {
                        ForEach(BackupMediaSettings.sizeOptions, id: \.self) { Text(BackupMediaSettings.sizeTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 6)
                .onChange(of: maxMB) { old, new in
                    BackupMediaSettings.maxMB = new
                    if new != 0 && (old == 0 || new < old) { confirmPrune = true }
                }

                Divider()
                Toggle(L("Медиа по сотовой сети"), isOn: $cellular)
                    .tint(.blue)
                    .padding(.vertical, 10)
                    .onChange(of: cellular) { _, new in BackupMediaSettings.cellular = new }

                Divider()
                Toggle(L("Медиа только на зарядке"), isOn: $chargingOnly)
                    .tint(.blue)
                    .padding(.vertical, 10)
                    .onChange(of: chargingOnly) { _, new in BackupMediaSettings.chargingOnly = new }
            }
        }
        .foregroundStyle(AppColor.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func narrows(old: BackupMediaSettings.Mode, new: BackupMediaSettings.Mode) -> Bool {
        switch (old, new) {
        case (.all, .photos), (.all, .none), (.photos, .none): return true
        default: return false
        }
    }

    private var resetButton: some View {
        Button(L("Сбросить копию"), role: .destructive) { confirmReset = true }
    }

    private var nowButton: some View {
        Button(L("Создать копию сейчас")) {
            if backup.mediaBlockedByNetwork {
                askCellular = true        // без Wi-Fi медиа не уйдут — спросить, а не молчать
            } else {
                Task { await backup.backupNow(force: true) }
            }
        }
        .alert(L("Нет подключения к Wi-Fi"), isPresented: $askCellular) {
            Button(L("Продолжить с медиа")) { Task { await backup.backupNow(force: true, cellularMedia: true) } }
            Button(L("Продолжить без медиа")) { Task { await backup.backupNow(force: true) } }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Фото и видео сохраняются только по Wi-Fi. Сохранить их сейчас по сотовой сети?"))
        }
    }

    private func line(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(warning ? Color.orange : AppColor.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(L("Переписка сохраняется в вашем iCloud и переживает выход из аккаунта и смену телефона."))
            paragraph(L("Копия зашифрована. Ключ состоит из двух частей: одна лежит в Связке ключей iCloud, другая защищена вашим PIN. Ни Apple, ни Ringly прочитать копию не могут."))
            paragraph(L("Без Связки ключей iCloud копия не восстановится на другом устройстве. В копию попадают фото и видео, которые есть на этом устройстве."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppColor.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// Ввод уже заданного PIN: из PIN-копии берётся половина ключа копии, сама PIN-копия переписывается
// в формат v2. Системные элементы. Открывается и из настроек, и однократным напоминанием (MainTabView).
struct ICloudPinSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L("Введите PIN"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                } header: {
                    Text(L("Введите PIN, чтобы включить копию переписки в iCloud"))
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(L("Тот же PIN, что защищает ключ профиля."))
                    }
                }
            }
            .navigationTitle(L("Копия в iCloud"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Отмена")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(L("Готово")) { Task { await submit() } }.disabled(pin.count < 4)
                    }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await viewModel.backupService.unlockICloudBackup(pin: pin)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
