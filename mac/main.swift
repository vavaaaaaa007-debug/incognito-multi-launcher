// 一键多开无痕浏览器 —— 每个窗口都是独立的临时配置目录 + 无痕模式，互不共享 Cookie/登录态，关闭即清除。
import SwiftUI
import AppKit
import Combine
import ApplicationServices

// MARK: - 浏览器定义

enum BrowserKind: String, CaseIterable, Identifiable {
    case chrome = "Google Chrome"
    case edge = "Microsoft Edge"
    case brave = "Brave Browser"
    case firefox = "Firefox"
    var id: String { rawValue }

    var appPath: String { "/Applications/\(rawValue).app" }
    var binary: String { "\(appPath)/Contents/MacOS/" + (self == .firefox ? "firefox" : rawValue) }
    var installed: Bool { FileManager.default.isExecutableFile(atPath: binary) }
    var isChromium: Bool { self != .firefox }
}

// MARK: - 九宫格布局

struct GridLayout {
    static let cols = 3, rows = 3, gap: CGFloat = 4

    /// 第 index 个窗口的位置（AX 坐标系：主屏左上角为原点）。超过 9 个时按页错位叠放。
    static func frame(index: Int) -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let primaryH = NSScreen.screens[0].frame.height
        let top = primaryH - (vf.origin.y + vf.height)
        let w = (vf.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let h = (vf.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        let slot = index % 9, page = index / 9
        let col = slot % cols, row = slot / cols
        let offset = CGFloat(page) * 28
        return CGRect(x: vf.origin.x + gap + CGFloat(col) * (w + gap) + offset,
                      y: top + gap + CGFloat(row) * (h + gap) + offset,
                      width: w.rounded(.down), height: h.rounded(.down))
    }

    /// 用辅助功能接口把某进程的第一个窗口移到指定位置
    @discardableResult
    static func place(pid: pid_t, in rect: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let win = windows.first else { return false }
        var pos = rect.origin, size = rect.size
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
        return true
    }
}

// MARK: - 实例管理

final class Instance: Identifiable, ObservableObject {
    let id = UUID()
    let number: Int
    let browser: BrowserKind
    let dir: URL
    let process: Process
    @Published var running = true
    init(number: Int, browser: BrowserKind, dir: URL, process: Process) {
        self.number = number; self.browser = browser; self.dir = dir; self.process = process
    }
}

final class Manager: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var message = ""
    private var counter = 0
    /// 所有运行共用的上层目录；每次运行只用自己的 run-<进程号> 子目录，同时开两份软件也互不影响
    let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("WuhenDuokai", isDirectory: true)
    let baseDir: URL

    init() {
        let fm = FileManager.default
        baseDir = rootDir.appendingPathComponent("run-\(getpid())", isDirectory: true)
        // 只清理已经退出的那些运行留下的目录（异常退出、强制退出）；还在运行的另一份软件的目录不碰。
        // 旧版本直接放在上层目录里的 cr-*/ff-* 也一并清掉。
        for name in (try? fm.contentsOfDirectory(atPath: rootDir.path)) ?? [] {
            if name.hasPrefix("run-"), let pid = pid_t(name.dropFirst(4)), Manager.processAlive(pid) { continue }
            try? fm.removeItem(at: rootDir.appendingPathComponent(name))
        }
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    /// 进程是否还在（kill 0 只检查、不发信号；EPERM 表示进程存在但属于别人）
    static func processAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    var axTrusted: Bool { AXIsProcessTrusted() }

    func requestAX() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }

