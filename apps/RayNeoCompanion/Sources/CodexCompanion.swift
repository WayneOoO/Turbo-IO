import Foundation
import Combine
import Security

enum HermesBridgeError: LocalizedError {
    case configuration, missingKey, offline, invalidResponse, rejected(String), unknownDelivery
    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写无账号、查询参数的 HTTPS 桥接地址；仅模拟器允许 HTTP 回环地址。"
        case .missingKey: return "请先保存此桥接地址的独立令牌。"
        case .offline: return "桥接未连接，请检查电脑服务与网络。"
        case .invalidResponse: return "桥接响应无效或版本不匹配。"
        case .rejected(let code): return "桥接未接受请求（\(code)）。没有自动重试。"
        case .unknownDelivery: return "上次提交结果未知。请点核对上次提交，不要重复创建任务。"
        }
    }
}

enum HermesEndpoint {
    static func normalize(_ text: String, allowLoopback: Bool = false) throws -> String {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.url != nil, c.path.isEmpty || c.path == "/",
              c.scheme == "https" || (allowLoopback && c.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)) else { throw HermesBridgeError.configuration }
        c.path = ""; c.host = host.lowercased()
        return c.string!
    }
    static var simulatorLoopback: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

enum HermesTokenVault {
    static func get(_ endpoint: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.turboio.hermes", kSecAttrAccount as String: endpoint, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, endpoint: String) throws {
        guard token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw HermesBridgeError.missingKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.turboio.hermes", kSecAttrAccount as String: endpoint]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let rc = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if rc == errSecItemNotFound {
            guard SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw HermesBridgeError.missingKey }
        } else if rc != errSecSuccess { throw HermesBridgeError.missingKey }
    }
}

/// 一步真实工具执行。字段对齐桥接契约的 task.steps 元素。
struct HermesStep: Decodable {
    let name: String
    let status: String            // running | done | error
    let detail: String
    let durationMs: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "步骤"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "running"
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        durationMs = try? c.decodeIfPresent(Double.self, forKey: .durationMs)
    }
    private enum CodingKeys: String, CodingKey { case name, status, detail, durationMs }
}

struct HermesTokens: Decodable {
    let input: Int?
    let output: Int?
    let total: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try? c.decodeIfPresent(Int.self, forKey: .input)
        output = try? c.decodeIfPresent(Int.self, forKey: .output)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }
    private enum CodingKeys: String, CodingKey { case input, output, total }
}

struct HermesTask: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let text: String
    let status: String            // queued | running | done | failed | stopped
    let tier: String?             // 低 | 中 | 高（未出现时为 nil）
    let steps: [HermesStep]
    let answer: String
    let startedAt: Double?
    let finishedAt: Double?
    let error: String
    let tokens: HermesTokens?

    var running: Bool { status == "queued" || status == "running" }
    var sessionSuffix: String { sessionId.isEmpty ? "—" : String(sessionId.suffix(6)) }
    var durationMs: Double? {
        guard let startedAt = startedAt else { return nil }
        return (finishedAt ?? Date().timeIntervalSince1970 * 1000) - startedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "queued"
        tier = try? c.decodeIfPresent(String.self, forKey: .tier)
        steps = (try? c.decodeIfPresent([HermesStep].self, forKey: .steps)) ?? []
        answer = (try? c.decodeIfPresent(String.self, forKey: .answer)) ?? ""
        startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Double.self, forKey: .finishedAt)
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? ""
        tokens = try? c.decodeIfPresent(HermesTokens.self, forKey: .tokens)
    }
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, text, status, tier, steps, answer, startedAt, finishedAt, error, tokens
    }
}

struct HermesSession: Decodable, Identifiable {
    let sessionId: String
    let title: String
    let updatedAt: Double?
    var id: String { sessionId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
    private enum CodingKeys: String, CodingKey { case sessionId, title, updatedAt }
}

/// GET /v1/hermes/state 的完整形状。缺字段不致命，超出上限才算无效响应。
struct HermesState: Decodable {
    let protocolName: String
    let online: Bool
    let workspace: String
    let serverTime: Double?
    let active: HermesTask?
    let tasks: [HermesTask]
    let sessions: [HermesSession]
    let events: [HermesPushEvent]?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolName = (try? c.decodeIfPresent(String.self, forKey: .protocolName)) ?? ""
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        workspace = (try? c.decodeIfPresent(String.self, forKey: .workspace)) ?? ""
        serverTime = try? c.decodeIfPresent(Double.self, forKey: .serverTime)
        active = try? c.decodeIfPresent(HermesTask.self, forKey: .active)
        tasks = (try? c.decodeIfPresent([HermesTask].self, forKey: .tasks)) ?? []
        sessions = (try? c.decodeIfPresent([HermesSession].self, forKey: .sessions)) ?? []
        events = try? c.decodeIfPresent([HermesPushEvent].self, forKey: .events)
    }
    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", online, workspace, serverTime, active, tasks, sessions, events
    }
}

