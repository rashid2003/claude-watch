import Charts
import SwiftUI
import WatchProtocol

struct AccountDetailView: View {
    @Environment(RemoteStore.self) private var store
    let profileId: String

    @State private var samples: [UsageSample] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var range: Range = .day

    enum Range: String, CaseIterable, Identifiable {
        case fiveHours = "5h", day = "24h", week = "7d"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .fiveHours: 5 * 3600
            case .day: 86400
            case .week: 7 * 86400
            }
        }
    }

    private var account: AccountStatus? {
        store.snapshot?.accounts.first { $0.id == profileId } ?? store.snapshot?.account(forProfile: profileId)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let a = account {
                        AccountRowView(account: a, now: ctx.date, showSessions: false, showDetailsLink: false)
                        Divider()
                        SectionTitle(title: "usage") {
                            Picker("Range", selection: $range) {
                                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        chart.padding(.bottom, 10)
                        if a.memberProfileIds.count > 1 || !a.alsoOpenIn.isEmpty {
                            Divider()
                            SectionTitle("windows")
                            ForEach(a.memberProfileIds, id: \.self) { id in
                                HStack(spacing: 6) {
                                    Text("▸").foregroundStyle(Theme.clay).fixedSize()
                                    Text(store.snapshot?.accountName(forProfile: id) ?? id)
                                    Text("· " + id).foregroundStyle(.secondary)
                                }
                                .font(Theme.monoSmall)
                                .padding(.vertical, 3)
                            }
                        }
                        Divider()
                        SectionTitle(title: "chats", count: a.sessions.count) { EmptyView() }
                        if a.sessions.isEmpty {
                            EmptyNote(text: "No recent chats.")
                        }
                        ForEach(a.sessions) { s in
                            NavigationLink(value: ChatRoute(id: s.id)) { SessionRowView(session: s, showAccount: false) }
                                .buttonStyle(.row)
                                .foregroundStyle(.primary)
                        }
                    } else {
                        EmptyNote(text: "This account isn't in the latest snapshot.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .screenBackground()
        .navigationTitle(account?.profile.name.lowercased() ?? "account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("✻").foregroundStyle(Theme.clay)
                    Text(account?.profile.name.lowercased() ?? "account")
                }
                .font(Theme.monoTitle)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var visible: [UsageSample] {
        let from = Date().addingTimeInterval(-range.seconds)
        return samples.filter { $0.t >= from }
    }

    @ViewBuilder private var chart: some View {
        if loading && samples.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("loading samples…") }
                .font(Theme.monoSmall).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let loadError, samples.isEmpty {
            Text("✗ " + loadError).font(Theme.monoSmall).foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if visible.isEmpty {
            Text("no samples in the last \(range.rawValue)").font(Theme.monoSmall).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            Chart {
                ForEach(visible, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("Percent", s.fiveHour), series: .value("Limit", "5h"))
                        .foregroundStyle(by: .value("Limit", "5h"))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Time", s.t), y: .value("Percent", s.weekly), series: .value("Limit", "7d"))
                        .foregroundStyle(by: .value("Limit", "7d"))
                        .interpolationMethod(.linear)
                }
                RuleMark(y: .value("Cap", 100))
                    .foregroundStyle(Theme.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartForegroundStyleScale(["5h": Theme.clay, "7d": Theme.yellow])
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(Theme.monoTiny) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour())
                        .font(Theme.monoTiny)
                }
            }
            .chartLegend(position: .top, alignment: .leading) {
                HStack(spacing: 12) {
                    legend("5h", Theme.clay)
                    legend("7d", Theme.yellow)
                }
                .font(Theme.monoTiny)
            }
            .frame(height: 200)
            .accessibilityLabel("Usage over the last \(range.rawValue)")
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(name).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            samples = try await store.usage(profileId: profileId).sorted { $0.t < $1.t }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { AccountDetailView(profileId: "default") }
        .environment(RemoteStore(preview: Fixtures.snapshot))
        .tint(Theme.clay)
}
