import Foundation

// Межпроцессная блокировка (flock) поверх файла в App-Group-контейнере.
// Сериализует расшифровку между приложением и NSE: два процесса не двигают
// один и тот же ратчет одновременно (Signal делает то же — это не наш велосипед).
// flock привязан к открытому файловому дескриптору и держится на уровне ПРОЦЕССА,
// поэтому корректно переживает await (resume на другом потоке того же процесса).
final class CrossProcessLock {
    private let fd: Int32

    init(name: String) {
        let url = AppGroup.containerURL.appendingPathComponent(name)
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
    }

    deinit { if fd >= 0 { close(fd) } }

    // эксклюзивно выполнить тело; другой процесс на это время блокируется на flock(LOCK_EX)
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN) } }
        return try await body()
    }
}
