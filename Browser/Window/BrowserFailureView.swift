import AppKit
import SwiftUI

struct BrowserFailureView: View {
    let failure: BrowserPageFailure
    let bezelStyle: BrowserBezelStyle
    let profileColor: NSColor
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.white

            VStack(spacing: 14) {
                Image(systemName: failure.isCertificateError ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(failure.isCertificateError ? .orange : .secondary)

                VStack(spacing: 6) {
                    Text(failure.title)
                        .font(.system(size: 22, weight: .semibold))

                    Text(failure.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let url = failure.url {
                        Text(url.absoluteString)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 460)
                    }

                    Text(failure.detail)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Button(action: onRetry) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .padding(24)
            .frame(maxWidth: 540)
        }
    }
}
