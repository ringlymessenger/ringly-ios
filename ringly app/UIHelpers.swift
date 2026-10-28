import UIKit

@MainActor
func rootViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
        .first { $0.activationState == .foregroundActive } as? UIWindowScene
    return scene?.keyWindow?.rootViewController
}

// Самый верхний показанный контроллер — чтобы открыть экран поверх шита (корень уже занят им).
@MainActor
func topViewController() -> UIViewController? {
    var top = rootViewController()
    while let next = top?.presentedViewController { top = next }
    return top
}
