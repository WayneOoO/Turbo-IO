import SwiftUI

struct HermesCompanionView: View {
    @EnvironmentObject private var hermes: HermesCompanion
    @EnvironmentObject private var push: HermesPush
    @EnvironmentObject private var notifications: CompanionNotifications
    @Environment(\.scenePhase) private var scenePhase
    @State private var endpoint = ""
    @State private var token = ""
    @State private var voiceTools = false
    @State private var prompt = ""
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Label("你的电脑，眼镜里的 Hermes", systemImage: "terminal").font(.headline)
                    Text("发任务、查进度、续聊会话；显示真实工具步骤、档位与会话号。电脑独立执行，眼镜语音不必一直等待；本 App 没有审批环节。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text(hermes.status).font(.caption).accessibilityIdentifier("hermes-status")
                    if let state = hermes.state {
                        Text(state.workspace).font(.caption2).textSelection(.enabled)
                        Badge(text: state.online ? "桥接在线" : "桥接离线", active: state.online)
                    }
                }
                Card {
                    Text("电脑桥接").font(.headline)
                    TextField("HTTPS 地址", text: $endpoint).accessibilityIdentifier("hermes-endpoint")
                    SecureField("独立访问令牌（留空保留）", text: $token).privacySensitive().accessibilityIdentifier("hermes-token")
                    Toggle("允许语音把任务交给 Hermes 工具", isOn: $voiceTools).accessibilityIdentifier("hermes-voice-tools")
                    Text("开启后，语音识别出的任务文字可能发送到此电脑及 Hermes。音频只上传到你自己的桥接；不接管已有桌面任务。语音识别由桥接完成，不需要这里的模型密钥。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Button("保存配置，不启动任务") {
                        do { try hermes.save(endpoint: endpoint, token: token, voiceTools: voiceTools); token = "" }
                        catch { self.error = error.localizedDescription; token = "" }
                    }.disabled(hermes.busy || hermes.hasUnknownDelivery).accessibilityIdentifier("hermes-save")
                    Button("连接／刷新状态") { Task { await hermes.refresh() } }
                        .disabled(!hermes.configured).accessibilityIdentifier("hermes-refresh")
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Card {
                    Toggle("Hermes 完成和失败时主动提醒", isOn: Binding(get: { push.enabled }, set: { push.setEnabled($0) }))
                        .accessibilityIdentifier("hermes-push-enabled")
                    Text(push.status).font(.caption).accessibilityIdentifier("hermes-push-status")
                    Text(notifications.testStatus).font(.caption2).accessibilityIdentifier("hermes-push-delivery")
                    NavigationLink("眼镜通知开关与发送测试") { NotificationCenterView() }
                    Text("开启后只提醒新事件；步骤与档位属过程事件，留本页查看。提醒只负责通知，不代表任何操作已被批准。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("已允许眼镜通知时，连接后会恢复此总开关；不会替换其他 App 来源过滤设置。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    Text("当前是 App 获准运行时约每两秒检查；未接 APNs，系统挂起或强退后不能保证及时提醒。电脑桥接内存最多保留128条事件，重启会清空。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
                if hermes.hasUnknownDelivery {
                    Card {
                        Label("上次提交结果待核对", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
                        Text("保留同一请求编号，不自动创建第二个任务。网络恢复后先核对。待核对内容临时保存在本机，确认后清除。")
                            .font(.caption)
                        Button("核对上次提交") { Task { await hermes.retryPending() } }.disabled(hermes.busy)
                    }
                }
                Card {
                    HStack {
                        Text("当前任务").font(.headline); Spacer()
                        Button("改为新任务") { hermes.select(nil) }.disabled(hermes.busy || hermes.hasUnknownDelivery)
                    }
                    Text(currentTarget)
                        .font(.caption).accessibilityIdentifier("hermes-current-target")
                    TextField("交给 Hermes 的要求…", text: $prompt, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("hermes-prompt")
                    Button("填入随机校验测试") {
                        prompt = "这是 Turbo IO 连接测试。不要读写文件或运行工具，只回复：Hermes 校验 " + String(UUID().uuidString.prefix(6))
                    }.accessibilityIdentifier("hermes-fixture")
                    HStack {
                        Button("发送到电脑") {
                            Task { do { try await hermes.ask(text: prompt); prompt = "" } catch { self.error = error.localizedDescription } }
                        }
                            .disabled(!hermes.configured || hermes.busy || hermes.hasUnknownDelivery || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("hermes-send")
                        Spacer()
                        Button("停止任务", role: .destructive) { Task { do { try await hermes.stop() } catch { self.error = error.localizedDescription } } }
                            .disabled(!hermes.canStop || hermes.busy || hermes.hasUnknownDelivery)
                            .accessibilityIdentifier("hermes-stop")
                    }
                }
                if let task = hermes.selected { detail(task) }
                if let tasks = hermes.state?.tasks, !tasks.isEmpty {
                    Card {
                        Text("桥接管理的任务").font(.headline)
                        ForEach(tasks) { task in
                            row(task)
                            if task.id != tasks.last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
                Text("页面前台每两秒刷新。关闭页面不停止电脑任务；本版不承诺 iOS 后台实时通知。语音可问“Hermes 做完了吗？”。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(22)
        }.background(Palette.background).navigationTitle("Hermes 控制台").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .onAppear { endpoint = hermes.endpoint; voiceTools = hermes.voiceToolsEnabled }
            .task {
                while !Task.isCancelled {
                    if scenePhase == .active { await hermes.refresh() }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
            .alert("Hermes 桥接", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    private var currentTarget: String {
        guard let id = hermes.selectedTaskID else { return "下一条将新建会话" }
        let session = hermes.selectedSessionID.map { String($0.suffix(6)) } ?? "新建"
        return "任务 \(String(id.prefix(8))) · 会话 \(session)"
    }

    /// 状态 + 档位徽章 + 耗时 + 会话号后 6 位。
    private func row(_ task: HermesTask) -> some View {
        Button { hermes.select(task.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(HermesText.status(task.status)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(task.text.isEmpty ? "（没有记录原话）" : task.text)
                        .font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                    HStack(spacing: 5) {
                        Text("耗时 " + HermesText.duration(task.durationMs))
                        Text("·")
                        Text("会话 " + task.sessionSuffix)
                    }.font(.caption2).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if let tier = task.tier, !tier.isEmpty { Badge(text: tier) }
                if task.id == hermes.selectedTaskID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(hermes.busy || hermes.hasUnknownDelivery)
            .accessibilityIdentifier("hermes-task-\(task.id)")
            .accessibilityLabel("\(HermesText.status(task.status))，会话 \(task.sessionSuffix)，耗时 \(HermesText.duration(task.durationMs))")
    }

    /// ① 步骤时间线（真实工具调用）② 回答正文，随轮询刷新。
    private func detail(_ task: HermesTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(HermesText.status(task.status)).font(.headline)
                if let tier = task.tier, !tier.isEmpty { Badge(text: "档位 " + tier, active: true) }
                Spacer()
                Text("耗时 " + HermesText.duration(task.durationMs)).font(.caption2).foregroundStyle(Palette.muted)
            }
            Text("会话 \(task.sessionSuffix) · 任务 \(String(task.id.prefix(8)))")
                .font(.caption2).foregroundStyle(Palette.muted).textSelection(.enabled)
            if task.steps.isEmpty {
                Text(task.running ? "等待 Hermes 汇报第一个步骤…" : "这次任务没有工具步骤。")
                    .font(.caption).foregroundStyle(Palette.muted)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("真实步骤").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            dot(step.status)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text("\(index + 1). \(step.name)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Badge(text: HermesText.stepStatus(step.status))
                                    Text(HermesText.duration(step.durationMs)).font(.caption2).foregroundStyle(Palette.muted)
                                }
                                if !step.detail.isEmpty {
                                    Text(step.detail).font(.caption2).foregroundStyle(Palette.muted)
                                        .lineLimit(3).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if !task.error.isEmpty {
                Label(task.error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber)
            }
            Divider().overlay(Palette.mint.opacity(0.3))
            Text(task.answer.isEmpty ? (task.running ? "Hermes 正在执行，回答稍后出现" : "还没有收到 Hermes 输出") : task.answer)
                .font(.system(size: 15)).textSelection(.enabled).privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("hermes-output")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Palette.mint)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
    }

    /// running 转圈、error 红点、done 绿点。
    @ViewBuilder private func dot(_ status: String) -> some View {
        if status == "running" {
            ProgressView().controlSize(.mini).frame(width: 14, height: 16)
        } else {
            Circle().fill(status == "error" ? Color.red : Palette.green)
                .frame(width: 9, height: 9).padding(.top, 6)
        }
    }
}
