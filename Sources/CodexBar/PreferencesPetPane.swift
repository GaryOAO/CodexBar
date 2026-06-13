import CodexBarCore
import Foundation
import SwiftUI

@MainActor
struct PetPane: View {
    @Bindable var settings: SettingsStore

    @State private var hookStatus: String = ""
    @State private var hookBusy = false
    @State private var bleState: String = "—"
    @State private var firmware: String = "—"
    @State private var peripheralName: String = "—"
    @State private var lastRSSI: String = "—"
    @State private var lastWrite: String = "—"
    @State private var lastTheme: String = "—"
    @State private var lastStatus: PetStatus?
    @State private var lastCodexStatus: PetCodexStatus?
    @State private var lastCodexWrite: String = "—"
    @State private var deviceState: PetDeviceState?
    @State private var deviceStateUpdatedAt: Date?
    @State private var testStatus: String = ""
    @State private var runtimeDetail: String = "—"
    @State private var bleRuntimeDetail: String = "—"
    @State private var bleAuthorization: String = "—"

    // Display config UI state. Seeded from the pet on appear (if connected),
    // otherwise defaults to English / Overview / both providers.
    @State private var displayLocale: PetDisplayConfig.Locale = .english
    @State private var displayDefaultLayout: PetDisplayConfig.Layout = .overview
    @State private var displayHideCodex: Bool = false
    @State private var displayCompact: Bool = false
    @State private var displayConfigSentAt: Date?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(
                    title: "桌宠 Hook（CLI 生命周期桥接）",
                    caption: """
                    将 Claude Code 和 Codex CLI 的 Hook 事件（SessionStart、PreToolUse、PostToolUse、Stop、\
                    UserPromptSubmit）转发到 CodexBar 的本地 Unix socket，让 ESP32-S3 桌宠实时响应编码活动。
                    """) {
                        HStack(spacing: 8) {
                            Button {
                                self.runHookInstall()
                            } label: {
                                if self.hookBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("安装桌宠 Hook")
                                }
                            }
                            .disabled(self.hookBusy)

                            Button("卸载") {
                                self.runHookUninstall()
                            }
                            .disabled(self.hookBusy)

                            Spacer()
                        }
                        if !self.hookStatus.isEmpty {
                            Text(self.hookStatus)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("会写入 Hook 命令到 ~/.claude/settings.json 和 ~/.codex/config.toml；可重复执行。")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }

                Divider()

