import SwiftUI

struct RunHistoryView: View {
    let db: DatabaseManager?
    @State private var runs: [BackupRun] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Runs").font(.caption).foregroundColor(.secondary)
            if runs.isEmpty {
                Text("No runs recorded.").font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(runs, id: \.id) { run in
                    RunRowView(run: run, db: db)
                }
            }
        }
        .onAppear { loadRuns() }
    }

    private func loadRuns() {
        runs = (try? db?.fetchRecentRuns(limit: 5)) ?? []
    }
}

private struct RunRowView: View {
    let run: BackupRun
    let db: DatabaseManager?
    @State private var expanded = false
    @State private var results: [JobResult] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: iconName(for: run.status))
                    .foregroundColor(color(for: run.status))
                Text(shortDate(run.startedAt)).font(.caption2)
                Spacer()
                Button(expanded ? "▲" : "▼") { toggle() }
                    .buttonStyle(.borderless).font(.caption2)
            }
            if expanded {
                ForEach(results, id: \.id) { r in
                    HStack {
                        Text(r.jobType.rawValue).font(.caption2)
                        Spacer()
                        Text(r.status.rawValue).font(.caption2)
                            .foregroundColor(r.status == .done ? .green : .red)
                    }.padding(.leading, 16)
                }
            }
        }
    }

    private func toggle() {
        expanded.toggle()
        if expanded, let id = run.id {
            results = (try? db?.fetchJobResults(forRun: id)) ?? []
        }
    }

    private func iconName(for s: RunStatus) -> String {
        switch s {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.circle.fill"
        default:       return "arrow.clockwise"
        }
    }

    private func color(for s: RunStatus) -> Color {
        switch s {
        case .success: return .green
        case .partial: return .orange
        case .failed:  return .red
        default:       return .blue
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}