    func launch(browser: BrowserKind, count: Int, url: String, zoom rawZoom: Int) {
        // 缩放比例来自本机保存的设置，限制在 25%–500%：0 或负数会让 log() 得出无效值，浏览器配置写坏
        let zoom = min(max(rawZoom, 25), 500)
        guard browser.installed else { message = "未安装 \(browser.rawValue)"; return }
        let alive = instances.filter { $0.running }.count
        // 每行一个网址，每个窗口里各开成一个标签页
        // 只接受 http/https 网址：以 "-" 开头的行会被浏览器当成启动参数（例如能运行程序的开关）
        let lines = url.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let targets = lines.compactMap(Self.safeURL)
        let skipped = lines.count - targets.count
        for i in 0..<count {
            counter += 1
            let slot = alive + i
            let rect = GridLayout.frame(index: slot)
            let dir = baseDir.appendingPathComponent("\(browser.isChromium ? "cr" : "ff")-\(counter)-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: browser.binary)
            var args: [String]
            if browser.isChromium {
                args = ["--user-data-dir=\(dir.path)", "--incognito", "--no-first-run",
                        "--no-default-browser-check", "--disable-sync", "--new-window",
                        "--window-position=\(Int(rect.minX)),\(Int(rect.minY))",
                        "--window-size=\(Int(rect.width)),\(Int(rect.height))"]
                args += targets
                // 默认页面缩放：Chromium 的缩放级别 = log(比例)/log(1.2)，写进这个临时配置的 Preferences
                let level = log(Double(zoom) / 100) / log(1.2)
                let prefDir = dir.appendingPathComponent("Default")
                try? FileManager.default.createDirectory(at: prefDir, withIntermediateDirectories: true)
                let json = "{\"partition\":{\"default_zoom_level\":{\"x\":\(level)}},\"browser\":{\"has_seen_welcome_page\":true}}"
                try? json.write(to: prefDir.appendingPathComponent("Preferences"), atomically: true, encoding: .utf8)
            } else {
                // 整个配置永久隐私浏览模式 + 关掉首次启动页
                let prefs = """
                user_pref("browser.privatebrowsing.autostart", true);
                user_pref("browser.shell.checkDefaultBrowser", false);
                user_pref("browser.aboutwelcome.enabled", false);
                user_pref("datareporting.policy.dataSubmissionEnabled", false);
                user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
                user_pref("browser.startup.homepage_override.mstone", "ignore");
                user_pref("startup.homepage_welcome_url", "");
                user_pref("browser.sessionstore.resume_from_crash", false);
                user_pref("layout.css.devPixelsPerPx", "\(Double(zoom) / 100 * (NSScreen.main?.backingScaleFactor ?? 2))");
                """
                try? prefs.write(to: dir.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
                args = ["-profile", dir.path, "-no-remote", "-new-instance",
                        "-width", "\(Int(rect.width))", "-height", "\(Int(rect.height))"]
                args += targets
            }
            p.arguments = args
            let inst = Instance(number: counter, browser: browser, dir: dir, process: p)
            p.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    inst.running = false
                    try? FileManager.default.removeItem(at: inst.dir)
                    self?.instances.removeAll { $0.id == inst.id }
                }
            }
            do {
                try p.run()
                instances.append(inst)
                placeWhenReady(pid: p.processIdentifier, rect: rect)
            } catch {
                message = "启动失败：\(error.localizedDescription)"
                try? FileManager.default.removeItem(at: dir)
            }
        }
        message = "已打开 \(count) 个 \(browser.rawValue) 无痕窗口"
            + (skipped > 0 ? "（跳过 \(skipped) 行不是 http/https 网址的内容）" : "")
    }

    /// 把一行文字变成安全的 http/https 网址；不带协议的补上 https://，其余一律拒绝
    static func safeURL(_ line: String) -> String? {
        let s = line.contains("://") ? line : "https://" + line
        guard !line.hasPrefix("-"), let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return nil }
        return u.absoluteString
    }

    /// 窗口出现后再用辅助功能精确对齐九宫格（Firefox 必须靠这个）
    private func placeWhenReady(pid: pid_t, rect: CGRect, attempt: Int = 0) {
        guard axTrusted, attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if !GridLayout.place(pid: pid, in: rect) {
                self?.placeWhenReady(pid: pid, rect: rect, attempt: attempt + 1)
            }
        }
    }

    func retile() {
        guard axTrusted else { requestAX(); message = "请在 系统设置→隐私与安全性→辅助功能 中允许本软件，然后再点一次"; return }
        for (i, inst) in instances.filter({ $0.running }).enumerated() {
            GridLayout.place(pid: inst.process.processIdentifier, in: GridLayout.frame(index: i))
        }
        message = "已按九宫格重新排列"
    }

    func focus(_ inst: Instance) {
        NSRunningApplication(processIdentifier: inst.process.processIdentifier)?.activate()
    }

    func close(_ inst: Instance) {
        if inst.process.isRunning { inst.process.terminate() }
    }

    func closeAll() {
        instances.forEach { close($0) }
        message = "已关闭全部窗口，临时数据已清除"
    }

    /// 退出软件时：结束所有实例并删除全部临时数据
    func shutdown() {
        instances.forEach { if $0.process.isRunning { $0.process.terminate() } }
        let deadline = Date().addingTimeInterval(3)
        while instances.contains(where: { $0.process.isRunning }) && Date() < deadline { usleep(100_000) }
        instances.forEach { if $0.process.isRunning { kill($0.process.processIdentifier, SIGKILL) } }
        try? FileManager.default.removeItem(at: baseDir)   // 只删自己这次运行的目录
        rmdir(rootDir.path)                                 // 上层目录空了才会删掉；别的运行还在就保留
    }
}

