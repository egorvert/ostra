import SwiftUI

/// A Liquid Glass surface with adjustable frost.
///
/// `frost` runs from 0 to 1:
/// - 0 is pure glass. It refracts the canvas and suits any background.
/// - Around 0.5 a translucent fill sits on the glass, so text keeps its
///   contrast over busy backgrounds.
/// - 1 is opaque.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var frost: Double
    var interactive: Bool
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    private var fillOpacity: Double {
        // Ease in, so the first half of the slider stays clearly glassy.
        let clamped = min(max(frost, 0), 1)
        return clamped * clamped * (3 - 2 * clamped) * 0.98 + (clamped >= 0.999 ? 0.02 : 0)
    }

    private var glass: Glass {
        var glass: Glass = frost < 0.06 ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }

    func body(content: Content) -> some View {
        content
            .background {
                if fillOpacity > 0.001 {
                    shape.fill(Theme.frostFill(scheme).opacity(fillOpacity))
                }
            }
            .glassEffect(glass, in: shape)
    }
}

extension View {
    /// Puts the view on a Liquid Glass panel with rounded corners.
    func glassPanel(
        cornerRadius: CGFloat = Theme.panelRadius,
        frost: Double = 0,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(GlassSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            frost: frost,
            interactive: interactive,
            tint: tint
        ))
    }

    /// Puts the view on a Liquid Glass capsule.
    func glassCapsule(frost: Double = 0, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: Capsule(style: .continuous), frost: frost, interactive: interactive, tint: tint))
    }

    /// Puts the view on a Liquid Glass circle.
    func glassCircle(interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: Circle(), frost: 0, interactive: interactive, tint: tint))
    }
}

/// A key label. Quiet by design: it informs without asking for attention.
struct Keycap: View {
    var label: String
    var size: CGFloat = 20
    var prominent = false
    @Environment(\.colorScheme) private var scheme

    init(_ label: String, size: CGFloat = 20, prominent: Bool = false) {
        self.label = label
        self.size = size
        self.prominent = prominent
    }

    var body: some View {
        Text(label)
            .font(Theme.mono(size * 0.54, .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, label.count > 1 ? size * 0.28 : 0)
            .frame(minWidth: size, minHeight: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.primary.opacity(prominent ? 0.12 : (scheme == .dark ? 0.10 : 0.055)))
            }
            .fixedSize()
    }
}

/// A row of tabs. A soft pill sits behind the chosen one and slides to the
/// next when the choice changes.
///
/// Every label keeps one weight, so nothing shifts sideways as the pill moves.
struct TextTabs<Item: Hashable>: View {
    var items: [Item]
    var selection: Item
    var label: (Item) -> String
    /// The key that selects an item, shown before its label.
    var hint: (Item) -> String? = { _ in nil }
    var onSelect: (Item) -> Void

    @Namespace private var namespace
    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    Motion.perform(Motion.tabContent) { onSelect(item) }
                } label: {
                    HStack(spacing: 5) {
                        if let key = hint(item) {
                            Text(key)
                                .font(Theme.mono(10, .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Text(label(item))
                            .font(Theme.ui(12, .medium))
                            .foregroundStyle(
                                isSelected || hovered == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                            )
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
            }
        }
        .animation(Motion.tab, value: selection)
        .animation(Motion.hover, value: hovered)
    }
}

/// A small icon button for panel headers.
struct QuietIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A thin separator that reads on glass in both color schemes.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: vertical ? 0.75 : nil, height: vertical ? nil : 0.75)
    }
}
