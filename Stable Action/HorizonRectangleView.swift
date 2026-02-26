//
//  HorizonRectangleView.swift
//  Stable Action
//
//  A fixed 3:4 viewport centred on screen. The camera preview layer inside
//  counter-rotates + scales against the phone roll so the image is always
//  horizon-locked. Everything outside the rectangle is clipped away.
//

import SwiftUI
import CoreMotion
import Combine

// MARK: - Motion Manager

final class MotionManager: ObservableObject {

    /// Full-circle roll angle (radians) derived from the gravity vector.
    /// Uses atan2 so it covers −π…+π with no dead-zones at ±180°.
    @Published var roll: Double = 0.0

    private let motionManager = CMMotionManager()

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] data, _ in
            guard let self, let data else { return }
            // gravity.x = left/right, gravity.y = up/down (negative when upright)
            // atan2(x, -y): portrait upright → 0, CW tilt → positive
            self.roll = atan2(data.gravity.x, -data.gravity.y)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Horizon Rectangle View

struct HorizonRectangleView: View {

    @ObservedObject var motion: MotionManager

    var body: some View {
        GeometryReader { geo in
            let cW = geo.size.width
            let cH = geo.size.height

            // Size so the diagonal = min(cW,cH) × 0.90
            // For a 3:4 rect: diagonal = W × 5/3  (√(3²+4²) = 5)
            // → W = min(cW,cH) × 3/5 × 0.90
            let rectW = min(cW, cH) * (3.0 / 5.0) * 0.90
            let rectH = rectW * (4.0 / 3.0)

            // Counter-rotate so the rectangle stays upright
            let angle = -motion.roll

            ZStack {
                // Subtle fill
                Rectangle()
                    .fill(Color.white.opacity(0.04))

                // White border
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)

                // Yellow corner brackets
                ViewfinderCorners()
                    .stroke(
                        Color.yellow,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
            }
            .frame(width: rectW, height: rectH)
            .rotationEffect(.radians(angle))
            .position(x: cW / 2, y: cH / 2)
        }
    }
}

// MARK: - Corner brackets

private struct ViewfinderCorners: Shape {
    private let arm: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = arm
        let r = rect.insetBy(dx: 1, dy: 1)

        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + a))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + a, y: r.minY))

        // Top-right
        p.move(to: CGPoint(x: r.maxX - a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + a))

        // Bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - a))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - a, y: r.maxY))

        // Bottom-left
        p.move(to: CGPoint(x: r.minX + a, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - a))
        return p
    }
}
