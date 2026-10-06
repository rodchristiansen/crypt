//
//  RunView.swift
//  Managed Encryption Escrow
//
//  Run tab: choose a checkin run, start or stop it, and watch its output.
//

import SwiftUI
import ManagedEncryptionEscrowXPC

struct RunView: View {
    @Environment(XPCClient.self) private var xpcClient
    @State private var showDebug = false
    // Verify only reads, so it is the safe default; Rotate needs an
    // administrator and is one deliberate choice away.
    @State private var mode: RunMode = RunMode.launchRequested() ?? .verify

    private var helperNeeded: Bool { true }
    private var helperAvailable: Bool { xpcClient.helperStatus == .available }

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
                .padding([.horizontal, .top])

            runControlBar
                .padding()

            resultBanner

            Divider()

            ConsoleView(outputLines: showDebug ? xpcClient.outputLines : xpcClient.outputLines.filter { $0.level != .debug })
                .padding()
        }
    }

    // MARK: - Mode Selector

    @ViewBuilder
    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Run", selection: $mode) {
                ForEach(RunMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(xpcClient.isRunning)

            HStack(spacing: 6) {
                if mode.requiresAdmin {
                    Image(systemName: xpcClient.isUnlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(.secondary)
                }
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Run Control Bar

    @ViewBuilder
    private var runControlBar: some View {
        HStack(spacing: 12) {
            if xpcClient.isRunning {
                stopButton
            } else {
                runButton
            }

            if xpcClient.isRunning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running...")
                        .foregroundStyle(.secondary)
                    if let caption = xpcClient.latestProgressLine {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            statusIndicator

            Toggle("Debug", isOn: $showDebug)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show or hide DEBUG lines (checkin writes them when the log level is Debug)")

            if !xpcClient.outputLines.isEmpty && !xpcClient.isRunning {
                clearButton
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var runButton: some View {
        let disabled = helperNeeded && !helperAvailable
        if #available(macOS 26, *) {
            Button {
                xpcClient.run(mode: mode)
            } label: {
                Label("Run Managed Encryption Escrow", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(disabled)
        } else {
            Button {
                xpcClient.run(mode: mode)
            } label: {
                Label("Run Managed Encryption Escrow", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if #available(macOS 26, *) {
            Button(role: .destructive) {
                xpcClient.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
        } else {
            Button(role: .destructive) {
                xpcClient.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if #available(macOS 26, *) {
            Button("Clear") { clearOutput() }
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            Button("Clear") { clearOutput() }
                .controlSize(.small)
        }
    }

    private func clearOutput() {
        xpcClient.outputLines.removeAll()
        xpcClient.lastExitCode = nil
    }

    // MARK: - Status

    @ViewBuilder
    private var statusIndicator: some View {
        if let exitCode = xpcClient.lastExitCode {
            if exitCode == 0 && xpcClient.errorCount == 0 {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if exitCode == 0 {
                // Matches the banner: a run that logged errors is not shown as clean.
                Label("Completed with errors", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Label(RunMode.describeExit(exitCode).map { "\($0.prefix(1).uppercased())\($0.dropFirst()) (exit \(exitCode))" } ?? "Failed (exit \(exitCode))",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }

        if helperNeeded && !helperAvailable && !xpcClient.isRunning {
            Label("Helper not available", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let exitCode = xpcClient.lastExitCode, !xpcClient.isRunning {
            let errors = xpcClient.errorCount
            let success = exitCode == 0
            HStack(spacing: 8) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Text(success
                     ? (errors == 0 ? "Completed successfully" : "Completed with \(errors) error\(errors == 1 ? "" : "s")")
                     : RunMode.describeExit(exitCode).map { "Finished: \($0) (exit code \(exitCode))" }
                        ?? "Failed with exit code \(exitCode), \(errors) error\(errors == 1 ? "" : "s")")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(success && errors == 0 ? .green : .red)
            .padding(10)
            .background((success && errors == 0 ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
