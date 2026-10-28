import SwiftUI
import AVFoundation
import Combine

// Редактор фрагмента кастомного гудка: звонящий слышит 45 с (длина дозвона), и пользователь сам
// выбирает, какие. Рамка на 45 с стоит на месте по центру, под ней пальцем двигается волна всего
// трека (как выбор звука в Instagram/TikTok) — точнее, чем тянуть узкий ползунок по 5-минутной
// песне. «Прослушать» играет ровно выбранный кусок по кругу, как его услышит звонящий.
// Показывается, только если трек длиннее 45 с; короткий уходит в обработку как есть.
struct RingbackTrimView: View {
    let fileURL: URL
    let fileName: String
    let onDone: (Double) -> Void        // начало фрагмента, секунды
    let onCancel: () -> Void

    @StateObject private var preview = RingbackPreview()
    @State private var wave: RingbackStudio.Waveform?
    @State private var failed = false
    @State private var start: Double = 0
    @State private var dragBase: Double?
    @State private var atEdge = false
    @ObservedObject private var calls = CallManager.shared

    private let length = RingbackStudio.maxDuration
    private var maxStart: Double { max(0, (wave?.duration ?? length) - length) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text(fileName)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.subtext)
                    .lineLimit(1)
                    .truncationMode(.middle)

                VStack(spacing: 6) {
                    Text("\(Self.clock(start)) – \(Self.clock(start + length))")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(AppColor.text)
                    Text(L("Эти 45 секунд услышит звонящий"))
                        .font(.footnote)
                        .foregroundStyle(AppColor.subtext)
                }

                waveformStrip
                    .frame(height: 128)

                overview

                Button {
                    preview.toggle(from: start)
                } label: {
                    Label(preview.isPlaying ? L("Пауза") : L("Прослушать"),
                          systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 170)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColor.brand)
                .controlSize(.large)
                .disabled(wave == nil || calls.phase != .idle)   // во время звонка звук занят звонком

                Spacer(minLength: 0)

                Label(L("Двигайте волну, чтобы выбрать момент"), systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(AppColor.faint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(AppColor.background.ignoresSafeArea())
            .navigationTitle(L("Фрагмент гудка"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Отмена")) { preview.stop(); onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { preview.stop(); onDone(start) }
                        .disabled(wave == nil)
                }
            }
            .alert(L("Не удалось открыть файл"), isPresented: $failed) {
                Button("OK") { onCancel() }
            }
        }
        .task {
            preview.load(fileURL)
            do { wave = try await RingbackStudio.waveform(of: fileURL) }
            catch {
                CallDiag.log("🎵 мелодия: волна не построилась — \(error)")
                failed = true
            }
        }
        .onDisappear { preview.stop() }
    }

    // ===== волна под рамкой =====

    private var waveformStrip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let windowWidth = (width * 0.72).rounded()
            let windowX = (width - windowWidth) / 2
            let pointsPerSecond = windowWidth / length

