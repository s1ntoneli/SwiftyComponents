//
//  RecordingError.swift
//  SwiftyComponents
//
//  Created by lixindong on 2025/11/3.
//


/// 录制错误枚举
public enum RecordingError: Error {
    case noSourcePrepared
    case invalidState
    case recordingFailed(String)
    case userAbort
    
    case deviceNotFound
    case cannotAddInput
    case cannotAddOutput
    case sessionFailedToStart
    case sessionNotRunning
    case outputNotConfigured
    case notPrepared
}
