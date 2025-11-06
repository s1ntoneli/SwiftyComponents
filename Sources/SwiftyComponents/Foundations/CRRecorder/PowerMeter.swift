/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that calculates the average and peak power levels for the captured audio samples.
*/

import Foundation
import AVFoundation
import Accelerate

struct AudioLevels {
    static let zero = AudioLevels(level: 0, peakLevel: 0)
    let level: Float
    let peakLevel: Float
}

// The protocol for the object that provides peak and average power levels to adopt.
protocol AudioLevelProvider {
    var levels: AudioLevels { get }
}

class PowerMeter: AudioLevelProvider {
    private let kMinLevel: Float = 0.000_000_01 // -160 dB
    
    private struct PowerLevels {
        let average: Float
        let peak: Float
    }
    
    private var values = [PowerLevels]()
    
    private var meterTableAverage = MeterTable()
    private var meterTablePeak = MeterTable()
    
    var levels: AudioLevels {
        if values.isEmpty { return AudioLevels(level: 0.0, peakLevel: 0.0) }
        return AudioLevels(level: meterTableAverage.valueForPower(values[0].average),
                           peakLevel: meterTablePeak.valueForPower(values[0].peak))
    }
    
    func processSilence() {
        if values.isEmpty { return }
        values = []
    }
    
    // Calculates the average (rms) and peak level of each channel in the PCM buffer and caches data.
    func process(buffer: AVAudioPCMBuffer) {
        var powerLevels = [PowerLevels]()
        let channelCount = Int(buffer.format.channelCount)
        let length = vDSP_Length(buffer.frameLength)
        
//        print("🎵 Buffer info - channels: \(channelCount), frameLength: \(buffer.frameLength), stride: \(buffer.stride)")
        
        if let floatData = buffer.floatChannelData {
//            print("🎵 Processing float data")
            for channel in 0..<channelCount {
                // 使用 stride = 1 而不是 buffer.stride
                powerLevels.append(calculatePowers(data: floatData[channel], strideFrames: 1, length: length))
            }
        } else if let int16Data = buffer.int16ChannelData {
//            print("🎵 Processing int16 data")
            for channel in 0..<channelCount {
                // Convert the data from int16 to float values before calculating the power values.
                var floatChannelData: [Float] = Array(repeating: Float(0.0), count: Int(buffer.frameLength))
                vDSP_vflt16(int16Data[channel], 1, &floatChannelData, 1, length)
                var scalar = Float(INT16_MAX)
                vDSP_vsdiv(floatChannelData, 1, &scalar, &floatChannelData, 1, length)
                
                powerLevels.append(calculatePowers(data: floatChannelData, strideFrames: 1, length: length))
            }
        } else if let int32Data = buffer.int32ChannelData {
//            print("🎵 Processing int32 data")
            for channel in 0..<channelCount {
                // Convert the data from int32 to float values before calculating the power values.
                var floatChannelData: [Float] = Array(repeating: Float(0.0), count: Int(buffer.frameLength))
                vDSP_vflt32(int32Data[channel], 1, &floatChannelData, 1, length)
                var scalar = Float(INT32_MAX)
                vDSP_vsdiv(floatChannelData, 1, &scalar, &floatChannelData, 1, length)
                
                powerLevels.append(calculatePowers(data: floatChannelData, strideFrames: 1, length: length))
            }
        }
        self.values = powerLevels
    }
    
    private func calculatePowers(data: UnsafePointer<Float>, strideFrames: Int, length: vDSP_Length) -> PowerLevels {
        var max: Float = 0.0
        vDSP_maxv(data, strideFrames, &max, length)
        
        var rms: Float = 0.0
        vDSP_rmsqv(data, strideFrames, &rms, length)
        
        // 确保值不为 0 或 NaN，使用更安全的最小值
        let safeMax = max.isNormal && max > kMinLevel ? max : kMinLevel
        let safeRms = rms.isNormal && rms > kMinLevel ? rms : kMinLevel
        
        let peakDB = 20.0 * log10(safeMax)
        let averageDB = 20.0 * log10(safeRms)
        
//        print("🔊 Raw max: \(max), rms: \(rms)")
//        print("🔊 Safe max: \(safeMax), rms: \(safeRms)")
//        print("🔊 Calculated peakDB: \(peakDB), averageDB: \(averageDB)")
        
        return PowerLevels(average: averageDB, peak: peakDB)
    }
}

private struct MeterTable {
    
    // The decibel value of the minimum displayed amplitude.
    private let kMinDB: Float = -40.0  // 从-60改为-40，提高敏感度
    
    // The table needs to be large enough so that there are no large gaps in the response.
    private let tableSize = 300
    
    private let scaleFactor: Float
    private var meterTable = [Float]()
    
    init() {
        let dbResolution = kMinDB / Float(tableSize - 1)
        scaleFactor = 1.0 / dbResolution
        
        // This controls the curvature of the response.
        // 1.5 makes it more sensitive than 2.0
        let root: Float = 1.5
        
        let rroot = 1.0 / root
        let minAmp = dbToAmp(dBValue: kMinDB)
        let ampRange = 1.0 - minAmp
        let invAmpRange = 1.0 / ampRange
        
        for index in 0..<tableSize {
            let decibels = Float(index) * dbResolution
            let amp = dbToAmp(dBValue: decibels)
            let adjAmp = (amp - minAmp) * invAmpRange
            meterTable.append(powf(adjAmp, rroot))
        }
    }
    
    private func dbToAmp(dBValue: Float) -> Float {
        return powf(10.0, 0.05 * dBValue)
    }
    
    func valueForPower(_ power: Float) -> Float {
        guard power.isNormal else { 
            print("⚠️ power not normal: \(power)")
            return 0 
        }
        
//        print("🔊 Input power: \(power) dB, kMinDB: \(kMinDB)")
        
        if power < kMinDB {
//            print("📉 Power below minimum (\(kMinDB)): returning 0")
            return 0.0
        } else if power >= 0.0 {
//            print("📈 Power at or above 0: returning 1")
            return 1.0
        } else {
            let index = Int(power / (kMinDB / Float(tableSize - 1)))
//            print("📊 Calculated index: \(index), tableSize: \(tableSize)")
            
            if index >= 0 && index < meterTable.count {
                let result = meterTable[index]
//                print("✅ Table lookup result: \(result)")
                return result
            } else {
//                print("❌ Index out of bounds: \(index)")
                return 0.0
            }
        }
    }
}
