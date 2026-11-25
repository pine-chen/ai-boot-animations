// Claude 开机动画 —— 轻量常驻监听进程
// 只负责监听 Claude 桌面端 / Claude Code CLI 启动与设置窗口请求，不加载 AVFoundation / CoreImage / 窗口图层。
// 真正播放或显示设置时才拉起 ClaudeBootAnimationPlayer，退出后播放进程立即退出以归还全部内存。
//
// Copyright (C) 2026 wynneceles
// 本程序以 GNU GPL v3 发布，见仓库根目录 LICENSE。
// This program is free software under the GNU General Public License v3.

import AppKit
import Darwin
import Foundation

let claudeBundleID = "com.anthropic.claudefordesktop"
let showSettingsNote = Notification.Name("io.github.celestewynne0506-pixel.claude-boot-animation.show-settings")
let showWorkerSettingsNote = Notification.Name("io.github.celestewynne0506-pixel.claude-boot-animation.worker-show-settings")
let launchCLINote = Notification.Name("io.github.celestewynne0506-pixel.claude-boot-animation.launch-cli")

let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "org.alacritty",
    "com.github.wez.wezterm",
    "co.zeit.hyper",
    "com.raphaelamorim.rio",
    "org.tabby"
]

let ignoredAncestorNames: Set<String> = [
    "claude", "Claude", "Code", "Code Helper", "Cursor", "Cursor Helper",
    "Windsurf", "Antigravity", "Zed", "Electron"
]

let playerForwardedFlags: Set<String> = [
    "--preview", "--loop-only", "--wait-cache", "--render-subtitle", "--show-menu"
]

func playerURL() -> URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ClaudeBootAnimationPlayer")
}

func configDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeBootAnimation")
}

// MARK: - 轻量进程表（纯 Darwin sysctl/proc，零子进程开销）

struct ProcEntry {
    let pid: pid_t
    let ppid: pid_t
    let name: String
}

func snapshotProcesses() -> [pid_t: ProcEntry] {
    let byteCount = proc_listallpids(nil, 0)
    guard byteCount > 0 else { return [:] }
    let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let actualBytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
    guard actualBytes > 0 else { return [:] }
    let count = Int(actualBytes) / MemoryLayout<pid_t>.stride

    var table: [pid_t: ProcEntry] = [:]
    table.reserveCapacity(count)
    var bsd = proc_bsdinfo()
    let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    var nameBuf = [CChar](repeating: 0, count: 256)

    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
        let len = proc_name(pid, &nameBuf, 256)
        let name: String
        if len > 0 {
            name = String(cString: nameBuf)
        } else {
            name = withUnsafePointer(to: bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
        }
        table[pid] = ProcEntry(pid: pid, ppid: pid_t(bsd.pbi_ppid), name: name)
    }
    return table
}

func findHostTerminalPID(for cliPID: pid_t, in table: [pid_t: ProcEntry]) -> pid_t? {
    var cur = table[cliPID]?.ppid ?? 0
    var depth = 0
    while cur > 1 && depth < 16 {
        if let app = NSRunningApplication(processIdentifier: cur),
           let bid = app.bundleIdentifier,
           terminalBundleIDs.contains(bid) {
            return cur
        }
        if let entry = table[cur] {
            if ignoredAncestorNames.contains(entry.name) {
                return nil
            }
            cur = entry.ppid
        } else {
            break
        }
        depth += 1
    }
    // 若经过 tmux / screen 守护进程导致 ppid 断到 pid 1，退回检查当前前台是否为已知终端
    if let front = NSWorkspace.shared.frontmostApplication,
       let bid = front.bundleIdentifier,
       terminalBundleIDs.contains(bid) {
        return front.processIdentifier
    }
    return nil
}

final class WatcherDelegate: NSObject, NSApplicationDelegate {
    private var worker: Process?
    private var lockFD: Int32 = -1
    private var seenCLIPids = Set<pid_t>()
    private var cliTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dir = configDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lockFD = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            DistributedNotificationCenter.default().postNotificationName(
                showSettingsNote, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return
        }

        DistributedNotificationCenter.default().addObserver(
            forName: showSettingsNote, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettingsInWorker()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        // 启动时已存在的 claude CLI 进程记入 seenCLIPids，不补播
        let initialTable = snapshotProcesses()
        for (pid, entry) in initialTable where entry.name == "claude" {
            seenCLIPids.insert(pid)
        }
        cliTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scanForNewClaudeCLI()
        }

        if CommandLine.arguments.contains("--settings") {
            spawnWorker(args: ["--settings"])
        } else if !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty {
            spawnWorker(args: ["--standby"])
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsInWorker()
        return false
    }

    @objc func appLaunched(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == claudeBundleID else { return }
        if worker?.isRunning != true {
            spawnWorker(args: ["--launch-pid", "\(app.processIdentifier)"])
        }
    }

    private func scanForNewClaudeCLI() {
        let table = snapshotProcesses()
        // 清理已退出的 PID
        seenCLIPids = seenCLIPids.filter { table[$0]?.name == "claude" }
        for (pid, entry) in table where entry.name == "claude" && !seenCLIPids.contains(pid) {
            seenCLIPids.insert(pid)
            guard let termPID = findHostTerminalPID(for: pid, in: table) else { continue }
            if worker?.isRunning == true {
                DistributedNotificationCenter.default().postNotificationName(
                    launchCLINote,
                    object: nil,
                    userInfo: ["cliPid": Int(pid), "terminalPid": Int(termPID)],
                    deliverImmediately: true)
            } else {
                spawnWorker(args: ["--launch-cli-pid", "\(pid)", "--terminal-pid", "\(termPID)"])
            }
            break
        }
    }

    private func openSettingsInWorker() {
        if worker?.isRunning == true {
            DistributedNotificationCenter.default().postNotificationName(
                showWorkerSettingsNote, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            spawnWorker(args: ["--settings"])
        }
    }

    private func spawnWorker(args: [String]) {
        let url = playerURL()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if self?.worker === proc { self?.worker = nil }
            }
        }
        do {
            try p.run()
            worker = p
        } catch {
            worker = nil
        }
    }
}

// 命令行测试 / 预览参数直接交给播放端执行
if CommandLine.arguments.contains(where: { playerForwardedFlags.contains($0) }) {
    let url = playerURL()
    let argv = [url.path] + Array(CommandLine.arguments.dropFirst())
    let cArgs = argv.map { strdup($0) } + [nil]
    execv(url.path, cArgs)
    exit(1)
}

let app = NSApplication.shared
let delegate = WatcherDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
