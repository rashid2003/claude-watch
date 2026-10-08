import SwiftUI
import UIKit
import WatchProtocol

/// Scan the QR code from "Pair iPhone…" on the Mac, or type host, port and code (needed in the Simulator).
struct PairingView: View {
    @Environment(RemoteStore.self) private var store
    @State private var host = ""
    @State private var port = PairingView.defaultPort
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var scanned: PairingPayload?
    @FocusState private var focus: Field?

    private enum Field { case host, port, code }
    /// 7433, or 7434 in Session Watch Next (pairs with the Mac's Next build by default).
    static let defaultPort = Bundle.main.object(forInfoDictionaryKey: "SWDefaultPort") as? String ?? "7433"
    private let hasCamera = QRScanner.isAvailable
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 40

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("pair with your mac").font(Theme.monoBold)
                        Text("On the Mac open Session Watch → iPhone and scan the code. It connects through the Session Watch relay; Tailscale is optional.")
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
                            TextField(PairingView.defaultPort, text: $port).keyboardType(.numberPad)
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
                            LoadingLine(text: "pairing…").frame(minHeight: 44)
                        } else {
                            Button("↵ pair") {
                                let hosts = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                Task { await pair(hosts: hosts, port: Int(port) ?? Int(PairingView.defaultPort) ?? 7433, code: code) }
                            }
                            .buttonStyle(.clay)
                            .fixedSize()
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || code.count != 6 || Int(port) == nil)
                        }
                    }
                    .padding(.top, 14)

                    Divider().padding(.top, 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("no mac handy?").foregroundStyle(.secondary)
                            Button {
                                focus = nil
                                Haptics.send()
                                withAnimation(.easeInOut(duration: 0.3)) { store.enterDemo() }
                            } label: {
                                Text("› try demo").frame(minHeight: 36)
                            }
                            .buttonStyle(LinkButtonStyle(color: Theme.clay, font: Theme.monoSmall.weight(.semibold)))
                            .disabled(busy)
                            .accessibilityHint("Shows the app with sample accounts and chats")
                        }
                        Text("sample accounts and chats · nothing is sent anywhere · exit from the mac tab")
                            .font(Theme.monoTiny)
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.monoSmall)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screenBackground()
            #if DEBUG
            // Development: pair the Simulator in one go (SIMCTL_CHILD_SW_PAIR='{"v":1,"macName":…}', the QR's JSON).
            .task { if let qr = ProcessInfo.processInfo.environment["SW_PAIR"] { handleScan(qr) } }
            #endif
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("✻").foregroundStyle(Theme.clay)
                        Text("session-watch")
                    }
                    .font(Theme.monoTitle)
                }
            }
        }
    }

    private func field<F: View>(_ label: String, focus f: Field, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).fixedSize().frame(minWidth: labelWidth, alignment: .leading)
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
        Task { await pair(hosts: p.hosts, port: p.port, code: p.code, relay: p.relay) }
    }

    private func pair(hosts: [String], port: Int, code: String, relay: RelayInfo? = nil) async {
        busy = true
        error = nil
        focus = nil
        defer { busy = false }
        do {
            let creds = try await RemoteClient.pair(hosts: hosts, port: port, code: code,
                                                    deviceName: UIDevice.current.name, relay: relay)
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
