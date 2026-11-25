// Claude 开机动画 —— 轻量常驻监听进程
// 只负责监听 Claude 桌面端启动与设置窗口请求，不加载 AVFoundation / CoreImage / 窗口图层。
// 真正播放或显示设置时才拉起 ClaudeBootAnimationPlayer，Claude 退出后播放进程立即退出以归还全部内存。
//
// Copyright (C) 2026 wynneceles
// 本程序以 GNU GPL v3 发布，见仓库根目录 LICENSE。
// This program is free software under the GNU General Public License v3.

import AppKit
import Foundation

let claudeBundleID = "com.anthropic.claudefordesktop"
let showSettingsNote = Notification.Name("io.github.celestewynne0506-pixel.claude-boot-animation.show-settings")
let showWorkerSettingsNote = Notification.Name("io.github.celestewynne0506-pixel.claude-boot-animation.worker-show-settings")

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

final class WatcherDelegate: NSObject, NSApplicationDelegate {
    private var worker: Process?
    private var lockFD: Int32 = -1

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
