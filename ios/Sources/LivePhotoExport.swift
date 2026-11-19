import Foundation
import Photos
import UIKit
import AVFoundation

/// 把页面导出的「实况配对素材 ZIP」（封面 + 视频）写成相册里的原生 Live Photo。
///
/// 页面产出的是 ZIP（store 方式，无压缩）：
///   封面.jpg / .png / .webp  +  动态.mp4 / .mov（个别浏览器会退成 .webm）
/// 这里解出两个文件，再用 PHAssetCreationRequest 同时添加 photo 与 pairedVideo，
/// 系统就会把它认成一张真正的实况照片，用户不用再去快捷指令里重新配对。
enum LivePhotoExport {

    /// 识别成功并开始写相册时返回 true；不是配对包就返回 false 走原来的保存逻辑。
    @discardableResult
    static func saveIfPair(zipURL: URL, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let data = try? Data(contentsOf: zipURL) else { return false }
        let entries = MiniZip.read(data)
        guard !entries.isEmpty else { return false }

        let imageExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "webp"]
        let videoExts: Set<String> = ["mov", "mp4", "m4v"]

        let images = entries.filter { imageExts.contains($0.ext) && $0.data.count > 1024 }
        let videos = entries.filter { videoExts.contains($0.ext) && $0.data.count > 1024 }

        // 没有视频的包：可能是实况录制失败的兜底包（只有封面），存成静态图；
        // 但「打包全格式」一次给三张图，那种要继续走原来的分享逻辑，不能误存。
        if videos.isEmpty {
            guard images.count == 1, let only = images.first else { return false }
            let name = only.name.isEmpty ? "Iris.png" : only.name
            let url = tempURL(name)
            try? only.data.write(to: url)
            saveStill(url, completion: completion)
            return true
        }
        guard let image = images.first, let video = videos.first else { return false }

        // 照片：JPEG / HEIC 直接用；PNG、WebP 转成 JPEG（Live Photo 的静态资源只认这两种）
        let base = (image.name as NSString).deletingPathExtension
        var photoURL: URL
        var photoName = base + "." + image.ext
        if image.ext == "jpg" || image.ext == "jpeg" || image.ext == "heic" || image.ext == "heif" {
            photoURL = tempURL(photoName)
            try? image.data.write(to: photoURL)
        } else {
            guard let ui = UIImage(data: image.data),
                  let jpg = ui.jpegData(compressionQuality: 0.95) else { return false }
            photoName = base + ".jpg"          // PNG / WebP 转码后扩展名跟着变，避免相册里名字与实际格式不符
            photoURL = tempURL(photoName)
            try? jpg.write(to: photoURL)
        }

        let videoURL = tempURL(base + "." + video.ext)
        try? video.data.write(to: videoURL)

        save(photo: photoURL, video: videoURL, photoName: photoName,
             videoName: base + "." + video.ext, completion: completion)
        return true
    }

    static func saveFiles(photo: URL, video: URL, photoName: String, videoName: String,
                          completion: ((Bool) -> Void)?) {
        save(photo: photo, video: video, photoName: photoName, videoName: videoName, completion: completion)
    }

    static func saveStillForFallback(_ url: URL) {
        saveStill(url, completion: nil)
    }

    private static func saveStill(_ url: URL, completion: ((Bool) -> Void)?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async { completion?(ok) }
            }
        }
    }

    private static func save(photo: URL, video: URL, photoName: String, videoName: String,
                             completion: ((Bool) -> Void)?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            // 相册对「配对视频」只认 QuickTime 容器，MediaRecorder 出来的 mp4 先转一层。
            ensureMov(video: video, originalName: videoName) { mov, movName in
                guard let mov = mov else {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    let po = PHAssetResourceCreationOptions()
                    po.originalFilename = photoName
                    req.addResource(with: .photo, fileURL: photo, options: po)
                    let vo = PHAssetResourceCreationOptions()
                    vo.originalFilename = movName
                    req.addResource(with: .pairedVideo, fileURL: mov, options: vo)
                }) { ok, _ in
                    DispatchQueue.main.async { completion?(ok) }
                }
            }
        }
    }

    private static func ensureMov(video: URL, originalName: String,
                                  completion: @escaping (URL?, String) -> Void) {
        if video.pathExtension.lowercased() == "mov" {
            completion(video, originalName)
            return
        }
        let asset = AVURLAsset(url: video)
        guard asset.tracks(withMediaType: .video).count > 0,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(nil, originalName)
            return
        }
        let out = video.deletingPathExtension().appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mov
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status == .completed {
                    completion(out, (originalName as NSString).deletingPathExtension + ".mov")
                } else {
                    completion(nil, originalName)
                }
            }
        }
    }

    private static func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-live-export", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(name)
    }
}

/// 只够用的 ZIP 读取：支持 store（method 0），页面产出的包就是这个格式。
struct ZipItem {
    let name: String
    let data: Data
    var ext: String { (name as NSString).pathExtension.lowercased() }
}

enum MiniZip {
    static func read(_ data: Data) -> [ZipItem] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { return [] }
        let count = Int(u16(bytes, eocd + 10))
        let cdOffset = Int(u32(bytes, eocd + 16))
        guard cdOffset > 0, cdOffset < bytes.count else { return [] }

        var p = cdOffset
        var out: [ZipItem] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x02014b50 else { break }
            let method = u16(bytes, p + 10)
            let compSize = Int(u32(bytes, p + 20))
            let nameLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            let localOff = Int(u32(bytes, p + 42))
            guard p + 46 + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[(p + 46)..<(p + 46 + nameLen)], encoding: .utf8) ?? ""
            let next = p + 46 + nameLen + extraLen + commentLen

            if method == 0, localOff + 30 <= bytes.count {
                let lName = Int(u16(bytes, localOff + 26))
                let lExtra = Int(u16(bytes, localOff + 28))
                let start = localOff + 30 + lName + lExtra
                let end = start + compSize
                if start >= 0, end <= bytes.count, end >= start {
                    out.append(ZipItem(name: name, data: Data(bytes[start..<end])))
                }
            }
            p = next
        }
        return out
    }

    private static func findEOCD(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        let lower = max(0, b.count - 65557)
        var i = b.count - 22
        while i >= lower {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o + 2 <= b.count else { return 0 }
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
