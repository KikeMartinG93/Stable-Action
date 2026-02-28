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
    @Published var roll: Double = 0.0

    /// Crop-window translation in normalised sensor fractions (-1…+1).
    /// +X = shift crop right (phone moved left), +Y = shift crop up (phone moved down).
    /// CameraManager scales these by the available pixel margin before cropping.
    @Published var offsetX: Double = 0.0
    @Published var offsetY: Double = 0.0

    private let motionManager = CMMotionManager()

    // Velocity accumulators for the translation integrator (m/s, device frame).
    private var velX: Double = 0.0
    private var velY: Double = 0.0

    // Tuning constants
    /// dt between motion updates (must match deviceMotionUpdateInterval).
    private let dt: Double = 1.0 / 120.0
    /// How quickly the velocity bleeds off when there's no acceleration (0-1 per update).
    /// Higher = snappier return to centre; lower = smoother but drifts more.
    private let velocityDecay: Double = 0.88
    /// How quickly the position offset returns to centre when the phone is still.
    private let positionDecay: Double = 0.96
    /// Scales raw acceleration (m/s²) into normalised offset units.
    /// Tuned so a 0.5 g lateral jerk ≈ 0.3 normalised units of offset.
    private let sensitivity: Double = 0.012

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = dt
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] data, _ in
            guard let self, let data else { return }

            // ── Roll ─────────────────────────────────────────────────
            self.roll = atan2(data.gravity.x, -data.gravity.y)

            // ── Translation (X/Y shift) ───────────────────────────────
            // userAcceleration has gravity removed; x = left/right, y = up/down
            // in the device frame when held portrait.
            let ax = data.userAcceleration.x   // positive = phone jerked right
            let ay = data.userAcceleration.y   // positive = phone jerked up

            // Integrate acceleration → velocity, then decay
            self.velX = (self.velX + ax * self.dt) * self.velocityDecay
            self.velY = (self.velY + ay * self.dt) * self.velocityDecay

            // Integrate velocity → offset, then decay toward zero
            // Negate: if phone jerks right we shift crop left to compensate
            self.offsetX = (self.offsetX - self.velX * self.sensitivity) * self.positionDecay
            self.offsetY = (self.offsetY - self.velY * self.sensitivity) * self.positionDecay

            // Clamp to ±1 so we never ask for a crop outside the sensor buffer
            self.offsetX = max(-1.0, min(1.0, self.offsetX))
            self.offsetY = max(-1.0, min(1.0, self.offsetY))
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        velX = 0; velY = 0; offsetX = 0; offsetY = 0
    }
}

// MARK: - Horizon Rectangle View

struct HorizonRectangleView: View {

    @ObservedObject var motion: MotionManager

    var body: some View {
        GeometryReader { geo in
            let cW = geo.size.width
            let cH = geo.size.height

            let rectW = min(cW, cH) * (3.0 / 5.0) * 0.90
            let rectH = rectW * (4.0 / 3.0)

            // Counter-rotate so the rectangle stays upright
            let angle = -motion.roll

            // Shift to match the crop translation offset.
            // Available margin on each side = (containerDim - rectDim) / 2
            let marginX = (cW - rectW) / 2
            let marginY = (cH - rectH) / 2
            let shiftX  = CGFloat(motion.offsetX) * marginX * 0.9
            let shiftY  = CGFloat(motion.offsetY) * marginY * 0.9

            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                ViewfinderCorners()
                    .stroke(
                        Color.yellow,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
            }
            .frame(width: rectW, height: rectH)
            .rotationEffect(.radians(angle))
            .position(x: cW / 2 + shiftX, y: cH / 2 - shiftY)  // negate Y: UIKit Y↓ vs CIImage Y↑
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
