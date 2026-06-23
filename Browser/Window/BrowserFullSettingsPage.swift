import AppKit
import SwiftUI

struct BrowserFullSettingsPage: View {
    @ObservedObject var browser: BrowserState
    let onClose: () -> Void

    @State private var isAddingProfile = false
    @State private var editingProfileID: BrowserProfile.ID?
    @State private var isAddingUserScript = false
    @State private var editingUserScriptID: BrowserUserScript.ID?
    @State private var userScriptDraft = FullSettingsUserScriptDraft()

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

                        FullSettingsSection(title: "User Scripts", systemName: "curlybraces") {
                            VStack(alignment: .leading, spacing: 8) {
                                if browser.userScripts.isEmpty && !isAddingUserScript {
                                    Text("No scripts")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(browser.userScripts) { script in
                                    FullSettingsUserScriptRow(
                                        script: script,
                                        isEditing: editingUserScriptID == script.id,
                                        onEnabledChange: { isEnabled in
                                            browser.setUserScriptEnabled(id: script.id, isEnabled: isEnabled)
                                        },
                                        onEdit: {
                                            startEditingUserScript(script)
                                        },
                                        onDelete: {
                                            deleteUserScript(script)
                                        }
                                    )
                                }
                            }

                            if isAddingUserScript || editingUserScript != nil {
                                FullSettingsUserScriptEditor(
                                    title: isAddingUserScript ? "New Script" : "Edit Script",
                                    draft: $userScriptDraft,
                                    onSave: saveUserScriptDraft,
                                    onCancel: cancelUserScriptEditor
                                )
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            HStack {
                                FullSettingsActionButton(
                                    title: isAddingUserScript ? "Cancel" : "Add Script",
                                    systemName: isAddingUserScript ? "xmark" : "plus"
                                ) {
                                    if isAddingUserScript {
                                        cancelUserScriptEditor()
                                    } else {
                                        startAddingUserScript()
                                    }
                                }

                                Spacer()
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

    private var editingUserScript: BrowserUserScript? {
        guard let editingUserScriptID else {
            return nil
        }

        return browser.userScripts.first { $0.id == editingUserScriptID }
    }

    private func startAddingUserScript() {
        withAnimation(.easeInOut(duration: 0.14)) {
            editingUserScriptID = nil
            isAddingUserScript = true
            userScriptDraft = FullSettingsUserScriptDraft()
        }
    }

    private func startEditingUserScript(_ script: BrowserUserScript) {
        withAnimation(.easeInOut(duration: 0.14)) {
            isAddingUserScript = false
            editingUserScriptID = script.id
            userScriptDraft = FullSettingsUserScriptDraft(script: script)
        }
    }

    private func cancelUserScriptEditor() {
        withAnimation(.easeInOut(duration: 0.14)) {
            isAddingUserScript = false
            editingUserScriptID = nil
            userScriptDraft = FullSettingsUserScriptDraft()
        }
    }

    private func saveUserScriptDraft() {
        guard userScriptDraft.canSave else {
            return
        }

        if isAddingUserScript {
            browser.createUserScript(
                name: userScriptDraft.name,
                matchPatterns: userScriptDraft.matchPatterns,
                source: userScriptDraft.source,
                isEnabled: userScriptDraft.isEnabled,
                injectionTime: userScriptDraft.injectionTime,
                forMainFrameOnly: userScriptDraft.forMainFrameOnly
            )
        } else if let editingUserScriptID {
            browser.updateUserScript(
                id: editingUserScriptID,
                name: userScriptDraft.name,
                matchPatterns: userScriptDraft.matchPatterns,
                source: userScriptDraft.source,
                isEnabled: userScriptDraft.isEnabled,
                injectionTime: userScriptDraft.injectionTime,
                forMainFrameOnly: userScriptDraft.forMainFrameOnly
            )
        }

        cancelUserScriptEditor()
    }

    private func deleteUserScript(_ script: BrowserUserScript) {
        withAnimation(.easeInOut(duration: 0.14)) {
            if editingUserScriptID == script.id {
                editingUserScriptID = nil
                userScriptDraft = FullSettingsUserScriptDraft()
            }
            isAddingUserScript = false
            browser.deleteUserScript(id: script.id)
        }
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
        .contentShape(Rectangle())
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

private struct FullSettingsUserScriptDraft: Equatable {
    var name = "New Script"
    var matchPatterns = BrowserUserScript.defaultMatchPatterns
    var source = BrowserUserScript.defaultSource
    var isEnabled = true
    var injectionTime: BrowserUserScriptInjectionTime = .documentEnd
    var forMainFrameOnly = true

    init() {}

    init(script: BrowserUserScript) {
        name = script.name
        matchPatterns = script.matchPatterns
        source = script.source
        isEnabled = script.isEnabled
        injectionTime = script.injectionTime
        forMainFrameOnly = script.forMainFrameOnly
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !matchPatterns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct FullSettingsUserScriptRow: View {
    let script: BrowserUserScript
    let isEditing: Bool
    let onEnabledChange: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FullSettingsSwitch(isOn: script.isEnabled) {
                onEnabledChange(!script.isEnabled)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(script.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(script.injectionTime.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(script.displayName)")
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(script.displayName)")
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isEditing ? Color.primary.opacity(0.1) : Color.primary.opacity(0.04))
        }
    }

    private var detailText: String {
        let patterns = script.normalizedMatchPatternLines.joined(separator: ", ")
        let frameScope = script.forMainFrameOnly ? "main frame" : "all frames"
        return "\(patterns) - \(frameScope)"
    }
}

private struct FullSettingsSwitch: View {
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? Color.accentColor.opacity(isHovered ? 0.95 : 0.82) : Color.primary.opacity(isHovered ? 0.18 : 0.12))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                        .padding(2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .accessibilityLabel(isOn ? "Disable Script" : "Enable Script")
        .help(isOn ? "Disable" : "Enable")
    }
}

private struct FullSettingsUserScriptEditor: View {
    let title: String
    @Binding var draft: FullSettingsUserScriptDraft
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Toggle("Enabled", isOn: $draft.isEnabled)
                    .font(.system(size: 12, weight: .medium))
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 6) {
                FullSettingsLabel("Name")
                FullSettingsTextField(text: $draft.name)
            }

            VStack(alignment: .leading, spacing: 6) {
                FullSettingsLabel("Match Patterns")
                FullSettingsTextEditor(text: $draft.matchPatterns, minHeight: 58, isMonospaced: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                FullSettingsLabel("Run At")
                FullSettingsSegmentedControl {
                    ForEach(BrowserUserScriptInjectionTime.allCases, id: \.rawValue) { injectionTime in
                        FullSettingsSegmentButton(
                            title: injectionTime.label,
                            isSelected: draft.injectionTime == injectionTime
                        ) {
                            draft.injectionTime = injectionTime
                        }
                    }
                }
            }

            Toggle("Main Frame Only", isOn: $draft.forMainFrameOnly)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                FullSettingsLabel("Source")
                FullSettingsTextEditor(text: $draft.source, minHeight: 220, isMonospaced: true)
            }

            HStack(spacing: 8) {
                FullSettingsActionButton(title: "Save", systemName: "checkmark") {
                    onSave()
                }
                .disabled(!draft.canSave)

                FullSettingsActionButton(title: "Cancel", systemName: "xmark") {
                    onCancel()
                }

                Spacer()
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct FullSettingsTextField: View {
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct FullSettingsTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    let isMonospaced: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(isMonospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
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
