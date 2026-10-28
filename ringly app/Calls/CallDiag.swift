import Foundation
import SwiftUI
import Combine
import AVFAudio
import WebRTC

// Экранный журнал диагностики звонков (этап B «стабильность звонков»).
// Логи снимаются прямо с экрана приложения (другого способа снять их с устройства нет),
// поэтому пишем сюда все ключевые события: WS-события звонка, сигналинг, ICE, аудиосессию, CallKit.
// Диагностика ничего не меняет в поведении звонка — только наблюдает.
@MainActor
final class CallDiag: ObservableObject {
    static let shared = CallDiag()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    @Published private(set) var lines: [Line] = []

    // вызывается из любого потока (колбэки WebRTC/CallKit приходят не на main)
    nonisolated static func log(_ text: String) {
        print("📞 \(text)")
        Task { @MainActor in shared.append(text) }
    }

    // снимок состояния аудиосессии — главный подозреваемый «соединились, но тишина».
    // active/isAudioEnabled в связке показывают рассинхрон RTCAudioSession между звонками.
    nonisolated static func logAudio(_ label: String) {
        let av = AVAudioSession.sharedInstance()
        let rtc = RTCAudioSession.sharedInstance()
        let route = av.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: "+")
        log("🔊 \(label): active=\(rtc.isActive) audioEnabled=\(rtc.isAudioEnabled) manual=\(rtc.useManualAudio) "
            + "cat=\(av.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) "
            + "mode=\(av.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")) out=[\(route)]")
    }

    nonisolated static func iceName(_ s: RTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "?"
        }
    }

    private func append(_ text: String) {
        lines.append(Line(at: Date(), text: text))
        if lines.count > 800 { lines.removeFirst(lines.count - 800) }   // потолок, чтобы не разъедать память
    }

    func clear() { lines = [] }

    // весь журнал одним текстом (для копирования)
    var fullText: String {
        lines.map { "\(Self.timeFmt.string(from: $0.at)) \($0.text)" }.joined(separator: "\n")
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// Прокручиваемый журнал. Встраивается панелью в экран звонка и открывается из чата (после звонка).
struct CallDiagView: View {
    @ObservedObject private var diag = CallDiag.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if diag.lines.isEmpty {
                        Text(L("Журнал пуст — сделай звонок")).foregroundStyle(.secondary).padding()
                    }
                    ForEach(diag.lines) { l in
                        Text("\(CallDiag.timeFmt.string(from: l.at)) \(l.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(l.id)
                    }
                }
                .padding(8)
                .textSelection(.enabled)
            }
            .onChange(of: diag.lines.count) { _ in
                if let last = diag.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = diag.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
