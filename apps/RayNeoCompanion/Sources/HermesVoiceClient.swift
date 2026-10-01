import Foundation

/// 语音入口失败一律给「人话」：不静默、不崩、不自动重试。
enum HermesVoiceError: LocalizedError {
    case configuration, missingKey, offline, invalidResponse, tooLarge, emptyAudio, asrFailed, rejected(String)
    var errorDescription: String? {
        switch self {
        case .configuration: return "语音识别失败（configuration）：桥接地址或令牌无效，请到「Hermes 任务」页重新保存。"
        case .missingKey: return "语音识别失败（missing_key）：这台手机上没有该桥接地址的令牌。"
        case .offline: return "语音识别失败（offline）：手机连不上电脑桥接，请检查网络与电脑服务。"
        case .invalidResponse: return "语音识别失败（invalid_response）：桥接返回的内容无法解析。"
        case .tooLarge: return "这段语音太长（超过 8 MiB，约 4 分钟），没有被识别；请说短一点。"
        case .emptyAudio: return "没有可识别的音频，本次没有发送。"
        case .asrFailed: return "语音识别失败（asr_failed）"
        case .rejected(let code): return "语音识别失败（\(code)）"
        }
    }
}

/// POST /v1/hermes/voice 的响应：{text, source, taskId, sessionId, status}。
/// 缺字段不致命，但 text 必须是可显示的一句原话。
struct HermesVoiceResult: Decodable {
    let text: String
    let source: String?
    let taskId: String?
    let sessionId: String?
    let status: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        taskId = try? c.decodeIfPresent(String.self, forKey: .taskId)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
    }
    private enum CodingKeys: String, CodingKey { case text, source, taskId, sessionId, status }
}

/// 非 wav/mp3/m4a/ogg 的音频必须先在手机上套标准 44 字节 WAV 头再发。
enum HermesVoiceAudio {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16

    /// RIFF/WAVE/fmt/data 四段 + PCM s16le。解码侧按小端读。
    static func wav(pcm: Data, sampleRate: Int = 16_000, channels: Int = 1) -> Data? {
        guard !pcm.isEmpty, pcm.count % 2 == 0, channels >= 1, channels <= 2,
              let rate = UInt32(exactly: sampleRate), rate > 0,
              let channelCount = UInt16(exactly: channels),
              let dataBytes = UInt32(exactly: pcm.count),
              let riffBytes = UInt32(exactly: pcm.count + 36) else { return nil }
        let bits = UInt16(bitsPerSample), bytesPerSample = UInt16(bitsPerSample / 8)
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(littleEndian(riffBytes))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(littleEndian(UInt32(16)))                                   // PCM fmt 块长度
        header.append(littleEndian(UInt16(1)))                                    // 1 = PCM
        header.append(littleEndian(channelCount))
        header.append(littleEndian(rate))
        header.append(littleEndian(rate * UInt32(channelCount) * UInt32(bytesPerSample)))
        header.append(littleEndian(channelCount * bytesPerSample))
        header.append(littleEndian(bits))
        header.append(contentsOf: Array("data".utf8))
        header.append(littleEndian(dataBytes))
        guard header.count == 44 else { return nil }
        var output = Data(); output.reserveCapacity(header.count + pcm.count)
        output.append(header); output.append(pcm)
        return output
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var bytes = value.littleEndian
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }
}

private final class HermesVoiceNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// 唯一语音入口：原始音频字节 POST 到桥接，识别与派活都在服务器侧。
/// 音频不落盘；不重定向；不自动重试（重试会把同一段话变成两个任务）。
enum HermesVoiceClient {
    static let path = "/v1/hermes/voice"
    static let maximumBytes = 8 * 1_024 * 1_024

    static func send(audio: Data, contentType: String, endpoint: String, token: String) async throws -> HermesVoiceResult {
        guard !audio.isEmpty else { throw HermesVoiceError.emptyAudio }
        guard audio.count <= maximumBytes else { throw HermesVoiceError.tooLarge }
        guard contentType.range(of: "^audio/[a-z0-9.+-]{1,32}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw HermesVoiceError.configuration }
        let base = try HermesEndpoint.normalize(endpoint, allowLoopback: HermesEndpoint.simulatorLoopback)
        let config = URLSessionConfiguration.ephemeral
        // 服务器侧要跑完整段音频的识别，比普通接口慢；上限仍留在两分钟内。
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 130
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: HermesVoiceNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"; request.httpBody = audio
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let failure as URLError {
            throw [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .timedOut, .networkConnectionLost]
                .contains(failure.code) ? HermesVoiceError.offline : HermesVoiceError.invalidResponse
        }
        catch { throw HermesVoiceError.invalidResponse }
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw HermesVoiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = (object?["error"] as? String) ?? "http_\(http.statusCode)"
            let safe = raw.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil ? raw : "request_failed"
            throw safe == "asr_failed" ? HermesVoiceError.asrFailed : HermesVoiceError.rejected(safe)
        }
        let result = try JSONDecoder().decode(HermesVoiceResult.self, from: data)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HermesVoiceError.asrFailed }
        return result
    }

    /// 本机解码得到的 16 kHz 单声道 s16le → 套 WAV 头 → audio/wav。
    static func send(pcm: Data, sampleRate: Int, endpoint: String, token: String) async throws -> HermesVoiceResult {
        guard let wav = HermesVoiceAudio.wav(pcm: pcm, sampleRate: sampleRate) else { throw HermesVoiceError.emptyAudio }
        return try await send(audio: wav, contentType: "audio/wav", endpoint: endpoint, token: token)
    }
}

/// 设备侧的音频汇合点：只做缓冲与「说完了」判定，发送交给 CompanionVoiceRuntime。
/// 只在主线程被调用（core-probe 的音频回调保证在主线程），因此不再另加锁。
/// 关掉待命、本轮超时或用户收手时由设备侧调 finish()。
final class HermesVoiceHub: @unchecked Sendable {
    static let shared = HermesVoiceHub()
    /// 收尾静音：16 kHz 下 10 ms 一帧，70 帧 ≈ 700 ms。
    static let silenceFrames = 70
    /// 单轮上限 4 MiB（约 131 秒 16 kHz 单声道），远低于桥接的 8 MiB。
    static let maximumBytes = 4 * 1_024 * 1_024
    /// 少于 200 ms 的碎片不当一句话。
    static let minimumBytes = 6_400
    private weak var runtime: CompanionVoiceRuntime?
    private var buffer = Data()
    private var silence = 0
    private var voiced = false
    var enabled: Bool { runtime != nil }
    var pendingBytes: Int { buffer.count }

    func attach(_ runtime: CompanionVoiceRuntime) { self.runtime = runtime }

    /// 原始 PCM + 每 10 ms 帧的语音掩码（掩码位为 1 表示该帧有人声）。
    func append(pcm: Data, speechMask: UInt32, frames: Int) {
        guard !pcm.isEmpty else { return }
        if buffer.count + pcm.count > Self.maximumBytes { finish(); return }
        buffer.append(pcm)
        if speechMask != 0 { voiced = true; silence = 0 }
        else if frames > 0 { silence += frames }
        if voiced, silence >= Self.silenceFrames, buffer.count >= Self.minimumBytes { finish() }
    }

    /// 取走本轮音频并交给运行时发送；没有音频时什么都不做。
    func finish() {
        guard !buffer.isEmpty else { return }
        let payload = buffer
        buffer = Data(); silence = 0; voiced = false
        guard payload.count >= Self.minimumBytes else { return }
        let runtime = self.runtime
        Task { @MainActor in await runtime?.deliverVoiceRound(pcm: payload) }
    }
}
