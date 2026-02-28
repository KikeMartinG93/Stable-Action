//
//  PreviewLayerProxy.swift
//  Stable Action
//
//  Holds a weak reference to the AVCaptureVideoPreviewLayer so SwiftUI
//  views can convert coordinate rects via Apple's API instead of guessing.
//

import AVFoundation

final class PreviewLayerProxy {
    weak var layer: AVCaptureVideoPreviewLayer?
}
