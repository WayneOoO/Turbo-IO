import SwiftUI
import Combine

@MainActor final class CompanionVoiceRuntime: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var enabled = false
    @Published private(set) var phase = "disabled"
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var transcriptFinal = false
    @Published private(set) var modelComplete = false
    @Published private(set) var bridgeReady = false
    @Published private(set) var voiceTaskID: String?
    @Published private(set) var voiceStatus = ""
    @Published private(set) var continuous = false
    @Published private(set) var cloud = false
    @Published private(set) var latestEvent = "尚未加载设备通信核心"
    @Published var error: String?
    private let timeline: ConversationTimeline?
    weak var hermes: HermesCompanion?
    private var activeTurn: UUID?
    var onBusiness: ((String, UInt8, Data) -> Void)?
    var onBusinessLoss: (() -> Void)?
    var featureIsBusy: (() -> Bool)?
    var onConnectionChange: ((String?) -> Void)?
    var onRuntimeRefresh: (() -> Void)?
    private var previousDeviceID: String?
    var deviceID: String? {
        #if COMPANION_DEVICE
        return controller.companionDeviceID
        #else
        return nil
        #endif
    }
    func sendBusiness(_ index: UInt8, payload: Data) throws {
        #if COMPANION_DEVICE
        prepare(); try controller.companionSendBusiness(index, payload: payload)
        #else
        throw DeviceFeatureError.disconnected
        #endif
    }
    func sendFile(_ url: URL, id: String) throws -> String {
        #if COMPANION_DEVICE
        return try controller.companionSendFile(url,id:id)
        #else
        throw DeviceFeatureError.disconnected
        #endif
    }
    func cancelFile(_ task: String) {
        #if COMPANION_DEVICE
        controller.companionCancelFile(task)
        #endif
    }
    init(timeline: ConversationTimeline? = nil) { self.timeline = timeline; HermesVoiceHub.shared.attach(self) }
    deinit {
        #if COMPANION_DEVICE
        poll?.invalidate()
        #endif
    }
    #if COMPANION_DEVICE
    let controller = ProbeController()
    private var poll: Timer?
    #endif
    var supportsDevice: Bool {
        #if COMPANION_DEVICE
        return true
        #else
        return false
        #endif
    }
    var phaseLabel: String {
        ["disabled": "待命已关闭", "waitingForConnection": "等待认证连接", "idle": "等待眼镜唤醒",
         "recording": "正在听你说", "processing": "正在生成回答", "displaying": "回答已发完，可继续说"] [phase] ?? "等待状态"
    }
    func prepare() {
        #if COMPANION_DEVICE
        guard poll == nil else { refresh(); return }
        // 语音识别已内置在电脑桥接：不再把工具定义交给设备侧模型，也不再需要本机密钥。
        HermesVoiceHub.shared.attach(self)
        controller.companionBusiness = { [weak self] in self?.onBusiness?($0,$1,$2) }
        controller.companionBusinessLoss = { [weak self] in self?.onBusinessLoss?() }
        controller.companionLog = { [weak self] line in self?.latestEvent = String(line.prefix(200)) }
        controller.companionTranscript = { [weak self] id, text, final in
            guard let self, !text.isEmpty else { return }
            if self.activeTurn != id { self.finishTimelineTurn(); self.activeTurn = id }
            self.timeline?.record(ConversationEvent(id: id, kind: .transcript, text: text, final: final))
        }
        controller.companionCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .startAudio, .vadStart:
                DisplayObservation.shared.newUtterance()
                self.finishTimelineTurn()
                self.clearText()
            case .streamText(let text, let final): self.transcript = text; self.transcriptFinal = final
            case .text(let text): self.answer = text
            case .answer(let text, _, let id, _):
                self.answer = String((self.answer + text).prefix(8192))
                self.timeline?.record(ConversationEvent(id: id, kind: .answerDelta, text: text))
            case .responseComplete:
                self.modelComplete = true
                if let id = self.activeTurn { self.timeline?.record(ConversationEvent(id: id, kind: .completed)) }
            default: break
            }
        }
        controller.loadViewIfNeeded()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        poll = timer; RunLoop.main.add(timer, forMode: .common); refresh()
        #endif
    }
    func refresh() {
        #if COMPANION_DEVICE
        ready = controller.companionReady; enabled = controller.companionEnabled
        phase = controller.companionPhase; bridgeReady = hermes?.configured == true
        DisplayObservation.shared.connection(ready, phase:phase)
        if ["disabled", "waitingForConnection", "idle"].contains(phase) { finishTimelineTurn() }
        continuous = controller.companionContinuous; cloud = controller.companionCloud
        let current = deviceID
        if previousDeviceID != current { previousDeviceID = current; onConnectionChange?(current) }
        onRuntimeRefresh?()
        #endif
    }
    func discover() {
        #if COMPANION_DEVICE
        prepare(); controller.companionDiscover(); refresh()
        #endif
    }
    func connect() {
        #if COMPANION_DEVICE
        prepare(); controller.companionConnect(); refresh()
        #endif
    }
    func reconnectBonded() {
        #if COMPANION_DEVICE
        prepare(); controller.companionReconnectBonded(); refresh()
        #endif
    }
    func start(cloud: Bool, continuous: Bool) {
        guard featureIsBusy?() != true else { error = "请先结束眼镜录音或提词器任务，再开启语音待命。"; return }
        #if COMPANION_DEVICE
        prepare()
        guard controller.companionStart(cloud: cloud, continuous: continuous) else {
            error = "需要唯一已认证的眼镜；语音识别要用「Hermes 任务」页保存的桥接地址与令牌。"; refresh(); return
        }
        refresh()
        #endif
    }
    func stop() {
        #if COMPANION_DEVICE
        controller.companionStop(); refresh()
        #endif
    }
    func endRound() {
        #if COMPANION_DEVICE
        HermesVoiceHub.shared.finish()   // 收尾：先把攒下的音频交出去，再关本轮
        controller.companionEndRound(); refresh()
        #endif
    }
    /// 一轮语音收齐后由 HermesVoiceHub 调用：音频发给电脑桥接，原话回填对话流。
    /// 本机不再有 ASR 与模型；Hermes 的回答由「Hermes 任务」页的既有轮询显示。
    func deliverVoiceRound(pcm: Data) async {
        guard let hermes, hermes.configured else {
            failVoice("语音识别失败（bridge_unconfigured）：先到「Hermes 任务」页保存桥接地址与令牌。")
            return
        }
        let endpoint = hermes.endpoint
        guard let token = HermesTokenVault.get(endpoint) else {
            failVoice(HermesVoiceError.missingKey.localizedDescription)
            return
        }
        endRound()
        voiceStatus = "音频已发给电脑桥接，正在识别…"
        let turn = UUID()
        finishTimelineTurn(); activeTurn = turn
        do {
            let result = try await HermesVoiceClient.send(pcm: pcm, sampleRate: HermesVoiceAudio.sampleRate,
                                                          endpoint: endpoint, token: token)
            let text = String(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            transcript = text; transcriptFinal = true
            timeline?.record(ConversationEvent(id: turn, kind: .transcript, text: text, final: true))
            voiceTaskID = result.taskId.flatMap { $0.isEmpty ? nil : $0 }
            if let taskId = voiceTaskID {
                hermes.adoptVoiceTask(taskId: taskId, sessionId: result.sessionId)
                voiceStatus = "已交给 Hermes · 任务 " + String(taskId.prefix(8)) + "（进度与回答在「Hermes 任务」页）"
                timeline?.record(ConversationEvent(id: turn, kind: .answerDelta,
                    text: "已提交 Hermes 任务 " + String(taskId.prefix(8)) + "；回答在「Hermes 任务」页随轮询显示。"))
            } else {
                voiceStatus = "识别完成，但桥接没有返回任务号；请在「Hermes 任务」页核对。"
            }
        } catch let failure {
            let reason = (failure as? HermesVoiceError)?.localizedDescription
                ?? (failure as? HermesBridgeError)?.localizedDescription
                ?? "语音识别失败（request_failed）"
            failVoice(reason)
        }
    }
    /// 失败一律出声：屏幕上一句人话 + 既有弹窗，不静默、不崩。
    private func failVoice(_ reason: String) {
        voiceTaskID = nil
        voiceStatus = reason
        error = reason
    }
    func clearText() { transcript = ""; answer = ""; transcriptFinal = false; modelComplete = false }
    private func finishTimelineTurn() {
        if let id = activeTurn { timeline?.record(ConversationEvent(id: id, kind: .interrupted)); activeTurn = nil }
    }
}

#if COMPANION_DEVICE
struct VoiceDiagnosticsView: UIViewControllerRepresentable {
    let runtime: CompanionVoiceRuntime
    func makeUIViewController(context: Context) -> ProbeController { runtime.prepare(); return runtime.controller }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}
}
#endif
