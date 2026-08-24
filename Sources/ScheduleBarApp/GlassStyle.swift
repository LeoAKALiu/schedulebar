import SwiftUI

// MARK: - Liquid Glass backgrounds
//
// Liquid Glass (`glassEffect`) requires macOS 26. The deployment target is
// macOS 14, so every helper falls back to the pre-glass styling, matching the
// previous appearance exactly on older systems.

extension View {
    /// Capsule background for status/priority/date/tag pills.
    /// macOS 26+: tinted Liquid Glass. Earlier: flat tint fill (or control
    /// background with a stroke when `tint` is nil, matching `TagPillView`).
    @ViewBuilder
    func glassPill(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: Capsule())
        } else if let tint {
            self
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
    }

    /// Rounded card background for the Quick Add / Candidate Edit form cards.
    /// macOS 26+: clear Liquid Glass. Earlier: control background with stroke.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }

    /// Background for inline error banners (Quick Add / Candidate Edit).
    /// macOS 26+: red-tinted Liquid Glass. Earlier: flat red fill.
    @ViewBuilder
    func glassErrorBanner(cornerRadius: CGFloat = 6) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(.red),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Background for the floating console error banner.
    /// macOS 26+: red-tinted Liquid Glass. Earlier: regular material with stroke.
    @ViewBuilder
    func glassFloatingBanner(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(.red),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

/// Wraps adjacent glass elements so they merge into one unified effect on
/// macOS 26+. On earlier systems this is just the content itself.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
