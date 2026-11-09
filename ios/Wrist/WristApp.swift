import SwiftUI

@main
struct WristApp: App {
    @StateObject private var watch = WatchController.shared
    @Environment(\.scenePhase) private var phase

    init() {
        WatchController.shared.registerBackgroundRefresh()
        KeepAlive.shared.start()
        CommandPoller.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(watch)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, now in
            if now == .background { watch.scheduleBackgroundRefresh() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var watch: WatchController
    var body: some View {
        if watch.paired { NowView() } else { PairView() }
    }
}

// MARK: - Now

struct NowView: View {
    @EnvironmentObject var watch: WatchController
    @State private var showSettings = false
    @State private var showPair = false

    var body: some View {
        let card = watch.current
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if watch.cards.count > 1 {
                        Picker("Watch", selection: Binding(get: { watch.current?.id }, set: { watch.selected = $0 })) {
                            ForEach(watch.cards) { c in Text(c.name).tag(Optional(c.id)) }
                        }
                        .pickerStyle(.segmented)
                    }
                    hero(card)
                    HStack(spacing: 12) {
                        Tile(title: "Steps", value: card?.snapshot?.steps.map { "\($0.count)" } ?? "–", symbol: "figure.walk")
                        Tile(title: "Battery", value: card?.snapshot?.battery.map { "\($0.percent)%" } ?? "–", symbol: batterySymbol(card))
                    }
                    if let hr = card?.hrToday, !hr.isEmpty { HeartLine(points: hr).frame(height: 90) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(syncLine(card)).font(.footnote).foregroundStyle(.secondary)
                        if !watch.influxText.isEmpty { Text(watch.influxText).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .refreshable { watch.syncNow() }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPair = true; watch.startPairing() } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPair, onDismiss: { watch.cancelPairing() }) { PairView() }
            .onChange(of: watch.pairing) { _, on in if !on { showPair = false } }
        }
    }

    private func hero(_ card: WatchController.Card?) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card?.snapshot?.latestHr.map { "\($0.bpm)" } ?? "–")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                Text("bpm").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(card?.name ?? "Watch").font(.headline).foregroundStyle(.secondary)
            Chip(text: card?.state ?? "–", on: card?.state == "Linked")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            LinearGradient(colors: [Color(red: 0.55, green: 0.08, blue: 0.16), Color(red: 0.12, green: 0.02, blue: 0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func batterySymbol(_ card: WatchController.Card?) -> String {
        guard let p = card?.snapshot?.battery?.percent else { return "battery.0" }
        return p > 75 ? "battery.100" : p > 50 ? "battery.75" : p > 25 ? "battery.50" : "battery.25"
    }

    private func syncLine(_ card: WatchController.Card?) -> String {
        guard let d = card?.lastSync else { return "Not synced yet" }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "Synced \(f.string(from: d))"
    }
}

struct Tile: View {
    let title: String, value: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 32, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct Chip: View {
    let text: String, on: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct HeartLine: View {
    let points: [HrPoint]
    var body: some View {
        GeometryReader { geo in
            let lo = Double(points.map(\.bpm).min() ?? 40) - 5, hi = Double(points.map(\.bpm).max() ?? 120) + 5
            let t0 = Double(points.first?.atMs ?? 0), t1 = Double(max(points.last?.atMs ?? 1, (points.first?.atMs ?? 0) + 1))
            Path { path in
                for (i, p) in points.enumerated() {
                    let x = (Double(p.atMs) - t0) / (t1 - t0) * geo.size.width
                    let y = geo.size.height * (1 - (Double(p.bpm) - lo) / (hi - lo))
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color(red: 1, green: 0.3, blue: 0.4), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Pair

struct PairView: View {
    @EnvironmentObject var watch: WatchController
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "applewatch.radiowaves.left.and.right").font(.system(size: 64)).foregroundStyle(.pink)
            Text("Pair your watch").font(.title.bold())
            if watch.pairing {
                Text(watch.pairingText).multilineTextAlignment(.center).foregroundStyle(.secondary)
                ForEach(watch.found) { w in
                    Button { watch.pair(with: w) } label: {
                        HStack { Text(w.name).bold(); Spacer(); Image(systemName: "chevron.right") }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Button("Cancel") { watch.cancelPairing() }.padding(.top, 8)
            } else {
                Button { watch.startPairing() } label: {
                    Text("Find watch").bold().frame(maxWidth: .infinity).padding(16)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .padding(24)
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var watch: WatchController
    @Environment(\.dismiss) var dismiss
    @State private var allDay = Settings.allDayScan
    @State private var notifications = true
    @State private var features: [HealthFeature] = []
    @State private var confirmForget = false

    var body: some View {
        let card = watch.current
        NavigationStack {
            Form {
                Section("Measurements") {
                    ForEach(features, id: \.id) { f in
                        Toggle(f.name, isOn: Binding(get: { f.enabled }, set: { on in
                            if let id = card?.id { watch.setHealthFeature(id, f.id, on) }
                            if let i = features.firstIndex(where: { $0.id == f.id }) { features[i].enabled = on }
                        }))
                    }
                }
                Section(card?.name ?? "Watch") {
                    Toggle("Notifications", isOn: $notifications)
                        .onChange(of: notifications) { _, on in if let id = card?.id { watch.setNotifications(id, on) } }
                    if let d = card?.snapshot?.device {
                        LabeledContent("Model", value: d.name)
                        LabeledContent("Firmware", value: "\(d.firmware)")
                    }
                    Button("Send Test Notification") { watch.notify(title: "Wrist", message: "Test from Wrist") }
                    if let id = card?.id {
                        NavigationLink("Calibrate Hands") { HandsView(id: id) }
                    }
                    Button("Forget Watch", role: .destructive) { confirmForget = true }
                }
                Section("Data") {
                    Text(watch.influxText.isEmpty ? "Influx: waiting" : watch.influxText)
                    Text("Raw log: Files → Wrist → raw").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { if let id = card?.id { features = watch.healthFeatures(id) } }
            .confirmationDialog("Forget \(card?.name ?? "this watch")?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { if let id = card?.id { watch.forget(id) }; dismiss() }
            }
        }
    }
}

// MARK: - Hands

struct HandsView: View {
    @EnvironmentObject var watch: WatchController
    let id: UUID
    @State private var hand: UInt8 = 1

    var body: some View {
        VStack(spacing: 28) {
            Text("Set The Hands To 12:00").font(.title3.bold())
            Picker("Hand", selection: $hand) {
                Text("Hour").tag(UInt8(1))
                Text("Minute").tag(UInt8(0))
                Text("Activity").tag(UInt8(2))
            }
            .pickerStyle(.segmented)
            HStack(spacing: 14) {
                step("-10", -10); step("-1", -1); step("+1", 1); step("+10", 10)
            }
        }
        .padding(16)
        .navigationTitle("Calibrate Hands")
        .onAppear { watch.handsStart(id) }
        .onDisappear { watch.handsStop(id) }
    }

    private func step(_ label: String, _ steps: Int16) -> some View {
        Button(label) { watch.handsMove(id, hand: hand, steps: steps) }
            .font(.title3.bold())
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
