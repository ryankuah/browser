import AppKit
import SwiftUI

struct TrafficLightControls: View {
    let window: NSWindow?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            TrafficLightButton(
                color: Color(red: 1.0, green: 0.37, blue: 0.34),
                icon: "xmark",
                label: "Close",
                showsIcon: isHovered
            ) {
                window?.performClose(nil)
            }

            TrafficLightButton(
                color: Color(red: 1.0, green: 0.74, blue: 0.18),
                icon: "minus",
                label: "Minimize",
                showsIcon: isHovered
            ) {
                window?.miniaturize(nil)
            }

            TrafficLightButton(
                color: Color(red: 0.25, green: 0.79, blue: 0.30),
                icon: "plus",
                label: "Zoom",
                showsIcon: isHovered
            ) {
                window?.zoom(nil)
            }
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .cursor(.pointingHand)
    }
}

private struct TrafficLightButton: View {
    let color: Color
    let icon: String
    let label: String
    let showsIcon: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.12), lineWidth: 0.5)
                }
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.46))
                        .opacity(showsIcon ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
