import Foundation

// Пользовательские настройки звонков. ЛОКАЛЬНЫЕ — сервер о выборе не знает и знать не должен,
// как чёрный список и мьюты. Никаких новых полей в профиле.
enum CallSettings {
    private static let relayOnlyKey = "calls.relayOnly"

    // «Звонить через сервер»: в SDP уходят ТОЛЬКО relay-кандидаты, поэтому собеседник не видит наш IP.
    //
    // Важно про семантику (она контринтуитивна): настройка прячет НАШ адрес от собеседника,
    // но НЕ прячет его адрес от нас — его кандидаты приходят в его SDP независимо от нашей настройки.
    // Тексты в UI обязаны говорить именно это, иначе обещание получится ложным.
    //
    // Медиа при этом остаётся E2EE: TURN пересылает уже зашифрованный DTLS-SRTP и содержимое не видит.
    // По умолчанию ВЫКЛЮЧЕНО: relay для всех — это весь медиатрафик через наш coturn, в том числе
    // для тех, кого раскрытие IP не волнует.
    static var relayOnly: Bool {
        get { UserDefaults.standard.bool(forKey: relayOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: relayOnlyKey) }
    }

    private static let simulateBlockKey = "calls.simulateBlock"

    // Скрытое меню → «Имитировать блокировку звонков»: худший случай для РФ — центральный TURN
    // недоступен и прямое соединение не проходит, звонок может идти ТОЛЬКО через волонтёрский TURN
    // (GET /relays/turn-pair). Нет волонтёрских — звонок честно не соединяется. DPI так не воспроизвести.
    static var simulateBlock: Bool {
        get { UserDefaults.standard.bool(forKey: simulateBlockKey) }
        set { UserDefaults.standard.set(newValue, forKey: simulateBlockKey) }
    }

    // Пускать в SDP только relay-кандидаты: по выбору пользователя или при имитации блокировки.
    static var mustRelay: Bool { relayOnly || simulateBlock }
}
