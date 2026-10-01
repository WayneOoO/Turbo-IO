import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var timeline: ConversationTimeline
    @State private var showConfiguration = false
    @State private var showSimulation = false
    @State private var showDiagnostics = false
    @State private var useCloud = true
    @State private var continuous = true
    @State private var confirmStart = false
    var body: some View {
        Screen(title: "语音会话", eyebrow: "耳机收音 · 桥接识别 · Hermes 执行") {
            HStack {
                Label(runtime.phaseLabel, systemImage: runtime.enabled ? "waveform" : "moon")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(); Badge(text: runtime.supportsDevice ? (runtime.ready ? "已认证" : "未连接") : "模拟器预览")
            }.foregroundStyle(Palette.ink).padding(16).background(Palette.mint.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 18) {
                Label("你说的话", systemImage: "mic").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.transcript.isEmpty ? "唤醒后，桥接识别到的原话显示在这里" : runtime.transcript)
                    .font(.system(size: 18)).foregroundStyle(.white).privacySensitive()
                Divider().overlay(Palette.mint.opacity(0.3))
                Label("Hermes 回答", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.answer.isEmpty ? "回答在「Hermes 任务」页随桥接轮询显示，本 App 不再内置模型" : runtime.answer)
                    .font(.system(size: 16)).foregroundStyle(Palette.mint).lineSpacing(6).privacySensitive()
                if runtime.modelComplete { Text("模型输出已完成 · 不等于镜片渲染完成").font(.caption2).foregroundStyle(Palette.mint.opacity(0.6)) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("live-voice-content")
            if !runtime.voiceStatus.isEmpty {
                Text(runtime.voiceStatus).font(.caption).foregroundStyle(Palette.amber)
                    .accessibilityIdentifier("voice-bridge-status")
            }
            if !runtime.enabled {
                Text("麦克风未启用 · 没有音频正在传输").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text(runtime.phase == "idle" || runtime.phase == "waitingForConnection" ? "服务待命，不是全天录音；等眼镜主动唤醒。" : "本轮音频处理中；关闭待命可停止本轮与后续自动响应。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            HStack {
                Button("模型设置") { showConfiguration = true }.accessibilityIdentifier("model-settings")
                Spacer()
                Button("本地流程演示") { showSimulation = true }.accessibilityIdentifier("open-session-lab")
            }.font(.subheadline)
            NavigationLink { HermesCompanionView() } label: {
                Label("Hermes 任务", systemImage: "terminal")
            }.accessibilityIdentifier("hermes-conversation-entry")
            NavigationLink { ModelToolsView() } label: {
                Label("AI Tools · 查看模型可用工具", systemImage: "wrench.and.screwdriver")
            }.accessibilityIdentifier("model-tools-conversation-entry")
            if let error = timeline.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber)
            }
            NavigationLink { ConversationTimelineView() } label: {
                Card { FeatureRow(icon: "clock.arrow.circlepath", title: "对话时间轴", subtitle: "自动记录本机对话 · 导出与分享", status: "本地保存", active: true) }
            }.buttonStyle(.plain).accessibilityIdentifier("conversation-timeline")
            Card {
                Text("语音链路").font(.headline).foregroundStyle(Palette.ink)
                FeatureRow(icon: "waveform", title: "眼镜音频直发电脑桥接", subtitle: "桥接内置豆包 ASR 转文字，App 不保存语音密钥", status: "改造后")
                Divider().overlay(Palette.line)
                FeatureRow(icon: "bolt", title: "Hermes 执行 · 控制台轮询", subtitle: "任务号与回答在「Hermes 任务」页显示", status: "改造后")
                Divider().overlay(Palette.line)
                Text("App 不再连阿里云 ASR、不再连 DeepSeek、不再向模型发工具定义。唤醒后的音频只上传到你自己配置的电脑桥接；识别出的原话交给 Hermes，由 Hermes 自己决定用哪些工具。当前无 TTS。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if runtime.supportsDevice {
                Card {
                    Toggle("使用桥接识别", isOn: $useCloud).disabled(runtime.enabled)
                    Toggle("持续收声 · 允许插话", isOn: $continuous).disabled(runtime.enabled || !useCloud).accessibilityIdentifier("voice-continuous-draft")
                    Text(runtime.enabled ? (runtime.cloud && runtime.continuous ? "实际运行：持续收声 · 每段静音后各交一次" : "实际运行：非持续模式 · 输出时不保证插话") : "上方开关是下次启动配置，尚未运行")
                        .font(.caption).foregroundStyle(Palette.amber).accessibilityIdentifier("voice-effective-policy")
                    Text(useCloud ? "唤醒后的音频送往你自己的电脑桥接，识别与执行都在那一侧；录音只在待命会话内。" : "仅本机流程演示；回复每轮随机测试串，不识别、不上传。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("语音识别已内置在桥接（豆包 ASR），无需在这里配置任何密钥。")
                        .font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("voice-builtin-note")
                }
                if runtime.enabled {
                    PrimaryButton(title: "关闭待命", icon: "stop.circle") { runtime.stop() }
                    Button("结束本轮，保留待命") { runtime.endRound() }
                } else {
                    PrimaryButton(title: "开启眼镜语音待命", icon: "waveform", enabled: runtime.ready && (!useCloud || runtime.bridgeReady)) { confirmStart = true }
                }
                Button("连接与解绑管理") { showDiagnostics = true }
                Text(runtime.latestEvent).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            } else {
                Text("此构建不加载眼镜通信库，也不会调用云服务。真机请使用 RayNeoCompanionDevice 构建；下面的演示不代表实际收音。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Text("每段话说完后由手机侧静音判定收尾并提交一次；同一轮里继续说会另起一次提交。识别失败不静默，会在上方给出原因。")
                .font(.caption).foregroundStyle(Palette.amber)
            Button("清除本次屏幕文字") { runtime.clearText() }.font(.caption)
        }
        .onAppear { runtime.prepare(); reflectRunningPolicy() }
        .onChange(of: runtime.enabled) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.cloud) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.continuous) { _ in reflectRunningPolicy() }
        .sheet(isPresented: $showConfiguration) { ModelConfigurationView() }
        .sheet(isPresented: $showSimulation) { SessionSimulationView() }
        #if COMPANION_DEVICE
        .sheet(isPresented: $showDiagnostics, onDismiss: { runtime.refresh() }) {
            NavigationStack { VoiceDiagnosticsView(runtime: runtime).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDiagnostics = false } } } }
        }
        #endif
        .confirmationDialog(useCloud ? "开启后，主动唤醒会把音频发送到你自己配置的电脑桥接（识别与执行都在那一侧）。" : "开启本地随机回复测试，不上传语音。", isPresented: $confirmStart) {
            Button("确认开启待命") { runtime.start(cloud: useCloud, continuous: continuous) }
        }
        .alert("语音服务", isPresented: Binding(get: { runtime.error != nil }, set: { if !$0 { runtime.error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(runtime.error ?? "") }
    }
    private func reflectRunningPolicy() {
        guard runtime.enabled else { return }
        useCloud = runtime.cloud; continuous = runtime.continuous
    }
}
