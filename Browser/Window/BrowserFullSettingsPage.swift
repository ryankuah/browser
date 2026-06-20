import AppKit
import SwiftUI

struct BrowserFullSettingsPage: View {
    @ObservedObject var browser: BrowserState
    let onClose: () -> Void

    @State private var isAddingProfile = false
    @State private var editingProfileID: BrowserProfile.ID?

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.16)
                ),
                profileColor: browser.profileNSColor,
                simpleFillOpacity: 0.72
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        FullSettingsSection(title: "General", systemName: "magnifyingglass") {
                            VStack(alignment: .leading, spacing: 10) {
                                FullSettingsLabel("Search Engine")

                                FullSettingsSegmentedControl {
                                    ForEach(BrowserSearchEngine.allCases, id: \.rawValue) { engine in
                                        FullSettingsSegmentButton(
                                            title: engine.label,
                                            isSelected: browser.searchEngine == engine
                                        ) {
                                            browser.setSearchEngine(engine)
                                        }
                                    }
                                }
                            }

                            FullSettingsDivider()

                            FullSettingsValueRow(
                                title: "Downloads",
                                value: browser.downloadsDirectoryDisplayPath,
                                systemName: "folder"
                            )

                            HStack(spacing: 8) {
                                FullSettingsActionButton(title: "Open Folder", systemName: "arrow.up.forward.app") {
                                    browser.openDownloadsFolder()
                                }

                                FullSettingsActionButton(title: "Copy Path", systemName: "doc.on.doc") {
                                    browser.copyDownloadsDirectoryPath()
                                }

                                Spacer()
                            }
                        }

                        FullSettingsSection(title: "Appearance", systemName: "paintpalette") {
                            FullSettingsLabel("Bezel Style")

                            FullSettingsSegmentedControl {
                                ForEach(BrowserBezelStyle.allCases, id: \.rawValue) { style in
                                    FullSettingsSegmentButton(
                                        title: style.label,
                                        isSelected: browser.bezelStyle == style
                                    ) {
                                        browser.setBezelStyle(style)
                                    }
                                }
                            }
                        }

                        FullSettingsSection(title: "Profiles", systemName: "person.crop.circle") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(browser.profiles) { profile in
                                    FullSettingsProfileRow(
                                        profile: profile,
                                        isSelected: browser.selectedProfileID == profile.id,
                                        canDelete: browser.profiles.count > 1,
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

                            if isAddingProfile {
                                ProfileCreationPanel(
                                    title: "New Profile",
                                    defaultName: "",
                                    defaultColor: NSColor(hexString: BrowserProfile.defaultColorHex) ?? .systemBlue,
                                    profileColor: browser.profileNSColor
                                ) { name, colorHex in
                                    browser.createProfile(name: name, colorHex: colorHex)
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        isAddingProfile = false
                                    }
                                }
                            }

                            if let editingProfile {
                                ProfileCreationPanel(
                                    title: "Edit Profile",
                                    defaultName: editingProfile.displayName,
                                    defaultColor: NSColor(hexString: editingProfile.colorHex) ?? .systemBlue,
                                    submitTitle: "Save",
                                    profileColor: browser.profileNSColor
                                ) { name, colorHex in
                                    browser.updateProfile(id: editingProfile.id, name: name, colorHex: colorHex)
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        editingProfileID = nil
                                    }
                                }
                            }

                            HStack {
                                FullSettingsActionButton(
                                    title: isAddingProfile ? "Cancel" : "Add Profile",
                                    systemName: isAddingProfile ? "xmark" : "plus"
                                ) {
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        editingProfileID = nil
                                        isAddingProfile.toggle()
                                    }
                                }

                                Spacer()
                            }
                        }

                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.visible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))

            Text("Settings")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .accessibilityLabel("Close Settings")
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var editingProfile: BrowserProfile? {
        guard let editingProfileID else {
            return nil
        }

        return browser.profiles.first { $0.id == editingProfileID }
    }
}

private struct FullSettingsSection<Content: View>: View {
    let title: String
    let systemName: String
    let content: Content

    init(title: String, systemName: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemName = systemName
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FullSettingsLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct FullSettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.38)
    }
}

private struct FullSettingsValueRow: View {
    let title: String
    let value: String
    let systemName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct FullSettingsSegmentedControl<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            content
        }
    }
}

private struct FullSettingsSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.13) : isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct FullSettingsActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.13) : Color.primary.opacity(0.09))
        }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct FullSettingsProfileRow: View {
    let profile: BrowserProfile
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemBlue))
                        .frame(width: 16, height: 16)

                    Text(profile.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(profile.displayName)")
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .accessibilityLabel("Delete \(profile.displayName)")
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        }
    }
}
