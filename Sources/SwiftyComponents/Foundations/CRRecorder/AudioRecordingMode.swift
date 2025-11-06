//
//  AudioRecordingMode.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//


/// 音频录制模式
public enum AudioRecordingMode: String, Sendable {
    case none           // 不录制音频
    case merged         // 音频和视频合并在一个文件中
    case separate       // 音频单独录制成一个文件
}
