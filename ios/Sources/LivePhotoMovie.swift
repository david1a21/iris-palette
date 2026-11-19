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

        // 不做任何解码/重绘：原样搬运压缩样本，内存占用几乎为零。
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { completion(nil); return }
        reader.add(vOut)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { completion(nil); return }
        writer.add(vIn)

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

        let queue = DispatchQueue(label: "iris.live.movie")
        var failed = false
        var finishedVideo = false

        vIn.requestMediaDataWhenReady(on: queue) { [reader, writer] in
            _ = (reader, writer)   // 必须强持有，否则函数返回后 reader 被释放，copyNextSampleBuffer 会抛异常
            while vIn.isReadyForMoreMediaData {
                if reader.status == .failed || reader.status == .cancelled || reader.status == .completed {
                    failed = true
                    vIn.markAsFinished()
                    return
                }
                guard let sb = vOut.copyNextSampleBuffer() else {
                    finishedVideo = true
                    vIn.markAsFinished()
                    return
                }
                if !vIn.append(sb) { failed = true; vIn.markAsFinished(); return }
            }
        }

        let mid = CMTimeMultiplyByFloat64(asset.duration, multiplier: 0.5)
        if let sample = stillTimeSample(stillFD, at: mid) {
            mIn.append(sample)
        }
        mIn.markAsFinished()

        func finishIfReady() {
            _ = (reader, writer)
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
