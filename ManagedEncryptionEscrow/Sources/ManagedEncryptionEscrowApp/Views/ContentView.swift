//
//  ContentView.swift
//  Managed Encryption Escrow
//
//  Main window with three tabs: Prefs, Run, and Logs.
//  Uses standard TabView which renders as Liquid Glass on macOS 26+.
//  `-tab run` or `-tab logs` on the command line opens that tab, and
//  `-run verify` or `-run check-auth-mechs` starts that read-only run, so an
//  administrator or a script can open the window where it is needed.
//

import SwiftUI
import ManagedEncryptionEscrowXPC

struct ContentView: View {
    @Environment(XPCClient.self) private var xpcClient
    @State private var viewModel = SettingsViewModel()
    @State private var selectedTab: ContentTab = ContentTab.fromLaunchArguments()

    enum ContentTab: String, Hashable {
        case prefs, run, logs

        static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> ContentTab {
            if RunMode.launchRequested(defaults) != nil { return .run }
            return defaults.string(forKey: "tab").flatMap(ContentTab.init(rawValue:)) ?? .prefs
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsView(viewModel: viewModel)
                .environment(xpcClient)
                .tabItem { Text("Prefs") }
                .tag(ContentTab.prefs)

            RunView()
                .environment(xpcClient)
                .tabItem { Text("Run") }
                .tag(ContentTab.run)

            LogView()
                .tabItem { Text("Logs") }
                .tag(ContentTab.logs)
        }
        .onAppear {
            xpcClient.connect()
            WindowSnapshot.scheduleIfRequested()
            if let mode = RunMode.launchRequested() {
                Task {
                    // Give the helper ping a moment to answer before the run.
                    try? await Task.sleep(for: .seconds(1))
                    xpcClient.run(mode: mode)
                }
            }
        }
    }
}

extension RunMode {
    /// The run named by `-run` at launch, when it is one that changes nothing.
    /// A run that needs an administrator is never started this way.
    static func launchRequested(_ defaults: UserDefaults = .standard) -> RunMode? {
        guard let mode = defaults.string(forKey: "run").flatMap(RunMode.init(rawValue:)),
              !mode.requiresAdmin, mode != .escrow else { return nil }
        return mode
    }
}
