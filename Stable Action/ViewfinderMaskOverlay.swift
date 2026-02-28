import SwiftUI

struct ViewfinderMaskOverlay: View {
    let rect: CGRect

    var body: some View {
        GeometryReader { geo in
            let full = geo.frame(in: .local)
            ZStack {
                // Dim outside the rect
                Color.black.opacity(0.45)
                    .mask(
                        Rectangle()
                            .overlay(
                                Rectangle()
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blendMode(.destinationOut)
                            )
                    )
                    .compositingGroup()

                // Yellow border around the rect
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .frame(width: full.width, height: full.height, alignment: .center)
        }
        .allowsHitTesting(false)
    }
}
