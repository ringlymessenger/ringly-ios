import SwiftUI

// Задать PIN резервной копии ключа профиля. Шит: после онбординга (предложение) и из Профиля.
//
// Оформление — как у KeyRecoveryView и онбординга: иконка в фирменном круге, заголовок, поля с
// подписями и фирменной обводкой в фокусе, широкая фиолетовая кнопка внизу.
struct BackupPinView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    private enum Field { case pin, confirm }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 18) {
                        pinField(L("Новый PIN"), placeholder: L("От 4 цифр"), text: $pin, field: .pin,
                                 invalid: false)
                        pinField(L("Повторите PIN"), placeholder: L("Ещё раз"), text: $confirm, field: .confirm,
                                 invalid: mismatch)
                        // о несовпадении — только когда второе поле набрано целиком: на полпути это не ошибка
                        if mismatch {
                            Text(L("PIN не совпадает"))
                                .font(.footnote).foregroundStyle(.red)
                                .padding(.top, -10)
                                .transition(.opacity)
                        }
                        if let error {
                            Text(error)
                                .font(.footnote).foregroundStyle(.red)
                                .transition(.opacity)
                        }
                    }
                    hint.padding(.top, 28)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton
            Button(L("Позже")) { dismiss() }       // можно задать PIN позже из Профиля
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColor.subtext)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // тап мимо полей убирает клавиатуру; жест на фоновом слое, а не на корне — см. OnboardingView
        .background(
            AppColor.background
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { focused = nil }
        )
        .animation(.easeInOut(duration: 0.15), value: mismatch)
        .animation(.easeInOut(duration: 0.15), value: error)
        .onAppear { focused = .pin }
        .presentationDragIndicator(.visible)
    }

    private var mismatch: Bool { confirm.count >= pin.count && !confirm.isEmpty && confirm != pin }
    private var canSave: Bool { pin.count >= 4 && pin == confirm && !done }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppColor.brand)
                .frame(width: 72, height: 72)
                .background(AppColor.brand.opacity(0.15), in: Circle())
                .padding(.bottom, 12)
            Text(L("PIN резервной копии"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppColor.text)
                .multilineTextAlignment(.center)
            Text(L("PIN защищает ключ профиля и копию переписки в iCloud. Без него не восстановить ни профиль, ни переписку на новом устройстве. Сервер PIN не узнает."))
                .font(.subheadline)
                .foregroundStyle(AppColor.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
        .padding(.bottom, 28)
    }

    private func pinField(_ label: String, placeholder: String, text: Binding<String>,
                          field: Field, invalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppColor.text)
            SecureField(placeholder, text: text)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)       // без предложения сохранить пароль в связку
                .focused($focused, equals: field)
                .foregroundStyle(AppColor.text)
                .tint(AppColor.brand)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(AppColor.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(invalid ? Color.red : (focused == field ? AppColor.brand : .clear), lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.15), value: focused)
                .onChange(of: text.wrappedValue) { _ in if error != nil { error = nil } }
        }
    }

    // зачем это вообще нужно — карточкой, как подсказка на экране восстановления
    private var hint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 18))
                .foregroundStyle(AppColor.brand)
                .frame(width: 24)
            Text(L("Запомните PIN: он понадобится, если вы потеряете все устройства. Восстановить его нельзя."))
                .font(.footnote)
                .foregroundStyle(AppColor.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var primaryButton: some View {
        Button {
            focused = nil
            Task { await save() }
        } label: {
            Group {
                if busy {
                    ProgressView().tint(.white)
                } else if done {
                    Label(L("Сохранено"), systemImage: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Text(L("Сохранить")).font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background((done ? Color.green : AppColor.brand).opacity(canSave || done || busy ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy || !canSave)
        .animation(.easeInOut(duration: 0.15), value: canSave)
        .animation(.easeInOut(duration: 0.2), value: done)
        .padding(.horizontal, 24)
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await viewModel.backupService.save(pin: pin)
            done = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
