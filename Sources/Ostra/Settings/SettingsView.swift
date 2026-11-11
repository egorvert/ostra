import AppKit
import OstraCore
import SwiftUI
import UniformTypeIdentifiers

/// The settings sheet: canvas background, glass, appearance, and the engine's status.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = app.settings

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(Theme.ui(17, .semibold))
                Spacer()
                Button("Reset") { app.settings.reset() }
                    .buttonStyle(.plain)
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(.secondary)
                Keycap("esc", size: 18)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Canvas") {
                        row("Background") {
                            Picker("", selection: $settings.data.canvasStyle) {
                                ForEach(CanvasStyle.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 280)
                        }
                        row("Color") {
                            HStack(spacing: 10) {
                                ColorPicker("", selection: canvasColor, supportsOpacity: false)
                                    .labelsHidden()
                                ForEach(Self.swatches, id: \.self) { hex in
                                    swatch(hex)
                                }
                                if settings.data.canvasColor != nil {
                                    Button("Default") { settings.data.canvasColor = nil }
                                        .buttonStyle(.plain)
                                        .font(Theme.ui(11.5, .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if settings.data.canvasStyle == .dots || settings.data.canvasStyle == .grid {
                            row("Pattern strength") {
                                Slider(value: $settings.data.patternStrength, in: 0...1)
                                    .frame(width: 280)
                            }
                        }
                        if settings.data.canvasStyle == .image {
                            row("Image") {
                                HStack(spacing: 10) {
                                    Button("Choose…") { chooseImage() }
                                    if let path = settings.data.backgroundImagePath {
                                        Text((path as NSString).lastPathComponent)
                                            .font(Theme.text(12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: 200, alignment: .leading)
                                    } else {
                                        Text("No image chosen")
                                            .font(Theme.text(12))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            row("Dim") {
                                Slider(value: $settings.data.imageDim, in: 0...0.9)
                                    .frame(width: 280)
                            }
                            row("Blur") {
                                Slider(value: $settings.data.imageBlur, in: 0...40)
                                    .frame(width: 280)
                            }
                        }
                    }

                    section("Glass") {
                        row("Chat pane", note: "Pure glass suits any background. Frosted keeps text readable. Opaque hides the canvas.") {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $settings.data.chatFrost, in: 0...1)
                                    .frame(width: 280)
                                HStack {
                                    Text("Glass")
                                    Spacer()
                                    Text("Frosted")
                                    Spacer()
                                    Text("Opaque")
                                }
                                .font(Theme.ui(10.5, .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 280)
                            }
                        }
                        row("Menus and panels") {
                            Slider(value: $settings.data.panelFrost, in: 0...1)
                                .frame(width: 280)
                        }
                        row("Agents and projects", note: "Picks dark or light text from the canvas behind each one.") {
                            Toggle("Adapt text to the background", isOn: $settings.data.adaptiveInk)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    section("Appearance") {
                        row("Theme") {
                            Picker("", selection: $settings.data.appearance) {
                                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 280)
                        }
                    }

                    section("Engine") {
                        row("Status") {
                            Text(engineStatus)
                                .font(Theme.text(12.5))
                                .foregroundStyle(app.store.connection.isReady ? Theme.green : Color.secondary)
                        }
                        ForEach(app.store.providers) { provider in
                            row(provider.name) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(provider.isReady ? Theme.green : Theme.neutral.opacity(0.6))
                                        .frame(width: 7, height: 7)
                                    Text(provider.isReady ? "Ready · \(provider.models.count) models" : (provider.statusMessage ?? "Not available"))
                                        .font(Theme.text(12))
                                        .foregroundStyle(provider.isReady ? .primary : .secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 600)
        .frame(maxHeight: 680)
        .glassPanel(cornerRadius: 28, frost: max(0.6, app.settings.data.panelFrost))
        .padding(40)
    }

    private static let swatches = ["#F5F4EF", "#EEF1F4", "#F3EEF5", "#E9EFE8", "#1C1D21", "#101418"]

    private var engineStatus: String {
        switch app.store.connection {
        case .ready: Runtime.options.demo ? "Demo engine (simulated agents)" : "Connected"
        case .idle, .starting: "Starting"
        case let .preparing(message, _): message
        case .connecting: "Connecting"
        case let .reconnecting(attempt): "Reconnecting (attempt \(attempt))"
        case let .failed(message): message
        }
    }

    private var canvasColor: Binding<Color> {
        Binding(
            get: { app.settings.data.canvasColor.flatMap(Color.init(hex:)) ?? Theme.canvasBase(scheme) },
            set: { app.settings.data.canvasColor = $0.hexString }
        )
    }

    private func swatch(_ hex: String) -> some View {
        Button {
            app.settings.data.canvasColor = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .clear)
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) }
                .overlay {
                    if app.settings.data.canvasColor == hex {
                        Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3)
                    }
                }
        }
        .buttonStyle(.pressable)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a background image for the canvas."
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.data.backgroundImagePath = url.path
            app.settings.data.canvasStyle = .image
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    private func row<Content: View>(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Theme.ui(12.5, .medium))
                if let note {
                    Text(note)
                        .font(Theme.text(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 170, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
