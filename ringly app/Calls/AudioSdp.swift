import Foundation
import WebRTC

// Настройка аудио под плохую сеть (network-optimization.md, этап 3).
//
// До неё дорожка создавалась вообще без ограничений, а SDP не правился — Opus работал на дефолтах
// libwebrtc, то есть пакетами по 20 мс.
//
// Почему это дорого: заголовки IP+UDP+RTP+SRTP — около 50 байт на пакет. При 20 мс это 50 пакетов
// в секунду, то есть ≈20 кбит/с ОДНИХ заголовков — втрое больше, чем сам голос на минимальном
// битрейте Opus (6–8 кбит/с). При 60 мс заголовки дают ≈6,7 кбит/с: экономия больше, чем весь
// полезный поток. Это самый крупный рычаг в звонках, и он не требует ни своего кодека, ни смены
// архитектуры.
//
// ⚠️ Все четыре параметра описывают, что МЫ ХОТИМ ПОЛУЧАТЬ (RFC 7587): они попадают в наш SDP
// и управляют кодировщиком СОБЕСЕДНИКА. Поэтому выгода появляется сразу, даже если на той стороне
// старая версия приложения: libwebrtc честно соблюдает присланный `a=ptime` независимо от того,
// умеет ли сам клиент его выставлять.
enum AudioSdp {

    // Размер пакета. Цена — +40 мс к задержке в одну сторону; на фоне обычных 100–150 мс у WebRTC
    // это терпимо, а на плохой сети незаметно вовсе. Менять — здесь, одной константой.
    //
    // Адаптивно переключать ptime по качеству связи нельзя без пере-согласования (новый offer/answer
    // посреди разговора), а это заметно рискованнее, чем статическое значение. Если понадобится —
    // сначала померить по `quality()`, которая уже считает потери и джиттер.
    static let ptime = 60
    static let maxPtime = 120

    // Параметры fmtp для Opus.
    //   useinbandfec — избыточность внутри потока: потерянный пакет восстанавливается из следующего.
    //                  libwebrtc обычно ставит её сам, но полагаться на дефолт чужой библиотеки
    //                  в том, ради чего всё и делается, не стоит.
    //   usedtx       — не передавать тишину. В разговоре молчит примерно половина времени.
    //   stereo       — голосу не нужен, а стерео удвоило бы поток.
    //
    // Потолка битрейта здесь намеренно НЕТ. GCC и Opus сами уходят вниз при деградации, а статический
    // maxaveragebitrate только опустил бы верхнюю планку на хорошей связи — ровно тот вывод, к
    // которому пришли при работе над стабильностью звонков («динамические кодеки — не тот рычаг»).
    static let opusParams: [String: String] = [
        "useinbandfec": "1",
        "usedtx": "1",
        "stereo": "0"
    ]

    static func tuned(_ sdp: RTCSessionDescription) -> RTCSessionDescription {
        let result = tune(sdp.sdp)

        // В лог звонка — чтобы «применилось ли» проверялось фактом, а не верой. Строка fmtp и ptime
        // это ровно то, что нужно увидеть при ручной проверке.
        let marks = result.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("a=fmtp:") && $0.contains("usedtx") || $0.hasPrefix("a=ptime:") }
        CallDiag.log("🎚 аудио SDP: \(marks.joined(separator: " | "))")

        return RTCSessionDescription(type: sdp.type, sdp: result)
    }

    // Правка текста SDP. Отдельной чистой функцией — чтобы её можно было прочитать и проверить
    // без поднятия соединения.
    static func tune(_ sdp: String) -> String {
        // libwebrtc отдаёт CRLF, но полагаться на это не будем: разделитель определяем по факту
        // и им же собираем обратно, иначе получим один склеенный «кадр» вместо строк.
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)

        // Границы аудио-секции: правки не должны затрагивать видео.
        guard let audioStart = lines.firstIndex(where: { $0.hasPrefix("m=audio") }) else { return sdp }
        var audioEnd = lines[(audioStart + 1)...].firstIndex(where: { $0.hasPrefix("m=") })
            ?? lines.endIndex

        // Номер payload-типа Opus берём из rtpmap: он динамический и не обязан быть 111.
        guard let rtpmapIndex = lines[audioStart..<audioEnd].firstIndex(where: {
            $0.lowercased().contains(" opus/48000")
        }) else { return sdp }
        let payloadType = String(lines[rtpmapIndex]
            .dropFirst("a=rtpmap:".count)
            .prefix(while: { $0.isNumber }))
        guard !payloadType.isEmpty else { return sdp }

        // Прежние ptime/maxptime убираем: два значения в одной секции — неопределённое поведение.
        // Идём с конца, иначе удаление сдвигает ещё не пройденные индексы.
        if audioEnd > audioStart + 1 {
            for i in stride(from: audioEnd - 1, through: audioStart + 1, by: -1)
            where lines[i].hasPrefix("a=ptime:") || lines[i].hasPrefix("a=maxptime:") {
                lines.remove(at: i)
                audioEnd -= 1
            }
        }

        let fmtpPrefix = "a=fmtp:\(payloadType) "
        let newFmtp = fmtpPrefix + merged(
            existing: lines[audioStart..<audioEnd].first { $0.hasPrefix(fmtpPrefix) }
                .map { String($0.dropFirst(fmtpPrefix.count)) }
        )

        if let fmtpIndex = lines[audioStart..<audioEnd].firstIndex(where: { $0.hasPrefix(fmtpPrefix) }) {
            lines[fmtpIndex] = newFmtp
            lines.insert(contentsOf: ["a=ptime:\(ptime)", "a=maxptime:\(maxPtime)"], at: fmtpIndex + 1)
        } else if let rtpmap = lines[audioStart..<audioEnd].firstIndex(where: {
            $0.lowercased().contains(" opus/48000")
        }) {
            lines.insert(contentsOf: [newFmtp, "a=ptime:\(ptime)", "a=maxptime:\(maxPtime)"], at: rtpmap + 1)
        }

        return lines.joined(separator: separator)
    }

    // Дописываем свои параметры к тем, что libwebrtc уже поставил (например minptime), не затирая их:
    // слепая замена строки убрала бы согласованные значения, о которых мы не знаем.
    private static func merged(existing: String?) -> String {
        var params: [(String, String)] = []
        var seen = Set<String>()

        for pair in (existing ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let key = parts.first, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            params.append((key, opusParams[key] ?? value))
            seen.insert(key)
        }

        for (key, value) in opusParams.sorted(by: { $0.key < $1.key }) where !seen.contains(key) {
            params.append((key, value))
        }

        return params.map { $0.1.isEmpty ? $0.0 : "\($0.0)=\($0.1)" }.joined(separator: ";")
    }
}
