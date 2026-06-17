import SwiftUI

struct BrowserSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrafficLightControls()
                .padding(.horizontal, 16)
                .padding(.top, 16)

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.secondary.opacity(0.28))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text("R")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                Text("ryankuah.com")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.regularMaterial)

            MouseEventBlocker()
        }
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator.opacity(0.35))
                .frame(width: 1)
        }
    }
}
