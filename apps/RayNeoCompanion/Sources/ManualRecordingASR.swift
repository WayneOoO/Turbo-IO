import Foundation
import AVFoundation
import Combine
import SwiftUI

enum RecordingASRError: LocalizedError {
    case unsupported, limit, credentials, remote, empty
    var errorDescription: String? {
        switch self {
        case .unsupported: return "此音频无法由 iOS 解码。请使用有效 WAV、M4A、MP3 等系统支持格式；原始眼镜容器可能需要额外转换。"
        case .limit: return "手动转写暂限约 4 分钟音频 / 32 MiB 解码 PCM；超出的部分没有提交。"
        case .credentials: return "请先在「Hermes 任务」页保存桥接地址与令牌；模拟器不调用真实语音服务。"
        case .remote: return "桥接连接、超时或响应失败，没有保存为成功转写；可重试。"
        case .empty: return "桥接未返回有效文字，没有生成空笔记。"
        }
    }
}

enum RecordingPCMDecoder {
    static func decode(_ url: URL, inputChannel: Int? = nil, diagnostic: (String) -> Void = { _ in }) throws -> Data {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { diagnostic("open-failed"); throw RecordingASRError.unsupported }
        let format = input.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, input.length > 0,
              format.channelCount > 0, format.channelCount <= 32,
              Double(input.length) / format.sampleRate <= 600 else { throw RecordingASRError.limit }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { diagnostic("converter-init-failed"); throw RecordingASRError.unsupported }
        if let channel = inputChannel {
            guard channel >= 0, channel < Int(format.channelCount) else { throw RecordingASRError.unsupported }
        }
        var pcm = Data(), failed = false
        for _ in 0..<10_000 {
            try Task.checkCancellation()
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { requested, status in
                do {
                    let remaining = input.length - input.framePosition
                    guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                    let count = min(requested, source.frameCapacity, AVAudioFrameCount(min(remaining, Int64(UInt32.max))))
                    try input.read(into: source, frameCount: count)
                    try mixToMono(source, into: mono, inputChannel: inputChannel)
                    status.pointee = source.frameLength == 0 ? .endOfStream : .haveData
                    return source.frameLength == 0 ? nil : mono
                } catch { failed = true; status.pointee = .endOfStream; return nil }
            }
            guard !failed, error == nil, result != .error else { diagnostic("convert-failed read=\(failed) status=\(result.rawValue) code=\(error?.code ?? 0)"); throw RecordingASRError.unsupported }
            if output.frameLength > 0, let samples = output.int16ChannelData {
                guard pcm.count + Int(output.frameLength) * 2 <= 32 * 1_024 * 1_024 else { throw RecordingASRError.limit }
                pcm.append(UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: Int(output.frameLength) * 2)
            }
            if result == .endOfStream {
                guard !pcm.isEmpty else { throw RecordingASRError.empty }
                return pcm
            }
        }
        throw RecordingASRError.limit
    }

    /// Explicit equal-weight downmix before resampling. AVAudioConverter's
    /// default channel mapping can select channel 0 instead of mixing stereo.
    /// Average rather than sum so full-scale in-phase channels cannot overflow.
    private static func mixToMono(_ source: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer, inputChannel: Int?) throws {
        guard let input = source.floatChannelData, let output = mono.floatChannelData,
              source.frameLength <= mono.frameCapacity else { throw RecordingASRError.unsupported }
        let channels = Int(source.format.channelCount)
        let selected = inputChannel.map { $0..<($0 + 1) } ?? (0..<channels)
        for frame in 0..<Int(source.frameLength) {
            var sum = 0.0
            for channel in selected {
                let value = Double(input[channel][frame])
                guard value.isFinite else { throw RecordingASRError.unsupported }
                sum += value
            }
            output[0][frame] = Float(max(-1, min(1, sum / Double(selected.count))))
        }
        mono.frameLength = source.frameLength
    }
}

