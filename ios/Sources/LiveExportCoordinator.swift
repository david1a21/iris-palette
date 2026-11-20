import UIKit
import WebKit
import Photos

/// 原生实况导出：直接从页面拿「封面 + 动态」两段素材，一次写成相册里的 Live Photo。
/// 动态优先走「逐帧离线合成」：页面按 1/30 秒精确 seek、逐帧渲染成 JPEG，
/// 原生用 AVAssetWriter 以固定时间戳写 MOV，帧数确定、不掉帧；
/// 逐帧失败时才退回实时录制，仍未拿到 MP4 再用原片。
final class LiveExportCoordinator {

    weak var webView: WKWebView?
    var onAlert: ((String, String) -> Void)?
    var onSaved: ((Bool) -> Void)?

    private var handles: [String: FileHandle] = [:]
    private var sources: [String: String] = [:]
    private var urls: [String: URL] = [:]
    private var names: [String: String] = [:]

    // 逐帧离线合成
    private var frames: [Data] = []
    private var frameTotal = 0
    private var frameWidth = 0
    private var frameHeight = 0
    private var frameFPS = 30
    private var capturingFrames = false

    func start() {
        guard let web = webView else { return }
        let js = #"""
        (async function(){
          var H = window.webkit.messageHandlers.iris;
          function fail(msg){ try{ H.postMessage({op:'liveFail', msg:msg}); }catch(e){} }
          function b64(blob){
            return new Promise(function(res, rej){
              var fr = new FileReader();
              fr.onload = function(){ var s = String(fr.result||''); var i = s.indexOf(','); res(i>=0 ? s.slice(i+1) : s); };
              fr.onerror = rej;
              fr.readAsDataURL(blob);
            });
          }
          async function push(kind, name, mtype, blob, src){
            H.postMessage({op:'liveBegin', kind:kind, name:name, mime:mtype, bytes:blob.size, source:src});
            var STEP = 131072, pos = 0;
            while(pos < blob.size){
              var end = Math.min(pos + STEP, blob.size);
              var s = await b64(blob.slice(pos, end));
              H.postMessage({op:'liveChunk', kind:kind, b64:s});
              pos = end;
            }
            H.postMessage({op:'liveEnd', kind:kind});
          }
          /* 逐帧离线：暂停播放，按 1/fps 精确 seek，渲染当前帧后整帧交给原生。
             帧数固定，不存在实时录制那种「某帧没赶上就永久丢」的问题。 */
          async function captureFrames(){
            var v = LIVE.video;
            if(!v || v.readyState < 1 || !v.videoWidth) return false;
            var dur = Math.max(.2, Math.min(4, LIVE.duration || v.duration || 1.5));
            var fps = 30;
            var n = Math.max(2, Math.min(120, Math.round(dur * fps)));
            /* v1.0.35：动态轨尺寸从「封面画布的真实像素」推（页面 liveTargetDims），
               不再用 exportDims —— 后者可能带画框 / 被预览尺寸影响，导致封面与动态轨比例不同，
               系统播放时按封面矩形拉伸视频 → 画面被压扁。 */
            var W, Hh;
            try{
              var td = liveTargetDims();
              W = td[0]; Hh = td[1];
            }catch(e0){
              var dm = exportDims();
              var k = Math.min(1, 1440 / Math.max(dm[0], dm[1]));
              W = Math.max(2, Math.round(dm[0] * k));
              Hh = Math.max(2, Math.round(dm[1] * k));
            }
            H.postMessage({op:'liveFramesBegin', n:n, w:W, h:Hh, fps:fps});
            try{ v.pause(); }catch(e){}
            /* 析帧时关掉原图对比，否则抓到的帧会是未经处理的原片 */
            try{ comparing = false; }catch(e){}
            LIVE.recording = true; LIVE.recordDims = [W, Hh]; LIVE.playing = true;
            /* v1.0.36：录制 / 合成的每一帧都由主画布按目标尺寸全分辨率渲染，
               不再从几百像素的预览画布放大 —— 否则 1440 的轨道里全是插值马赛克。 */
            LIVE.exportRender = {w:W, h:Hh};
            var scratch = document.createElement('canvas'); scratch.width = W; scratch.height = Hh;
            function seek(t){
              return new Promise(function(res){
                var done = false;
                function f(){ if(done) return; done = true; try{ v.removeEventListener('seeked', f); }catch(e){} res(); }
                try{ v.addEventListener('seeked', f, {once:true}); v.currentTime = t; }catch(e){}
                setTimeout(f, 400);
              });
            }
            try{
              for(var i=0;i<n;i++){
                await seek(Math.min(i / fps, Math.max(0, dur - 0.001)));
                /* 强制上传这一帧：paintFrame 里按录制帧率做了上传节流，seek 后必须重置 */
                LIVE.lastUpload = 0;
                try{ paintFrame(); }catch(e){}
                // 立刻把 WebGL 画布同步拷到 2D 画布，再从 2D 画布编码：
                // 避免 WebGL 缓冲区在合成后被清空导致抓到黑帧。
                /* v1.0.35：等比裁切绘制。以前是 drawImage(canvas,0,0,W,Hh) 硬拉伸，
                   预览画布比例（视口比例）与照片比例不同时，逐帧画面就被压扁。 */
                try{
                  var sctx = scratch.getContext('2d');
                  if(typeof liveDrawFitted === 'function') liveDrawFitted(sctx, canvas, W, Hh);
                  else sctx.drawImage(canvas, 0, 0, W, Hh);
                }catch(e){}
                var blob = await new Promise(function(r){ scratch.toBlob(r, 'image/jpeg', 0.92); });
                if(!blob) throw new Error('frame encode failed');
                H.postMessage({op:'liveFrame', i:i, b64: await b64(blob)});
              }
            }catch(e){
              try{ H.postMessage({op:'liveFramesCancel'}); }catch(_){}
              LIVE.exportRender = null;
              LIVE.playing = false; LIVE.recording = false; LIVE.recordDims = null;
              try{ render(); }catch(e){} return false;
            }
            LIVE.exportRender = null;
            LIVE.playing = false; LIVE.recording = false; LIVE.recordDims = null;
            try{ render(); }catch(e){}
            return true;
          }
          try{
            if (typeof LIVE === 'undefined' || !LIVE.pair) { fail('当前画面没有实况视频'); return; }
            var vf = LIVE.vidFile;
            if(!vf) throw new Error('没有找到导入的实况动态片段');
            var cover = await canvasToBlob(typeof liveCoverCanvas === 'function' ? liveCoverCanvas() : renderExportCanvas(), 'image/jpeg', 0.95);
            var base = 'LivePhoto';
            try{ base = LIVE.baseName || (LIVE.imgName ? liveBase(LIVE.imgName) : '') || liveBase(vf.name) || 'LivePhoto'; }catch(e){}
            await push('photo', base + '.jpg', 'image/jpeg', cover, 'image');

            // 一、逐帧离线合成（首选）
            var offline = false;
            try{ offline = await captureFrames(); }catch(e){ offline = false; }

            if(!offline){
              // 二、实时录制（退回）
              async function rec(m){
                try{ var c = m ? await recordLiveClip(m) : await recordLiveClip(); if(c && c.size > 2048) return c; }catch(e){}
                return null;
              }
              var clip = await rec('video/mp4;codecs=avc1.42E01E') || await rec('video/mp4') || await rec();
              var recorded = !!clip && !/webm/i.test(clip.type || '');
              if(!recorded){
                clip = vf;
                try{ H.postMessage({op:'liveNote', msg:'动态逐帧合成与实时录制都未成功，已使用原片动态（不含滤镜）'}); }catch(e){}
              }
              var vext = '.mov';
              if(recorded){
                vext = /mp4/i.test(clip.type || '') ? '.mp4' : ((clip.type||'').indexOf('quicktime') >= 0 ? '.mov' : '.mp4');
              } else {
                var vm = /\.([a-z0-9]+)$/i.exec(vf.name || '');
                vext = vm ? ('.' + vm[1].toLowerCase()) : '.mov';
              }
              await push('video', base + vext, recorded ? (clip.type || 'video/mp4') : (vf.type || 'video/quicktime'), clip || vf, recorded ? 'recorded' : 'original');
            }
          }catch(e){
            fail(String(e && e.message || e));
          }
        })();
        """#
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 封面 / 退回路径的字节流

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

    // MARK: - 逐帧离线合成

    func beginFrames(_ body: [String: Any]) {
        frames.removeAll()
        frameTotal = (body["n"] as? Int) ?? 0
        frameWidth = (body["w"] as? Int) ?? 0
        frameHeight = (body["h"] as? Int) ?? 0
        frameFPS = max(1, (body["fps"] as? Int) ?? 30)
        capturingFrames = true
    }

    func appendFrame(_ body: [String: Any]) {
        guard capturingFrames,
              let b64 = body["b64"] as? String,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
        frames.append(data)
        guard frameTotal > 0, frames.count >= frameTotal else { return }
        capturingFrames = false
        encodeFramesAndSave()
    }

    func cancelFrames() {
        capturingFrames = false
        frames.removeAll()
    }

    private func encodeFramesAndSave() {
        let all = frames
        frames.removeAll()
        guard let photo = urls["photo"], let photoName = names["photo"] else { return }

        let base = (photoName as NSString).deletingPathExtension
        let movie = Self.dir().appendingPathComponent(base + ".mov")
        let w = frameWidth, h = frameHeight, fps = frameFPS

        LiveFrames.encode(frames: all, width: w, height: h, fps: fps, to: movie) { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.onAlert?("实况保存失败", "逐帧合成没有产出可用的视频，请重试一次。")
                return
            }
            LivePhotoExport.saveFiles(photo: photo, video: movie, photoName: photoName,
                                      videoName: base + ".mov", videoIsRecorded: true) { ok2 in
                self.urls.removeAll(); self.names.removeAll(); self.sources.removeAll()
                self.onSaved?(ok2)
                if !ok2 {
                    LivePhotoExport.saveStillForFallback(photo)
                    let detail = LivePhotoExport.lastError
                    let ctx = LivePhotoExport.lastContext
                    self.onAlert?("实况保存失败", "封面已单独存成照片。原因：\(detail)（\(ctx)）")
                }
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
