import Foundation

actor DeviceResolver {
	static let shared = DeviceResolver()

	// Кэш девайс-листов. Это ГОРЯЧИЙ путь отправки: раньше каждый sendText делал
	// GET /users/:id/devices (+ GET /me) — и сообщение уходило за 3 round-trip'а вместо одного.
	// Рассинхрон кэша (устройство добавили/удалили) ловится ошибкой POST /messages →
	// MessagingService делает invalidate + один retry. TTL — потолок протухания для случая,
	// который сервер ошибкой не считает (у получателя появилось НОВОЕ устройство).
	private struct CacheEntry {
		let devices: [RecipientDevice]
		let fetchedAt: Date
	}
	private var cache: [String: CacheEntry] = [:]
	private let ttl: TimeInterval = 300   // 5 минут

	// вернуть protocolDeviceId для (userId, deviceId); незнакомое устройство → рефетч даже при живом TTL
	// (входящее от только что добавленного устройства отправителя)
	func protocolDeviceId(userId: String, deviceId: String) async -> Int? {
		if let pid = cache[userId]?.devices.first(where: { $0.deviceId == deviceId })?.protocolDeviceId {
			return pid
		}
		let fresh = await fetch(userId: userId)
		return fresh?.first(where: { $0.deviceId == deviceId })?.protocolDeviceId
	}

	// девайсы для fan-out: из кэша, пока жив TTL; при промахе — с сервера.
	// Работает и для СВОЕГО userId (/users/:id/devices отдаёт и себя) — так свои
	// устройства для мультидевайс-синка идут через тот же кэш, без GET /me на каждое сообщение.
	func devices(userId: String) async -> [RecipientDevice] {
		if let entry = cache[userId], Date().timeIntervalSince(entry.fetchedAt) < ttl {
			return entry.devices
		}
		// ошибка сети → отдаём протухший кэш, если был (лучше отправить по старому списку, чем никак)
		return await fetch(userId: userId) ?? cache[userId]?.devices ?? []
	}

	// сбросить кэш юзера (после ошибки отправки «девайс-лист разошёлся с сервером»)
	func invalidate(userId: String) {
		cache[userId] = nil
	}

	// сбросить всё (на foreground: пока были в фоне, девайс-листы могли измениться)
	func invalidateAll() {
		cache = [:]
	}

	private func fetch(userId: String) async -> [RecipientDevice]? {
		do {
			let resp: UserDevicesResponse = try await APIClient.shared.request("users/\(userId)/devices")
			cache[userId] = CacheEntry(devices: resp.devices, fetchedAt: Date())
			return resp.devices
		} catch {
			print("DeviceResolver error:", error)
			return nil   // ошибку не кэшируем
		}
	}
}