// MARK: - 界面（薄荷绿主题）

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 配色：浅色 / 深色模式各一套，跟随系统切换
enum Theme {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    static let accent  = dyn(0x1FB386, 0x3DD9A4)   // 薄荷绿：主按钮、选中状态
    static let deep    = dyn(0x0B7A5A, 0x7BE8C2)   // 深薄荷：浅底上的文字和图标
    static let soft    = dyn(0xE6F7F0, 0x15352B)   // 浅薄荷：选中底色、提示条
    static let window  = dyn(0xF3FAF7, 0x111815)   // 窗口背景
    static let card    = dyn(0xFFFFFF, 0x1A2420)   // 卡片
    static let border  = dyn(0xD3EEE3, 0x274239)   // 卡片描边
    static let danger  = dyn(0xE5484D, 0xFF6B6F)
}

/// 主按钮：薄荷绿实心，按下变暗，不可用时变灰
struct MintButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(enabled ? Theme.accent : Color.gray.opacity(0.45)))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .contentShape(Rectangle())
    }
}

/// 次要按钮：白底描边；tint 决定文字颜色
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.deep
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? tint : Color.secondary)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Theme.soft : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .opacity(enabled ? 1 : 0.6)
            .contentShape(Rectangle())
    }
}

/// 白色卡片容器
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

