//
//  WindowSnapshot.swift
//  Managed Encryption Escrow
//
//  `-snapshot <path.png>` on the command line renders the window, title bar
//  included, to a PNG a few seconds after launch and then quits. It needs no
//  screen-recording permission, so documentation screenshots can be made on a
//  headless test machine. `-appearance dark` or `-appearance light` renders the
//  snapshot in that appearance.
//

import AppKit

enum WindowSnapshot {
    @MainActor
    static func scheduleIfRequested(_ defaults: UserDefaults = .standard) {
        guard let path = defaults.string(forKey: "snapshot"), !path.isEmpty else { return }
        switch defaults.string(forKey: "appearance")?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
