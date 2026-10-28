// файл: Views/HomeView.swift
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // аватар: пока кружок с инициалом (про загрузку картинки — ниже)
            if let img = viewModel.avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 110, height: 110)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.blue.opacity(0.25))
                    .frame(width: 110, height: 110)
                    .overlay(Text(initial).font(.system(size: 44)).foregroundStyle(.blue))
            }

            // имя/фамилия — из расшифрованного профиля
            if let profile = viewModel.profile {
                Text("\(profile.firstName) \(profile.lastName)")
                    .font(.title).bold()
            } else if viewModel.me?.encryptedProfile != nil {
                // шифр есть, а ключа на устройстве нет
                Text(L("Имя недоступно на этом устройстве"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // username — plaintext, всегда доступен
            if let username = viewModel.me?.username {
                Text("@\(username)").foregroundStyle(.secondary)
            }

            Spacer()

            Button(L("Выйти")) { viewModel.logout() }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding()
    }

    // инициал для аватара-заглушки: из имени, иначе из ника
    private var initial: String {
        if let f = viewModel.profile?.firstName.first { return String(f).uppercased() }
        if let u = viewModel.me?.username?.first { return String(u).uppercased() }
        return "?"
    }
}