/// 一行里的一个下拉项：上面小标题，下面下拉框
struct Field<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 设置卡片里的一行：左边标题，右边内容
struct SettingRow<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mgr: Manager
    @State private var browser: BrowserKind = BrowserKind.allCases.first { $0.installed } ?? .chrome
    @State private var count = 9
    static let defaultURLs = "https://platform.muse.ai/\nhttps://muse.ai/?activation_view=setup"
    @AppStorage("zoomPercent") private var zoom = 50
    @AppStorage("openURLs") private var url = ContentView.defaultURLs
    @State private var axOK = AXIsProcessTrusted()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let zooms = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150]

    private var installedBrowsers: [BrowserKind] { BrowserKind.allCases.filter { $0.installed } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                settingsCard
                actions
                if !axOK { axHint }
                runningSection
            }
            .padding(20)
        }
        .background(Theme.window)
        .tint(Theme.accent)
        .frame(minWidth: 640, minHeight: 620)
        .onReceive(timer) { _ in axOK = AXIsProcessTrusted() }
    }

    // 顶部：图标 + 名称 + 运行状态
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("一键多开无痕浏览器").font(.system(size: 19, weight: .bold))
                Text("每个窗口独立配置 + 无痕模式，账号互不串号，关闭即清除数据")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(mgr.instances.isEmpty ? Color.gray.opacity(0.5) : Theme.accent).frame(width: 8, height: 8)
                Text(mgr.instances.isEmpty ? "未运行" : "运行中 \(mgr.instances.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mgr.instances.isEmpty ? Color.secondary : Theme.deep)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(mgr.instances.isEmpty ? Theme.card : Theme.soft))
            .overlay(Capsule().strokeBorder(Theme.border))
        }
    }

    // 设置：浏览器 / 数量 / 缩放 / 网址
    private var settingsCard: some View {
        Card {
            // 浏览器 / 窗口数量 / 默认缩放：一行三个下拉框
            HStack(alignment: .top, spacing: 14) {
                Field(title: "浏览器", icon: "globe") {
                    Picker("", selection: $browser) {
                        ForEach(installedBrowsers) { b in Text(b.rawValue).tag(b) }
                    }
                    .labelsHidden()
                    .disabled(installedBrowsers.isEmpty)
                    .help(installedBrowsers.isEmpty ? "这台电脑没有找到 Chrome / Edge / Brave / Firefox" : "只列出这台电脑上已安装的浏览器")
                }
                Field(title: "窗口数量", icon: "square.grid.3x3") {
                    Picker("", selection: $count) {
                        ForEach(1...36, id: \.self) { n in Text(n == 9 ? "9 个（九宫格）" : "\(n) 个").tag(n) }
                    }
                    .labelsHidden()
                    .help("1–36 个；超过 9 个时，下一组会稍微错开叠放")
                }
                Field(title: "默认缩放", icon: "plus.magnifyingglass") {
                    Picker("", selection: $zoom) {
                        ForEach(zooms, id: \.self) { Text($0 == 100 ? "100%（原始大小）" : "\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .help("网页内容的显示比例")
                }
            }
            Divider().overlay(Theme.border)
            SettingRow(title: "打开网址", icon: "link") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $url)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.window))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    HStack {
                        Text("每行一个，每个窗口各开一个标签页；只接受 http/https 网址")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { url = ContentView.defaultURLs }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.deep)
                            .disabled(url == ContentView.defaultURLs)
                    }
                }
            }
        }
    }

    // 操作：主按钮 + 次要按钮 + 结果提示
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { mgr.launch(browser: browser, count: count, url: url, zoom: zoom) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.fill")
                    Text("一键打开 \(count) 个无痕窗口")
                    Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.75)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18)))
                }
            }
            .buttonStyle(MintButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!browser.installed)

            HStack(spacing: 10) {
                Button { mgr.retile() } label: { Label("九宫格重新排列", systemImage: "rectangle.split.3x3") }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(mgr.instances.isEmpty)
                Button { mgr.closeAll() } label: { Label("全部关闭并清除", systemImage: "xmark.circle") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.danger))
                    .disabled(mgr.instances.isEmpty)
                Spacer()
                if !mgr.message.isEmpty {
                    let bad = ["失败", "未安装", "请在"].contains { mgr.message.contains($0) }
                    Label(mgr.message, systemImage: bad ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(bad ? Theme.danger : Theme.deep)
                        .lineLimit(2).transition(.opacity)
                }
            }
        }
    }

    // 辅助功能权限：温和提示，不用警告色
    private var axHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.deep)
            VStack(alignment: .leading, spacing: 1) {
                Text("开启「辅助功能」权限，九宫格排列更精准").font(.system(size: 12.5, weight: .medium))
                Text("Chrome / Edge / Brave 不开也能用；Firefox 需要这个权限才能排好")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去开启") { mgr.requestAX() }.buttonStyle(SoftButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.soft))
    }

    // 运行中的窗口列表
    private var runningSection: some View {
        Card {
            HStack {
                Text("运行中的窗口").font(.system(size: 14, weight: .semibold))
                Text("\(mgr.instances.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.deep)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.soft))
                Spacer()
            }
            if mgr.instances.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 30)).foregroundStyle(Theme.accent.opacity(0.6))
                    Text("还没有打开的窗口").font(.system(size: 13, weight: .medium))
                    Text("选好浏览器和数量，点上面的「一键打开」").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(spacing: 0) {
                    ForEach(mgr.instances) { inst in
                        HStack(spacing: 12) {
                            Text("\(inst.number)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Theme.deep)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.soft))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(inst.browser.rawValue).font(.system(size: 13, weight: .medium))
                                Label("无痕 · 独立配置", systemImage: "eye.slash")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { mgr.focus(inst) } label: { Image(systemName: "arrow.up.forward.app") }
                                .buttonStyle(SoftButtonStyle()).help("切到这个窗口")
                            Button { mgr.close(inst) } label: { Image(systemName: "xmark") }
                                .buttonStyle(SoftButtonStyle(tint: Theme.danger)).help("关闭这个窗口并清除它的数据")
                        }
                        .padding(.vertical, 8)
                        if inst.id != mgr.instances.last?.id { Divider().overlay(Theme.border) }
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: Manager!
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 测试用：WUHEN_APPEARANCE=dark / light 只让这一份软件用深色或浅色，不改系统设置
        switch ProcessInfo.processInfo.environment["WUHEN_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
    func applicationWillTerminate(_ notification: Notification) { manager.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WuhenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var mgr = Manager()
    var body: some Scene {
        WindowGroup("一键多开无痕浏览器") {
            ContentView().environmentObject(mgr).onAppear { delegate.manager = mgr }
        }
        .windowResizability(.contentMinSize)
    }
}
