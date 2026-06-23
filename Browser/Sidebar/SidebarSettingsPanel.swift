import AppKit
import SwiftUI

struct BrowserSettingsPanel: View {
    @ObservedObject var browser: BrowserState
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onOpenFullSettings: () -> Void

    @State private var isAddingProfile = false
    @State private var editingProfileID: BrowserProfile.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Profiles")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    isAddingProfile.toggle()
                                }
                            } label: {
                                Image(systemName: isAddingProfile ? "minus" : "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 24, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isAddingProfile ? "Cancel Profile" : "Add Profile")
                            .help(isAddingProfile ? "Cancel" : "Add Profile")
                        }

                        if isAddingProfile {
                            ProfileCreationPanel(
                                title: "New Profile",
                                defaultName: "",
                                defaultColor: NSColor(hexString: BrowserProfile.defaultColorHex) ?? .systemBlue,
                                profileColor: profileColor
                            ) { name, colorHex in
                                browser.createProfile(name: name, colorHex: colorHex)
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    isAddingProfile = false
                                }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let editingProfile = editingProfile {
                            ProfileCreationPanel(
                                title: "Edit Profile",
                                defaultName: editingProfile.displayName,
                                defaultColor: NSColor(hexString: editingProfile.colorHex) ?? .systemBlue,
                                submitTitle: "Save",
                                profileColor: profileColor
                            ) { name, colorHex in
                                browser.updateProfile(id: editingProfile.id, name: name, colorHex: colorHex)
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    editingProfileID = nil
                                }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        HStack(spacing: 6) {
                            ForEach(browser.profiles) { profile in
                                ProfileDotButton(
                                    profile: profile,
                                    isSelected: browser.selectedProfileID == profile.id,
                                    onSelect: {
                                        browser.switchProfile(id: profile.id)
                                    },
                                    onEdit: {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            isAddingProfile = false
                                            editingProfileID = profile.id
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            if editingProfileID == profile.id {
                                                editingProfileID = nil
                                            }
                                            browser.deleteProfile(id: profile.id)
                                        }
                                    }
                                )
                            }
                        }
                    }

                    Divider()
                        .opacity(0.38)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Bezel Style")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(BrowserBezelStyle.allCases, id: \.rawValue) { style in
                                SettingsSegmentButton(
                                    title: style.label,
                                    isSelected: browser.bezelStyle == style
                                ) {
                                    browser.setBezelStyle(style)
                                }
                            }
                        }
                    }

                    Divider()
                        .opacity(0.38)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Page Zoom")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        SettingsZoomControls(browser: browser)
                    }

                    Divider()
                        .opacity(0.38)

                    HStack(spacing: 8) {
                        ForEach(BrowserMediaDeviceKind.allCases, id: \.rawValue) { kind in
                            MediaPermissionButton(
                                kind: kind,
                                isAllowed: browser.activeMediaPermissionSnapshot.isAllowed(kind),
                                isEnabled: browser.activeMediaPermissionSnapshot.hasActivePage
                            ) {
                                browser.toggleActivePageMediaPermission(kind)
                            }
                        }

                        Spacer()

                        Button(action: onOpenFullSettings) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 30, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                        .accessibilityLabel("Open Full Settings")
                        .help("Full Settings")
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 420)
            .scrollIndicators(.visible)
        }
        .background {
            BrowserChromeBackground(
                bezelStyle: bezelStyle,
                cornerRadius: 8,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.12)
                ),
                profileColor: profileColor
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var editingProfile: BrowserProfile? {
        guard let editingProfileID else {
            return nil
        }

        return browser.profiles.first { $0.id == editingProfileID }
    }
}

private struct SettingsZoomControls: View {
    @ObservedObject var browser: BrowserState

    private var activeTab: BrowserTab? {
        browser.activeTab
    }

    var body: some View {
        HStack(spacing: 6) {
            SettingsZoomButton(systemName: "minus", label: "Zoom Out") {
                browser.zoomOutActiveTab()
            }
            .disabled(activeTab == nil)

            Text(activeTab?.pageZoomPercentText ?? "100%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }

            SettingsZoomButton(systemName: "plus", label: "Zoom In") {
                browser.zoomInActiveTab()
            }
            .disabled(activeTab == nil)

            SettingsZoomButton(systemName: "arrow.counterclockwise", label: "Reset Zoom") {
                browser.resetActiveTabZoom()
            }
            .disabled(activeTab == nil)
        }
    }
}

private struct SettingsZoomButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct ProfileDotButton: View {
    let profile: BrowserProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemBlue))
                .frame(width: 18, height: 18)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(Color.primary.opacity(0.7), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button(role: .destructive, action: onDelete) {
                Text("Delete")
            }
        }
        .accessibilityLabel(profile.displayName)
        .help(profile.displayName)
    }
}

private struct SettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct MediaPermissionButton: View {
    let kind: BrowserMediaDeviceKind
    let isAllowed: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconSystemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isAllowed ? Color.green : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isAllowed ? Color.green.opacity(0.34) : Color.primary.opacity(0.1), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .cursor(isEnabled ? .pointingHand : .arrow)
        .accessibilityLabel(kind.accessibilityLabel)
        .help("\(kind.accessibilityLabel): \(isAllowed ? "Allowed" : "Blocked")")
    }

    private var iconSystemName: String {
        if isAllowed {
            return kind.iconSystemName
        }

        switch kind {
        case .camera:
            return "video.slash.fill"
        case .microphone:
            return "mic.slash.fill"
        }
    }

    private var backgroundColor: Color {
        if isAllowed {
            return Color.green.opacity(0.14)
        }

        return isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04)
    }
}
