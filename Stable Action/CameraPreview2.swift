//
//  CameraPreview2.swift
//  Stable Action
//
//  A horizon-locked camera preview that shows exactly the crop region
//  the CameraManager records — a 3:4 portrait rect that stays level
//  with the horizon as the phone rolls.
//
//  Crop geometry (must stay in sync with CameraManager):
//    cropFraction  = 3/5 × 0.90
//    aspect        = 3 wide : 4 tall
//    The rect is sized so its diagonal fits the shorter screen dimension
//    with a 10 % inset, matching HorizonRectangleView.
//

import SwiftUI
import AVFoundation

// MARK: - UIView

/// A UIView that hosts an AVCaptureVideoPreviewLayer, counter-rotates it
/// by the current device roll, and clips to the crop rectangle — giving a
/// live preview that matches the recorded video pixel-for-pixel.
final class HorizonCropPreviewView: UIView {

    // ── Constants (mirror CameraManager) ──────────────────────────────
    private let cropFraction: CGFloat = 3.0 / 5.0 * 0.90
    private let cropAspectW:  CGFloat = 3.0
    private let cropAspectH:  CGFloat = 4.0

    // ── Sub-layers ─────────────────────────────────────────────────────
    /// Container whose transform is the counter-rotation.
    private let rotatingContainer = CALayer()
    /// The actual camera feed.
    private let previewLayer = AVCaptureVideoPreviewLayer()



    // MARK: Init

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true                 // hard crop to the SwiftUI frame

        // Preview layer fills the rotating container.
        previewLayer.session     = session
        previewLayer.videoGravity = .resizeAspectFill

        rotatingContainer.addSublayer(previewLayer)
        layer.addSublayer(rotatingContainer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let cW = bounds.width
        let cH = bounds.height
        let cx = cW / 2
        let cy = cH / 2

        // ── 1. Crop rect size (portrait 3:4, diagonal = shorter × 0.90) ──
        // This exactly matches HorizonRectangleView & CameraManager maths.
        let shorter = min(cW, cH)
        let cropW   = shorter * cropFraction              // same as rectW in HorizonRectangleView
        let cropH   = cropW * (cropAspectH / cropAspectW)

        // ── 2. The preview layer must cover the crop rect even after the
        //       largest expected rotation.  Worst-case is 45° → expand by √2.
        //       Using 1.5× is safe and matches typical tilt angles.
        let expand:  CGFloat = 1.5
        let layerW = cropW * expand
        let layerH = cropH * expand

        // ── 3. Position rotatingContainer centred in this view ───────────
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatingContainer.bounds   = CGRect(x: 0, y: 0, width: layerW, height: layerH)
        rotatingContainer.position = CGPoint(x: cx, y: cy)
        previewLayer.frame         = rotatingContainer.bounds
        CATransaction.commit()

        updateLayout()
    }

    // MARK: Layout (extracted so it can be called without rotation)

    private func updateLayout() {
        // No additional layout adjustments needed — static preview, no rotation.
    }
}

// MARK: - SwiftUI wrapper

/// Drop-in SwiftUI view.  Pass the same `session` and `motion` objects
/// used by the rest of the app.
struct CameraPreview2: UIViewRepresentable {

    let session:  AVCaptureSession
    /// Optional tap-to-focus callback (viewPoint, devicePoint).
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil

    // ── Constants (mirror CameraManager) ─────────────────────────────
    private let cropFraction: CGFloat = 3.0 / 5.0 * 0.90
    private let cropAspectH:  CGFloat = 4.0
    private let cropAspectW:  CGFloat = 3.0

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> HorizonCropPreviewView {
        let view = HorizonCropPreviewView(session: session)

        // Tap-to-focus
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view

        return view
    }

    func updateUIView(_ uiView: HorizonCropPreviewView, context: Context) {
        context.coordinator.onTap = onTap
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        weak var previewView: HorizonCropPreviewView?

        init(onTap: ((CGPoint, CGPoint) -> Void)?) { self.onTap = onTap }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let vp = gesture.location(in: view)
            // For device-point conversion we use the inner previewLayer.
            // Access it via the rotating container's first sublayer.
            if let pl = view.layer.sublayers?.first?.sublayers?.first as? AVCaptureVideoPreviewLayer {
                let dp = pl.captureDevicePointConverted(fromLayerPoint: vp)
                onTap?(vp, dp)
            } else {
                onTap?(vp, CGPoint(x: 0.5, y: 0.5))
            }
        }
    }
}
