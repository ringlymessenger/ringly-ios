import Foundation
import CloudKit
import CryptoKit
import UIKit
import BackgroundTasks
import Combine

// Резервная копия переписки в iCloud пользователя (docs/icloud-backup.md). Этапы 1–3: ключ, текст,
// служебные данные (ключи профилей контактов, блок-лист, мьют, свои имена, прочитанность), медиа,
// восстановление.
//
// Где: CloudKit, private database, своя зона на каждый аккаунт Ringly (на одном Apple ID бывает
// несколько аккаунтов). Всё содержимое — AES-GCM ключом из BackupKeys, имена записей — HMAC: Apple
// видит только число записей, размеры и время.
//
// ⚠️ ГЛАВНЫЙ ИНВАРИАНТ: копию пишет устройство, у которого есть ВСЯ история — оно её создало или
// восстановило из копии (флаг baseSynced). Иначе свежее устройство после входа (или то же самое
// после «Выйти», у него прежний protocolDeviceId!) перезаписало бы копию своей пустой историей.
// Писатель один (Manifest.writerDeviceId), как у WhatsApp и Signal; забрать роль = сначала слить
// чужую копию в себя, потом писать.

struct BackupManifest: Codable {
    var v = 1
    var writerDeviceId: Int
    var writerName: String
    var updatedAt: Int64                  // мс
    var messageCount: Int
    var segments: [String: Entry]         // ключ сегмента → запись
    var media: [String: MediaEntry]? = nil   // attachmentId → файл; nil в манифестах до этапа 3

    struct Entry: Codable, Equatable {
        var record: String                // имя записи CloudKit (HMAC)
        var sha: String                   // SHA-256 открытого содержимого — понять, менялся ли сегмент
        var count: Int
    }

    // Файл заливается один раз: содержимое по attachmentId не меняется
    struct MediaEntry: Codable, Equatable {
        var record: String
        var ext: String
        var bytes: Int
        var video: Bool
    }
}

struct BackupMediaProgress: Equatable {
    var done: Int
    var total: Int
    var downloading: Bool
}

struct BackupSummary: Equatable {
    var messages: Int
    var mediaFiles: Int
    var mediaBytes: Int
}

// всё, кроме сообщений: без ключей профилей контактов на новом устройстве не видно ни имён, ни аватаров
struct BackupMeta: Codable {
    var v = 1
    var contactKeys: [String: String]
    var blocked: [ArchivedBlock]
    var muted: [String]
    var aliases: [String: String]
    var lastRead: [String: Int64]
}

enum BackupStatus: Equatable {
    case off
    case noAccount                        // нет входа в iCloud или iCloud выключен для Ringly
    case waitingPin(hasPin: Bool)         // нет halfB: ввести существующий PIN или задать новый
    case noKeychainKey                    // копия в iCloud есть, а halfA на это устройство не пришла
    case keyMismatch                      // копия зашифрована другим ключом (сменили PIN-копию на другом устройстве)
    case notRestored(count: Int)          // копия есть, но это устройство её не восстановило → не пишет
    case otherWriter(name: String, at: Date)
    case running
    case idle(last: Date?)
    case failed(String)
}

// Однократное напоминание о PIN (§2: у кого PIN нет — попросить задать; у кого PIN старого формата —
// ввести, чтобы в PIN-копию легла половина ключа). Дальше — только экран настроек.
enum BackupPinPrompt: String, Identifiable {
    case set, enter
    var id: String { rawValue }
}

@MainActor
final class ICloudBackup: ObservableObject {
    static let shared = ICloudBackup()
    nonisolated static let taskIdentifier = "com.reguzov.ringly.icloudBackup"

    @Published private(set) var status: BackupStatus = .idle(last: nil)
    @Published private(set) var restoring = false
    @Published var restoreResult: String?
    @Published private(set) var mediaProgress: BackupMediaProgress?
    @Published private(set) var summary: BackupSummary?
    @Published var pinPrompt: BackupPinPrompt?

    private let container = CKContainer(identifier: "iCloud.com.reguzov.ringly-app")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var loop: Task<Void, Never>?
    private var busy = false
    private var cellularOnce = false
    private var lastAttempt = Date.distantPast

    private static let everyWhileOpen: UInt64 = 30 * 60 * 1_000_000_000
    private static let batchSize = 20

    // ---- настройки и локальные флаги ----

    private enum Keys {
        static let enabled = "icloudBackup.enabled"          // настройка устройства, переживает выход
        static let baseSynced = "icloudBackup.baseSynced"    // ↓ флаги аккаунта: стираются при выходе
        static let claimWriter = "icloudBackup.claimWriter"
        static let lastAt = "icloudBackup.lastAt"
        static let offered = "icloudBackup.restoreOffered"
        static let mediaRestorePending = "icloudBackup.mediaRestorePending"
        static let pinPromptShown = "icloudBackup.pinPromptShown"
        static let needsNewPin = "icloudBackup.needsNewPin"     // после сброса: старый PIN забыт
    }
    private let defaults = UserDefaults.standard

