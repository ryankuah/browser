import AppKit
import SwiftUI

struct BrowserToastStack: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(browser.toasts.prefix(4)) { toast in
                BrowserToastView(
                    toast: toast,
                    bezelStyle: browser.bezelStyle,
                    profileColor: browser.profileNSColor,
                    onAllow: {
                        browser.allowMediaPermissionToast(id: toast.id)
                    },
                    onDeny: {
                        browser.denyMediaPermissionToast(id: toast.id)
                    },
                    onOpenDownload: {
                        guard let downloadID = toast.downloadID else {
                            return
                        }

                        browser.openDownloadedFile(id: downloadID)
                    },
                    onDismiss: {
                        browser.dismissToast(id: toast.id)
                    }
                )
                .webViewOcclusionRegion()
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!browser.toasts.isEmpty)
    }
}

struct BrowserZoomHUDView: View {
    let hud: BrowserZoomHUD
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor

    private let cornerRadius: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(hud.percentText)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)

                BrowserChromeBackground(
                    bezelStyle: bezelStyle,
                    cornerRadius: cornerRadius,
                    effect: .liquidGlass(
                        style: .clear,
                        tintColor: NSColor.black.withAlphaComponent(0.18)
                    ),
                    profileColor: profileColor,
                    profileTintAlpha: 0.2
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 22, y: 12)
        .id(hud.id)
    }
}

private struct BrowserToastView: View {
    let toast: BrowserToast
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onOpenDownload: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHovered = false

    private let notificationCornerRadius: CGFloat = 24

    private var iconColor: Color {
        switch toast.status {
        case .pending:
            return .accentColor
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toast.iconSystemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if toast.kind != .mediaPermission {
                        Text(toast.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let progressFraction = toast.progressFraction, toast.status == .pending {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if toast.kind == .download && toast.status == .pending {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            toastActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)

                BrowserChromeBackground(
                    bezelStyle: bezelStyle,
                    cornerRadius: notificationCornerRadius,
                    effect: .liquidGlass(
                        style: .clear,
                        tintColor: NSColor.black.withAlphaComponent(0.18)
                    ),
                    profileColor: profileColor,
                    profileTintAlpha: 0.24
                )
            }
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 18, height: 18)
                    .background {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)

                            Circle()
                                .fill(Color.black.opacity(0.28))
                        }
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.86)
            .offset(x: -2, y: -2)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 28, y: 14)
        .offset(x: dragOffset)
        .opacity(max(0.35, 1 - Double(abs(dragOffset) / 180)))
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 96 || abs(value.predictedEndTranslation.width) > 150 {
                        withAnimation(.easeOut(duration: 0.14)) {
                            dragOffset = value.translation.width < 0 ? -420 : 420
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onDismiss()
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var toastActions: some View {
        switch toast.kind {
        case .mediaPermission:
            HStack(spacing: 8) {
                Button("Deny", action: onDeny)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }

                Button("Allow", action: onAllow)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }

                Spacer()
            }
            .padding(.leading, 30)
        case .download:
            if toast.status == .success {
                HStack {
                    Button("Open", action: onOpenDownload)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        }

                    Spacer()
                }
                .padding(.leading, 30)
            }
        }
    }
}

struct LoadingBezelPill: View {
    @State private var isPulsing = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(isPulsing ? 0.86 : 0.34))
            .frame(width: isPulsing ? 46 : 34, height: 3)
            .shadow(color: Color.white.opacity(isPulsing ? 0.32 : 0.12), radius: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}
