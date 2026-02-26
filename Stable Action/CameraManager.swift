//
//  CameraManager.swift
//  Stable Action
//
//  Created by Rudra Shah on 26/02/26.
//

import AVFoundation
import Combine
import Photos
import UniformTypeIdentifiers

final class CameraManager: NSObject, ObservableObject {

    enum CameraType {
        case wide
        case ultraWide
        case telephoto
    }

    // Preferred camera type (defaults to ultra‑wide if available)
    @Published var cameraType: CameraType = .ultraWide {
        didSet {
            // Reconfigure the video input when the preference changes
            sessionQueue.async { [weak self] in
                self?.reconfigureVideoInput()
            }
        }
    }

    // MARK: - Session
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var isConfigured = false

    // MARK: - Inputs / Outputs
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()

    // MARK: - Published state
    @Published var permissionDenied = false
    @Published var isRecording = false
    @Published var lastVideoURL: URL? = nil

    /// When true, Cinematic Video Stabilization (Action Mode equivalent) is applied
    @Published var actionModeEnabled = false {
        didSet { sessionQueue.async { self.applyStabilization() } }
    }

    // Temp file URL for the current recording
    private var currentRecordingURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
    }

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            checkMicThenStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.checkMicThenStart() }
                else { DispatchQueue.main.async { self?.permissionDenied = true } }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    private func checkMicThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in self?.startSession() }
        default:
            startSession() // start without mic if denied
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - Session Configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration(); isConfigured = true }

        // Video input (prefer current camera type, fallback handled in helper)
        guard let videoDevice = selectVideoDevice(for: cameraType, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else { return }
        session.addInput(videoInput)
        videoDeviceInput = videoInput

        // Enable continuous autofocus & auto-exposure from the start
        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            videoDevice.unlockForConfiguration()
        } catch {
            print("Initial focus config error:", error)
        }

        enforceFourByThreeAndMinZoom()

        // Audio input
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            audioDeviceInput = audioInput
        }

        // Movie output
        guard session.canAddOutput(movieOutput) else { return }
        session.addOutput(movieOutput)

        // Initial stabilization
        applyStabilization()
    }

    private func applyStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if actionModeEnabled {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
            }
        } else {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
        // Keep session preset at .inputPriority to honor 4:3 activeFormat
        session.sessionPreset = .inputPriority
    }

    // Select a video device for a given camera type and position, with sensible fallbacks
    private func selectVideoDevice(for type: CameraType, position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        switch type {
        case .ultraWide:
            if let d = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
                return d
            }
            // Fallback to wide if ultra‑wide isn't available
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)

        case .telephoto:
            if let d = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: position) {
                return d
            }
            // Fallback to wide if telephoto isn't available
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)

        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
    }

    // Pick the highest-resolution 4:3 video format supported by the device
    private func best4by3Format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let target: Double = 4.0 / 3.0
        var best: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let w = dims.width
            let h = dims.height
            if w == 0 || h == 0 { continue }
            let ratio = Double(w) / Double(h)
            if abs(ratio - target) > 0.01 { continue }

            // Prefer formats that can run at >= 30 fps
            let supports30 = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30.0 }
            if !supports30 { continue }

            if w > bestWidth {
                best = format
                bestWidth = w
            }
        }
        return best
    }

    // Enforce 4:3 aspect by selecting an appropriate activeFormat and zoom out fully
    private func enforceFourByThreeAndMinZoom() {
        guard let device = videoDeviceInput?.device else { return }
        // Use inputPriority so the device's activeFormat takes precedence
        session.sessionPreset = .inputPriority

        do {
            try device.lockForConfiguration()

            if let format = best4by3Format(for: device) {
                device.activeFormat = format
                // Aim for 30 fps when possible
                let desiredFPS: Double = 30.0
                if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= desiredFPS }) {
                    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFPS))
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                }
            }

            if #available(iOS 17.0, *) {
                device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
            } else {
                device.videoZoomFactor = 1.0
            }

            device.unlockForConfiguration()
        } catch {
            print("4:3/zoom config error:", error)
        }
    }

    // Reconfigure only the video input to switch lenses at runtime
    private func reconfigureVideoInput() {
        session.beginConfiguration()

        if let currentVideoInput = videoDeviceInput {
            session.removeInput(currentVideoInput)
            videoDeviceInput = nil
        }

        if let device = selectVideoDevice(for: cameraType, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoDeviceInput = input
            // Enforce 4:3 aspect and minimum zoom for the new lens
            enforceFourByThreeAndMinZoom()
        }

        session.commitConfiguration()

        // Update stabilization settings for the new connection
        applyStabilization()
    }

    /// Public API to change camera type from UI code
    func setCameraType(_ type: CameraType) {
        // Update on main to publish change, actual reconfiguration happens on sessionQueue via didSet
        DispatchQueue.main.async { [weak self] in
            self?.cameraType = type
        }
    }

    // MARK: - Focus & Exposure

    /// `point` is in camera device coordinates (0,0)–(1,1)
    func focusAt(point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                print("Focus error:", error)
            }

            // After lock settles, restore continuous autofocus
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self,
                      let device = self.videoDeviceInput?.device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("Restore focus error:", error)
                }
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                let url = self.currentRecordingURL
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true }
            }
        }
    }

    // MARK: - Save to Photos

    private func saveVideoToLibrary(url: URL) {
        let save = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, error in
                if let error { print("Video save error:", error) }
                try? FileManager.default.removeItem(at: url)
            }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            save()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited { save() }
            }
        default: break
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            if error == nil {
                self.lastVideoURL = outputFileURL
                self.saveVideoToLibrary(url: outputFileURL)
            } else {
                print("Recording error:", error!)
            }
        }
    }
}

