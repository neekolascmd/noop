import SwiftUI
import StrandDesign

/// Support, attribution, and contact.
struct SupportView: View {
    @State private var showDiagnostics = false

    var body: some View {
        ScreenScaffold(title: "Support",
                       subtitle: "Help, diagnostics, project information, and contact details.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Help & Contact", overline: "Get in touch")
                    contactCard
                    builtOnCard
                }
                .staggeredAppear(index: 0)
                disclaimerCard
                    .staggeredAppear(index: 1)
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                TestCentreView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDiagnostics = false }
                        }
                    }
            }
        }
    }

    /// One hairline-divided row inside a grouped frosted card: a tinted leading glyph, a title +
    /// detail stack, and a trailing accent chevron when the row taps through to an action.
    @ViewBuilder
    private func groupedRow(icon: String, tint: Color, title: LocalizedStringKey,
                            detail: String, showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
            }
        }
    }

    private var contactCard: some View {
        NoopCard {
            VStack(spacing: 12) {
                Button {
                    showDiagnostics = true
                } label: {
                    groupedRow(icon: "stethoscope", tint: StrandPalette.accent,
                               title: "Diagnostics & Support",
                               detail: String(localized: "Create a redacted report and capture extra detail for the connected device."),
                               showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Diagnostics and Support")

                Divider().overlay(StrandPalette.hairline)

                Button {
                    if let url = URL(string: "mailto:\(ProjectInfo.contactEmail)") { PlatformOpen.url(url) }
                } label: {
                    groupedRow(icon: "envelope.fill", tint: StrandPalette.accent,
                               title: "Get in touch",
                               detail: String(localized: "Questions, feedback, bugs: \(ProjectInfo.contactEmail)"),
                               showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Email \(ProjectInfo.contactEmail)")
                .help("Email \(ProjectInfo.contactEmail)")
            }
        }
    }

    private var builtOnCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "hands.clap.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 28, height: 28)
                        .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Built on").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("This stands on community reverse-engineering. Huge thanks:")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                ForEach(Array(ProjectInfo.attributions.enumerated()), id: \.element.repo) { index, a in
                    if index > 0 { Divider().overlay(StrandPalette.hairline) }
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text(a.repo).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
                        Text("· \(a.note)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var disclaimerCard: some View {
        NoopCard(padding: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                    .font(.system(size: 13)).accessibilityHidden(true)
                Text("Not affiliated with, endorsed by, or connected to WHOOP. Interoperability software for hardware you own and your own data. Use it only with a device you own, and not in breach of any agreement that applies to you. Not a medical device.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hosts ``SupportView`` as a centred panel over a dimmed backdrop. Clicking anywhere
/// outside the panel — or pressing Esc, or the ✕ — closes it. Taps on the panel itself
/// are absorbed (the panel is opaque) so its controls keep working.
struct SupportModalOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            SupportView()
                .frame(width: 560, height: 680)
                .background(StrandPalette.surfaceBase,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close Support")
                }
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 14)
        }
        #if os(macOS)
        .onExitCommand { isPresented = false }   // Esc-to-close is a macOS-only command
        #endif
        .transition(.opacity)
    }
}
