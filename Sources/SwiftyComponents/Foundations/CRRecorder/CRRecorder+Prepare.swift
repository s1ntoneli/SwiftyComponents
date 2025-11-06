//
//  File.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//

import Foundation
import AVFoundation

extension CRRecorder {
    
    func prepareCameraSession(cameraId: String, filename: String) async throws {
        
    }
    
    func prepareCaptureSession(deviceID: String, filename: String) async throws {
        
    }
}

open class AVCaptureSessionTool {
    
    var fileOutput: AVCaptureFileOutput?
    
    func createFileOutput() -> AVCaptureFileOutput {
        return AVCaptureMovieFileOutput()
    }
    
    func stopRecording() {
        
    }
    
    func prepareCaptureSession(deviceID: String, filename: String) async throws {
        
    }
}
