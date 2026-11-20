import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UIKit

/// 把「页面逐帧渲染好的 JPEG 序列」合成成一段恒定帧率的 MOV。
/// 不走 MediaRecorder，因此不存在实时录制掉帧的问题：
/// 帧数由页面按 1/fps 精确 seek 决定，原生按固定时间戳逐帧写入。
enum LiveFrames {

    static func encode(frames: [Data], width: Int, height: Int, fps: Int, to url: URL,
                       completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: url)

            guard !frames.isEmpty, width > 1, height > 1,
                  let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input, sourcePixelBufferAttributes: attrs)

            guard writer.canAdd(input) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            writer.add(input)

            guard writer.startWriting() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            writer.startSession(atSourceTime: .zero)

            var ok = true
            for (i, data) in frames.enumerated() {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { ok = false; break }
                    Thread.sleep(forTimeInterval: 0.004)
                }
                if !ok { break }
                guard let buf = pixelBuffer(from: data, width: width, height: height) else {
                    ok = false; break
                }
                let t = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(max(1, fps)))
                if !adaptor.append(buf, withPresentationTime: t) { ok = false; break }
            }

            input.markAsFinished()
            if !ok { writer.cancelWriting() }

            let sem = DispatchSemaphore(value: 0)
            writer.finishWriting { sem.signal() }
            sem.wait()

            let success = ok && writer.status == .completed
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// JPEG → BGRA 的 CVPixelBuffer（画正，不上下颠倒）。
    private static func pixelBuffer(from data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        // CGBitmapContext 的第 0 行在内存里就是图像的顶行，
        // AVAssetWriter 也按顶行优先消费，这里不能再翻一次，否则动态会倒过来。
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