                SettingsSection(
                    title: "桌宠连接（BLE）",
                    caption: """
                    连接 ESP32-S3 RLCD 桌宠。状态面板会同步当前 Claude 提供商的 5 小时和每周用量；\
                    可用测试按钮确认桌宠响应正常。
                    """) {
                        PreferenceToggleRow(
                            title: "启用桌宠连接",
                            subtitle: "启动本地 Hook socket，扫描 BLE 桌宠，并推送状态更新。",
                            binding: self.$settings.petEnabled)

                        HStack(spacing: 12) {
                            Image(systemName: self.bleState == "ready"
                                ? "dot.radiowaves.left.and.right"
                                : "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(self.bleState == "ready" ? Color.green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("连接状态：\(self.localizedBleState)")
                                    .font(.body)
                                Text("固件版本：\(self.firmware)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button("授权 / 重新连接蓝牙") {
                                self.requestForegroundBluetoothStart()
                            }
                            .disabled(!self.settings.petEnabled)

                            Button("打开系统蓝牙权限") {
                                self.openBluetoothPrivacy()
                            }
                            .disabled(!self.settings.petEnabled)

                            Button("显示 App") {
                                self.revealCodexBarApp()
                            }
                            .disabled(!self.settings.petEnabled)

                            Button("复制路径") {
                                self.copyCodexBarAppPath()
                            }
                            .disabled(!self.settings.petEnabled)

                            Text(
                                "ClawdPet 通常不会出现在系统蓝牙设备列表；这里显示“已连接”才是准确信号。若系统没有弹出权限，请允许 CodexBar 或 CodexBar BLE Helper 使用蓝牙。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .controlSize(.small)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("实时详情")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading),
                                ],
                                alignment: .leading,
                                spacing: 8)
                            {
                                self.detailCell("设备", self.peripheralName)
                                self.detailCell("信号", self.lastRSSI)
                                self.detailCell("最后推送", self.lastWrite)
                                self.detailCell("主题", self.lastTheme)
                                self.detailCell("授权", self.bleAuthorization)
                                self.detailCell("运行时", self.runtimeDetail)
                                self.detailCell("蓝牙", self.bleRuntimeDetail)
                            }

                            self.deviceStateSection(self.deviceState, updatedAt: self.deviceStateUpdatedAt)

                            Divider()
                                .opacity(0.5)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading),
                                ],
                                alignment: .leading,
                                spacing: 8)
                            {
                                if let status = self.lastStatus {
                                    self.detailCell("模式", self.modeLabel(status.mode))
                                    self.detailCell(
                                        "5 小时",
                                        "\(status.usage5hPct)% 已用 / \(100 - min(status.usage5hPct, 100))% 剩余")
                                    self.detailCell(
                                        "每周",
                                        "\(status.usageWeekPct)% 已用 / \(100 - min(status.usageWeekPct, 100))% 剩余")
                                    self.detailCell("今日 Token", self.formatTokens(status.todayTokens))
                                    self.detailCell("5h 重置", self.formatReset(status.reset5hMinutes))
                                    self.detailCell("周重置", self.formatReset(status.resetWeekMinutes))
                                    self.detailCell("同步标记", self.formatFlags(status.flags))
                                    self.detailCell("同步载荷", self.payloadSummary(status))
                                    if let codex = self.lastCodexStatus {
                                        self.detailCell("Codex 今日", self.formatTokens(codex.todayTokens))
                                        self.detailCell("Codex 推送", self.lastCodexWrite)
                                    }
                                } else {
                                    self.detailCell("同步载荷", "还没有推送过状态")
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Group {
                            Text("主题")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            HStack(spacing: 8) {
                                Button("Clawd") { self.sendTheme(.clawd) }
                                Text("RLCD 固定使用同一套 Clawd 身份；旧主题值会在固件端归一化。")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .controlSize(.small)

                            Text("性格")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Picker("性格", selection: self.$settings.petPersonality) {
                                ForEach(PetPersonality.allCases) { personality in
                                    Text(self.personalityLabel(personality)).tag(personality)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("每 \(Int(self.settings.petPushIntervalSeconds)) 秒推送一次")
                                        .font(.body)
                                    Spacer()
                                }
                                Slider(
                                    value: self.$settings.petPushIntervalSeconds,
                                    in: 1...30,
                                    step: 1)
                                Text("CodexBar 通过 BLE 刷新桌宠状态的频率。")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }

                            PreferenceToggleRow(
                                title: "随机短句",
                                subtitle: "空闲时允许桌宠偶尔说一句。",
                                binding: self.$settings.petQuipsEnabled)
                            PreferenceToggleRow(
                                title: "微动作眨眼",
                                subtitle: "工具事件之间显示轻微的眨眼动画。",
                                binding: self.$settings.petMicroActionsEnabled)
                            PreferenceToggleRow(
                                title: "Token 里程碑庆祝",
                                subtitle: "当天 Token 数达到整点里程碑时显示庆祝效果。",
                                binding: self.$settings.petMilestoneCelebrationsEnabled)
                            PreferenceToggleRow(
                                title: "安静时段",
                                subtitle: "在设定时间内让桌宠变暗或休眠。",
                                binding: self.$settings.petQuietHoursEnabled)

                            if self.settings.petQuietHoursEnabled {
                                HStack(spacing: 16) {
                                    Stepper(
                                        "开始：\(self.settings.petQuietHoursStart):00",
                                        value: self.$settings.petQuietHoursStart,
                                        in: 0...23)
                                    Stepper(
                                        "结束：\(self.settings.petQuietHoursEnd):00",
                                        value: self.$settings.petQuietHoursEnd,
                                        in: 0...23)
                                    Spacer()
                                }
                                .controlSize(.small)
                            }

                            Text("用量显示")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Picker("用量显示", selection: self.$settings.petUsageDisplay) {
                                ForEach(PetUsageDisplayMode.allCases) { mode in
                                    Text(self.usageDisplayLabel(mode)).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("测试")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            HStack(spacing: 8) {
                                Button("发送测试脉冲") { self.sendTestPulse() }
                                Button("发送断开状态") { self.sendDisconnectedTest() }
                                Button("发送 1B 里程碑") { self.sendMilestoneTest() }
                                Button("发送过热状态") { self.sendOverheatedTest() }
                                Spacer()
                            }
                            .controlSize(.small)
                        }
                        .disabled(!self.settings.petEnabled)

                        if !self.testStatus.isEmpty {
                            Text(self.testStatus)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                // ── Display config: pushed to the pet over BLE ffe6 and
                // persisted in NVS so the pet remembers user preference
                // across reboots. Adding more knobs later means extending
                // PetDisplayConfig + this section.
                SettingsSection(
                    title: "屏幕显示（Pet Display）",
                    caption: """
                    选择桌宠屏幕上的标签语言、开机默认页面，以及是否隐藏 Codex 列。\
                    设置写入桌宠后会持久保存到设备 NVS，断电不丢失。
                    """) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("标签语言")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Picker("标签语言", selection: self.$displayLocale) {
                                ForEach(PetDisplayConfig.Locale.allCases, id: \.self) { loc in
                                    Text(loc.displayName).tag(loc)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("默认页面")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Picker("默认页面", selection: self.$displayDefaultLayout) {
                                ForEach(PetDisplayConfig.Layout.allCases, id: \.self) { l in
                                    Text(l.displayName).tag(l)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Toggle(
                                "隐藏 Codex 列（单 provider 模式）",
                                isOn: self.$displayHideCodex)
                            Toggle(
                                "紧凑模式（更小的字 / 间距）",
                                isOn: self.$displayCompact)

                            HStack {
                                Button("应用到桌宠") { self.applyDisplayConfig() }
                                    .keyboardShortcut(.defaultAction)
                                Spacer()
                                if let sent = self.displayConfigSentAt {
                                    Text("已应用：\(self.relativeTime(sent))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(!self.settings.petEnabled)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            self.refreshState()
            self.seedDisplayConfigFromPet()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            self.refreshState()
        }
    }

    private var localizedBleState: String {
        switch self.bleState {
        case "disabled": "未启用"
        case "starting": "启动中"
        case "off": "关闭"
        case "authorizing": "等待系统授权"
        case "permissionRequired": "需要蓝牙授权"
        case "scanning": "扫描中"
        case "connecting": "连接中"
        case "ready": "已连接"
        default: self.bleState
        }
    }

    private var localizedBleAuthorization: String {
        let raw = UserDefaults.standard.object(forKey: "petBleAuthorization") as? Int
        return switch raw {
        case 0: "未决定"
        case 1: "受限制"
        case 2: "已拒绝"
        case 3: "已允许"
        default: "—"
        }
    }

    private func usageDisplayLabel(_ mode: PetUsageDisplayMode) -> String {
        switch mode {
        case .remaining: "剩余"
        case .used: "已用"
        case .both: "同时显示"
        }
    }

    private func personalityLabel(_ personality: PetPersonality) -> String {
        switch personality {
        case .calm: "冷静"
        case .playful: "活泼"
        case .focus: "专注"
        }
    }

    private func detailCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceStateSection(_ state: PetDeviceState?, updatedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text("板端状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            if let state {
                self.deviceStateRow("房间", self.formatRoom(state))
                self.deviceStateRow("供电", self.formatPower(state))
                self.deviceStateRow("Clawd 状态", self.formatClawdState(state))
                self.deviceStateRow("更新时间", self.formatDeviceStateUpdatedAt(updatedAt))
            } else {
                Text("等待桌宠上报真实状态")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func deviceStateRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeLabel(_ raw: UInt8) -> String {
        guard let mode = PetMode(rawValue: raw) else { return "未知(\(raw))" }
        switch mode {
        case .greeting: return "问候"
        case .idle: return "待机"
        case .thinking: return "思考"
        case .working: return "工作"
        case .outputting: return "输出"
        case .debugging: return "阅读/排错"
        case .wizard: return "联网"
        case .carrying: return "搬运"
        case .conducting: return "编排"
        case .juggling: return "多任务"
        case .sweeping: return "整理"
        case .ultraThink: return "深度思考"
        case .overheated: return "过热"
        case .reviewing: return "检查"
        case .notification: return "提醒"
        case .error: return "错误"
        case .disconnected: return "断连"
        case .celebrating: return "庆祝"
        case .resting: return "休息"
        }
    }

    private func formatTokens(_ tokens: UInt32) -> String {
        switch tokens {
        case 1_000_000_000...:
            String(format: "%.1fB", Double(tokens) / 1_000_000_000.0)
        case 1_000_000...:
            String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        case 1000...:
            String(format: "%.1fK", Double(tokens) / 1000.0)
        default:
            "\(tokens)"
        }
    }

    private func formatReset(_ minutes: UInt16) -> String {
        if minutes == PetStatus.unknownReset { return "未知" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }

    private func formatFlags(_ flags: UInt8) -> String {
        var parts: [String] = []
        if flags & PetStatus.flagBitFiveHourWarning != 0 { parts.append("5h 警告") }
        if flags & PetStatus.flagBitWeeklyWarning != 0 { parts.append("周警告") }
        if flags & PetStatus.flagBitRateLimited != 0 { parts.append("限速") }
        if flags & PetStatus.flagBitAnyFetching != 0 { parts.append("刷新中") }
        if flags & PetStatus.flagBitQuipsDisabled != 0 { parts.append("短句关") }
        if flags & PetStatus.flagBitMicroActionsDisabled != 0 { parts.append("微动作关") }
        if flags & PetStatus.flagBitMilestonesDisabled != 0 { parts.append("里程碑关") }
        if flags & PetStatus.flagBitQuietHoursActive != 0 { parts.append("安静时段") }
        return parts.isEmpty ? "无" : parts.joined(separator: "、")
    }

    private func payloadSummary(_ status: PetStatus) -> String {
        status.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func formatRoom(_ state: PetDeviceState) -> String {
        let temp = state.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "温度未知"
        let humidity = state.humidityPct.map { "湿度 \($0)%" } ?? "湿度未知"
        return "\(temp) · \(humidity)"
    }

    private func formatPower(_ state: PetDeviceState) -> String {
        let battery = state.batteryPct.map { "电量 \($0)%" } ?? "电量未知"
        let voltage = state.batteryVolts.map { String(format: "%.2f V", $0) } ?? "电压未知"
        return "\(battery) · \(voltage)"
    }

    private func formatClawdState(_ state: PetDeviceState) -> String {
        [
            "Lv \(state.petLevel)",
            "饥饿 \(state.hunger)",
            "快乐 \(state.happiness)",
            "精力 \(state.energy)",
            "心情 \(state.mood >= 0 ? "+\(state.mood)" : "\(state.mood)")",
            "亲密 \(state.bond)",
            "压力 \(state.stress)",
            self.formatSleepFlags(state),
            "运行 \(self.formatUptime(state.uptimeSeconds))",
        ].joined(separator: " · ")
    }

    private func formatSleepFlags(_ state: PetDeviceState) -> String {
        var parts: [String] = []
        if state.isLocalQuiet { parts.append("安静中") }
        if state.isSoftPowerOff { parts.append("软关机") }
        if state.isPanelSleepActive { parts.append("面板睡眠") }
        return parts.isEmpty ? "清醒" : parts.joined(separator: "、")
    }

    private func formatUptime(_ seconds: UInt16) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分 \(seconds % 60) 秒" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }

    private func formatDeviceStateUpdatedAt(_ updatedAt: Date?) -> String {
        updatedAt.map { Self.relativeTimeFormatter.localizedString(for: $0, relativeTo: Date()) } ?? "—"
    }

    private func sendTheme(_ theme: PetTheme) {
        PetSharedAccess.setTheme(theme)
        self.testStatus = "已发送主题：\(theme)"
    }

    /// Seed the display-config UI from whatever the pet last persisted to
    /// NVS (read on connect via PetBLEClient.lastDisplayConfig). Falls back
    /// to defaults when the pet hasn't been seen yet.
    private func seedDisplayConfigFromPet() {
        guard let cfg = PetSharedAccess.snapshot()?.lastDisplayConfig else { return }
        self.displayLocale = cfg.locale
        self.displayDefaultLayout = cfg.defaultLayout
        self.displayHideCodex = cfg.hideCodex
        self.displayCompact = cfg.compactMode
    }

    /// Bundle the UI state into a PetDisplayConfig and push to the pet
    /// (BLE characteristic ffe6). The pet validates + persists to NVS so
    /// the choice survives a reboot.
    private func applyDisplayConfig() {
        let cfg = PetDisplayConfig(
            locale: self.displayLocale,
            defaultLayout: self.displayDefaultLayout,
            hideCodex: self.displayHideCodex,
            compactMode: self.displayCompact)
        PetSharedAccess.setDisplayConfig(cfg)
        self.displayConfigSentAt = Date()
        self.testStatus = "已应用显示设置"
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func requestForegroundBluetoothStart() {
        NSApp.activate(ignoringOtherApps: true)
        PetSharedAccess.requestForegroundStart?()
        self.testStatus = "已请求前台蓝牙授权 / 重新连接"
        self.refreshState()
    }

    private func openBluetoothPrivacy() {
        SystemSettingsLinks.openBluetoothPrivacy()
        self.testStatus = "已打开系统蓝牙权限设置；允许 CodexBar 后请点击重新连接"
    }

    private func revealCodexBarApp() {
        SystemSettingsLinks.revealInstalledCodexBarApp()
        self.testStatus = "已在 Finder 中定位 CodexBar.app"
    }

    private func copyCodexBarAppPath() {
        SystemSettingsLinks.copyInstalledCodexBarAppPath()
        self.testStatus = "已复制 /Applications/CodexBar.app"
    }

    private func sendTestPulse() {
        guard PetSharedAccess.client != nil || PetSharedAccess.helper != nil else {
            self.testStatus = "桌宠客户端尚未启动"
            return
        }
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 42,
            usageWeekPct: 73,
            mode: PetMode.celebrating.rawValue,
            flags: 0,
            presentation: self.presentationByte(),
            todayTokens: 125_000,
            epochSeconds: UInt32(Date().timeIntervalSince1970))
        PetSharedAccess.pushStatus(status)
        self.testStatus = "测试脉冲已发送"
    }

    private func sendDisconnectedTest() {
        guard PetSharedAccess.client != nil || PetSharedAccess.helper != nil else {
            self.testStatus = "桌宠客户端尚未启动"
            return
        }
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 0,
            usageWeekPct: 0,
            mode: PetMode.disconnected.rawValue,
            flags: 0,
            presentation: self.presentationByte(),
            todayTokens: 0,
            epochSeconds: UInt32(Date().timeIntervalSince1970))
        PetSharedAccess.pushStatus(status)
        self.testStatus = "断开状态已发送"
    }

    private func sendMilestoneTest() {
        guard PetSharedAccess.client != nil || PetSharedAccess.helper != nil else {
            self.testStatus = "桌宠客户端尚未启动"
            return
        }
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 50,
            usageWeekPct: 50,
            mode: PetMode.celebrating.rawValue,
            flags: 0,
            presentation: self.presentationByte(),
            todayTokens: 1_000_000_000,
            epochSeconds: UInt32(Date().timeIntervalSince1970))
        PetSharedAccess.pushStatus(status)
        self.testStatus = "1B 里程碑已发送"
    }

    private func sendOverheatedTest() {
        guard PetSharedAccess.client != nil || PetSharedAccess.helper != nil else {
            self.testStatus = "桌宠客户端尚未启动"
            return
        }
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 95,
            usageWeekPct: 92,
            mode: PetMode.overheated.rawValue,
            flags: PetStatus.flagBitFiveHourWarning | PetStatus.flagBitWeeklyWarning | PetStatus.flagBitRateLimited,
            presentation: self.presentationByte(),
            todayTokens: 0,
            epochSeconds: UInt32(Date().timeIntervalSince1970))
        PetSharedAccess.pushStatus(status)
        self.testStatus = "过热状态已发送"
    }

    private func presentationByte() -> UInt8 {
        self.settings.petUsageDisplay.wireValue | (self.settings.petPersonality.wireValue << 4)
    }

    private func refreshState() {
        guard self.settings.petEnabled else {
            self.bleState = "disabled"
            self.firmware = "—"
            self.peripheralName = "—"
            self.lastRSSI = "—"
            self.lastStatus = nil
            self.lastCodexStatus = nil
            self.lastCodexWrite = "—"
            self.deviceState = nil
            self.deviceStateUpdatedAt = nil
            self.runtimeDetail = "已禁用"
            self.bleRuntimeDetail = "—"
            self.bleAuthorization = "—"
            return
        }
        if let snapshot = PetSharedAccess.snapshot() {
            self.bleState = snapshot.state
            self.firmware = snapshot.firmwareInfo ?? "—"
            self.peripheralName = snapshot.peripheralName ?? "—"
            self.lastRSSI = snapshot.rssi.map { "\($0) dBm" } ?? "—"
            self.lastStatus = snapshot.lastStatus
            self.lastCodexStatus = snapshot.lastCodexStatus
            self.lastCodexWrite = snapshot.lastCodexStatusSentAt.map {
                Self.relativeTimeFormatter.localizedString(
                    for: Date(timeIntervalSince1970: $0),
                    relativeTo: Date())
            } ?? "—"
            self.deviceState = snapshot.deviceState
            self.deviceStateUpdatedAt = snapshot.deviceStateUpdatedAt.map(Date.init(timeIntervalSince1970:))
            self.lastWrite = snapshot.lastStatusSentAt.map {
                Self.relativeTimeFormatter.localizedString(
                    for: Date(timeIntervalSince1970: $0),
                    relativeTo: Date())
            } ?? "—"
            self.lastTheme = snapshot.lastTheme.map { "\($0)" } ?? "—"
            self.runtimeDetail = UserDefaults.standard.string(forKey: "petRuntimeDetail") ?? "—"
            self.bleRuntimeDetail = snapshot.runtimeDetail
            self.bleAuthorization = self.authorizationLabel(snapshot.authorizationRawValue)
            return
        }
        guard let client = PetSharedAccess.client else {
            self.bleState = "starting"
            self.firmware = "—"
            self.peripheralName = "—"
            self.lastRSSI = "—"
            self.lastStatus = nil
            self.lastCodexStatus = nil
            self.lastCodexWrite = "—"
            self.deviceState = nil
            self.deviceStateUpdatedAt = nil
            self.runtimeDetail = UserDefaults.standard.string(forKey: "petRuntimeDetail") ?? "启动中"
            self.bleRuntimeDetail = UserDefaults.standard.string(forKey: "petBleRuntimeDetail") ?? "—"
            self.bleAuthorization = self.localizedBleAuthorization
            return
        }
        self.bleState = String(describing: client.state)
        self.firmware = client.firmwareInfo ?? "—"
        self.peripheralName = client.peripheralName ?? "—"
        self.lastRSSI = client.lastRSSI.map { "\($0) dBm" } ?? "—"
        self.lastStatus = client.lastStatus
        self.lastCodexStatus = client.lastCodexStatus
        self.lastCodexWrite = client.lastCodexStatusSentAt.map { Self.relativeTimeFormatter.localizedString(
            for: $0,
            relativeTo: Date()) } ?? "—"
        self.deviceState = client.deviceState
        self.deviceStateUpdatedAt = client.deviceStateUpdatedAt
        self.lastWrite = client.lastStatusSentAt.map { Self.relativeTimeFormatter.localizedString(
            for: $0,
            relativeTo: Date()) } ?? "—"
        self.lastTheme = client.lastTheme.map { "\($0)" } ?? "—"
        self.runtimeDetail = UserDefaults.standard.string(forKey: "petRuntimeDetail") ?? "—"
        self.bleRuntimeDetail = UserDefaults.standard.string(forKey: "petBleRuntimeDetail") ?? "—"
        self.bleAuthorization = self.localizedBleAuthorization
    }

    private func authorizationLabel(_ raw: Int) -> String {
        switch raw {
        case 0: "未决定"
        case 1: "受限制"
        case 2: "已拒绝"
        case 3: "已允许"
        default: "—"
        }
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.unitsStyle = .short
        return formatter
    }()

    private func runHookInstall() {
        self.hookBusy = true
        Task.detached(priority: .userInitiated) {
            let result: Result<PetHookInstaller.Report, Error>
            do {
                let report = try PetHookInstaller.install()
                result = .success(report)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.hookBusy = false
                switch result {
                case let .success(report):
                    self.hookStatus = report.notes.joined(separator: " · ")
                case let .failure(error):
                    self.hookStatus = "安装失败：\(error)"
                }
            }
        }
    }

    private func runHookUninstall() {
        self.hookBusy = true
        Task.detached(priority: .userInitiated) {
            let result: Result<PetHookInstaller.Report, Error>
            do {
                let report = try PetHookInstaller.uninstall()
                result = .success(report)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.hookBusy = false
                switch result {
                case let .success(report):
                    self.hookStatus = report.notes.joined(separator: " · ")
                case let .failure(error):
                    self.hookStatus = "卸载失败：\(error)"
                }
            }
        }
    }
}
