import MapKit
import SwiftUI
import TeslaLinkCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?

    var body: some View {
        @Bindable var model = model
        Form {
            // Settings has no artboard: a system form under the same header as every screen.
            Section {
                ScreenHeader(title: "Settings")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if model.isDemo {
                Section {
                    Button("Leave demo and connect your Tesla") { model.leaveDemo() }
                } header: {
                    Text("Demo mode")
                } footer: {
                    Text("You're looking at a simulated car and generated history, stored separately from your own data.")
                }
            } else {
                Section {
                    ForEach(model.accounts) { account in
                        NavigationLink { AccountDetailView(accountID: account.id) } label: { AccountRow(account: account) }
                    }
                    NavigationLink { AddAccountView() } label: {
                        Label("Add Tesla account", systemImage: "plus")
                    }
                    Button("Reload vehicles") { Task { await model.refreshVehicleList() } }
                } header: {
                    Text("Tesla accounts")
                } footer: {
                    Text("Cars from every linked account appear together. A car shared by two accounts is logged once.")
                }
            }

            Section("Display") {
                Picker("Units", selection: $model.settings.units) {
                    ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Toggle("Record drives with phone GPS", isOn: $model.settings.usePhoneGPS)
                Toggle("Notify when charging finishes", isOn: $model.settings.notifyChargeComplete)
                Toggle("Notify when a drive is logged", isOn: $model.settings.notifyDriveLogged)
            } header: {
                Text("Logging")
            } footer: {
                Text("With location set to Always, the phone notices when you start moving and keeps logging for the whole drive, without you opening the app.")
            }

            Section("Places") {
                NavigationLink("Geofences & electricity prices") { GeofencesView() }
            }

            Section {
                Stepper("Let car sleep after \(Int(model.settings.logger.idleMinutesBeforeSuspend)) min idle",
                        value: $model.settings.logger.idleMinutesBeforeSuspend, in: 3...60)
                Stepper("Then leave it alone for \(Int(model.settings.logger.suspendMinutes)) min",
                        value: $model.settings.logger.suspendMinutes, in: 5...60)
                Toggle("Only sleep when locked", isOn: $model.settings.logger.requireLockedToSleep)
                Stepper("Driving: every \(Int(model.settings.logger.drivingInterval)) s", value: $model.settings.logger.drivingInterval, in: 5...120, step: 5)
                Stepper("Charging: every \(Int(model.settings.logger.chargingInterval)) s", value: $model.settings.logger.chargingInterval, in: 15...600, step: 15)
            } header: {
                Text("Polling")
            } footer: {
                Text("The Fleet API bills per request. Longer intervals cost less; drive tracks stay detailed thanks to phone GPS. Requests only run while iOS gives the app time.")
            }

            Section("Data") {
                Button("Export all data (JSON)") { Task { await export() } }
                if let exportURL { ShareLink("Share export", item: exportURL) }
            }

            Section("Advanced") {
                NavigationLink("Tesla developer app") { TeslaSetupView(backTitle: "Settings") }
                NavigationLink("About & licenses") { AboutView() }
            }
        }
        .tlListStyle()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func export() async {
        guard let data = try? await model.store.exportJSON() else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "TeslaLink-export-\(Date().formatted(.iso8601.year().month().day())).json")
        try? data.write(to: url)
        exportURL = url
    }
}

/// One linked account in Settings: who it is, its cars and whether it's connected.
private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: TeslaAccount

    var body: some View {
        let status = model.accountStatus[account.id]
        let cars = model.cars(of: account).map(\.displayName)
        HStack(spacing: TL.Space.s3) {
            Circle()
                .fill(status.map(AccountStatusLine.color) ?? TL.Palette.steelDeep)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title ?? "Tesla account").foregroundStyle(TL.Palette.ink)
                Text(([cars.isEmpty ? "No cars yet" : cars.joined(separator: ", "), account.region.shortName]).joined(separator: " · "))
                    .font(TL.Typeface.caption)
                    .foregroundStyle(TL.Palette.inkMuted)
                if let status, status != .connected {
                    AccountStatusLine(status: status)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Connected", "Sign-in expired", or what Tesla said.
private struct AccountStatusLine: View {
    let status: AccountStatus

    var body: some View {
        Text(text).font(TL.Typeface.caption).foregroundStyle(Self.color(status))
    }

    private var text: String {
        switch status {
        case .connected: "Connected"
        case .needsReconnect: "Sign-in expired. Reconnect to keep logging."
        case .problem(let message): message
        }
    }

    static func color(_ status: AccountStatus) -> Color {
        status == .connected ? TL.Palette.charge : TL.Palette.amber
    }
}

/// One linked account: status, cars, reconnect and disconnect.
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    @State private var confirmDisconnect = false

    var body: some View {
        ScrollView {
            if let account = model.accounts.first(where: { $0.id == accountID }) {
                let status = model.accountStatus[account.id]
                VStack(alignment: .leading, spacing: TL.Space.s4) {
                    ScreenHeader(back: "Settings", label: "Tesla account · \(account.region.shortName)", title: account.title ?? "Tesla account", titleSize: 28)
                    Card(title: "Status", lightbar: false) {
                        VStack(alignment: .leading, spacing: TL.Space.s3) {
                            AccountStatusLine(status: status ?? .connected)
                            if status != .connected && status != nil {
                                ConnectTeslaButton(title: "Reconnect", reconnecting: account)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card(title: "Cars", lightbar: false) {
                        let cars = model.cars(of: account)
                        VStack(alignment: .leading, spacing: TL.Space.s2) {
                            if cars.isEmpty {
                                Text("None yet. They appear after the next refresh.").font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                            }
                            ForEach(cars) { car in
                                Text(car.displayName).font(TL.Typeface.sans(15, .semibold)).foregroundStyle(TL.Palette.ink)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: TL.Space.s1) {
                        Button("Disconnect this account", role: .destructive) { confirmDisconnect = true }
                            .buttonStyle(.tlSecondary)
                        Text("Its cars stop updating. Their history stays on this phone.")
                            .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                    }
                }
                .padding(.horizontal, TL.Space.s4)
                .padding(.bottom, TL.Space.s6)
            }
        }
        .tlScreen()
        .confirmationDialog("Disconnect this Tesla account?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await model.disconnect(accountID)
                    dismiss()
                }
            }
        } message: {
            Text("TeslaLink stops logging its cars. You can connect it again later.")
        }
    }
}

/// Linking another Tesla account (a partner's car, a second household).
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TL.Space.s4) {
                ScreenHeader(back: "Settings", label: "Tesla accounts", title: "Add an account")
                Text("Sign in with the other Tesla account. Tesla's page opens without the last sign-in remembered, so you can use different details. Its cars join the switcher; cars you already log stay as they are.")
                    .font(TL.Typeface.body)
                    .foregroundStyle(TL.Palette.inkMuted)
                ConnectTeslaButton(title: "Connect another account", onLinked: { dismiss() })
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, TL.Space.s4)
            .padding(.bottom, TL.Space.s6)
        }
        .tlScreen()
    }
}

struct GeofencesView: View {
    @Environment(AppModel.self) private var model
    /// In the open Duo's right pane: its own header with the add button, since the system bar's
    /// button would land in the side column under the menu.
    var inPane = false
    @State private var fences: [Geofence] = []
    @State private var editing: Geofence?

    var body: some View {
        List {
            if inPane {
                Section {
                    ScreenHeader(label: "Settings", title: Text("Places")) {
                        Button { editing = newFence() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TL.Palette.ion)
                                .frame(width: 44, height: 44)
                                .background(ChamferedRectangle(cut: TL.Chamfer.sm).fill(TL.Palette.surface2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add place")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(fences) { g in
                Button { editing = g } label: {
                    VStack(alignment: .leading) {
                        Text(g.name).foregroundStyle(.primary)
                        if let t = g.tariff {
                            Text("\(t.pricePerUnit.formatted(.currency(code: t.currencyCode))) per \(t.basis == .perMinute ? "min" : "kWh")\(t.windows.isEmpty ? "" : " + time-of-use")")
                                .font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                        }
                    }
                }
            }
            .onDelete { idx in
                Task {
                    for i in idx { if let id = fences[i].id { try? await model.store.deleteGeofence(id: id) } }
                    await load()
                }
            }
        }
        .overlay { if fences.isEmpty { ContentUnavailableView("No places", systemImage: "mappin", description: Text("Add Home to name drives and price home charging.")) } }
        .tlListStyle()
        .navigationTitle("Places")
        .toolbar(inPane ? .hidden : .automatic, for: .navigationBar)
        // Touching the side column, the list would reach in under the menu: stop short of it.
        // The margin gets the list's ground too; otherwise the stack's black shows through.
        .padding(.trailing, inPane ? TL.Space.s4 : 0)
        .background(TL.Palette.ground)
        .toolbar {
            if !inPane {
                Button { editing = newFence() } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { g in
            NavigationStack { GeofenceEditor(fence: g) { saved in Task { try? await model.store.save(saved); await load(); model.markDataChanged() } } }
        }
        // Reloads with the data: the demo's places are seeded just after launch.
        .task(id: model.dataVersion) { await load() }
    }

    private func load() async { fences = (try? await model.store.geofences()) ?? [] }

    private func newFence() -> Geofence {
        let s = model.selectedVehicle.flatMap { model.status(for: $0.vin).snapshot }
        return Geofence(name: fences.isEmpty ? "Home" : "New place", latitude: s?.latitude ?? 37.3349, longitude: s?.longitude ?? -122.009, radiusM: 75)
    }
}

struct GeofenceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var fence: Geofence
    let onSave: (Geofence) -> Void
    @State private var hasTariff = false
    @State private var price = 0.25
    @State private var basis: Tariff.Basis = .energyUsed
    @State private var offPeak = false
    @State private var offPeakPrice = 0.12
    @State private var offPeakStart = 22
    @State private var offPeakEnd = 6
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $fence.name)
                MapReader { proxy in
                    Map(position: $camera) {
                        MapCircle(center: .init(latitude: fence.latitude, longitude: fence.longitude), radius: fence.radiusM)
                            .foregroundStyle(.tint.opacity(0.25))
                        Marker(fence.name, coordinate: .init(latitude: fence.latitude, longitude: fence.longitude))
                    }
                    .onTapGesture { pt in
                        if let c = proxy.convert(pt, from: .local) { fence.latitude = c.latitude; fence.longitude = c.longitude }
                    }
                }
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
                Text("Tap the map to move the place.").font(TL.Typeface.caption).foregroundStyle(TL.Palette.inkMuted)
                Stepper("Radius \(Int(fence.radiusM)) m", value: $fence.radiusM, in: 25...1000, step: 25)
            }
            Section("Electricity price") {
                Toggle("Track charging cost here", isOn: $hasTariff)
                if hasTariff {
                    Picker("Billed on", selection: $basis) {
                        Text("Energy from the wall").tag(Tariff.Basis.energyUsed)
                        Text("Energy into the battery").tag(Tariff.Basis.energyAdded)
                        Text("Minutes").tag(Tariff.Basis.perMinute)
                    }
                    LabeledContent("Price") { TextField("Price", value: $price, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Toggle("Off-peak rate", isOn: $offPeak)
                    if offPeak {
                        LabeledContent("Off-peak price") { TextField("Price", value: $offPeakPrice, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        Stepper("From \(offPeakStart):00", value: $offPeakStart, in: 0...23)
                        Stepper("Until \(offPeakEnd):00", value: $offPeakEnd, in: 0...23)
                    }
                }
            }
        }
        .navigationTitle(fence.id == nil ? "New place" : fence.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var g = fence
                    g.tariff = hasTariff ? Tariff(basis: basis, pricePerUnit: price,
                                                  windows: offPeak ? [.init(startMinute: offPeakStart * 60, endMinute: offPeakEnd * 60, pricePerUnit: offPeakPrice)] : [],
                                                  currencyCode: Locale.current.currency?.identifier ?? "USD") : nil
                    onSave(g)
                    dismiss()
                }
            }
        }
        .onAppear {
            camera = .region(MKCoordinateRegion(center: .init(latitude: fence.latitude, longitude: fence.longitude), latitudinalMeters: 600, longitudinalMeters: 600))
            if let t = fence.tariff {
                hasTariff = true; price = t.pricePerUnit; basis = t.basis
                if let w = t.windows.first { offPeak = true; offPeakPrice = w.pricePerUnit; offPeakStart = w.startMinute / 60; offPeakEnd = w.endMinute / 60 }
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("TeslaLink is an independent app and is not affiliated with Tesla, Inc. or the TeslaMate project.")
                Text("The logging approach (when to poll, when to let the car sleep, how consumption is derived from charges) is inspired by TeslaMate and re-implemented from scratch in Swift.")
            }
            Section("Privacy") {
                Text("Everything is stored in a single database on this device. TeslaLink talks only to Tesla's servers, and uses Tesla's public configurator images for the car picture.")
            }
        }
        .navigationTitle("About")
    }
}
