import SwiftUI

/// The label styling shared by every plain menu-style row in the dropdown, footer, and detail panel: a
/// full-width left-aligned row that turns the system accent color with white text on hover, matching how
/// native macOS menus (and Docker Desktop's, which the dropdown is modeled on) highlight the hovered item.
/// Just the label — callers wrap it in whatever triggers the action (`Button`, `SettingsLink`) and drive
/// `isHovering` from their own `.onHover`, since SwiftUI has no shared hover state across view types.
struct MenuRowLabel: View {
    let title: String
    let isHovering: Bool
    var isEnabled: Bool = true

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(!isEnabled ? Color.secondary : (isHovering ? Color.white : Color.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovering && isEnabled ? Color.accentColor : Color.clear)
    }
}
