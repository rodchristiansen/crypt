//
//  SettingsView.swift
//  Managed Encryption Escrow
//
//  Prefs tab: centred app header, then Crypt's preferences in two columns of
//  cards, then a read-only list of Crypt's launchd jobs. Settings a profile
//  manages show their managed value, disabled (gray), and one banner under
//  the header explains why instead of a caption on every field; only MDM can
//  change them. Any other field can be edited, and Save asks for an
//  administrator at that moment. When a profile manages everything there is
//  nothing to save, and the window is read-only under the banner.
//

import SwiftUI
import ManagedEncryptionEscrowXPC

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(XPCClient.self) private var xpcClient

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appInfoHeader

                if viewModel.hasManagedSettings {
                    ProfileManagedBanner()
                }

                Divider()

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        serverSection
                        escrowSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 16) {
                        keySection
                        usersSection
                        loggingSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                ServicesSection(
                    prefixes: ["com.grahamgilbert.crypt"],
                    extraDaemonDirectories: [
                        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons").path
                    ]
                )

                HStack(spacing: 12) {
                    Spacer()
                    saveStatusLabel
                    if !viewModel.allSettingsManaged {
                        saveButtons
                    }
                }
                .padding(.top, 4)
            }
            .padding()
        }
        .onAppear {
            viewModel.configure(client: xpcClient)
            viewModel.load()
        }
    }

    // MARK: - App Info Header

    @ViewBuilder
    private var appInfoHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            Text("Managed Encryption Escrow")
                .font(.largeTitle.bold())

            Text("Escrows this Mac's FileVault recovery key to a Crypt server and keeps it valid.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Documentation", destination: URL(string: "https://github.com/rodchristiansen/crypt#readme")!)
                    .font(.caption)
                Link("Report Issue", destination: URL(string: "https://github.com/grahamgilbert/crypt/issues")!)
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Save

    @ViewBuilder
    private var saveButtons: some View {
        let disabled = !viewModel.hasUnsavedChanges || viewModel.saveStatus == .saving
        Button("Revert") {
            viewModel.revert()
        }
        .disabled(disabled)
        .help("Discard the changes you have not saved")

        Button("Save") {
            Task { await viewModel.save() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
        .help("An administrator name and password is needed to save")
    }

    // MARK: - Save Status

    @ViewBuilder
    private var saveStatusLabel: some View {
        switch viewModel.saveStatus {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving").font(.callout).foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .transition(.opacity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        card("Server", systemImage: "server.rack") {
            settingRow(.serverURL, label: "Crypt server URL") {
                TextField("https://crypt.example.com", text: $viewModel.serverURL)
                    .textFieldStyle(.roundedBorder)
            }
            if !SettingsViewModel.isAcceptableServerURL(viewModel.serverURL) {
                Text("Must be an https address.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            settingRow(.serverTimeout, label: "Request timeout") {
                numberField(value: $viewModel.serverTimeout, range: 5...600, step: 5, unit: "seconds")
            }
            settingRow(.serverRetryAttempts, label: "Retries") {
                numberField(value: $viewModel.serverRetryAttempts, range: 0...10, step: 1, unit: "attempts")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("API key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch viewModel.apiKeyState {
                case .managed:
                    Text("Set")
                        .foregroundStyle(.secondary)
                case .set:
                    Text("Set")
                case .notSet:
                    Text("Not set")
                }
            }
        }
    }

    @ViewBuilder
    private var escrowSection: some View {
        card("Escrow", systemImage: "arrow.up.doc") {
            settingRow(.keyEscrowInterval, label: "Re-escrow an unchanged key every") {
                numberField(value: $viewModel.keyEscrowInterval, range: 1...720, step: 1, unit: "hours")
            }
            settingRow(.validateKey) {
                Toggle("Check the held key still unlocks the disk, and replace it if not", isOn: $viewModel.validateKey)
            }
            settingRow(.removePlist) {
                Toggle("Remove the local key file after escrow", isOn: $viewModel.removePlist)
            }
        }
    }

    @ViewBuilder
    private var keySection: some View {
        card("Recovery key", systemImage: "key") {
            settingRow(.rotateUsedKey) {
                Toggle("Rotate the key after it has been used", isOn: $viewModel.rotateUsedKey)
            }
            settingRow(.generateNewKey) {
                Toggle("Generate a new key at the next login", isOn: $viewModel.generateNewKey)
            }
            settingRow(.manageAuthMechs) {
                Toggle("Reinstall Crypt's login-window mechanisms when missing", isOn: $viewModel.manageAuthMechs)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Stored in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.keyStorage)
            }
            Text("The key itself is never shown in this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        card("Users", systemImage: "person.2") {
            settingRow(.skipUsers, label: "Skip users") {
                TextField("admin, support", text: $viewModel.skipUsersText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Crypt never enables FileVault at login for these accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var loggingSection: some View {
        card("Logging", systemImage: "doc.text") {
            settingRow(.logLevel, label: "Log level") {
                Picker("", selection: $viewModel.logLevel) {
                    ForEach(SettingsViewModel.logLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160, alignment: .leading)
            }
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func numberField(value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Managed Setting Row

    @ViewBuilder
    private func settingRow<Content: View>(
        _ key: CryptPreferenceKey,
        label: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let managed = viewModel.isManaged(key)
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .disabled(managed)
        }
    }
}
