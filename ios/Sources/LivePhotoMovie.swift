import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import Darwin

/// 把一段普通视频重新封装成「实况照片可用的 MOV」：
///   1. 视频逐帧重绘到静态帧的像素尺寸（长宽比一致，必要时居中裁切）
///   2. 资产级 metadata：com.apple.quicktime.content.identifier
///   3. metadata 轨道：com.apple.quicktime.still-image-time，放在片子中间
/// 这是 Photos 配对校验认的三样东西。
enum LivePhotoMovie {

    static func makeIdentifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<22).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    static func wrap(video: URL, identifier: String, targetSize: CGSize,
                     completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first,
              targetSize.width > 0, targetSize.height > 0,
              let stillFD = stillTimeFormatDescription() else {
            completion(nil); return
        }

        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        let out = video.deletingPathExtension().appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: out)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else {
            completion(nil); return
        }

        let vOut = AVAssetReaderTrackOutput(
            track: vTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { completion(nil); return }
        reader.add(vOut)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { completion(nil); return }
        writer.add(vIn)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillFD)
        mIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(mIn) else { completion(nil); return }
        writer.add(mIn)

        let idItem = AVMutableMetadataItem()
        idItem.identifier = .quickTimeMetadataContentIdentifier
        idItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        idItem.value = identifier as NSString
        writer.metadata = [idItem]

        guard writer.startWriting() else { completion(nil); return }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting(); completion(nil); return
        }

        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        let dstRect = CGRect(x: 0, y: 0, width: width, height: height)
        let queue = DispatchQueue(label: "iris.live.movie")
        var failed = false
        var finishedVideo = false

        vIn.requestMediaDataWhenReady(on: queue) {
            while vIn.isReadyForMoreMediaData {
                guard let sb = vOut.copyNextSampleBuffer() else {
                    finishedVideo = true
                    vIn.markAsFinished()
                    return
                }
                guard let pool = adaptor.pixelBufferPool,
                      let srcPB = CMSampleBufferGetImageBuffer(sb) else { continue }
                var dstPB: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstPB)
                guard let dst = dstPB else { failed = true; vIn.markAsFinished(); return }

                let src = CIImage(cvPixelBuffer: srcPB)
                let scale = max(CGFloat(width) / src.extent.width, CGFloat(height) / src.extent.height)
                let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let crop = CGRect(
                    x: (scaled.extent.width - CGFloat(width)) / 2,
                    y: (scaled.extent.height - CGFloat(height)) / 2,
                    width: CGFloat(width), height: CGFloat(height)
                )
                let cropped = scaled
                    .cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
                context.render(cropped, to: dst, bounds: dstRect, colorSpace: CGColorSpaceCreateDeviceRGB())

                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if !adaptor.append(dst, withPresentationTime: pts) { failed = true; vIn.markAsFinished(); return }
            }
        }

        let mid = CMTimeMultiplyByFloat64(asset.duration, multiplier: 0.5)
        if let sample = stillTimeSample(stillFD, at: mid) {
            mIn.append(sample)
        }
        mIn.markAsFinished()

        func finishIfReady() {
            if failed || writer.status == .failed {
                writer.cancelWriting()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if !finishedVideo {
                queue.asyncAfter(deadline: .now() + 0.1) { finishIfReady() }
                return
            }
            writer.finishWriting {
                DispatchQueue.main.async { completion(writer.status == .completed ? out : nil) }
            }
        }
        queue.asyncAfter(deadline: .now() + 0.1) { finishIfReady() }
    }

    private static func stillTimeFormatDescription() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String
        ]
        var desc: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    private static func stillTimeSample(_ desc: CMFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: 1,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 1,
            flags: 0,
            blockBufferOut: &block
        )
        guard st == kCMBlockBufferNoErr, let bb = block else { return nil }
        var zero: Int8 = 0
        CMBlockBufferReplaceDataBytes(with: &zero, blockBuffer: bb, offsetIntoDestination: 0, dataLength: 1)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var size = 1
        var sample: CMSampleBuffer?
        let cs = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: desc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        return cs == noErr ? sample : nil
    }
}