    // по умолчанию включена (решение владельца, §2), в том числе у существующих пользователей
    var enabled: Bool { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
    private var baseSynced: Bool {
        get { defaults.bool(forKey: Keys.baseSynced) }
        set { defaults.set(newValue, forKey: Keys.baseSynced) }
    }
    private var claimWriter: Bool {
        get { defaults.bool(forKey: Keys.claimWriter) }
        set { defaults.set(newValue, forKey: Keys.claimWriter) }
    }
    // после восстановления: докачать файлы из копии (флаг, а не «всё, чего нет на устройстве», —
    // иначе вернулись бы и файлы, которые пользователь сам удалил в «Медиа и хранилище»)
    private var mediaRestorePending: Bool {
        get { defaults.bool(forKey: Keys.mediaRestorePending) }
        set { defaults.set(newValue, forKey: Keys.mediaRestorePending) }
    }
    private(set) var lastBackupAt: Date? {
        get { defaults.object(forKey: Keys.lastAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastAt) }
    }

    // ---- жизненный цикл (из AppViewModel) ----

    // вход выполнен и мы на главной: проверить, есть ли что восстановить, и делать копию раз в 30 мин
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)   // не мешать старту приложения
            while !Task.isCancelled, let self {
                await self.restoreIfAvailable()
                await self.backupNow()
                try? await Task.sleep(nanoseconds: Self.everyWhileOpen)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // уход в фон: досдать изменения, пока система даёт время, и запланировать ночную задачу
    func backupInBackground() {
        schedule()
        guard enabled, Date().timeIntervalSince(lastAttempt) > 120 else { return }
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "icloudBackup") {
            UIApplication.shared.endBackgroundTask(taskId)
        }
        Task {
            // фоновое время ~30 с: медиа — сколько успеет, остальное доделает ночная задача
            await backupNow(mediaDeadline: Date().addingTimeInterval(20))
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    // «Выйти»: копию в iCloud НЕ трогаем — ради этого она и есть; стираем только своё на устройстве
    func resetForLogout() {
        stop()
        for key in [Keys.baseSynced, Keys.claimWriter, Keys.lastAt, Keys.offered, Keys.mediaRestorePending, Keys.pinPromptShown, Keys.needsNewPin] {
            defaults.removeObject(forKey: key)
        }
        summary = nil
        BackupKeys.clearLocal()
        status = .idle(last: nil)
    }

    // Дата копии переписки, сделанной ЭТИМ устройством, — от неё зависит, что честно сказать при
    // выходе: «удалится навсегда» неправда, если история лежит в iCloud. Рабочая копия означает и
    // PIN-копию (половина ключа сохраняется только после того, как сервер принял PIN-копию,
    // ProfileKeyBackupService.save) — значит, после выхода она вернётся по PIN-коду.
    var savedCopyDate: Date? {
        guard enabled, baseSynced else { return nil }
        return lastBackupAt
    }

    // Досохранить копию перед выходом — иначе пропали бы сообщения новее последней копии (выход
    // стирает историю с устройства, а доставленное сервер уже удалил). Только текст: медиа может
    // качаться минутами, его доделает следующий вход. false — сохранить не вышло, выход решает
    // пользователь (молча выйти значило бы молча потерять переписку).
    func backupBeforeLogout() async -> Bool {
        guard savedCopyDate != nil else { return true }   // копии нет — и беречь нечего
        // идущую копию дожидаемся (до 20 с): параллельно запустить вторую нельзя
        var waited = 0
        while busy && waited < 100 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        guard !busy else { return false }
        let before = lastBackupAt
        await backupNow(mediaDeadline: Date())
        // копию ведёт другое устройство этого аккаунта — сообщения у него те же, она и так полная
        if case .otherWriter = status { return true }
        return lastBackupAt != before
    }

    // ---- фоновая задача (раз в сутки) ----

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            Task { @MainActor in
                ICloudBackup.shared.schedule()
                let work = Task { await ICloudBackup.shared.backupNow() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    private func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = BackupMediaSettings.chargingOnly
        request.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // ---- настройки (экран ICloudBackupView) ----

    func setEnabled(_ on: Bool, deleteRemote: Bool = false) async {
        defaults.set(on, forKey: Keys.enabled)
        if on {
            start()
            await backupNow()
        } else {
            stop()
            if deleteRemote { await deleteRemoteCopy() }
            status = .off
        }
    }

    // Удаление аккаунта и «удалить копию из iCloud»: зона целиком — только этого аккаунта
    func deleteRemoteCopy() async {
        guard let userId = AuthState.myUserId else { return }
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID(userId)])
        } catch let e as CKError where e.code == .zoneNotFound {
            // и так нет
        } catch {
            CallDiag.log("☁️ копия в iCloud не удалена: \(Self.describe(error))")
            return
        }
        baseSynced = false
        lastBackupAt = nil
    }

    // Онбординг уже предложил задать PIN — второй раз подряд о том же не спрашиваем
    func markPinPromptShown() {
        defaults.set(true, forKey: Keys.pinPromptShown)
    }

    private func promptPinOnce(hasPin: Bool) {
        guard !defaults.bool(forKey: Keys.pinPromptShown) else { return }
        defaults.set(true, forKey: Keys.pinPromptShown)
        pinPrompt = hasPin ? .enter : .set
    }

    // «Сбросить копию» (забыли PIN, копия с чужим ключом, Связка ключей потеряна): старая копия
    // удаляется целиком, ключ — новый (обе половины), новая копия создаётся из истории ЭТОГО
    // устройства после того, как задан новый PIN. Необратимо — только по явному подтверждению.
    func resetCopy() async {
        guard !busy, let userId = AuthState.myUserId else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID(userId)])
        } catch let e as CKError where e.code == .zoneNotFound {
            // копии и так нет
        } catch {
            CallDiag.log("☁️ сброс копии не удался: \(Self.describe(error))")
            status = Self.statusFor(error)
            return
        }
        _ = BackupKeys.replaceHalfA(userId: userId)
        BackupKeys.removeHalfB(userId: userId)
        baseSynced = false
        claimWriter = false
        mediaRestorePending = false
        lastBackupAt = nil
        defaults.set(true, forKey: Keys.offered)   // восстанавливать больше нечего
        defaults.set(true, forKey: Keys.needsNewPin)
        summary = nil
        status = .waitingPin(hasPin: false)
        CallDiag.log("☁️ копия сброшена, ждём новый PIN")
    }

    // «Делать копию на этом устройстве»: при следующем проходе слить чужую копию в себя и стать писателем
    func takeOverWriting() async {
        claimWriter = true
        await backupNow()
    }

    // Состояние для экрана настроек, без записи
    func refreshStatus() async {
        guard !busy else { return }
        guard enabled else { status = .off; return }
        guard let userId = AuthState.myUserId else { return }
        switch await prepare(userId: userId, creating: false) {
        case .stop(let s):
            status = s
        case .ready(_, let manifest):
            status = evaluate(manifest)
            summary = manifest.map(Self.summary)
        }
    }

    // Медиа исключили настройкой (или снизили лимит) и согласились удалить: убрать из копии то, что
    // больше не подходит. Только писатель — копию меняет одно устройство.
    func pruneMedia() async {
        guard !busy, let userId = AuthState.myUserId,
              case .ready(let ctx, var manifest?) = await prepare(userId: userId, creating: false),
              baseSynced, manifest.writerDeviceId == DeviceIdentity.protocolDeviceId else { return }
        busy = true
        defer { busy = false }

        var media = manifest.media ?? [:]
        let drop = media.filter { !BackupMediaSettings.wants(isVideo: $0.value.video, bytes: $0.value.bytes) }
        guard !drop.isEmpty else { return }
        do {
            try await deleteRecords(drop.values.map { CKRecord.ID(recordName: $0.record, zoneID: ctx.zoneID) })
            for key in drop.keys { media[key] = nil }
            manifest.media = media
            try await save([try Self.manifestRecord(ctx, manifest)])
            summary = Self.summary(manifest)
            CallDiag.log("☁️ копия: убрано медиа по настройкам — \(drop.count) файлов")
        } catch {
            CallDiag.log("☁️ копия: медиа не убраны: \(Self.describe(error))")
        }
    }

    // ---- выгрузка ----

    // mediaDeadline — сколько можно потратить на медиа (уход в фон даёт ~30 с); nil — пока не отменят
    // cellularMedia — разовое разрешение медиа по сотовой сети (алерт у «Создать копию сейчас»);
    // настройка при этом не меняется
    func backupNow(force: Bool = false, mediaDeadline: Date? = nil, cellularMedia: Bool = false) async {
        guard enabled, !busy, !restoring, let userId = AuthState.myUserId else { return }
        busy = true
        cellularOnce = cellularMedia
        defer { cellularOnce = false }
        lastAttempt = Date()
        status = .running
        defer { busy = false }

        let ctx: Context
        var manifest: BackupManifest?
        switch await prepare(userId: userId, creating: true) {
        case .stop(let s):
            status = s
            if case .waitingPin(let hasPin) = s { promptPinOnce(hasPin: hasPin) }
            return
        case .ready(let c, let m):
            ctx = c
            manifest = m
        }

        var snapshot = Snapshot()
        do {
            if let m = manifest {
                let me = DeviceIdentity.protocolDeviceId
                if claimWriter {
                    _ = try await importAll(ctx, manifest: m)       // сначала всё чужое — к себе
                    baseSynced = true
                    claimWriter = false
                    mediaRestorePending = true                      // и файлы того устройства
                } else if !baseSynced {
                    status = .notRestored(count: m.messageCount)
                    return
                } else if m.writerDeviceId != me {
                    status = .otherWriter(name: m.writerName, at: Self.date(m.updatedAt))
                    return
                }
            } else {
                baseSynced = true                                   // копии нет — создаём её мы
            }

            // На главном потоке, как и экспорт history-sync: хранилища в этом таргете изолированы
            // главным актором. Выносить в фон — только вместе с ними.
            snapshot = Self.snapshot()

            // Страховка поверх инварианта: резкое уменьшение истории — скорее сбой, чем намерение.
            // Ручная кнопка «Создать копию сейчас» (force) её обходит.
            if let m = manifest, !force, m.messageCount > 20, snapshot.messageCount < m.messageCount / 2 {
                status = .failed(L("Копия не обновлена: на устройстве намного меньше сообщений, чем в копии. Нажмите «Создать копию сейчас», если так и задумано."))
                return
            }

            var entries: [String: BackupManifest.Entry] = [:]
            var changed: [CKRecord] = []
            for (key, segment) in snapshot.segments {
                let name = Self.recordName(ctx, "seg|\(key)")
                let sha = Self.sha(segment.data)
                entries[key] = .init(record: name, sha: sha, count: segment.count)
                if manifest?.segments[key]?.sha == sha { continue }
                changed.append(try Self.segmentRecord(ctx, name: name, plaintext: segment.data))
            }
            let removed = (manifest?.segments ?? [:])
                .filter { entries[$0.key] == nil }
                .map { CKRecord.ID(recordName: $0.value.record, zoneID: ctx.zoneID) }

            // порядок важен: сегменты → манифест → удаление лишнего. Оборвались посередине — манифест
            // всё равно указывает только на существующие записи
            for batch in changed.chunked(Self.batchSize) { try await save(batch) }
            manifest = BackupManifest(
                writerDeviceId: DeviceIdentity.protocolDeviceId,
                writerName: UIDevice.current.name,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                messageCount: snapshot.messageCount,
                segments: entries,
                media: manifest?.media)
            try await save([try Self.manifestRecord(ctx, manifest!)])
            try await deleteRecords(removed)
            Self.cleanupTemp()

            lastBackupAt = Date()
            CallDiag.log("☁️ копия: \(changed.count) сегм. обновлено, \(removed.count) удалено, всего \(snapshot.messageCount) сообщений")
        } catch {
            Self.cleanupTemp()
            status = Self.statusFor(error)
            CallDiag.log("☁️ копия не сделана: \(Self.describe(error))")
            return
        }

        // Медиа — после текста: текст важнее и уже сохранён, сбой здесь его не отменяет
        var current = manifest!
        do {
            if mediaRestorePending {
                try await restoreMedia(ctx, manifest: current, inventory: snapshot.media, deadline: mediaDeadline)
            }
            try await backupMedia(ctx, manifest: &current, inventory: snapshot.media, deadline: mediaDeadline)
            status = .idle(last: lastBackupAt)
        } catch {
            status = Self.statusFor(error)
            CallDiag.log("☁️ медиа в копию не ушли: \(Self.describe(error))")
        }
        Self.cleanupTemp()
        mediaProgress = nil
        summary = Self.summary(current)
    }

    // ---- медиа (этап 3) ----

    // От новых к старым. Пишутся только файлы, которые есть на устройстве: не скачанное (выключенная
    // автозагрузка) в копию не попадёт, пока его не открыли.
    private func backupMedia(_ ctx: Context, manifest: inout BackupManifest,
                             inventory: [String: LocalMedia], deadline: Date?) async throws {
        var media = manifest.media ?? [:]

        // файлы удалённых сообщений — из копии тоже (писатель держит всю историю, см. инвариант)
        let stale = media.filter { inventory[$0.key] == nil }
        if !stale.isEmpty {
            try await deleteRecords(stale.values.map { CKRecord.ID(recordName: $0.record, zoneID: ctx.zoneID) })
            for key in stale.keys { media[key] = nil }
            manifest.media = media
            try await save([try Self.manifestRecord(ctx, manifest)])
        }

        guard mediaNetworkAllowed, BackupMediaSettings.powerAllowed else { return }
        let queue = inventory.values
            .filter { media[$0.ref.attachmentId] == nil
                && BackupMediaSettings.wants(isVideo: $0.ref.isVideo, bytes: $0.ref.bytes)
                && MediaStore.exists($0.ref.attachmentId, ext: $0.ref.fileExtension) }
            .sorted { $0.sentAt > $1.sentAt }
        guard !queue.isEmpty else { return }

        var unsaved = 0
        defer { mediaProgress = nil }
        for (i, item) in queue.enumerated() {
            if Task.isCancelled || deadline.map({ Date() > $0 }) == true { break }
            guard mediaNetworkAllowed, BackupMediaSettings.powerAllowed else { break }
            mediaProgress = .init(done: i, total: queue.count, downloading: false)

            let id = item.ref.attachmentId
            let ext = item.ref.fileExtension
            let plain = try Data(contentsOf: MediaStore.file(id, ext: ext))
            let name = Self.recordName(ctx, "media|\(id)")
            try await save([try Self.mediaRecord(ctx, name: name, attachmentId: id, plaintext: plain)], media: true)
            try? FileManager.default.removeItem(at: Self.tempDirectory.appendingPathComponent(name))
            media[id] = .init(record: name, ext: ext, bytes: plain.count, video: item.ref.isVideo)

            // манифест — каждые 5 файлов: оборвались посередине — залитое не заливаем снова
            unsaved += 1
            if unsaved >= 5 {
                manifest.media = media
                try await save([try Self.manifestRecord(ctx, manifest)])
                unsaved = 0
            }
        }
        manifest.media = media
        if unsaved > 0 { try await save([try Self.manifestRecord(ctx, manifest)]) }
        CallDiag.log("☁️ медиа: в копии \(media.count) файлов")
    }

    // После восстановления: докачать файлы из копии, от новых к старым. До загрузки в ленте видны
    // миниатюры — они и так лежат внутри сообщений.
    private func restoreMedia(_ ctx: Context, manifest: BackupManifest,
                              inventory: [String: LocalMedia], deadline: Date?) async throws {
        let missing = (manifest.media ?? [:])
            .filter { !MediaStore.exists($0.key, ext: $0.value.ext) }
            .sorted { (inventory[$0.key]?.sentAt ?? 0) > (inventory[$1.key]?.sentAt ?? 0) }
        guard !missing.isEmpty else { mediaRestorePending = false; return }
        guard mediaNetworkAllowed else { return }

        var done = 0
        defer { mediaProgress = nil }
        for (id, entry) in missing {
            if Task.isCancelled || deadline.map({ Date() > $0 }) == true { break }
            guard mediaNetworkAllowed else { break }
            mediaProgress = .init(done: done, total: missing.count, downloading: true)

            let record: CKRecord
            do {
                record = try await fetchMedia(CKRecord.ID(recordName: entry.record, zoneID: ctx.zoneID))
            } catch let e as CKError where e.code == .unknownItem {
                done += 1
                continue                                  // файла в копии нет — не повод останавливаться
            }
            guard let asset = record["blob"] as? CKAsset, let url = asset.fileURL else { done += 1; continue }
            let plain = try Self.openMedia(ctx, name: entry.record, attachmentId: id, sealed: try Data(contentsOf: url))
            // та же проверка, что при скачивании с сервера: в ленту попадает только то, что отправил автор
            if let ref = inventory[id]?.ref, Data(SHA256.hash(data: plain)).base64EncodedString() != ref.sha256 {
                CallDiag.log("☁️ медиа: контрольная сумма файла не совпала, пропущено")
                done += 1
                continue
            }
            _ = try MediaStore.write(plain, attachmentId: id, ext: entry.ext)
            done += 1
            if done % 10 == 0 { NotificationCenter.default.post(name: .pushNewMessage, object: nil) }
        }
        if done == missing.count { mediaRestorePending = false }
        NotificationCenter.default.post(name: .pushNewMessage, object: nil)   // баблы подхватят файлы
        CallDiag.log("☁️ медиа: восстановлено \(done) из \(missing.count)")
    }

    // ---- восстановление ----

    // Один раз за вход: если в iCloud есть копия, а это устройство её не восстанавливало — восстановить
    // сразу и молча. Раньше спрашивали алертом, но вопрос странный: отказываться от собственной
    // переписки незачем. Прогресс тоже не показываем — история появляется вся разом (importAll).
    func restoreIfAvailable() async {
        guard enabled, !baseSynced, !restoring, !defaults.bool(forKey: Keys.offered),
              let userId = AuthState.myUserId else { return }
        guard case .ready(_, _?) = await prepare(userId: userId, creating: false) else { return }
        await restore()
    }

    func restore() async {
        defaults.set(true, forKey: Keys.offered)
        guard !restoring, let userId = AuthState.myUserId else { return }
        restoring = true
        defer { restoring = false }

        guard case .ready(let ctx, let manifest?) = await prepare(userId: userId, creating: false) else {
            restoreResult = L("Копия в iCloud не найдена")
            return
        }
        do {
            let inserted = try await importAll(ctx, manifest: manifest)
            baseSynced = true
            claimWriter = true              // восстановили → это устройство теперь пишет копию (§6)
            mediaRestorePending = true      // файлы — следующим проходом, в фоне
            CallDiag.log("☁️ восстановлено \(inserted) сообщений из \(manifest.messageCount)")
        } catch {
            restoreResult = L("Не удалось восстановить переписку. Попробуйте позже в Профиль → Копия в iCloud.")
            CallDiag.log("☁️ восстановление не удалось: \(Self.describe(error))")
            return
        }
        await backupNow()
    }

    // Скачать все сегменты и импортировать ОДНОЙ записью (дедуп — в ChatStore.importArchive по
    // serverMessageId). Раньше каждый сегмент «беседа × месяц» писался отдельно, и список чатов
    // пересортировывался после каждого — чаты скакали, пока шло восстановление.
    private func importAll(_ ctx: Context, manifest: BackupManifest) async throws -> Int {
        var messages: [LocalMessage] = []
        var meta: BackupMeta?
        let all = Array(manifest.segments)
        for batch in all.chunked(Self.batchSize) {
            let ids = batch.map { CKRecord.ID(recordName: $0.value.record, zoneID: ctx.zoneID) }
            let results = try await database.records(for: ids)
            for (key, entry) in batch {
                let id = CKRecord.ID(recordName: entry.record, zoneID: ctx.zoneID)
                // одна недоступная запись не должна отменять всё восстановление
                guard let record = try? results[id]?.get(),
                      let asset = record["blob"] as? CKAsset, let url = asset.fileURL else { continue }
                let plain = try Self.open(ctx, name: entry.record, sealed: try Data(contentsOf: url))
                if key == "meta" {
                    meta = try JSONDecoder().decode(BackupMeta.self, from: plain)
                } else {
                    messages += try JSONDecoder().decode([LocalMessage].self, from: plain)
                }
            }
        }
        let inserted = ChatStore.importArchive(messages)
        if let meta {
            Self.apply(meta)
            for userId in meta.contactKeys.keys { ContactProfileCache.shared.refresh(userId) }   // имена и аватары
        }

        NotificationCenter.default.post(name: .pushNewMessage, object: nil)   // чаты перечитают историю
        BlockState.shared.reload()

        return inserted
    }

    // ---- подготовка: ключ, зона, манифест ----

    private struct Context {
        let userId: String
        let keys: BackupKeys.Derived
        let zoneID: CKRecordZone.ID
    }

    private enum Prepared {
        case ready(Context, BackupManifest?)
        case stop(BackupStatus)
    }

    private func prepare(userId: String, creating: Bool) async -> Prepared {
        do {
            guard try await container.accountStatus() == .available else { return .stop(.noAccount) }
            guard let halfB = BackupKeys.halfB(userId: userId) else {
                // после сброса на сервере ещё лежит PIN-копия со старым PIN — но его как раз забыли
                let hasPin = defaults.bool(forKey: Keys.needsNewPin)
                    ? false
                    : await ProfileKeyBackupService().backupExists() ?? true
                return .stop(.waitingPin(hasPin: hasPin))
            }
            defaults.removeObject(forKey: Keys.needsNewPin)          // новый PIN задан

            let zoneID = Self.zoneID(userId)
            let zoneExists = try await zoneExists(zoneID)
            let halfA: Data
            if let existing = BackupKeys.halfA(userId: userId) {
                halfA = existing
            } else if zoneExists {
                return .stop(.noKeychainKey)       // не создавать новую: затрём ключ существующей копии
            } else if creating {
                halfA = BackupKeys.createHalfA(userId: userId)
            } else {
                return .stop(.idle(last: nil))     // копии нет и ключа нет — восстанавливать нечего
            }

            let ctx = Context(userId: userId,
                              keys: BackupKeys.derive(halfA: halfA, halfB: halfB, userId: userId),
                              zoneID: zoneID)
            if !zoneExists {
                if creating { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
                return .ready(ctx, nil)
            }
            return .ready(ctx, try await fetchManifest(ctx))
        } catch BackupFailure.keyMismatch {
            return .stop(.keyMismatch)
        } catch {
            CallDiag.log("☁️ копия: подготовка не удалась: \(Self.describe(error))")
            return .stop(Self.statusFor(error))
        }
    }

    private func evaluate(_ manifest: BackupManifest?) -> BackupStatus {
        guard let m = manifest else { return .idle(last: nil) }
        if !baseSynced { return .notRestored(count: m.messageCount) }
        if m.writerDeviceId != DeviceIdentity.protocolDeviceId {
            return .otherWriter(name: m.writerName, at: Self.date(m.updatedAt))
        }
        return .idle(last: lastBackupAt ?? Self.date(m.updatedAt))
    }

    private func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        do {
            _ = try await database.recordZone(for: zoneID)
            return true
        } catch let e as CKError where e.code == .zoneNotFound || e.code == .unknownItem {
            return false
        }
    }

    private func fetchManifest(_ ctx: Context) async throws -> BackupManifest? {
        let name = Self.recordName(ctx, "manifest")
        let record: CKRecord
        do {
            record = try await database.record(for: CKRecord.ID(recordName: name, zoneID: ctx.zoneID))
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        }
        guard let sealed = record["data"] as? Data else { return nil }
        guard let plain = try? Self.open(ctx, name: name, sealed: sealed) else { throw BackupFailure.keyMismatch }
        return try JSONDecoder().decode(BackupManifest.self, from: plain)
    }

    // media: true — тяжёлые файлы: сотовая сеть только если разрешена в настройках копии
    private func save(_ records: [CKRecord], media: Bool = false) async throws {
        guard !records.isEmpty else { return }
        // имена записей детерминированы → перезаписываем на месте, без сверки версий
        let (results, _) = try await database.configuredWith(configuration: self.configuration(media: media)) { db in
            try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        }
        for (_, result) in results { _ = try result.get() }
    }

    private func fetchMedia(_ id: CKRecord.ID) async throws -> CKRecord {
        try await database.configuredWith(configuration: self.configuration(media: true)) { db in
            try await db.record(for: id)
        }
    }

    private func deleteRecords(_ ids: [CKRecord.ID]) async throws {
        for batch in ids.chunked(Self.batchSize) {
            _ = try await database.modifyRecords(saving: [], deleting: batch)
        }
    }

    private var mediaNetworkAllowed: Bool { BackupMediaSettings.networkAllowed || cellularOnce }

    // для алерта у «Создать копию сейчас»: медиа сейчас не уйдут — нет Wi-Fi, а сотовая выключена
    var mediaBlockedByNetwork: Bool { BackupMediaSettings.mode != .none && !BackupMediaSettings.networkAllowed }

    private func configuration(media: Bool) -> CKOperation.Configuration {
        let config = CKOperation.Configuration()
        config.allowsCellularAccess = !media || BackupMediaSettings.cellular || cellularOnce
        config.qualityOfService = media ? .utility : .userInitiated
        return config
    }

    // ---- содержимое ----

    private struct Snapshot {
        var segments: [String: (data: Data, count: Int)] = [:]
        var messageCount = 0
        var media: [String: LocalMedia] = [:]
    }

    // медиафайл, на который ссылается хоть одно сообщение (пересланное — тот же attachmentId)
    private struct LocalMedia {
        let ref: MediaRef
        let sentAt: Int64
    }

    // Текст бьётся на сегменты «беседа × месяц»: новое сообщение перезаливает только текущий месяц
    private static func snapshot() -> Snapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys          // стабильный вывод → сравнение по SHA работает
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.timeZone = TimeZone(identifier: "UTC")
        month.dateFormat = "yyyy-MM"

        var out = Snapshot()
        for (conversationId, messages) in ChatStore.exportByConversation() {
            let byMonth = Dictionary(grouping: messages) {
                month.string(from: Date(timeIntervalSince1970: TimeInterval($0.sentAt) / 1000))
            }
            for (m, list) in byMonth {
                guard let data = try? encoder.encode(list) else { continue }
                out.segments["c|\(conversationId)|\(m)"] = (data, list.count)
                out.messageCount += list.count
            }
            for message in messages where message.kind == "media" {
                for ref in MediaRef.decodeList(message.text) where !ref.isPending {
                    let known = out.media[ref.attachmentId]
                    if known == nil || known!.sentAt < message.sentAt {
                        out.media[ref.attachmentId] = LocalMedia(ref: ref, sentAt: message.sentAt)
                    }
                }
            }
        }

        let meta = BackupMeta(
            contactKeys: ContactKeyStore.allKeys(),
            blocked: BlockStore.all().map { ArchivedBlock(userId: $0.userId, username: $0.username) },
            muted: MuteStore.all(),
            aliases: ContactProfileStore.allAliases(),
            lastRead: ReadStore.allLastRead())
        if let data = try? encoder.encode(meta) { out.segments["meta"] = (data, 0) }

        return out
    }

    private static func apply(_ meta: BackupMeta) {
        for (userId, key) in meta.contactKeys where !ContactKeyStore.has(userId) {
            ContactKeyStore.save(userId: userId, profileKeyBase64: key)
        }
        for b in meta.blocked { BlockStore.setBlocked(b.userId, username: b.username, blocked: true) }
        for userId in meta.muted { MuteStore.setMuted(userId, muted: true) }
        for (userId, name) in meta.aliases where ContactProfileStore.alias(userId) == nil {
            ContactProfileStore.setAlias(userId, name)
        }
        ReadStore.importLastRead(meta.lastRead)
    }

    // ---- крипта и форматы записей ----

    // Порядок строго «сжать → зашифровать» (шифртекст не сжимается), как в копиях Signal.
    // AAD = имя записи: содержимое одной записи нельзя незаметно подсунуть под другую.
    private static func seal(_ ctx: Context, name: String, plaintext: Data) throws -> Data {
        let compressed = try (plaintext as NSData).compressed(using: .zlib) as Data
        guard let sealed = try AES.GCM.seal(compressed, using: ctx.keys.encryption,
                                            authenticating: Data(name.utf8)).combined else {
            throw BackupFailure.encryption
        }
        return sealed
    }

    private static func open(_ ctx: Context, name: String, sealed: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let compressed = try AES.GCM.open(box, using: ctx.keys.encryption, authenticating: Data(name.utf8))
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }

    // текст — файлом (CKAsset): у полей записи потолок 1 МБ, а месяц активного чата может быть больше
    private static func segmentRecord(_ ctx: Context, name: String, plaintext: Data) throws -> CKRecord {
        let url = tempDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try seal(ctx, name: name, plaintext: plaintext).write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        let record = CKRecord(recordType: "Segment", recordID: CKRecord.ID(recordName: name, zoneID: ctx.zoneID))
        record["blob"] = CKAsset(fileURL: url)
        return record
    }

    // Ключ файла выводится из ключа копии и attachmentId: хранить его не нужно, файл заливается один раз.
    // Без сжатия — фото и видео и так сжаты.
    private static func mediaKey(_ ctx: Context, _ attachmentId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ctx.keys.encryption,
                               info: Data("media|\(attachmentId)".utf8), outputByteCount: 32)
    }

    private static func mediaRecord(_ ctx: Context, name: String, attachmentId: String, plaintext: Data) throws -> CKRecord {
        guard let sealed = try AES.GCM.seal(plaintext, using: mediaKey(ctx, attachmentId),
                                            authenticating: Data(name.utf8)).combined else {
            throw BackupFailure.encryption
        }
        let url = tempDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try sealed.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        let record = CKRecord(recordType: "Media", recordID: CKRecord.ID(recordName: name, zoneID: ctx.zoneID))
        record["blob"] = CKAsset(fileURL: url)
        return record
    }

    private static func openMedia(_ ctx: Context, name: String, attachmentId: String, sealed: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: mediaKey(ctx, attachmentId), authenticating: Data(name.utf8))
    }

    private static func summary(_ manifest: BackupManifest) -> BackupSummary {
        let media = manifest.media ?? [:]
        return BackupSummary(messages: manifest.messageCount, mediaFiles: media.count,
                             mediaBytes: media.values.reduce(0) { $0 + $1.bytes })
    }

    private static func manifestRecord(_ ctx: Context, _ manifest: BackupManifest) throws -> CKRecord {
        let name = recordName(ctx, "manifest")
        let record = CKRecord(recordType: "Manifest", recordID: CKRecord.ID(recordName: name, zoneID: ctx.zoneID))
        record["data"] = try seal(ctx, name: name, plaintext: try JSONEncoder().encode(manifest)) as NSData
        return record
    }

    private static var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("icloud-backup", isDirectory: true)
    }

    private static func cleanupTemp() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private static func recordName(_ ctx: Context, _ label: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: ctx.keys.naming)).hex
    }

    // Зона — по userId, а не по ключу: найти копию нужно ДО того, как решать, можно ли создать halfA
    private static func zoneID(_ userId: String) -> CKRecordZone.ID {
        let hash = Data(SHA256.hash(data: Data("ringly-backup-zone|\(userId)".utf8))).hex.prefix(32)
        return CKRecordZone.ID(zoneName: "ringly-\(hash)", ownerName: CKCurrentUserDefaultName)
    }

    private static func sha(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    // Пользователю — понятная фраза; сырой текст CloudKit с id записей и кодами — только в журнал
    // (скрытое меню: 10 нажатий на «Профиль»), его пишут вызывающие через describe(_:).
    private static func statusFor(_ error: Error) -> BackupStatus {
        let generic = BackupStatus.failed(L("Не удалось создать копию. Попробуем ещё раз позже."))
        guard let ck = error as? CKError else { return generic }
        switch ck.code {
        case .notAuthenticated, .accountTemporarilyUnavailable: return .noAccount
        case .quotaExceeded: return .failed(L("В iCloud закончилось место"))
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .failed(L("Нет связи с iCloud, повторим позже"))
        default: return generic
        }
    }

    // для журнала: код CloudKit + текст + первая ошибка по записи (у partialFailure суть — внутри)
    private static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return String(describing: error) }
        var text = "CKError \(ck.code.rawValue): \(ck.localizedDescription)"
        if let inner = ck.partialErrorsByItemID?.values.first {
            text += " | \(inner.localizedDescription)"
        }
        return text
    }
}

private enum BackupFailure: Error {
    case keyMismatch
    case encryption
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