/// 桥接原始枚举值 → 界面中文。未知值原样显示，不猜。
enum HermesText {
    static func status(_ raw: String) -> String {
        switch raw {
        case "queued": return "排队中"
        case "running": return "执行中"
        case "done": return "已完成"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return raw
        }
    }
    static func stepStatus(_ raw: String) -> String {
        switch raw {
        case "running": return "进行中"
        case "done": return "已完成"
        case "error": return "出错"
        default: return raw
        }
    }
    static func duration(_ ms: Double?) -> String {
        guard let ms = ms, ms.isFinite, ms >= 0 else { return "—" }
        if ms < 1000 { return String(format: "%.0fms", ms) }
        return String(format: "%.1fs", ms / 1000)
    }
}

private final class HermesNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum HermesHTTP {
    static func call(endpoint: String, token: String, path: String, body: Data?) async throws -> Data {
        let allowed = ["/v1/hermes/state", "/v1/hermes/ask", "/v1/hermes/stop"]
        guard allowed.contains(path), token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw HermesBridgeError.configuration }
        let base = try HermesEndpoint.normalize(endpoint, allowLoopback: HermesEndpoint.simulatorLoopback)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35; config.timeoutIntervalForResource = 40
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: HermesNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesBridgeError.invalidResponse }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); data.append(byte); guard data.count <= 2_097_152 else { throw HermesBridgeError.invalidResponse } }
        // 提交任务返回 202，停止返回 200。
        guard (200...299).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = object?["error"] as? String ?? "http_\(http.statusCode)"
            let safe = raw.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil ? raw : "request_failed"
            throw HermesBridgeError.rejected(safe)
        }
        return data
    }
}

/// One catalogue supplies both the model request and the read-only tools UI.
struct HermesToolDescriptor: Identifiable {
    let id: String
    let title: String
    let description: String
    let example: String
    let requiresText: Bool
    var definition: [String: Any] {
        ["type": "function", "function": ["name": id, "description": description,
            "parameters": ["type": "object", "properties": requiresText ? ["text": ["type": "string", "description": "用户交给 Hermes 的完整要求，不添加授权"]] : [:],
                "required": requiresText ? ["text"] : [], "additionalProperties": false]]]
    }
    var schemaJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: definition, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "无法显示工具定义" }
        return text
    }
    static let all: [Self] = [
        .init(id: "hermes_ask", title: "把任务交给电脑上的 Hermes", description: "仅当用户明确要求 Hermes 执行或继续电脑任务时调用。发送到 App 选中的任务，未选择才新建会话；不适用于普通聊天。", example: "让 Hermes 检查一下这个项目的目录结构", requiresText: true),
        .init(id: "hermes_status", title: "查 Hermes 任务进度", description: "用户询问 Hermes 当前任务的进度、步骤或结果时调用。", example: "Hermes 做完了吗？", requiresText: false),
        .init(id: "hermes_stop", title: "停止 Hermes 任务", description: "仅用户明确要求停止 Hermes 当前任务时调用。停止回复朗读不等于停止 Hermes。", example: "停止 Hermes 当前任务", requiresText: false)
    ]
}

