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
    let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("WuhenDuokai", isDirectory: true)

    init() {
        // 清理上次异常退出遗留的临时目录
        try? FileManager.default.removeItem(at: baseDir)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    var axTrusted: Bool { AXIsProcessTrusted() }

    func requestAX() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }

    func launch(browser: BrowserKind, count: Int, url: String, zoom: Int) {
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
        try? FileManager.default.removeItem(at: baseDir)
    }
}

// MARK: - 界面

struct ContentView: View {
    @EnvironmentObject var mgr: Manager
    @State private var browser: BrowserKind = BrowserKind.allCases.first { $0.installed } ?? .chrome
    @State private var count = 9
    static let defaultURLs = "https://platform.muse.ai/\nhttps://muse.ai/?activation_view=setup"
    @AppStorage("zoomPercent") private var zoom = 50
    @AppStorage("openURLs") private var url = ContentView.defaultURLs
    @State private var axOK = AXIsProcessTrusted()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("一键多开无痕浏览器").font(.title2.bold())
            Text("每个窗口独立配置 + 无痕模式，账号互不串号；关闭即清除全部数据。")
                .font(.callout).foregroundStyle(.secondary)

            Form {
                Picker("浏览器", selection: $browser) {
                    ForEach(BrowserKind.allCases) { b in
                        Text(b.installed ? b.rawValue : "\(b.rawValue)（未安装）").tag(b).disabled(!b.installed)
                    }
                }
                Stepper("数量：\(count)", value: $count, in: 1...36)
                Picker("默认缩放", selection: $zoom) {
                    ForEach([25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150], id: \.self) { Text("\($0)%").tag($0) }
                }
                LabeledContent("打开网址") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $url)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Text("每行一个，每个窗口里各开一个标签页").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复默认") { url = ContentView.defaultURLs }.controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button { mgr.launch(browser: browser, count: count, url: url, zoom: zoom) } label: {
                    Label("一键打开 \(count) 个", systemImage: "square.grid.3x3.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return)
                Button { mgr.retile() } label: { Label("九宫格排列", systemImage: "rectangle.split.3x3") }
                    .controlSize(.large)
                Button(role: .destructive) { mgr.closeAll() } label: { Label("全部关闭", systemImage: "xmark.circle") }
                    .controlSize(.large).disabled(mgr.instances.isEmpty)
            }

            if !axOK {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("开启“辅助功能”权限后，九宫格排列更精准（Firefox 必需）。").font(.callout)
                    Spacer()
                    Button("去开启") { mgr.requestAX() }
                }
                .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if !mgr.message.isEmpty { Text(mgr.message).font(.callout).foregroundStyle(.secondary) }

            Text("运行中（\(mgr.instances.count)）").font(.headline)
            List(mgr.instances) { inst in
                HStack {
                    Image(systemName: "eye.slash").foregroundStyle(.purple)
                    Text("#\(inst.number)  \(inst.browser.rawValue)")
                    Spacer()
                    Button("前置") { mgr.focus(inst) }
                    Button("关闭") { mgr.close(inst) }
                }
            }
            .frame(minHeight: 160)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 640)
        .onReceive(timer) { _ in axOK = AXIsProcessTrusted() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: Manager!
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
