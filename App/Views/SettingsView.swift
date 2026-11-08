import MapKit
import SwiftUI
import TeslaLinkCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Account") {
                Picker("Region", selection: $model.settings.region) {
                    ForEach(FleetRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Button("Reload vehicles") { Task { await model.refreshVehicleList() } }
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
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
                NavigationLink("Developer app") { DeveloperAppSettingsView() }
                NavigationLink("About & licenses") { AboutView() }
            }
        }
        .tlListStyle()
        .navigationTitle("Settings")
    }

    private func export() async {
        guard let data = try? await model.store.exportJSON() else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "TeslaLink-export-\(Date().formatted(.iso8601.year().month().day())).json")
        try? data.write(to: url)
        exportURL = url
    }
}

struct DeveloperAppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Client ID", text: $model.settings.clientIDOverride).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Client secret", text: $model.settings.clientSecretOverride)
                TextField("Redirect URI", text: $model.settings.redirectURIOverride).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text("Leave empty to use the values built into the app (Config/Secrets.xcconfig). Create the app at developer.tesla.com; see docs/FLEET_API_SETUP.md.")
            }
        }
        .navigationTitle("Developer app")
    }
}

struct GeofencesView: View {
    @Environment(AppModel.self) private var model
    @State private var fences: [Geofence] = []
    @State private var editing: Geofence?

    var body: some View {
        List {
            ForEach(fences) { g in
                Button { editing = g } label: {
                    VStack(alignment: .leading) {
                        Text(g.name).foregroundStyle(.primary)
                        if let t = g.tariff {
                            Text("\(t.pricePerUnit.formatted(.currency(code: t.currencyCode))) per \(t.basis == .perMinute ? "min" : "kWh")\(t.windows.isEmpty ? "" : " + time-of-use")")
                                .font(.caption).foregroundStyle(.secondary)
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
        .toolbar {
            Button { editing = newFence() } label: { Label("Add", systemImage: "plus") }
        }
        .sheet(item: $editing) { g in
            NavigationStack { GeofenceEditor(fence: g) { saved in Task { try? await model.store.save(saved); await load(); model.markDataChanged() } } }
        }
        .task { await load() }
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
                Text("Tap the map to move the place.").font(.caption).foregroundStyle(.secondary)
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
