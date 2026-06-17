import SwiftUI

struct WindowBorder: View {
    static let thickness: CGFloat = 7
    static let headerHeight: CGFloat = thickness

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: 0) {
                    borderFill
                        .frame(height: Self.headerHeight)

                    Spacer()

                    borderFill
                        .frame(height: Self.thickness)
                }

                HStack(spacing: 0) {
                    borderFill
                        .frame(width: Self.thickness)

                    Spacer()

                    borderFill
                        .frame(width: Self.thickness)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var borderFill: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Rectangle()
                    .fill(.white.opacity(0.10))
            }
            .overlay {
                Rectangle()
                    .fill(.black.opacity(0.05))
            }
    }
}
