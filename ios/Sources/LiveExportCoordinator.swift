import UIKit
import WebKit
import Photos

/// 原生实况导出：直接从页面拿「封面 + 动态片段」两段字节，
/// 一次写成相册里的 Live Photo，不再经过 ZIP / 快捷指令。
final class LiveExportCoordinator {

    weak var webView: WKWebView?
    var onAlert: ((String, String) -> Void)?
    var onSaved: ((Bool) -> Void)?

    private var handles: [String: FileHandle] = [:]
    private var sources: [String: String] = [:]
    private var urls: [String: URL] = [:]
    private var names: [String: String] = [:]

    func start() {
        guard let web = webView else { return }
        let js = #"""
        (async function(){
          try{
            if (typeof LIVE === 'undefined' || !LIVE.pair) {
              window.webkit.messageHandlers.iris.postMessage({op:'liveFail', msg:'当前画面没有实况视频'});
              return;
            }
            var vf = LIVE.vidFile;
            if(!vf) throw new Error('没有找到导入的实况动态片段');
            var cover = await canvasToBlob(renderExportCanvas(), 'image/jpeg', 0.95);

            // 逐帧录制会把当前调色结果烘进动态片段；先要 mp4（AVFoundation 才读得动），失败再退回原片。
            async function rec(m){
              try{ var c = m ? await recordLiveClip(m) : await recordLiveClip(); if(c && c.size > 2048) return c; }catch(e){}
              return null;
            }
            var clip = await rec('video/mp4;codecs=avc1.42E01E') || await rec('video/mp4') || await rec();
            var recorded = !!clip && !/webm/i.test(clip.type || '');
            if(!recorded){
              clip = vf;
              try{ window.webkit.messageHandlers.iris.postMessage({op:'liveNote', msg:'动态片段录制失败，已使用原片动态（不含滤镜）'}); }catch(e){}
            }
            var base = 'LivePhoto';
            try{ base = LIVE.baseName || (LIVE.imgName ? liveBase(LIVE.imgName) : '') || liveBase(vf.name) || 'LivePhoto'; }catch(e){}
            var vext = '.mov';
            if(recorded){
              vext = /mp4/i.test(clip.type || '') ? '.mp4' : ((clip.type||'').indexOf('quicktime') >= 0 ? '.mov' : '.mp4');
            } else {
              var vm = /\.([a-z0-9]+)$/i.exec(vf.name || '');
              vext = vm ? ('.' + vm[1].toLowerCase()) : '.mov';
            }
            async function push(kind, name, mtype, blob, src){
              var H = window.webkit.messageHandlers.iris;
              H.postMessage({op:'liveBegin', kind:kind, name:name, mime:mtype, bytes:blob.size, source:src});
              var STEP = 131072, pos = 0;
              while(pos < blob.size){
                var end = Math.min(pos + STEP, blob.size);
                var b64 = await new Promise(function(res, rej){
                  var fr = new FileReader();
                  fr.onload = function(){ var s = String(fr.result||''); var i = s.indexOf(','); res(i>=0 ? s.slice(i+1) : s); };
                  fr.onerror = rej;
                  fr.readAsDataURL(blob.slice(pos, end));
                });
                H.postMessage({op:'liveChunk', kind:kind, b64:b64});
                pos = end;
              }
              H.postMessage({op:'liveEnd', kind:kind});
            }
            await push('photo', base + '.jpg', 'image/jpeg', cover, 'image');
            await push('video', base + vext, recorded ? (clip.type || 'video/mp4') : (vf.type || 'video/quicktime'), clip || vf, recorded ? 'recorded' : 'original');
          }catch(e){
            try{ window.webkit.messageHandlers.iris.postMessage({op:'liveFail', msg:String(e && e.message || e)}); }catch(_){}
          }
        })();
        """#
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    func begin(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String else { return }
        let name = (body["name"] as? String) ?? "part.bin"
        let url = Self.dir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        handles[kind] = fh
        urls[kind] = url
        names[kind] = name
        sources[kind] = (body["source"] as? String) ?? "original"
    }

    func append(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String,
              let b64 = body["b64"] as? String,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let fh = handles[kind] else { return }
        try? fh.write(contentsOf: data)
    }

    func end(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String else { return }
        try? handles[kind]?.close()
        handles[kind] = nil
        guard handles.isEmpty,
              let photo = urls["photo"], let video = urls["video"],
              let photoName = names["photo"], let videoName = names["video"] else { return }

        let p = photo, v = video, pn = photoName, vn = videoName
        let recorded = (sources["video"] == "recorded")
        urls.removeAll(); names.removeAll(); sources.removeAll()
        LivePhotoExport.saveFiles(photo: p, video: v, photoName: pn, videoName: vn,
                                  videoIsRecorded: recorded) { [weak self] ok in
            self?.onSaved?(ok)
            if !ok {
                LivePhotoExport.saveStillForFallback(p)
                let detail = LivePhotoExport.lastError
                let ctx = LivePhotoExport.lastContext
                self?.onAlert?("实况保存失败", "封面已单独存成照片。原因：\(detail)（\(ctx)）")
            }
        }
    }

    private static func dir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-live-native", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970 * 1000)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
