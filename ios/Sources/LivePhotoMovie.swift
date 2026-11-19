import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import Darwin

/// 把一段普通视频变成「实况照片可用的 MOV」：
///   1. 画幅对齐静态帧的长宽比（居中裁切，长边封顶），这才是 PhotoKit 判 InvalidResource 的主因
///   2. 资产级 metadata：com.apple.quicktime.content.identifier
///   3. metadata 轨道：com.apple.quicktime.still-image-time，放在片子中间
enum LivePhotoMovie {

    /// 系统实况里这个标识其实是 UUID 形态的字符串，随手拼 22 位字母数字并不合法。
    static func makeIdentifier() -> String {
        UUID().uuidString
    }

    static func wrap(video: URL, identifier: String, targetSize: CGSize,
                     completion: @escaping (URL?) -> Void) {
        guard targetSize.width > 0, targetSize.height > 0 else { completion(nil); return }
        normalize(video: video, targetSize: targetSize) { normalized in
            guard let normalized = normalized else { completion(nil); return }
            addMetadata(video: normalized, identifier: identifier, completion: completion)
        }
    }

    // MARK: - 画幅对齐

    private static func normalize(video: URL, targetSize: CGSize,
                                  completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first else { completion(nil); return }

        let transform0 = vTrack.preferredTransform
        let disp = CGRect(origin: .zero, size: vTrack.naturalSize).applying(transform0)
        let dw = abs(disp.width), dh = abs(disp.height)
        guard dw > 0, dh > 0 else { completion(nil); return }

        let tw = CGFloat(Int(targetSize.width.rounded()))
        let th = CGFloat(Int(targetSize.height.rounded()))
        let targetAspect = tw / th
        let currentAspect = dw / dh

        // 画幅已经一致就不用再动它，纯搬运即可。
        if abs(targetAspect - currentAspect) < 0.02 {
            completion(video)
            return
        }

        let comp = AVMutableComposition()
        guard let cTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil); return
        }
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        try? cTrack.insertTimeRange(range, of: vTrack, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cTrack)

        let scale = max(tw / dw, th / dh)
        var transform = transform0.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaled = CGRect(origin: .zero, size: vTrack.naturalSize).applying(transform)
        let tx = (tw - scaled.width) / 2 - scaled.minX
        let ty = (th - scaled.height) / 2 - scaled.minY
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: tw, height: th)
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instruction]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-live-norm-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: out)
        guard let exporter = AVAssetExportSession(asset: comp,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil); return
        }
        exporter.outputURL = out
        exporter.outputFileType = .mov
        exporter.videoComposition = vc
        exporter.shouldOptimizeForNetworkUse = false

        exporter.exportAsynchronously {
            _ = exporter          // 必须强持有到导出结束
            if exporter.status == .completed, exporter.error == nil {
                completion(out)
            } else {
                let fallback = video
                _ = fallback
                completion(nil)
            }
        }
    }

    // MARK: - 补 metadata 并重新封容器

    private static func addMetadata(video: URL, identifier: String,
                                    completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: video)
        guard let vTrack = asset.tracks(withMediaType: .video).first,
              let stillFD = stillTimeFormatDescription() else {
            completion(nil); return
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-live-wrap-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: out)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else {
            completion(nil); return
        }

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
            _ = (reader, writer)
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

    // MARK: - still-image-time

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