/// Explicit per-run local capture. No request headers; the audio is sent to the
/// user's own bridge without any key, so there is nothing to redact by default.
/// The source recording is untouched.
final class FileASRDiagnostic {
    let directory: URL
    private let secret: String
    private let handle: FileHandle
    private var size = 0
    init(root: URL, pcm: Data, secret: String) throws {
        self.secret = secret
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try pcm.write(to: directory.appendingPathComponent("sent-16000-mono-s16le.pcm"), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        let events = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: events.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw RecordingASRError.remote }
        handle = try FileHandle(forWritingTo: events)
    }
    deinit { try? handle.close() }
    func record(_ event: String, _ body: String) throws {
        let safe = secret.isEmpty ? body : body.replacingOccurrences(of: secret, with: "[REDACTED]")
        var line = try JSONSerialization.data(withJSONObject: ["time": Date().timeIntervalSince1970, "event": event, "body": safe], options: [.sortedKeys])
        line.append(10)
        guard size + line.count <= 2_097_152 else { throw RecordingASRError.limit }
        try handle.write(contentsOf: line); try handle.synchronize()
        size += line.count
    }
}

/// 手动转写：整段音频 POST 到用户自己的 Hermes 桥（服务器侧内置豆包 ASR）。
/// 本机不再持有任何语音密钥，也不再连阿里云 DashScope。
@MainActor enum HermesFileASR {
    static func transcribe(pcm: Data, endpoint: String, token: String, sampleRate: Int = 16_000,
                           diagnostic: FileASRDiagnostic? = nil) async throws -> String {
        guard pcm.count % 2 == 0 else { throw RecordingASRError.unsupported }
        guard let wav = HermesVoiceAudio.wav(pcm: pcm, sampleRate: sampleRate) else { throw RecordingASRError.empty }
        guard wav.count <= HermesVoiceClient.maximumBytes else { throw RecordingASRError.limit }
        try? diagnostic?.record("upload", "bytes=\(wav.count) format=wav sampleRate=\(sampleRate) channels=1 bits=16")
        do {
            let result = try await HermesVoiceClient.send(audio: wav, contentType: "audio/wav", endpoint: endpoint, token: token)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? diagnostic?.record("parsed-final", "characters=\(text.count)")
            guard !text.isEmpty else { throw RecordingASRError.empty }
            return text
        } catch let failure {
            try? diagnostic?.record("client-error", "description=\((failure as? LocalizedError)?.localizedDescription ?? "unknown")")
            throw failure
        }
    }
}

