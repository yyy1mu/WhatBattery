import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    let monitor: BatteryMonitor

    @AppStorage(AppLanguage.preferenceKey)
    private var language: AppLanguage = .system

    @State private var isRestartAlertPresented = false

    var body: some View {
        Form {
            Section("Language") {
                Picker("App Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName)
                            .tag(option)
                    }
                }
            }

            Section("Apple & Bluetooth") {
                LabeledContent("Status") {
                    Text(monitor.bluetooth.statusText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh Bluetooth") {
                        monitor.bluetooth.refreshNow()
                    }
                    .disabled(!monitor.bluetooth.canRefresh)

                    if monitor.bluetooth.needsBluetoothPermission {
                        Button("Open Bluetooth Privacy Settings") {
                            openBluetoothPrivacySettings()
                        }
                    }
                }
            }

            InputMonitoringSettingsSection(monitor: monitor)

            Section("Device Rules") {
                ForEach(monitor.ruleRegistrations) { registration in
                    DeviceRuleSettingRow(
                        registration: registration,
                        monitor: monitor
                    )
                }

                if monitor.ruleRegistrations.isEmpty {
                    Text("No valid device rules were loaded.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Rules files") {
                LabeledContent("Rules directory") {
                    Text(verbatim: "Application Support/WhatBattery/")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Show Rules Directory") {
                        revealRulesDirectory()
                    }
                    Button("Reload Rules") {
                        monitor.reloadRules()
                    }
                }
            }

            if !monitor.ruleIssues.isEmpty {
                Section("Rule Problems") {
                    ForEach(monitor.ruleIssues) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: language) {
            language.apply()
            isRestartAlertPresented = true
        }
        .alert(
            "Restart WhatBattery?",
            isPresented: $isRestartAlertPresented
        ) {
            Button("Restart Now") {
                AppRelauncher.relaunch()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Restart the app to apply the selected language everywhere.")
        }
        .alert(
            "Unable to Open the Rules Directory",
            isPresented: ruleFileErrorIsPresented
        ) {
            Button("OK") {
                monitor.clearRuleFileError()
            }
        } message: {
            Text(monitor.ruleFileError ?? "")
        }
    }

    private var ruleFileErrorIsPresented: Binding<Bool> {
        Binding(
            get: { monitor.ruleFileError != nil },
            set: { isPresented in
                if !isPresented {
                    monitor.clearRuleFileError()
                }
            }
        )
    }

    private func revealRulesDirectory() {
        guard let url = monitor.prepareRulesDirectory() else { return }
        NSWorkspace.shared.open(url)
    }

    private func openBluetoothPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct InputMonitoringSettingsSection: View {
    let monitor: BatteryMonitor

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            Toggle(
                "Check protected keyboard battery levels",
                isOn: enabledBinding
            )

            LabeledContent("Permission Status") {
                Label {
                    Text(statusLabel)
                } icon: {
                    Image(systemName: statusSymbol)
                }
                .foregroundStyle(statusColor)
            }

            if monitor.isInputMonitoringEnabled,
               monitor.inputMonitoringStatus != .granted {
                HStack {
                    if monitor.inputMonitoringStatus == .notDetermined {
                        Button("Request Access") {
                            monitor.requestInputMonitoringPermission()
                        }
                    }
                    Button("Open Input Monitoring Settings") {
                        openInputMonitoringSettings()
                    }
                    Button("Check Again") {
                        monitor.refreshInputMonitoringPermission()
                    }
                }
            }
        } header: {
            Text("Input Monitoring")
        } footer: {
            Text(
                "Lofree and other protected keyboard battery rules require Input Monitoring access. Turn this off to skip those rules and avoid checking permission status."
            )
        }
        .onAppear {
            monitor.refreshInputMonitoringPermission()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            monitor.refreshInputMonitoringPermission()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { monitor.isInputMonitoringEnabled },
            set: { monitor.setInputMonitoringEnabled($0) }
        )
    }

    private var statusLabel: LocalizedStringResource {
        switch monitor.inputMonitoringStatus {
        case .notChecked:
            "Not Checked"
        case .notDetermined:
            "Access Not Requested"
        case .denied:
            "Access Denied"
        case .granted:
            "Access Granted"
        }
    }

    private var statusSymbol: String {
        switch monitor.inputMonitoringStatus {
        case .notChecked:
            "minus.circle"
        case .notDetermined:
            "questionmark.circle"
        case .denied:
            "exclamationmark.triangle.fill"
        case .granted:
            "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch monitor.inputMonitoringStatus {
        case .notChecked, .notDetermined:
            .secondary
        case .denied:
            .orange
        case .granted:
            .green
        }
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        openURL(url)
    }
}

private struct DeviceRuleSettingRow: View {
    let registration: DeviceRuleRegistration
    let monitor: BatteryMonitor

    var body: some View {
        Toggle(isOn: enabledBinding) {
            HStack(spacing: 10) {
                Image(systemName: registration.rule.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(registration.rule.displayName)
                    Text(verbatim: registration.rule.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { registration.isEnabled },
            set: { isEnabled in
                monitor.setRuleEnabled(isEnabled, ruleID: registration.id)
            }
        )
    }
}
