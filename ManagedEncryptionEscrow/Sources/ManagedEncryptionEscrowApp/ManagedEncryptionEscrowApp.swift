//
//  ManagedEncryptionEscrowApp.swift
//  Managed Encryption Escrow
//
//  SwiftUI window for Crypt: its preferences, a manual checkin run with live
//  output, and the log of every run.
//

import SwiftUI

@main
struct ManagedEncryptionEscrowApp: App {
    @State private var xpcClient = XPCClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(xpcClient)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 850, height: 748)
    }
}
