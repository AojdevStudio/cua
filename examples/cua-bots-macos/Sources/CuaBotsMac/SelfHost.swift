// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import CuaBotsCore
import Foundation
import ScreenCaptureKit

/// Hooks for running the app unattended on an always-on Mac, all off unless
/// their variable is set:
///
/// * `CUA_BOTS_SEED=Name:harness` creates that bot on This Mac when no bot of
///   that name exists, so a fresh install comes up with its bot.
/// * `CUA_BOTS_SHOW_COMPUTER=1` opens the first bot's computer once it is up.
/// * `SIGUSR1` writes a report: the window to
///   `$CUA_BOTS_SNAPSHOT_DIR/<time>.png` and each bot's iPhone pairing link
///   to `$CUA_BOTS_PAIRING_FILE`.
@MainActor
enum SelfHost {
    private static var signalSource: DispatchSourceSignal?

    static func start(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["CUA_BOTS_SEED"], !spec.isEmpty { seed(model, spec) }
        if env["CUA_BOTS_SHOW_COMPUTER"] == "1", let first = model.store.bots.first {
            model.route = .bot(first.id)
            model.showProfile = false
            // After a reboot the Space is still booting. The window keeps the
            // first stream it opens, so open it once the screen answers.
            Task {
                await model.store.wake(first.id)
                if let bot = model.store.bot(first.id), let engine = model.engine {
                    var tries = 0
                    while tries < 90, await engine.pointer(bot) == nil {
                        tries += 1
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                model.showComputer = true
            }
        }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { Task { @MainActor in await report(model, env) } }
        source.resume()
        signalSource = source
    }

    static func seed(_ model: AppModel, _ spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty else { return }
        let harness = parts.count > 1 ? Harness(rawValue: parts[1]) ?? .claudeCode : .claudeCode
        guard model.store.bot(Bot.agentName(for: name)) == nil else { return }
        model.createBot(name: name, avatar: .default(for: name), harness: harness, placement: .local)
    }

    static func report(_ model: AppModel, _ env: [String: String]) async {
        if let dir = env["CUA_BOTS_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir)
                .appendingPathComponent("\(Date().formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))).png")
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try await snapshot(to: url)
            } catch {
                model.store.lastError = "Snapshot failed: \(error.localizedDescription)"
            }
        }
        if let path = env["CUA_BOTS_PAIRING_FILE"], let engine = model.engine {
            var lines = ["# iPhone pairing links", "", "Each link carries its bot's spacesd token.", ""]
            for bot in model.store.bots where bot.spaceID != nil {
                do { lines.append("- \(bot.name): `\(try await engine.pairingLink(bot))`") } catch {
                    lines.append("- \(bot.name): failed: \(error.localizedDescription)")
                }
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The main window (the largest visible one that isn't a panel, as the
    /// capture tour picks it), composited with the live stream.
    /// `currentProcess` needs no Screen Recording grant, so this works for an
    /// app that launchd starts.
    static func snapshot(to url: URL) async throws {
        guard #available(macOS 14.4, *) else { throw SnapshotError.unsupported }
        guard let main = NSApp.windows.filter({ $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw SnapshotError.noWindow }
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(main.windowNumber) })
        else { throw SnapshotError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.encode
        }
        try png.write(to: url)
    }

    enum SnapshotError: LocalizedError {
        case unsupported, noWindow, encode
        var errorDescription: String? {
            switch self {
            case .unsupported: "needs macOS 14.4"
            case .noWindow: "no window on screen"
            case .encode: "couldn't encode the PNG"
            }
        }
    }
}