            ZStack {
                if let wave {
                    Canvas { ctx, size in
                        drawBars(wave, in: ctx, size: size, windowX: windowX,
                                 windowWidth: windowWidth, pointsPerSecond: pointsPerSecond)
                    }
                } else {
                    ProgressView()
                }

                // рамка фрагмента — неподвижна, двигается волна под ней
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColor.brand.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppColor.brand, lineWidth: 2)
                    }
                    .frame(width: windowWidth)
                    .allowsHitTesting(false)

                // где сейчас играет прослушивание
                if preview.isPlaying {
                    Capsule()
                        .fill(AppColor.text)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                        .offset(x: windowX + (preview.position - start) * pointsPerSecond - width / 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = start
                            preview.beginScrub()
                        }
                        let raw = (dragBase ?? 0) - value.translation.width / pointsPerSecond
                        let clamped = min(max(raw, 0), maxStart)
                        // упёрлись в начало или конец трека — короткий щелчок, чтобы это чувствовалось
                        let edge = clamped != raw
                        if edge && !atEdge { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        atEdge = edge
                        start = clamped
                    }
                    .onEnded { _ in
                        dragBase = nil
                        atEdge = false
                        preview.endScrub(at: start)
                    }
            )
            .disabled(wave == nil)
        }
    }

    // Столбики-капсулы с шагом ~5 pt: каждый собран из нескольких отсчётов волны, и группы привязаны
    // ко времени трека, а не к экрану — при перетаскивании столбики едут, а не «перемигиваются».
    // Высота сглажена с соседями. В рамке — вертикальный градиент фирменного цвета (сыгранное
    // прослушиванием — основным цветом текста), снаружи — бледно. Каждый вид столбиков собирается
    // в один Path и заливается разом: так градиент один на всю полосу, а не на каждый столбик.
    private func drawBars(_ wave: RingbackStudio.Waveform, in ctx: GraphicsContext, size: CGSize,
                          windowX: CGFloat, windowWidth: CGFloat, pointsPerSecond: CGFloat) {
        let sampleStep = 1 / Double(RingbackStudio.Waveform.perSecond)
        let group = max(1, Int((Self.barPitch / (pointsPerSecond * sampleStep)).rounded()))
        let step = sampleStep * Double(group)                 // секунд на один столбик
        let pitch = CGFloat(step) * pointsPerSecond
        let barWidth = max(2, pitch * 0.55)
        let bars = (wave.peaks.count + group - 1) / group

        func level(_ g: Int) -> CGFloat {
            guard g >= 0, g < bars else { return 0 }
            let slice = wave.peaks[(g * group)..<min(wave.peaks.count, (g + 1) * group)]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }

        let first = max(0, Int((start - Double(windowX / pointsPerSecond)) / step) - 1)
        let last = min(bars - 1, Int((start + Double((size.width - windowX) / pointsPerSecond)) / step) + 1)
        guard first <= last else { return }

        let playhead = preview.isPlaying ? preview.position : -1
        let maxHeight = size.height - 20
        var outside = Path(), inside = Path(), played = Path()
        for g in first...last {
            let t = (Double(g) + 0.5) * step                  // центр столбика во времени трека
            let x = windowX + CGFloat(t - start) * pointsPerSecond
            let smooth = level(g - 1) * 0.25 + level(g) * 0.5 + level(g + 1) * 0.25
            let height = max(barWidth, smooth * maxHeight)
            let rect = CGRect(x: x - barWidth / 2, y: (size.height - height) / 2, width: barWidth, height: height)
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            if x < windowX || x > windowX + windowWidth { outside.addPath(bar) }
            else if t <= playhead { played.addPath(bar) }
            else { inside.addPath(bar) }
        }

        ctx.fill(outside, with: .color(AppColor.faint.opacity(0.6)))
        ctx.fill(inside, with: .linearGradient(
            Gradient(colors: [Self.brandLight, AppColor.brand, Self.brandLight]),
            startPoint: CGPoint(x: 0, y: (size.height - maxHeight) / 2),
            endPoint: CGPoint(x: 0, y: (size.height + maxHeight) / 2)))
        ctx.fill(played, with: .color(AppColor.text))
    }

    private static let barPitch: CGFloat = 5                       // шаг столбиков на экране, pt
    private static let brandLight = Color(red: 0.70, green: 0.60, blue: 1.0)

    // ===== где фрагмент во всём треке =====

    private var overview: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let total = max(wave?.duration ?? length, length)
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.fill)
                    Capsule()
                        .fill(AppColor.brand)
                        .frame(width: max(6, geo.size.width * length / total))
                        .offset(x: geo.size.width * start / total)
                }
            }
            .frame(height: 4)

            HStack {
                Text(Self.clock(0))
                Spacer()
                Text(Self.clock(wave?.duration ?? 0))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(AppColor.faint)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// Прослушивание фрагмента по кругу — как его будет крутить звонящий во время дозвона.
@MainActor
final class RingbackPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var range: ClosedRange<Double> = 0...RingbackStudio.maxDuration
    private var resumeAfterScrub = false

    func load(_ url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        } catch {
            CallDiag.log("🎵 прослушивание: файл не открылся — \(error)")
        }
    }

    func toggle(from start: Double) {
        if isPlaying { stop() } else { play(from: start) }
    }

    func play(from start: Double) {
        // во время звонка аудиосессией владеет звонок — не трогаем (инварианты ios-calls.md)
        guard CallManager.shared.phase == .idle, let player else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        range = start...(start + RingbackStudio.maxDuration)
        player.currentTime = start
        position = start
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        guard isPlaying || player?.isPlaying == true else { return }
        player?.pause()
        isPlaying = false
        if CallManager.shared.phase == .idle {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // пока двигают волну — тишина; отпустили — играем уже новый фрагмент с начала
    func beginScrub() {
        resumeAfterScrub = isPlaying
        if isPlaying { stop() }
    }

    func endScrub(at start: Double) {
        if resumeAfterScrub { play(from: start) }
        resumeAfterScrub = false
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        // конец фрагмента (или конец файла) — по кругу, как гудок у звонящего
        if position >= range.upperBound || !player.isPlaying {
            player.currentTime = range.lowerBound
            position = range.lowerBound
            player.play()
        }
    }
}

#if DEBUG
// Стенд `-trimHarness`: WAV на 3 минуты, похожий на музыку (удары, бас, секции разной громкости) —
// чтобы на волне было что разглядеть. Пишется один раз во временную папку.
enum RingbackTrimHarness {
    static func makeTrack() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trim-harness-v2.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 22_050, seconds = 180
        var pcm = Data(capacity: rate * seconds * 2)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(rate * seconds) {
            let t = Double(i) / Double(rate)
            // «куплет — припев»: громкость секций меняется каждые 20 с, вступление тихое
            let section = [0.25, 0.55, 0.9, 0.5, 1.0, 0.6, 0.95, 0.45, 0.3][min(8, Int(t / 20))]
            let beat = t.truncatingRemainder(dividingBy: 0.5)            // удар каждые полсекунды
            let kick = exp(-beat * 18) * Double.random(in: -1...1, using: &rng)
            let bass = sin(2 * .pi * 55 * t) * (0.5 + 0.5 * sin(t * .pi / 4))
            let v = (kick * 0.7 + bass * 0.35) * section
            var s = Int16(max(-1, min(1, v)) * 30_000).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        try? (header + pcm).write(to: url)
        return url
    }
}
#endif