/// 工具调用只能提交任务：本 App 没有审批，也不存在自动批准。
@MainActor final class HermesCompanion: ObservableObject {
    @Published private(set) var endpoint: String
    @Published private(set) var voiceToolsEnabled: Bool
    @Published private(set) var state: HermesState?
    @Published private(set) var status = "尚未连接电脑桥接"
    @Published private(set) var busy = false
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var hasUnknownDelivery = false
    private let defaults: UserDefaults
    private let key: (String) -> String?
    private let send: (String, String, String, Data?) async throws -> Data
    private var refreshing = false
    private var generation = UUID()
    private let prefix = "companion.hermes.v1."
    var selected: HermesTask? { state?.tasks.first { $0.id == selectedTaskID } }
    var configured: Bool { !endpoint.isEmpty && key(endpoint) != nil }
    var canStop: Bool { selected?.running == true }
    init(defaults: UserDefaults = .standard, key: @escaping (String) -> String? = HermesTokenVault.get,
         send: @escaping (String, String, String, Data?) async throws -> Data = HermesHTTP.call) {
        self.defaults = defaults; self.key = key; self.send = send
        endpoint = defaults.string(forKey: "companion.hermes.v1.endpoint") ?? ""
        voiceToolsEnabled = defaults.bool(forKey: "companion.hermes.v1.voiceTools")
        selectedTaskID = defaults.string(forKey: "companion.hermes.v1.selected")
        selectedSessionID = defaults.string(forKey: "companion.hermes.v1.session")
        hasUnknownDelivery = defaults.data(forKey: "companion.hermes.v1.pending") != nil
    }
    func save(endpoint input: String, token: String, voiceTools: Bool) throws {
        guard !busy, !hasUnknownDelivery else { throw HermesBridgeError.unknownDelivery }
        let normalized = try HermesEndpoint.normalize(input, allowLoopback: HermesEndpoint.simulatorLoopback)
        if !token.isEmpty { try HermesTokenVault.save(token, endpoint: normalized) }
        guard key(normalized) != nil else { throw HermesBridgeError.missingKey }
        if normalized != endpoint { selectedTaskID = nil; selectedSessionID = nil; defaults.removeObject(forKey: prefix + "selected"); defaults.removeObject(forKey: prefix + "session") }
        generation = UUID(); state = nil; endpoint = normalized; voiceToolsEnabled = voiceTools
        defaults.set(endpoint, forKey: prefix + "endpoint"); defaults.set(voiceTools, forKey: prefix + "voiceTools")
        status = "配置已保存；尚未联网。语音工具\(voiceTools ? "已允许" : "已关闭")"
    }
    func select(_ id: String?) {
        guard !busy, !hasUnknownDelivery, id == nil || state?.tasks.contains(where: { $0.id == id }) == true else { return }
        selectedTaskID = id; defaults.set(id, forKey: prefix + "selected")
        // 续聊 = 沿用该任务的会话号；改为新任务则清空，下次提交新建会话。
        if let id = id, let task = state?.tasks.first(where: { $0.id == id }) {
            selectedSessionID = task.sessionId
            if task.sessionId.isEmpty { defaults.removeObject(forKey: prefix + "session") } else { defaults.set(task.sessionId, forKey: prefix + "session") }
        } else {
            selectedSessionID = nil; defaults.removeObject(forKey: prefix + "session")
        }
    }
    func refresh() async {
        guard !refreshing, configured else { return }; refreshing = true; defer { refreshing = false }
        let current = generation, base = endpoint
        do {
            let data = try await send(base, key(base)!, "/v1/hermes/state", nil)
            let value = try JSONDecoder().decode(HermesState.self, from: data)
            guard current == generation else { return }
            guard value.protocolName == "hermes/1", value.tasks.count <= 32, (value.events?.count ?? 0) <= 128 else { throw HermesBridgeError.invalidResponse }
            state = value
            status = value.online ? "电脑桥接在线 · 工作区 \(value.workspace)" : "Hermes 进程离线"
        } catch {
            guard current == generation else { return }; state = nil
            status = (error as? HermesBridgeError)?.localizedDescription ?? "桥接连接失败；未自动提交任务"
        }
    }
    private func mutate(_ path: String, body: [String: Any]) async throws -> Data {
        guard !busy else { throw HermesBridgeError.rejected("bridge_busy") }
        guard !hasUnknownDelivery else { throw HermesBridgeError.unknownDelivery }
        guard let token = key(endpoint), !endpoint.isEmpty else { throw HermesBridgeError.missingKey }
        let data = try JSONSerialization.data(withJSONObject: body)
        let pending = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "path": path, "body": body])
        // At-most-once recovery retains user text locally until outcome is resolved.
        defaults.set(pending, forKey: prefix + "pending"); hasUnknownDelivery = true
        return try await deliver(path, data: data, token: token)
    }
    private func deliver(_ path: String, data: Data, token: String) async throws -> Data {
        busy = true; defer { busy = false }
        do {
            let response = try await send(endpoint, token, path, data)
            defaults.removeObject(forKey: prefix + "pending"); hasUnknownDelivery = false
            return response
        } catch { status = "提交结果待核对，不会自动重复发送"; throw error }
    }
    func retryPending() async {
        guard !busy, let pending = defaults.data(forKey: prefix + "pending"),
              let object = (try? JSONSerialization.jsonObject(with: pending)) as? [String: Any],
              object["endpoint"] as? String == endpoint, let path = object["path"] as? String,
              let body = object["body"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: body), let token = key(endpoint) else { return }
        do {
            let response = try await deliver(path, data: data, token: token)
            if path == "/v1/hermes/ask" { _ = try? applyAsk(response); status = "已确认上次提交；实际执行结果请看任务状态" }
            await refresh()
        } catch { status = "仍未确认上次提交；保留原请求编号，未新建重复任务" }
    }
    /// POST /v1/hermes/ask：sessionId 为 nil 时桥接新建会话。
    @discardableResult
    func ask(text: String, sessionId: String? = nil, requestID: String = UUID().uuidString) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192 else { throw HermesBridgeError.rejected("invalid_text") }
        let target = sessionId ?? selectedSessionID
        var body: [String: Any] = ["text": text, "requestId": requestID]
        if let target = target { body["sessionId"] = target } else { body["sessionId"] = NSNull() }
        let response = try await mutate("/v1/hermes/ask", body: body)
        let taskId = try applyAsk(response)
        status = "已提交，实际执行结果请看任务状态"; await refresh(); return taskId
    }
    /// 202 响应：{taskId, sessionId}。保存两者，后续任务默认续聊该会话。
    @discardableResult
    private func applyAsk(_ response: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let taskId = object["taskId"] as? String, !taskId.isEmpty else { throw HermesBridgeError.invalidResponse }
        selectedTaskID = taskId; defaults.set(taskId, forKey: prefix + "selected")
        if let sessionId = object["sessionId"] as? String, !sessionId.isEmpty {
            selectedSessionID = sessionId; defaults.set(sessionId, forKey: prefix + "session")
        }
        return taskId
    }
    func stop(requestID: String = UUID().uuidString) async throws {
        guard let id = selectedTaskID else { throw HermesBridgeError.rejected("no_selected_task") }
        let response = try await mutate("/v1/hermes/stop", body: ["taskId": id, "requestId": requestID])
        let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        guard object?["ok"] as? Bool == true else { throw HermesBridgeError.invalidResponse }
        status = "已请求停止；最终状态请看任务列表"; await refresh()
    }
    var toolDefinitions: [[String: Any]] {
        guard voiceToolsEnabled, configured else { return [] }
        return HermesToolDescriptor.all.map(\.definition)
    }
    func executeTool(name: String, arguments: String, requestID: UUID) async -> String {
        guard voiceToolsEnabled, configured, !Task.isCancelled else { return "Hermes 工具未开启。" }
        do {
            guard arguments.utf8.count <= 9000, let obj = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw HermesBridgeError.invalidResponse }
            switch name {
            case "hermes_ask":
                guard obj.count == 1, let text = obj["text"] as? String else { throw HermesBridgeError.invalidResponse }
                let id = try await ask(text: text, requestID: requestID.uuidString)
                return "已交给电脑上的 Hermes，任务编号 \(id.prefix(4))。任务会继续运行，你可以稍后问进度。"
            case "hermes_status":
                guard obj.isEmpty else { throw HermesBridgeError.invalidResponse }; await refresh()
                guard state?.online == true, let task = selected else { return "尚未取得当前 Hermes 任务状态，请在 Hermes 控制台连接并选择任务。" }
                let steps = task.steps.map { "\($0.name)\(HermesText.stepStatus($0.status))" }.joined(separator: "，")
                let tier = task.tier.map { "【\($0)】" } ?? ""
                return "Hermes：\(HermesText.status(task.status))\(tier)"
                    + (steps.isEmpty ? "" : "\n步骤：" + steps)
                    + (task.answer.isEmpty ? "" : "\n" + String(task.answer.suffix(350)))
            case "hermes_stop":
                guard obj.isEmpty else { throw HermesBridgeError.invalidResponse }; try await stop(requestID: requestID.uuidString)
                return "已请求 Hermes 停止当前任务，最终状态请在任务页核对。"
            default: return "不支持此工具，未执行任何操作。"
            }
        } catch { return "Hermes 请求未确认成功，请在手机核对。没有自动重试。" }
    }
}
