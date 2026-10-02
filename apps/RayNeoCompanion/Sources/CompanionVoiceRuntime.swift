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
    /// 眼镜屏回答回显：本轮设备侧轮次号 + 「同一个任务只推一次」的记账。
    private var answerRound: UUID?
    private var answerWatch: Task<Void, Never>?
    private var pushedAnswerTaskIDs: [String] = []
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
        answerWatch?.cancel()
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
        cancelAnswerWatch()
        controller.companionStop(); refresh()
        #endif
    }
    func endRound() {
        #if COMPANION_DEVICE
        cancelAnswerWatch()
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
        // 设备侧本轮不结束：先切到「等待回答」，Hermes 跑完再把回答当云端文本下发到眼镜。
        beginAnswerRound()
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
                #if COMPANION_DEVICE
                controller.companionSetAnswerQuery(text)   // 眼镜屏「问题」栏 = 识别原话
                #endif
                hermes.adoptVoiceTask(taskId: taskId, sessionId: result.sessionId)
                voiceStatus = "已交给 Hermes · 任务 " + String(taskId.prefix(8)) + "（进度与回答在「Hermes 任务」页）"
                timeline?.record(ConversationEvent(id: turn, kind: .answerDelta,
                    text: "已提交 Hermes 任务 " + String(taskId.prefix(8)) + "；回答在「Hermes 任务」页随轮询显示。"))
                watchAnswer(taskId: taskId)
            } else {
                voiceStatus = "识别完成，但桥接没有返回任务号；请在「Hermes 任务」页核对。"
                await closeAnswerRoundWith("已识别，但电脑桥接没有返回任务号，回答无法上屏。")
            }
        } catch let failure {
            let reason = (failure as? HermesVoiceError)?.localizedDescription
                ?? (failure as? HermesBridgeError)?.localizedDescription
                ?? "语音识别失败（request_failed）"
            failVoice(reason)
            await closeAnswerRoundWith("语音识别失败，本轮没有提交任务。")
        }
    }
    /// 失败一律出声：屏幕上一句人话 + 既有弹窗，不静默、不崩。
    private func failVoice(_ reason: String) {
        voiceTaskID = nil
        voiceStatus = reason
        error = reason
    }

    // MARK: - 眼镜屏回答回显（Hermes 任务跑完 → 当云端文本下发 type32 / type12）

    /// 语音轮提交前把设备侧本轮切到「等待回答」，并记住本轮轮次号。
    /// 这样眼镜不会收到退出命令，回答回来时还有页面可以渲染。
    private func beginAnswerRound() {
        #if COMPANION_DEVICE
        cancelAnswerWatch()
        answerRound = controller.companionBeginAnswerRound(query: "")
        if answerRound == nil {
            controller.companionEndRound()
            voiceStatus = "眼镜本轮已结束；回答只能在手机上查看。"
        } else {
            controller.companionKeepAnswerRoundAlive()
        }
        #endif
    }

    /// 起一轮「等 Hermes 跑完」的轮询；同一个任务号只推一次。
    private func watchAnswer(taskId: String) {
        #if COMPANION_DEVICE
        guard answerRound != nil, !pushedAnswerTaskIDs.contains(taskId) else { return }
        answerWatch?.cancel()
        answerWatch = Task { @MainActor [weak self] in await self?.pollAnswer(taskId: taskId) }
        #endif
    }

    /// 复用既有 GET /v1/hermes/state 轮询，不新造接口；只有任务终态才把回答推给眼镜。
    private func pollAnswer(taskId: String) async {
        #if COMPANION_DEVICE
        let giveUp = Date().addingTimeInterval(300)     // 超过 5 分钟：给一句人话收尾，别让镜片一直等
        while !Task.isCancelled {
            controller.companionKeepAnswerRoundAlive()   // 持续收声模式：别让设备侧看门狗提前关轮
            await hermes?.refresh()
            if let task = hermes?.state?.tasks.first(where: { $0.id == taskId }) {
                switch task.status {
                case "done":
                    await finishAnswer(task.answer, fallback: "任务已完成，但没有可显示的回答。", taskId: taskId)
                    return
                case "failed":
                    await finishAnswer("任务未完成，请到「Hermes 任务」页查看原因。", fallback: "任务未完成。", taskId: taskId)
                    return
                case "stopped":
                    await finishAnswer("任务已停止，没有回答。", fallback: "任务已停止。", taskId: taskId)
                    return
                default:
                    break
                }
            }
            if Date() >= giveUp {
                await finishAnswer("任务还在执行，回答稍后可在「Hermes 任务」页查看。", fallback: "任务还在执行。", taskId: taskId)
                return
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
        #endif
    }

    /// 收尾：把最终文本切片下发（末片 final:true 触发 type12），并记账只推一次。
    private func finishAnswer(_ raw: String, fallback: String, taskId: String) async {
        pushedAnswerTaskIDs.append(taskId)
        if pushedAnswerTaskIDs.count > 32 { pushedAnswerTaskIDs.removeFirst(pushedAnswerTaskIDs.count - 32) }
        #if COMPANION_DEVICE
        let text = HermesAnswerText.plain(raw)
        let sent = await pushAnswerText(text.isEmpty ? fallback : text)
        if sent {
            voiceStatus = "回答已发到眼镜屏（任务 " + String(taskId.prefix(8)) + "）"
        } else if let round = answerRound, controller.companionAnswerRoundID == round {
            // 本轮还开着但一片都没写进去：结束本轮，别让镜片停在「正在生成回答」。
            controller.companionAnswerFailed()
            answerRound = nil
            voiceStatus = "回答没上屏：本轮已结束，请在手机上查看。"
        } else {
            voiceStatus = "回答没上屏：眼镜本轮已结束或被新的语音轮替换。"
        }
        #endif
    }

    /// 没有任务号 / 识别失败：也给眼镜一句人话，别让它停在「正在生成回答」。
    private func closeAnswerRoundWith(_ text: String) async {
        #if COMPANION_DEVICE
        _ = await pushAnswerText(HermesAnswerText.plain(text))
        #endif
    }

    /// 逐片下发（每片 ≤512 字节，末片 isFinal:true）；片间留 60ms，别一次灌爆传输队列。
    /// 返回 false = 本轮已被取消/替换/掉线，不再重试。
    private func pushAnswerText(_ text: String) async -> Bool {
        #if COMPANION_DEVICE
        guard let round = answerRound, controller.companionAnswerRoundID == round else { return false }
        let pieces = HermesAnswerText.chunks(HermesAnswerText.prefix(text, bytes: HermesAnswerText.maximumBytes))
        guard !pieces.isEmpty else { return false }
        for (index, piece) in pieces.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return false }
            guard controller.companionPushAnswer(piece, isFinal: index == pieces.count - 1) else { return false }
        }
        answerRound = nil
        return true
        #else
        return false
        #endif
    }

    private func cancelAnswerWatch() {
        #if COMPANION_DEVICE
        answerWatch?.cancel(); answerWatch = nil; answerRound = nil
        #endif
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
