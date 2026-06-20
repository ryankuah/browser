import SwiftUI

struct BrowserControls: View {
    @ObservedObject var browser: BrowserState
    var tab: BrowserTab?
    let onOpenAddressPrompt: () -> Void

    @ViewBuilder
    var body: some View {
        if let tab {
            BrowserAddressField(
                tab: tab,
                onOpenAddressPrompt: onOpenAddressPrompt
            )
            .padding(.horizontal, 10)
        } else {
            EmptyBrowserAddressField(onOpenAddressPrompt: onOpenAddressPrompt)
                .padding(.horizontal, 10)
        }
    }
}

private struct BrowserAddressField: View {
    @ObservedObject var tab: BrowserTab

    let onOpenAddressPrompt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if shouldShowOriginIndicator {
                Image(systemName: originSecurityState.iconSystemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(originIndicatorColor)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(originSecurityState.accessibilityLabel)
                    .help(originSecurityState.accessibilityLabel)
            }

            Text(displayText)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .cursor(.iBeam)
        .onTapGesture(perform: onOpenAddressPrompt)
        .accessibilityLabel("Address")
        .accessibilityValue(tab.addressText)
    }

    private var displayText: String {
        isPlaceholder ? "Search or enter website" : tab.displayAddressText
    }

    private var isPlaceholder: Bool {
        tab.displayAddressText.isEmpty
    }

    private var originSecurityState: OriginSecurityState {
        tab.originSecurityState
    }

    private var shouldShowOriginIndicator: Bool {
        switch originSecurityState {
        case .insecure, .certificateError:
            return true
        case .noPage, .secure, .local:
            return false
        }
    }

    private var originIndicatorColor: Color {
        switch originSecurityState {
        case .noPage:
            return .secondary
        case .secure:
            return .green
        case .local:
            return .blue
        case .insecure, .certificateError:
            return .orange
        }
    }
}

private struct EmptyBrowserAddressField: View {
    let onOpenAddressPrompt: () -> Void

    var body: some View {
        HStack {
            Text("Search or enter website")
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .cursor(.iBeam)
        .onTapGesture(perform: onOpenAddressPrompt)
        .accessibilityLabel("Address")
    }
}
