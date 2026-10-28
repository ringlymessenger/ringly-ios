// файл: Views/KeyRecoveryView.swift
import SwiftUI

// Восстановление Profile Key по PIN-бэкапу.
// mandatory == true (fullScreenCover из MainTabView): PIN задан, без него профиль не вернуть —
// «Пропустить» НЕТ, экран не смахивается и переживает перезапуск (needsKeyRecovery выводится из
// состояния в AppViewModel.evaluateKeyRecovery, а не хранится). Запасной выход — только «Выйти из
// аккаунта» (честный: с подтверждением). Если ключ тем временем приедет синком с другого устройства,
// экран закроется сам (setMe → profile != nil → needsKeyRecovery = false).
// mandatory == false (открыт вручную из Профиля): можно закрыть.
struct KeyRecoveryView: View {
    var mandatory: Bool = false

    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmLogout = false
    @FocusState private var pinFocused: Bool

    // Оформление — как у онбординга: тот же заголовок, поле с фирменной обводкой в фокусе и
    // широкая фиолетовая кнопка внизу. Раньше экран был собран из системных заготовок
    // (roundedBorder, borderedProminent) и выглядел чужим на фоне остального приложения.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    pinField
                    if let error {
                        Text(error)
                            .font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                            .transition(.opacity)
                    }
                    hint.padding(.top, 28)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton
            secondaryButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // тап мимо поля убирает клавиатуру; жест на фоновом слое, а не на корне — см. OnboardingView
        .background(
            AppColor.background
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { pinFocused = false }
        )
        .animation(.easeInOut(duration: 0.15), value: error)
        .onAppear { pinFocused = true }
        .confirmationDialog(L("Выйти из аккаунта? История чатов останется на устройстве и вернётся при повторном входе в этот же аккаунт."),
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button(L("Выйти"), role: .destructive) { viewModel.logout(wipeLocal: false) }   // PIN не введён → не удаляем
            Button(L("Отмена"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppColor.brand)
                .frame(width: 72, height: 72)
                .background(AppColor.brand.opacity(0.15), in: Circle())
                .padding(.bottom, 12)
            Text(L("Восстановление профиля"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppColor.text)
            Text(L("Введите PIN, который вы задали для резервной копии. Имя, аватар и профили контактов расшифруются после восстановления ключа."))
                .font(.subheadline)
                .foregroundStyle(AppColor.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 48)
        .padding(.bottom, 28)
    }

    private var pinField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PIN").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppColor.text)
            SecureField(L("Введите PIN"), text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)       // без предложения сохранить пароль в связку
                .focused($pinFocused)
                .foregroundStyle(AppColor.text)
                .tint(AppColor.brand)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(AppColor.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(error != nil ? Color.red : (pinFocused ? AppColor.brand : .clear), lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.15), value: pinFocused)
                .onChange(of: pin) { _ in if error != nil { error = nil } }
        }
    }

    // подсказка про второе устройство — карточкой, а не мелким текстом в середине экрана
    private var hint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 18))
                .foregroundStyle(AppColor.brand)
                .frame(width: 24)
            Text(L("Если вы откроете приложение на другом устройстве, где профиль доступен, ключ восстановится автоматически — этот экран закроется сам."))
                .font(.footnote)
                .foregroundStyle(AppColor.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var canRestore: Bool { pin.count >= 4 }

    private var primaryButton: some View {
        Button {
            pinFocused = false
            Task { await restore() }
        } label: {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text(L("Восстановить")).font(.system(size: 17, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppColor.brand.opacity(canRestore ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy || !canRestore)
        .animation(.easeInOut(duration: 0.15), value: canRestore)
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var secondaryButton: some View {
        Group {
            if mandatory {
                Button(L("Выйти из аккаунта"), role: .destructive) { confirmLogout = true }
                    .foregroundStyle(.red)
            } else {
                Button(L("Закрыть")) { dismiss() }
                    .foregroundStyle(AppColor.subtext)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func restore() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await viewModel.backupService.restore(pin: pin)
            await viewModel.reloadAfterKeyRecovered()
            if !mandatory { dismiss() }   // mandatory закроется сам через needsKeyRecovery = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
