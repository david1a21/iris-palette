import Foundation
import AVFoundation
import CoreMedia
import Darwin

/// 把一段普通视频重新封装成「实况照片可用的 MOV」：
/// 保留原视频/音频轨道，额外写入
///   1. 资产级 metadata：com.apple.quicktime.content.identifier
///   2. 一条 metadata 轨道：com.apple.quicktime.still-image-time（值 0，PTS 0）
/// Photos 的配对校验认的正是这两样。
enum LivePhotoMovie {

    /// 生成 22 位实况标识（与系统相机同长度）
    static func makeIdentifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<22).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    static func wrap(video: URL, identifier: String, completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil); return
        }
        guard let stillFD = stillTimeFormatDescription() else {
            completion(nil); return
        }

        let out = video.deletingPathExtension().appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: out)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else {
            completion(nil); return
        }

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { completion(nil); return }
        reader.add(vOut)

        let vFormat = (vTrack.formatDescriptions.first as! CMFormatDescription)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { completion(nil); return }
        writer.add(vIn)

        var aOut: AVAssetReaderTrackOutput?
        var aIn: AVAssetWriterInput?
        if let aTrack = asset.tracks(withMediaType: .audio).first {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            let f = (aTrack.formatDescriptions.first as! CMFormatDescription)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: f)
            i.expectsMediaDataInRealTime = false
            if reader.canAdd(o) && writer.canAdd(i) {
                reader.add(o); writer.add(i)
                aOut = o; aIn = i
            }
        }

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

        if let sample = stillTimeSample(stillFD) {
            mIn.append(sample)
        }
        mIn.markAsFinished()

        DispatchQueue.global(qos: .userInitiated).async {
            while reader.status == .reading {
                var idle = true
                if vIn.isReadyForMoreMediaData {
                    if let sb = vOut.copyNextSampleBuffer() {
                        if vIn.append(sb) { idle = false }
                    } else {
                        vIn.markAsFinished()
                    }
                }
                if let ai = aIn, let ao = aOut, ai.isReadyForMoreMediaData {
                    if let sb = ao.copyNextSampleBuffer() {
                        if ai.append(sb) { idle = false }
                    } else {
                        ai.markAsFinished()
                    }
                }
                if idle { usleep(3000) }
            }
            if reader.status == .failed {
                writer.cancelWriting()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            writer.finishWriting {
                DispatchQueue.main.async {
                    completion(writer.status == .completed ? out : nil)
                }
            }
        }
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

    private static func stillTimeSample(_ desc: CMFormatDescription) -> CMSampleBuffer? {
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
            presentationTimeStamp: .zero,
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
