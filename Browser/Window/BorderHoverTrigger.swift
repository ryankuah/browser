import SwiftUI

struct BorderHoverTrigger: View {
    let onHover: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                hoverArea
                    .frame(width: WindowBorder.thickness)

                Spacer()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var hoverArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover(perform: onHover)
    }
}
