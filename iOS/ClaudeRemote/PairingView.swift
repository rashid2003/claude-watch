import SwiftUI
import UIKit
import WatchProtocol

/// Scan the QR code from "Pair iPhone…" on the Mac, or type host, port and code (needed in the Simulator).
struct PairingView: View {
    @Environment(RemoteStore.self) private var store
    @State private var host = ""
    @State private var port = "7433"
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var scanned: PairingPayload?
    @FocusState private var focus: Field?

    private enum Field { case host, port, code }
    private let hasCamera = QRScanner.isAvailable

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("pair with your mac").font(Theme.monoBold)
                        Text("On the Mac open ✻ claude-watch → iPhone… and scan the code. Both devices need Tailscale.")
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)

                    Divider()
                    SectionTitle("scan")
                    QRScanner { handleScan($0) }
                        .frame(height: hasCamera ? 260 : 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.clay.opacity(0.6)))
                    if let scanned {
                        StatusLine(ok: true, text: "found \(scanned.macName)").padding(.top, 6)
                    }

                    Divider().padding(.top, 12)
                    SectionTitle("or enter manually")
                    VStack(alignment: .leading, spacing: 8) {
                        field("host", focus: .host) {
                            TextField("my-mac.tail1234.ts.net, 100.x.y.z", text: $host)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        field("port", focus: .port) {
                            TextField("7433", text: $port).keyboardType(.numberPad)
                        }
                        field("code", focus: .code) {
                            TextField("6 digits", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
                        }
                        Text("several hosts: separate with commas; the first that answers wins")
                            .font(Theme.monoTiny)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if let error {
                            Text("✗ " + error)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if busy {
                            ProgressView().controlSize(.small)
                            Text("pairing…").font(Theme.monoSmall).foregroundStyle(.secondary)
                        } else {
                            Button("↵ pair") {
                                let hosts = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                Task { await pair(hosts: hosts, port: Int(port) ?? 7433, code: code) }
                            }
                            .buttonStyle(.clay)
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || code.count != 6 || Int(port) == nil)
                        }
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(Theme.clay)
                        Text("claude-remote")
                    }
                    .font(Theme.monoTitle)
                }
            }
        }
    }

    private func field<F: View>(_ label: String, focus f: Field, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            content().focused($focus, equals: f)
        }
        .fieldBox(focused: focus == f)
    }

    private func handleScan(_ text: String) {
        guard !busy else { return }
        guard let p = try? WireCoder.decoder.decode(PairingPayload.self, from: Data(text.utf8)) else {
            error = "That QR code isn't a ClaudeWatch pairing code."
            return
        }
        scanned = p
        host = p.hosts.joined(separator: ", ")
        port = String(p.port)
        code = p.code
        Task { await pair(hosts: p.hosts, port: p.port, code: p.code) }
    }

    private func pair(hosts: [String], port: Int, code: String) async {
        busy = true
        error = nil
        focus = nil
        defer { busy = false }
        do {
            let creds = try await RemoteClient.pair(hosts: hosts, port: port, code: code,
                                                    deviceName: UIDevice.current.name)
            store.didPair(creds)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    PairingView()
        .environment(RemoteStore(preview: nil, connection: .offline))
        .tint(Theme.clay)
}
