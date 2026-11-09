import SwiftUI

struct RootView: View {
    let services: AppServices

    // Launch argument so screenshot tooling can open a specific tab
    // (simctl has no tap injection). No effect outside dev launches.
    @State private var tab = ProcessInfo.processInfo.arguments.contains("-pulso-open-settings") ? 1 : 0

    var body: some View {
        if services.status.healthUnavailable {
            ContentUnavailableView(
                "Health Data Unavailable",
                systemImage: "heart.slash",
                description: Text("This device does not provide HealthKit data.")
            )
        } else {
            TabView(selection: $tab) {
                StatusView(services: services)
                    .tabItem { Label("Průběh", systemImage: "waveform.path.ecg") }
                    .tag(0)
                SettingsView(services: services)
                    .tabItem { Label("Nastavení", systemImage: "gearshape") }
                    .tag(1)
            }
        }
    }
}
