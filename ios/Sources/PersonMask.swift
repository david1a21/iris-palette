import Foundation
import UIKit
import Vision

/// 人像蒙版：把页面送来的缩小副本交给系统 Vision，回一张灰度 PNG。
/// 白＝主体，黑＝背景，中间灰＝软边缘（这正是页面 u_subject 要的口径）。
///
/// 两条路：
/// · iOS 17+ 用 VNGenerateForegroundInstanceMaskRequest，能按输入分辨率给出**软蒙版**，
///   发丝边缘留得下来；
/// · iOS 16 退回 VNGeneratePersonSegmentationRequest（.accurate），
///   分辨率是模型自身的（约 384×512），放大到导出尺寸时边缘会软一些。
enum PersonMask {

    static func generate(jpegBase64: String,
                         completion: @escaping (String?, Int, Int, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Data(base64Encoded: jpegBase64),
                  let img = UIImage(data: data),
                  let cg = img.cgImage else {
                DispatchQueue.main.async { completion(nil, 0, 0, "输入图片无法解码") }
                return
            }

            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])

            if #available(iOS 17.0, *) {
                let req = VNGenerateForegroundInstanceMaskRequest()
                do {
                    try handler.perform([req])
                    if let obs = req.results?.first {
                        let buf = try obs.createScaledMask(
                            for: obs.allInstances, croppedToInstancesContent: false)
                        if let png = pngBase64(buf) {
                            let w = CVPixelBufferGetWidth(buf)
                            let h = CVPixelBufferGetHeight(buf)
                            DispatchQueue.main.async { completion(png, w, h, "foreground") }
                            return
                        }
                    }
                } catch {
                    // 前景实例失败就落到人像分割，不在这里放弃
                }
            }

            let req = VNGeneratePersonSegmentationRequest()
            req.revision = VNGeneratePersonSegmentationRequest.Revision.revision1
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do {
                try handler.perform([req])
                if let obs = req.results?.first {
                    let buf = obs.pixelBuffer
                    if let png = pngBase64(buf) {
                        let w = CVPixelBufferGetWidth(buf)
                        let h = CVPixelBufferGetHeight(buf)
                        DispatchQueue.main.async { completion(png, w, h, "person") }
                        return
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(nil, 0, 0, "分割请求失败：\(error.localizedDescription)") }
                return
            }

            DispatchQueue.main.async { completion(nil, 0, 0, "画面里没有检测到人物") }
        }
    }

    /// 直接把蒙版像素写成灰度 PNG，不走 CoreImage 的色彩管理——
    /// 否则 float 0~1 的软蒙版经 sRGB 曲线往返会被压暗，边缘权重就偏了。
    private static func pngBase64(_ buf: CVPixelBuffer) -> String? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }

        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buf) else { return nil }

        var gray = [UInt8](repeating: 0, count: w * h)
        if CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent32Float {
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
                for x in 0..<w {
                    let v = row[x]
                    gray[y * w + x] = UInt8(max(0, min(255, (v.isFinite ? v : 0) * 255 + 0.5)))
                }
            }
        } else {
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { gray[y * w + x] = row[x] }
            }
        }

        var out: Data?
        if let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue),
           let dst = ctx.data {
            gray.withUnsafeBytes { raw in
                if let src = raw.baseAddress { dst.copyMemory(from: src, byteCount: w * h) }
            }
            if let cg = ctx.makeImage() { out = UIImage(cgImage: cg).pngData() }
        }
        return out?.base64EncodedString()
    }
}
