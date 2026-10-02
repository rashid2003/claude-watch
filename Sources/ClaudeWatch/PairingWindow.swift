import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WatchBridge
import WatchCore

/// "Pair iPhone…": a QR code the Claude Watch iPhone app scans, plus the paired devices with Revoke.
struct PairingWindow: View {
    @EnvironmentObject var model: WatchModel
    @State private var payload: PairingPayload?
    @State private var opened = Date()
    @State private var devices: [Device] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair iPhone").font(.title2.bold())
                if let bridge = model.bridge {
                    content(bridge, now: ctx.date)
                } else {
                    Text("The iPhone bridge is off. Set \"bridgeEnabled\": true in the config and restart ClaudeWatch.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .onAppear { refresh(); newCode() }
        .onDisappear { model.bridge?.server.pairing.close() }
        .onReceive(model.$bridgeTick) { _ in refresh() }
    }

    @ViewBuilder
    func content(_ bridge: BridgeController, now: Date) -> some View {
        let left = max(0, PairingGate.lifetime - now.timeIntervalSince(opened))
        let open = bridge.server.pairing.isOpen && left > 0
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if open, let payload, let img = Self.qr(payload) {
                    Image(nsImage: img).interpolation(.none).resizable().padding(10)
                } else {
                    Button("New code") { newCode() }
                }
            }
            .frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 8) {
                Text("In Claude Watch on your iPhone, tap Pair and scan this code. Both devices must be on your tailnet.")
                    .fixedSize(horizontal: false, vertical: true)
                if open, let payload {
                    Text(payload.code).font(.system(size: 30, weight: .semibold, design: .monospaced))
                    Text("Code expires in \(Int(left))s").foregroundStyle(.secondary).font(.caption)
                    Text("Manual entry: \(payload.hosts.first ?? "127.0.0.1") · port \(payload.port)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("The code expired or was used.").foregroundStyle(.secondary)
                }
                Button("New code") { newCode() }
            }
        }
        if bridge.server.boundHosts.allSatisfy({ $0 == "127.0.0.1" }) {
            Label("Tailscale isn't connected on this Mac, so only the Simulator can pair.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.callout)
        }
        Divider()
        Text("Paired devices").font(.headline)
        if devices.isEmpty {
            Text("None yet").foregroundStyle(.secondary)
        }
        ForEach(devices) { d in
            HStack {
                Image(systemName: "iphone")
                VStack(alignment: .leading) {
                    Text(d.name)
                    Text("Paired \(d.createdAt.formatted(date: .abbreviated, time: .shortened))"
                         + (d.lastSeenAt.map { " · seen \(Fmt.ago($0))" } ?? "")
                         + (d.apnsToken == nil ? " · no push" : " · push on"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke", role: .destructive) { bridge.server.revoke(deviceId: d.id); refresh() }
            }
        }
        if let last = bridge.server.audit.last {
            Text("Last remote action: \(last.text), \(Fmt.ago(last.at))").font(.caption).foregroundStyle(.secondary)
        }
    }

    func newCode() {
        guard let bridge = model.bridge else { return }
        payload = bridge.openPairing()
        opened = Date()
    }

    func refresh() { devices = model.bridge?.server.devices.all ?? [] }

    static func qr(_ payload: PairingPayload) -> NSImage? {
        guard let data = try? WireCoder.encoder.encode(payload) else { return nil }
        let f = CIFilter.qrCodeGenerator()
        f.message = data
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
