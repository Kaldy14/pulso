import SwiftUI

struct SettingsView: View {
    let services: AppServices

    @State private var testResult: String?
    @State private var testing = false
    @State private var confirmReimport = false

    var body: some View {
        @Bindable var settings = services.settings
        NavigationStack {
            Form {
                Section {
                    TextField("https://device.tailnet.ts.net/health/import", text: $settings.endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("X-Health-Key (required)", text: $settings.token)
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await services.testConnection()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if testing { Spacer(); Image(systemName: "network") }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Exact tailnet POST URL, including its path. Only Tailscale IPs or .ts.net names are accepted. Redirects are blocked.")
                }

                ForEach(TypeRegistry.groups, id: \.self) { group in
                    Section {
                        ForEach(TypeRegistry.all.filter { $0.group == group }) { type in
                            Toggle(type.displayName, isOn: enabledBinding(type.key))
                        }
                    } header: {
                        Text(group)
                    } footer: {
                        if group == TypeRegistry.groups.last {
                            Text("Disabling a type stops new deliveries; data already on your server stays there. Newly enabled types back-fill their full history on the next sync.")
                        }
                    }
                }

                Section {
                    Button("Znovu odeslat celou historii", role: .destructive) {
                        confirmReimport = true
                    }
                    .disabled(services.status.preparingReimport)
                    .confirmationDialog("Znovu odeslat celou historii?", isPresented: $confirmReimport) {
                        Button("Spustit úplný import", role: .destructive) {
                            Task { await services.reimportAll() }
                        }
                    } message: {
                        Text("Zastaví současný běh a znovu načte dostupnou historii povolených typů. Server musí slučovat opakované záznamy podle jejich ID.")
                    }
                } header: {
                    Text("Maintenance")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Pulso reads the Apple Health data you select and delivers it to the server you configure. No cloud, no accounts, no analytics.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func enabledBinding(_ key: String) -> Binding<Bool> {
        Binding {
            services.settings.isEnabled(key)
        } set: { value in
            services.settings.setEnabled(key, value)
            services.typeTogglesChanged()
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
