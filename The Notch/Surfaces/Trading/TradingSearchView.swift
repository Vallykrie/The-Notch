import SwiftUI

@MainActor struct TradingSearchView: View {
    @ObservedObject var store: TradingStore
    var close: () -> Void
    @State private var query = ""
    @State private var results: [TradingInstrument] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.textSecondary)
                TextField("Spot pair: BTC/USDT", text: $query)
                    .textFieldStyle(.plain).font(Theme.Text.caption).focused($focused)
                Button("Done", action: close).buttonStyle(.plain).font(Theme.Text.micro)
            }
            Text("Binance Spot · public feed").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
            if let error {
                Text(error).font(Theme.Text.micro).foregroundStyle(Theme.Colors.tradingDown)
            } else if loading {
                Text("Searching…").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
            } else if results.isEmpty {
                Text(query.isEmpty ? "Search a spot pair to add it to your watchlist." : "No matching pairs. Try a symbol or a shorter name.")
                    .font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(results) { item in
                        Button {
                            store.add(item)
                            if store.watchlist.contains(where: { $0.id == item.id }) { close() }
                            else { error = store.message }
                        } label: {
                            HStack {
                                Text(item.symbol).font(Theme.Text.caption).frame(width: 90, alignment: .leading)
                                Text(item.name).font(Theme.Text.micro).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(item.sourceLabel) · \(item.currency)")
                                    .font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
                                Image(systemName: "plus").font(Theme.Text.micro)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            results = []; error = nil
            let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty else { loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                let found = try await store.search(requested)
                guard !Task.isCancelled else { return }
                results = found; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? TradingDataError ?? .disconnected).localizedDescription
                loading = false
            }
        }
    }
}
