import AppKit
import SwiftUI

/// Custom About window styled after Ghostty's (icon tile, name, tagline, Version/Commit rows, link
/// buttons) rather than the plain AppKit "About Tokenomics" panel — reported directly as looking nicer.
/// Opened via `openWindow(id: "about")` from FooterView, same pattern as Settings/Token-tips windows.
struct AboutView: View {
    private let repoURL = URL(string: "https://github.com/froesef/tokenomics")!

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tokenomics"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The short git commit hash, stamped into `CFBundleVersion` at build time by
    /// `Scripts/build_app.sh` — "dev" for a bare `swift run` with no bundling step.
    private var commit: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    private var commitURL: URL? {
        guard commit != "dev", commit != "unknown" else { return nil }
        return repoURL.appendingPathComponent("commit").appendingPathComponent(commit)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

            VStack(spacing: 6) {
                Text(appName)
                    .font(.system(size: 26, weight: .bold))
                Text("Menu bar cost and cache-cooldown tracker for Claude Code and Codex sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Version")
                        .foregroundStyle(.secondary)
                    Text(version)
                        .gridColumnAlignment(.leading)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Commit")
                        .foregroundStyle(.secondary)
                    if let commitURL {
                        Link(commit, destination: commitURL)
                            .gridColumnAlignment(.leading)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text(commit)
                            .gridColumnAlignment(.leading)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .font(.system(size: 13))

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(repoURL.appendingPathComponent("blob/main/README.md"))
                } label: {
                    Text("README").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(repoURL)
                } label: {
                    Text("GitHub").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(32)
        .frame(width: 360)
    }
}
