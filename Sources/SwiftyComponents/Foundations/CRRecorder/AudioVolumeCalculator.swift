import Foundation
import AVFoundation
import Accelerate

struct AudioVolumeCalculator {
    
    /// 从 CMSampleBuffer 计算音量值，返回 0.0-1.0 的标准化值
    /// - Parameter sampleBuffer: 音频样本缓冲区
    /// - Returns: 音量值 (0.0-1.0)，更敏感的范围映射
    static func calculateVolume(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard status == noErr, let data = dataPointer, length > 0 else {
            return 0.0
        }
        
        // 获取音频格式信息
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return 0.0
        }
        
        let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let format = audioFormat else {
            return 0.0
        }
        
        let channelCount = Int(format.pointee.mChannelsPerFrame)
        let bytesPerSample = Int(format.pointee.mBitsPerChannel / 8)
        let sampleCount = length / bytesPerSample / channelCount
        
        guard sampleCount > 0 else {
            return 0.0
        }
        
        // 计算音频电平
        let audioLevel = calculateAudioLevel(data: data, sampleCount: sampleCount, channelCount: channelCount, bytesPerSample: bytesPerSample)
        
        // 应用敏感度调整，确保不同设备都有合适的响应
        return adjustSensitivity(audioLevel)
    }
    
    /// 从 CMSampleBuffer 计算详细音量信息
    /// - Parameter sampleBuffer: 音频样本缓冲区
    /// - Returns: (平均音量, 峰值音量, dB值)
    static func calculateDetailedVolume(from sampleBuffer: CMSampleBuffer) -> (average: Float, peak: Float, dbValue: Float) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return (0.0, 0.0, -160.0)
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard status == noErr, let data = dataPointer, length > 0 else {
            return (0.0, 0.0, -160.0)
        }
        
        // 获取音频格式信息
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return (0.0, 0.0, -160.0)
        }
        
        let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let format = audioFormat else {
            return (0.0, 0.0, -160.0)
        }
        
        let channelCount = Int(format.pointee.mChannelsPerFrame)
        let bytesPerSample = Int(format.pointee.mBitsPerChannel / 8)
        let sampleCount = length / bytesPerSample / channelCount
        
        guard sampleCount > 0 else {
            return (0.0, 0.0, -160.0)
        }
        
        // 计算音频电平
        let audioLevel = calculateAudioLevel(data: data, sampleCount: sampleCount, channelCount: channelCount, bytesPerSample: bytesPerSample)
        
        // 应用敏感度调整
        let adjustedLevel = adjustSensitivity(audioLevel)
        let peakLevel = min(1.0, adjustedLevel * 1.2) // 峰值稍高于平均值
        
        // 计算 dB 值
        let dbValue = 20.0 * log10(max(audioLevel, 1e-6))
        
        return (adjustedLevel, peakLevel, dbValue)
    }
    
    // MARK: - 私有方法
    
    /// 计算音频电平的核心方法
    private static func calculateAudioLevel(data: UnsafeMutablePointer<Int8>, sampleCount: Int, channelCount: Int, bytesPerSample: Int) -> Float {
        var totalPower: Float = 0.0
        
        if bytesPerSample == 2 {
            // 16位音频
            let samples = data.withMemoryRebound(to: Int16.self, capacity: sampleCount * channelCount) { $0 }
            for i in 0..<(sampleCount * channelCount) {
                let sample = Float(samples[i]) / Float(Int16.max)
                totalPower += sample * sample
            }
        } else if bytesPerSample == 4 {
            // 32位音频
            let samples = data.withMemoryRebound(to: Float.self, capacity: sampleCount * channelCount) { $0 }
            for i in 0..<(sampleCount * channelCount) {
                let sample = samples[i]
                totalPower += sample * sample
            }
        } else {
            // 其他格式，默认处理
            return 0.0
        }
        
        // 计算RMS值
        let rms = sqrt(totalPower / Float(sampleCount * channelCount))
        
        // 转换为0-1范围
        return min(1.0, max(0.0, rms))
    }
    
    /// 敏感度调整，为不同设备类型提供合适的响应
    private static func adjustSensitivity(_ level: Float) -> Float {
        // 更激进的放大，让音量指示器更容易达到高值
        if level < 0.005 {
            return min(1.0, level * 50.0)  // 放大50倍
        } else if level < 0.02 {
            return min(1.0, level * 25.0)  // 放大25倍
        } else if level < 0.1 {
            return min(1.0, level * 8.0)   // 放大8倍
        } else if level < 0.2 {
            return min(1.0, level * 4.0)   // 放大4倍
        } else {
            return min(1.0, level * 2.0)   // 所有音量都至少放大2倍
        }
    }
}
