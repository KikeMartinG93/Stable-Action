//
//  PhotoCaptureDelegate.swift
//  Stable Action
//
//  Created by Rudra Shah on 26/02/26.
//

import AVFoundation

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onPhotoData: (Data) -> Void
    private let onError: (Error) -> Void

    init(onPhotoData: @escaping (Data) -> Void,
         onError: @escaping (Error) -> Void) {
        self.onPhotoData = onPhotoData
        self.onError = onError
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            onError(error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onError(NSError(domain: "Camera", code: -1, userInfo: [NSLocalizedDescriptionKey: "No photo data"]))
            return
        }
        onPhotoData(data)
    }
}
