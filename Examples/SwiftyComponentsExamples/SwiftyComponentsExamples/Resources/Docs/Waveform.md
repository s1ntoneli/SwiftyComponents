# Waveform 组件接入指南

## 快速接入

```swift
import AVFoundation
import SwiftyComponents

// 1) 采样（RMS，单声道混合）
let asset = AVURLAsset(url: url)
let range = CMTimeRange(start: .zero, duration: asset.duration)
let values = try await WaveformAnalyzer.sampleAmplitudes(
    asset: asset,
    timeRange: range,
    samples: 200,
    mode: .rms,
    channel: .mix
)

// 2) 渲染（对称显示、平滑填充）
WaveformView(
    samples: values,
    style: .filled(smooth: true),
    mirror: true
)
```

## `WaveformView`
- `samples: [Float]` 0...1 归一化，建议下采样后与像素密度相当
- `style: WaveformStyle` `.bars`/`.outline(smooth:)`/`.filled(smooth:)`
- `mirror: Bool` `true`=双极（上下对称），`false`=单极（仅上半部）
- 可选：`tint`、`fillGradient(top:bottom:)`、`progress`、`progressColor`、`progressLineWidth`

## `WaveformAnalyzer`
- `sampleAmplitudes(fileURL|asset|track, timeRange, samples, mode: .rms|.peak, channel: .mix|.left|.right)`
- 产出：0...1 归一化数组；内部按固定时间窗聚合

## 下采样（纯函数）
- `WaveformDownsampler.downsampleMagnitudes(values, into: bins, mode: .rms|.peak)`
- 可用于离线处理或测试

```
// 示例：将更高密度的包络值下采样为 200 个 bins（RMS）
let compact = WaveformDownsampler.downsampleMagnitudes(envelope, into: 200, mode: .rms)
```
