import OstraCore
import SwiftUI

/// Global search: one field, and everything in the app underneath it.
///
/// It opens at once and has no entrance, because it opens many times a day.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        let sections = app.searchSections
        let flat = sections.flatMap(\.results)
        let highlighted = flat.indices.contains(app.searchHighlight) ? flat[app.searchHighlight].id : nil

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search agents, actions, files, and messages", text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.text(16))
                    .focused($focused)
                Keycap("esc", size: 20)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: 56)

            Hairline()

            if flat.isEmpty {
                Text(app.searchQuery.isEmpty ? "Nothing here yet" : "No results for “\(app.searchQuery)”")
                    .font(Theme.text(13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections, id: \.section) { group in
                                Text(group.section.rawValue)
                                    .font(Theme.ui(11, .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                ForEach(group.results) { result in
                                    SearchRow(result: result, highlighted: result.id == highlighted)
                                        .id(result.id)
                                        .onTapGesture { app.runSearchResult(result) }
                                        .onHover { inside in
                                            if inside, let index = flat.firstIndex(where: { $0.id == result.id }) {
                                                app.searchHighlight = index
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 432)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 640)
        .glassPanel(cornerRadius: Theme.panelRadius, frost: max(0.55, app.settings.data.panelFrost))
        .onAppear { focused = true }
    }
}

private struct SearchRow: View {
    let result: SearchResult
    var highlighted: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let agent = app.store.agent(result.agentID) {
                    if StatusDot.isVisible(phase: agent.phase, unseen: agent.snapshot.hasUnseenResult) {
                        StatusDot(phase: agent.phase, unseen: agent.snapshot.hasUnseenResult, size: 8)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1).frame(width: 8, height: 8)
                    }
                } else {
                    Image(systemName: result.symbol)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)

            Text(result.title)
                .font(Theme.ui(13, .medium))
                .lineLimit(1)
                .layoutPriority(1)

            if let subtitle = result.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.text(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if !result.keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(result.keys.enumerated()), id: \.offset) { _, key in
                        Keycap(key, size: 20, prominent: highlighted)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.07 : 0))
        }
        .contentShape(Rectangle())
    }
}
