import SwiftUI

struct StatusView: View {
    let services: AppServices
    @State private var confirmReimport = false
    private var status: AppStatus { services.status }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(headline, systemImage: status.preparingReimport ? "pause.circle" : "arrow.triangle.2.circlepath")
                        .font(.headline)
                    if let error = status.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    Text(status.currentType.isEmpty ? "Čekáme na synchronizaci" : status.currentType)
                        .font(.headline)
                    if status.totalTypes > 0 {
                        ProgressView(value: Double(status.completedTypes), total: Double(status.totalTypes))
                            .tint(.orange)
                        LabeledContent("Dokončené typy", value: "\(status.completedTypes) / \(status.totalTypes)")
                    }
                    LabeledContent("Načteno v tomto průchodu", value: status.loadedSamples.formatted())
                    if status.failedTypes > 0 {
                        LabeledContent("Typy s chybou", value: "\(status.failedTypes)").foregroundStyle(.red)
                    }
                } header: { Text("Načítání ze Zdraví") } footer: {
                    Text("Celkový počet záznamů předem neznáme. Průběh ukazuje dokončené datové typy, nikoli procento všech dat.")
                }
                Section {
                    Text(status.deliveredSamples.formatted())
                        .font(.system(.title, design: .rounded).weight(.semibold))
                    Text("Potvrzených záznamů od posledního úplného restartu")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Čeká v telefonu", value: "\(status.outboxPending.formatted()) dávek · \(ByteCountFormatter.string(fromByteCount: status.outboxBytes, countStyle: .file))")
                    if status.uploading { Label("Odesíláme dávku…", systemImage: "arrow.up.circle") }
                    if let date = status.lastDelivered {
                        LabeledContent("Poslední potvrzení") { Text(date, style: .relative) }
                    }
                    if let retry = status.outboxNextRetry {
                        LabeledContent("Další pokus nejdříve") { Text(retry, style: .time) }
                    }
                    Button("Zkusit odeslat teď") {
                        Task { await services.retryDelivery() }
                    }
                    .disabled(status.preparingReimport || status.uploading || status.outboxPending == 0)
                } header: { Text("Odesílání na nastavený server") } footer: {
                    Text("Potvrzení znamená uložení na nastaveném serveru. Následné předání dalšímu serveru aplikace nevidí.")
                }
                Section {
                    Button(status.syncing ? "Načítání probíhá…" : "Načíst nové údaje") {
                        Task { await services.syncNow(.manual) }
                    }
                    .disabled(status.syncing || status.preparingReimport)
                    NavigationLink("Detail průběhu") {
                        List {
                            ForEach(TypeRegistry.groups, id: \.self) { group in
                                Section(group) {
                                    ForEach(TypeRegistry.all.filter { $0.group == group && services.settings.isEnabled($0.key) }) { type in
                                        VStack(alignment: .leading) {
                                            Text(type.displayName)
                                            Text("\(status.typeStatus[type.key]?.totalDelivered ?? 0) potvrzených záznamů")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }.navigationTitle("Datové typy")
                    }
                    NavigationLink("Záznam aktivity") { LogView(services: services) }
                    Button("Znovu odeslat celou historii…", role: .destructive) { confirmReimport = true }
                        .disabled(status.preparingReimport)
                        .confirmationDialog("Znovu odeslat celou historii?", isPresented: $confirmReimport) {
                            Button("Spustit úplný import", role: .destructive) {
                                Task { await services.reimportAll() }
                            }
                        } message: {
                            Text("Zastavíme současný běh a znovu načteme dostupnou historii povolených typů ze Zdraví. Server musí slučovat opakované záznamy podle jejich ID.")
                        }
                } footer: {
                    Text("Při prvním nebo úplném importu nech aplikaci otevřenou. Načítání a odesílání probíhají současně; dokončeno je až po načtení typů a vyprázdnění fronty.")
                }
                if status.authNeeded {
                    Section {
                        Button("Povolit přístup ke Zdraví") { Task { await services.requestHealthAccess() } }
                    }
                }
                if #available(iOS 26.0, *) {
                    Section {
                        Button("Povolit přístup k lékům") { Task { await services.requestMedicationAccess() } }
                    }
                }
                if services.settings.baseURL == nil {
                    Section { Text("V Nastavení zadej adresu serveru a klíč.").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Pulso")
        }
    }

    private var headline: String {
        if status.preparingReimport { return "Připravujeme úplný restart…" }
        if status.reading { return "Načítáme historii" }
        if status.outboxPending > 0 { return status.uploading ? "Odesíláme uložená data" : "Data čekají na odeslání" }
        if status.passFinished && status.failedTypes == 0 { return "Synchronizace dokončena" }
        return "Synchronizace připravena"
    }
}
