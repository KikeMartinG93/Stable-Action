//
//  CameraPreview2.swift
//  Stable Action
//
//  Displays a live preview of the exact crop region that CameraManager records:
//    • Sensor frame rotated to portrait  (.oriented(.right))
//    • Counter-rotated by -roll          (horizon stabilisation)
//    • Centre-cropped to 3:4 rect        (cropFraction = 3/5 × 0.90)
//
//  The processed CIImage is delivered by CameraManager.previewFrameHandler
//  (on the data-output queue) and rendered into an MTKView every frame.
//

import SwiftUI
import MetalKit
import CoreImage

// MARK: - Metal renderer

/// MTKView subclass that draws CIImages sent from the CameraManager pipeline.
final class CropPreviewMTKView: MTKView {

    private let ciContext: CIContext
    private var latestImage: CIImage?
    private let renderLock = NSLock()

    override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        ciContext = CIContext(mtlDevice: dev,
                              options: [.useSoftwareRenderer: false,
                                        .workingColorSpace: CGColorSpaceCreateDeviceRGB() as Any])
        super.init(frame: frame, device: dev)
        framebufferOnly  = false          // needed so CIContext can render into it
        enableSetNeedsDisplay = false      // drive via setNeedsDisplay calls
        isPaused         = true           // we'll trigger draws manually
        backgroundColor  = .black
        contentScaleFactor = UIScreen.main.scale
        autoResizeDrawable = true
        delegate = nil                    // we override draw() directly
    }

    required init(coder: NSCoder) { fatalError() }

    /// Called from CameraManager.previewFrameHandler (data-output queue).
    func enqueue(_ image: CIImage) {
        renderLock.lock()
        latestImage = image
        renderLock.unlock()
        // Trigger a draw on the main thread.
        DispatchQueue.main.async { [weak self] in self?.draw() }
    }

    override func draw(_ rect: CGRect) {
        renderLock.lock()
        let image = latestImage
        renderLock.unlock()
        guard let image,
              let commandQueue = device?.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = currentDrawable else { return }

        let drawableSize = CGSize(width: drawableSize.width, height: drawableSize.height)

        // Scale CIImage to fill the drawable, letterbox/pillarbox preserving aspect.
        let imgW = image.extent.width
        let imgH = image.extent.height
        let scaleX = drawableSize.width  / imgW
        let scaleY = drawableSize.height / imgH
        let scale  = min(scaleX, scaleY)          // aspect-fit

        let scaledW = imgW * scale
        let scaledH = imgH * scale
        let tx = (drawableSize.width  - scaledW) / 2
        let ty = (drawableSize.height - scaledH) / 2

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: tx / scale, y: ty / scale)
        let displayed = image.transformed(by: transform)

        let renderDestination = CIRenderDestination(
            width:  Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: colorPixelFormat,
            commandBuffer: commandBuffer
        ) { [weak drawable] in drawable!.texture }

        renderDestination.isFlipped = false

        // Clear to black then composite the image.
        try? ciContext.startTask(toClear: renderDestination)
        try? ciContext.startTask(toRender: displayed, to: renderDestination)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI wrapper

/// Drop-in SwiftUI view.
/// Pass the `camera: CameraManager` — the view wires itself to
/// `camera.previewFrameHandler` in `makeUIView` and tears down in `dismantleUIView`.
struct CameraPreview2: UIViewRepresentable {

    let camera: CameraManager
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> CropPreviewMTKView {
        let view = CropPreviewMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())

        // Tap-to-focus
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view

        // Subscribe to processed frames from CameraManager
        camera.previewFrameHandler = { [weak view] ciImage in
            view?.enqueue(ciImage)
        }

        return view
    }

    func updateUIView(_ uiView: CropPreviewMTKView, context: Context) {
        context.coordinator.onTap = onTap
    }

    static func dismantleUIView(_ uiView: CropPreviewMTKView, coordinator: Coordinator) {
        // Nothing needed — CameraManager owns the handler, will be replaced or nilled on stop.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        weak var view: CropPreviewMTKView?

        init(onTap: ((CGPoint, CGPoint) -> Void)?) { self.onTap = onTap }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let pt = gesture.location(in: view)
            // Normalise to 0–1 device coordinates (centre = 0.5, 0.5)
            let dp = CGPoint(x: pt.x / view.bounds.width,
                             y: pt.y / view.bounds.height)
            onTap?(pt, dp)
        }
    }
}
