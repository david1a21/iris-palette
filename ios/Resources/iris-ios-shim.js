/* Iris iOS 外壳适配层：只在 WKWebView 里注入，页面本身不动
   - 把「造 a 标签 + click」的导出接成原生存档（iOS 上 blob 下载会静默失败）
   - 补安全区（页面用了 viewport-fit=cover 但没有 env()）
   - 放宽系统选择器对 .cube / .heic 的过滤
   - 三道闸，避免页面初始化时的临时图片被当成用户导出写进相册            */
(function () {
  if (window.__irisIOSBridge) return;
  window.__irisIOSBridge = true;

  var H = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.iris) || null;
  if (!H) return;

  /* ---------- 0) 抬高录制码率 ----------
     页面的 recordLiveClip 用 MediaRecorder 默认码率，录出来很软；
     这里包一层，凡是页面发起的录制都按 12 Mbps 走，画面细节能保住。 */
  (function () {
    try {
      var Orig = window.MediaRecorder;
      if (!Orig || Orig.__irisPatched) return;
      function Patched(stream, opts) {
        var o = {};
        if (opts) for (var k in opts) { if (Object.prototype.hasOwnProperty.call(opts, k)) o[k] = opts[k]; }
        if (!o.videoBitsPerSecond) o.videoBitsPerSecond = 12000000;
        return new Orig(stream, o);
      }
      Patched.prototype = Orig.prototype;
      Patched.isTypeSupported = Orig.isTypeSupported.bind(Orig);
      Patched.__irisPatched = true;
      window.MediaRecorder = Patched;
    } catch (e) {}
  })();

  /* ---------- 1) 手势闸 ---------- */
  var BOOT_AT = Date.now();
  var BOOT_GRACE = 2500;
  var LAST_GESTURE = -1e9;

  function mark(ev) {
    if (ev && ev.isTrusted === false) return;
    LAST_GESTURE = Date.now();
  }
  ['pointerdown', 'touchstart', 'mousedown', 'keydown'].forEach(function (t) {
    window.addEventListener(t, mark, true);
  });

  /* ---------- 2) 记录页面造过的 Blob ---------- */
  var blobs = new Map();
  var _create = URL.createObjectURL;
  URL.createObjectURL = function (obj) {
    var u = _create.apply(URL, arguments);
    try { if (obj instanceof Blob) blobs.set(u, obj); } catch (e) {}
    return u;
  };
  var _revoke = URL.revokeObjectURL;
  URL.revokeObjectURL = function (u) {
    try { setTimeout(function () { blobs.delete(u); }, 8000); } catch (e) {}
    return _revoke.apply(URL, arguments);
  };

  var OK_EXT = {
    png: 1, jpg: 1, jpeg: 1, webp: 1, gif: 1, heic: 1,
    mp4: 1, m4v: 1, mov: 1, zip: 1, json: 1, cube: 1
  };

  function extOf(name) {
    var m = /\.([a-z0-9]{2,5})(?=$|\?)/i.exec(name || '');
    return m ? m[1].toLowerCase() : '';
  }

  function allowed(name, blob) {
    // 以前要求「1.5 秒内有过手势」，但实况配对要先录 6 秒才下载，
    // 等文件出来时手势早过期了，导出会被静默吞掉。改成只要启动后有过一次真实手势即可。
    if (LAST_GESTURE < BOOT_AT) return false;
    if (!blob || blob.size < 64) return false;
    var e = extOf(name);
    if (e && !OK_EXT[e]) return false;
    var t = blob.type || '';
    if (t && !/^(image\/|video\/|application\/zip|application\/json|text\/plain)/.test(t)) return false;
    return true;
  }

  function send(obj) {
    try { H.postMessage(obj); } catch (e) {}
  }

  /* ---------- 3) 分块传原生：32KB 一块 ---------- */
  function save(name, blob) {
    return new Promise(function (resolve) {
      send({ op: 'begin', name: String(name || ''), mime: blob.type || 'application/octet-stream' });
      var STEP = 32768;
      var pos = 0;
      var dead = false;

      function next() {
        if (dead) return;
        if (pos >= blob.size) {
          send({ op: 'end', name: String(name || '') });
          resolve(true);
          return;
        }
        var end = Math.min(pos + STEP, blob.size);
        var reader = new FileReader();
        reader.onload = function () {
          var s = String(reader.result || '');
          var i = s.indexOf(',');
          send({ op: 'chunk', b64: i >= 0 ? s.slice(i + 1) : s });
          pos = end;
          next();
        };
        reader.onerror = function () { dead = true; resolve(false); };
        reader.readAsDataURL(blob.slice(pos, end));
      }
      next();
    });
  }

  function liveLoaded() {
    var b = document.getElementById('liveBadge');
    return !!(b && b.classList.contains('on'));
  }

  function exportLiveNative() {
    try { if (typeof toast === 'function') toast('正在生成实况照片…'); } catch (e) {}
    send({ op: 'exportLive' });
  }

  /* 页面的「导出实况配对素材」原本会造一个 ZIP 让用户去快捷指令重新配对。
     这里直接在捕获阶段拦下来，改走原生一次性写入，不再产生配对包。 */
  document.addEventListener('click', function (ev) {
    var el = ev.target;
    while (el && el !== document) {
      if (el.getAttribute && el.getAttribute('data-act') === 'pair') {
        ev.preventDefault();
        ev.stopPropagation();
        exportLiveNative();
        return;
      }
      el = el.parentElement;
    }
  }, true);

  function intercept(link) {
    if (Date.now() - BOOT_AT < BOOT_GRACE) return false;

    var href = link.href || '';
    var name = link.getAttribute('download') || link.download || ('Iris_' + Date.now() + '.png');

    /* 画面里已经载入实况时，「导出照片」出来的只会是静态图。
       这里换成页面自己的「导出实况配对素材」，交给原生写成一张真正的 Live Photo。 */
    var ex = extOf(name);
    if (ex && /^(png|jpg|jpeg|webp)$/.test(ex) && liveLoaded()) {
      exportLiveNative();
      return true;
    }

    var blob = blobs.get(href);
    if (blob) {
      if (!allowed(name, blob)) return false;
      save(name, blob);
      return true;
    }
    if (href.indexOf('blob:') === 0) {
      fetch(href).then(function (r) { return r.blob(); })
        .then(function (b) { if (allowed(name, b)) save(name, b); })
        .catch(function () {});
      return true;
    }
    return false;
  }

  /* ---------- 3.5) 实况照片：选图改走原生 PHPicker ----------
     页面点「＋ 换照片」本质是 input#file.click()。这里拦下来交给原生：
     原生从相簿里取「照片 + 配对视频」两段资源，按同名送回来，
     页面自己就会认成一组实况。普通照片 / 视频也走同一条路。          */
  var _inputClick = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function () {
    try {
      if (this.id === 'file' && Date.now() - LAST_GESTURE < 1500) {
        send({ op: 'pickPhotos' });
        return;
      }
    } catch (e) {}
    return _inputClick.apply(this, arguments);
  };

  /* 原生分块送来的实况素材：按文件名攒齐后拼成 File，塞进 input#file */
  var LIVE_FILES = {}, LIVE_ANNOUNCED = 0, LIVE_ENDED = 0;

  function attachLiveFiles() {
    var input = document.getElementById('file');
    if (!input) return;
    var dt = new DataTransfer();
    Object.keys(LIVE_FILES).forEach(function (name) {
      var e = LIVE_FILES[name];
      var bin = atob(e.parts.join(''));
      var u8 = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
      dt.items.add(new File([u8], name, { type: e.mime || '' }));
    });
    LIVE_FILES = {}; LIVE_ANNOUNCED = 0; LIVE_ENDED = 0;
    if (!dt.files.length) return;
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  window.__irisLiveFile = function (name, mime, total) {
    LIVE_FILES[name] = { mime: mime, total: total, parts: new Array(total), got: 0 };
    LIVE_ANNOUNCED += 1;
  };
  window.__irisLiveChunk = function (name, idx, b64) {
    var e = LIVE_FILES[name];
    if (!e) return;
    e.parts[idx] = b64;
  };
  window.__irisLiveFileEnd = function (name) {
    if (!LIVE_FILES[name]) return;
    LIVE_ENDED += 1;
    if (LIVE_ENDED >= LIVE_ANNOUNCED) attachLiveFiles();
  };

  var _click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    try {
      if (this.hasAttribute('download') && intercept(this)) return;
    } catch (e) {}
    return _click.apply(this, arguments);
  };

  window.addEventListener('click', function (ev) {
    var el = ev.target;
    while (el && el.tagName !== 'A') el = el.parentElement;
    if (!el || !el.hasAttribute('download')) return;
    if (intercept(el)) ev.preventDefault();
  }, true);

  /* ---------- 4) 界面补丁：安全区 / 选择器 ---------- */
  function patchUI() {
    try {
      var s = document.createElement('style');
      s.id = 'iris-ios-patch';
      s.textContent = [
        '.topbar{padding-top:calc(env(safe-area-inset-top,0px) + 9px) !important}',
        '.dock{padding-bottom:env(safe-area-inset-bottom,0px) !important}',
        /* 二级页面（说明书 / 快捷键 / 导出 / 关于…）原来是 inset:0 的全屏层，
           顶栏贴着屏幕最上沿，状态栏正好压住左边的「‹ 返回」和右边的关闭键。
           这里让整个二级页下移一个状态栏高度，返回键就落在安全区里了。 */
        '.subpage{padding-top:env(safe-area-inset-top,0px) !important}',
        '.subpage>.sp-body{padding-bottom:calc(18px + env(safe-area-inset-bottom,0px)) !important}',
        'html,body{overscroll-behavior:none}',
        'img{-webkit-user-drag:none}'
      ].join('');
      (document.head || document.documentElement).appendChild(s);

      var photo = document.getElementById('file');
      if (photo) photo.setAttribute('accept', 'image/*,video/*');
      var cube = document.getElementById('cubeFile');
      if (cube) cube.setAttribute('accept', '*/*');
      var json = document.getElementById('jsonFile');
      if (json) json.setAttribute('accept', '.json,application/json,text/plain,*/*');
    } catch (e) {}
  }

  /* ---------- 5) 侧滑返回的落点 ----------
     原生从屏幕左缘往右滑时会调这里。页面里有「二级页面」叠在上面就先关它，
     否则交给原生去走 WebView 自己的历史；都没有就不做任何事。            */
  window.__irisNativeBack = function () {
    var sp = document.getElementById('subPage');
    if (sp && sp.classList.contains('show')) {
      try {
        if (typeof closeSubPage === 'function') { closeSubPage(); return true; }
        var back = document.getElementById('spBack');
        if (back) { back.click(); return true; }
      } catch (e) {}
    }
    return false;
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', patchUI);
  } else {
    patchUI();
  }
})();
