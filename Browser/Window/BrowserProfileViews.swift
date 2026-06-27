import AppKit
import SwiftUI

struct ProfileBezelSwitcher: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(browser.profiles) { profile in
                    let isSelected = browser.selectedProfileID == profile.id

                    Button {
                        browser.switchProfile(id: profile.id)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemBlue))
                                .frame(width: 14, height: 14)
                                .overlay {
                                    Circle()
                                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                                }

                            Text(profile.displayName)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isSelected ? Color.primary : Color.clear)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .cursor(.pointingHand)
                    .accessibilityLabel(profile.displayName)
                    .help(profile.displayName)
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .background {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 10,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.08)
                ),
                profileColor: browser.profileNSColor
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
    }
}

struct ProfileOnboardingOverlay: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.black.withAlphaComponent(0.2)
                ),
                profileColor: browser.profileNSColor
            )
            .opacity(0.96)
            .ignoresSafeArea()

            ProfileCreationPanel(
                title: "Create Profile",
                defaultName: "Personal",
                defaultColor: NSColor(hexString: BrowserProfile.defaultColorHex) ?? .systemBlue,
                profileColor: browser.profileNSColor
            ) { name, colorHex in
                browser.createProfile(name: name, colorHex: colorHex)
            }
            .frame(width: 320)
            .padding(20)
        }
    }
}

struct ProfileCreationPanel: View {
    let title: String
    let defaultName: String
    let defaultColor: NSColor
    var submitTitle = "Create"
    var profileColor: NSColor?
    let onCreate: (String, String) -> Void

    @State private var name: String
    @State private var selectedColorHex: String

    init(
        title: String,
        defaultName: String,
        defaultColor: NSColor,
        submitTitle: String = "Create",
        profileColor: NSColor? = nil,
        onCreate: @escaping (String, String) -> Void
    ) {
        self.title = title
        self.defaultName = defaultName
        self.defaultColor = defaultColor
        self.submitTitle = submitTitle
        self.profileColor = profileColor
        self.onCreate = onCreate
        _name = State(initialValue: defaultName)
        _selectedColorHex = State(initialValue: defaultColor.hexString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ProfilePresetColorRow(
                    title: "Light",
                    colorHexes: BrowserProfile.lightPresetColorHexes,
                    selectedColorHex: $selectedColorHex
                )

                ProfilePresetColorRow(
                    title: "Dark",
                    colorHexes: BrowserProfile.darkPresetColorHexes,
                    selectedColorHex: $selectedColorHex
                )
            }

            Button {
                onCreate(name, selectedColorHex)
            } label: {
                Text(submitTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
            }
            .contentShape(Rectangle())
            .cursor(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .arrow : .pointingHand)
        }
        .padding(12)
        .background {
            BrowserChromeBackground(
                bezelStyle: .liquidGlass,
                cornerRadius: 10,
                effect: .liquidGlass(
                    style: .regular,
                    tintColor: NSColor.white.withAlphaComponent(0.1)
                ),
                profileColor: profileColor
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
            .shadow(color: Color.black.opacity(0.22), radius: 24, y: 12)
    }
}

private struct ProfilePresetColorRow: View {
    let title: String
    let colorHexes: [String]
    @Binding var selectedColorHex: String

    private let columns = [
        GridItem(.adaptive(minimum: 22, maximum: 22), spacing: 7)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(colorHexes, id: \.self) { colorHex in
                    Button {
                        selectedColorHex = colorHex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hexString: colorHex) ?? .systemBlue))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(isSelected(colorHex) ? 0.82 : 0.18), lineWidth: isSelected(colorHex) ? 2 : 1)
                            }
                            .overlay {
                                if isSelected(colorHex) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle((NSColor(hexString: colorHex) ?? .systemBlue).prefersDarkForeground ? .black : .white)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colorHex)
                    .help(colorHex)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isSelected(_ colorHex: String) -> Bool {
        selectedColorHex.caseInsensitiveCompare(colorHex) == .orderedSame
    }
}