@MainActor final class ManualRecordingASR: ObservableObject {
    @Published private(set) var recordingID: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var resultText = ""
    @Published private var work: Task<Void, Never>?
    var busy: Bool { work != nil }
    func cancel() { work?.cancel(); status = "正在取消，原音频保留…" }
    func start(id: UUID, title: String, archive: LocalArchiveController, captureDiagnostic: Bool = false, rightChannelOnly: Bool = false) {
        guard work == nil else { return }
        recordingID = id; progress = 0; resultText = ""
        #if COMPANION_DEVICE
        let endpoint = HermesCompanion.storedEndpoint
        guard !endpoint.isEmpty, let token = HermesTokenVault.get(endpoint) else { status = RecordingASRError.credentials.localizedDescription; return }
        work = Task { @MainActor in
            defer { work = nil }
            var diagnostic: FileASRDiagnostic?
            do {
                status = "校验本机音频…"
                guard let url = await archive.verify(id) else { throw RecordingASRError.unsupported }
                try Task.checkCancellation()
                status = "本机解码为 16 kHz 单声道…"
                let decoder = Task.detached(priority: .userInitiated) { try RecordingPCMDecoder.decode(url, inputChannel: rightChannelOnly ? 1 : nil) }
                let pcm = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                try Task.checkCancellation()
                progress = 0.5
                if captureDiagnostic {
                    let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    diagnostic = try FileASRDiagnostic(root: root.appendingPathComponent("ManualASRDiagnosticsV1"), pcm: pcm, secret: "")
                    try diagnostic?.record("source", "recording=\(id.uuidString) decodedBytes=\(pcm.count) channel=\(rightChannelOnly ? "right-only" : "equal-weight-downmix")")
                }
                status = "转写中，音频已发给电脑桥接…"
                let text = try await HermesFileASR.transcribe(pcm: pcm, endpoint: endpoint, token: token, diagnostic: diagnostic)
                try Task.checkCancellation()
                progress = 1
                resultText = text
                status = "保存新文字修订…"
                guard await archive.saveTranscript(recordingID: id, text: text, title: String(("ASR · " + title).prefix(64))) != nil else {
                    status = "识别已完成但笔记未保存，可复制下方文字；原音频保留。"; return
                }
                status = "转写完成，已保存为新 Markdown 修订；请核对识别内容。"
            } catch is CancellationError { status = "已取消后续处理；原音频和已提交修订保留。" }
            catch {
                try? diagnostic?.record("client-error", "domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription)")
                status = (error as? HermesVoiceError)?.localizedDescription
                    ?? (error as? HermesBridgeError)?.localizedDescription
                    ?? (error as? RecordingASRError)?.localizedDescription
                    ?? "转写未完成，可能断网或已取消；原音频保留。"
            }
        }
        #else
        status = RecordingASRError.credentials.localizedDescription
        #endif
    }
}

struct ManualRecordingASRView: View {
    let id: UUID, title: String
    @EnvironmentObject private var asr: ManualRecordingASR
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var confirmation = false
    @State private var captureDiagnostic = false
    @State private var rightChannelOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录音转文字").font(.headline)
            Text("只有确认后才把这份本机音频发送给你自己的电脑桥接（桥接内置豆包 ASR）；识别文字交给 Hermes，可能计费在桥接那一侧。成功后新增文字修订，不覆盖原音频或旧稿。")
                .font(.caption).foregroundStyle(Palette.muted)
            Text("转写期间请保持 App 在前台；长时间后台完成尚未验收。").font(.caption2).foregroundStyle(Palette.muted)
            Text("默认合并全部声道，再转为16kHz单声道并套标准 WAV 头；保留原始录音，不覆盖音频。单次上限约 4 分钟。").font(.caption2).foregroundStyle(Palette.muted)
            Toggle("仅下次保存 ASR 诊断", isOn: $captureDiagnostic).disabled(asr.busy).accessibilityIdentifier("manual-asr-diagnostic")
            if captureDiagnostic { Text("将额外保存本次发送的音频和桥接响应（可能含转录正文），仅存本机；不记录请求头或密钥。").font(.caption2) }
            if captureDiagnostic {
                Toggle("诊断：仅本次使用右声道", isOn: $rightChannelOnly).disabled(asr.busy).accessibilityIdentifier("manual-asr-right-channel")
            }
            Button("手动开始 ASR 转写") { confirmation = true }.disabled(asr.busy || archive.isBusy).accessibilityIdentifier("manual-recording-asr")
            if asr.recordingID == id {
                Text(asr.status).font(.caption)
                if asr.busy { ProgressView(value: asr.progress); Button("取消转写") { asr.cancel() } }
                if !asr.resultText.isEmpty { Text(asr.resultText).font(.caption).textSelection(.enabled).privacySensitive() }
            } else if asr.busy { Text("另一份录音正在转写。完成后再试。").font(.caption) }
        }.confirmationDialog("将这份录音发送到电脑桥接识别？识别结果需要人工核对。", isPresented: $confirmation) {
            Button("确认上传并转文字") {
                let capture = captureDiagnostic, right = captureDiagnostic && rightChannelOnly
                captureDiagnostic = false; rightChannelOnly = false
                asr.start(id: id, title: title, archive: archive, captureDiagnostic: capture, rightChannelOnly: right)
            }
        }
    }
}
