/* Iris 原生容器适配层：只在 WebView 环境注入，浏览器里保持原样 */
(function () {
  if (window.__irisNative) return;
  window.__irisNative = true;

  /* ---------- 1) 只补 WebView 特有的小坑，不动页面设计 ---------- */
  try {
    var s = document.createElement('style');
    s.id = 'iris-android-patch';
    s.textContent =
      'img{-webkit-user-drag:none}' +
      'canvas{touch-action:none}' +
      '::-webkit-selection{background:transparent}';
    (document.head || document.documentElement).appendChild(s);
  } catch (e) {}

  /* ---------- 2) 记录页面创建的 Blob，导出时直接取，绕开 fetch 的同源限制 ---------- */
  var blobs = new Map();
  var origCreate = URL.createObjectURL;
  URL.createObjectURL = function (obj) {
    var url = origCreate.apply(URL, arguments);
    try { if (obj instanceof Blob) blobs.set(url, obj); } catch (e) {}
    return url;
  };
  var origRevoke = URL.revokeObjectURL;
  URL.revokeObjectURL = function (url) {
    try { setTimeout(function () { blobs.delete(url); }, 8000); } catch (e) {}
    return origRevoke.apply(URL, arguments);
  };

  /* ---------- 2b) 只有「用户真的点了导出」才算导出 ----------
     页面内部把 Blob 变成图片预览、图标、缩略图时同样会走 createObjectURL + a[download]，
     如果只认 download 属性，任何自动触发的保存都会被误当成用户导出写进相册。
     这里要求：① 启动 2.5 秒内不接管（初始化阶段一律不碰）；
             ② 必须有 1.5 秒内的真实触摸/点击手势（isTrusted）；
             ③ 文件类型要在白名单内，且不是几十字节的占位图。            */
  var OK_EXT = {
    png: 1, jpg: 1, jpeg: 1, webp: 1, gif: 1, heic: 1,
    mp4: 1, m4v: 1, webm: 1, mov: 1, zip: 1, json: 1, cube: 1
  };

  /* 只认「像成品」的文件，不再认「多久以前的手势」：
     页面的导出是「点击 → 进度条 → 逐行编码 → 才 a.click()」，
     大图 / GIF / 实况 / 批量导出从点击到 click 常常好几秒。
     以前用 1.5 秒手势窗当闸门，慢一点的导出全被判成「不该我管」，
     漏给 WebView —— 而壳里没有下载器，文件就这么消失，相册自然找不到。 */
  function mimeAllowed(m) {
    if (!m) return true;
    if (m === 'application/octet-stream') return true;   /* 交给壳按扩展名兜底 */
    return /^(image\/|video\/|application\/(zip|x-zip-compressed)|application\/json|text\/plain)/.test(m);
  }

  function payloadOk(name, mime, size) {
    if (!(size > 64)) return false;                    /* 几十字节的图标/占位不算成品 */
    var ext = extOf(name);
    if (!ext) return /^(image|video)\//.test(mime || '');
    if (!OK_EXT[ext]) return false;
    return mimeAllowed(mime);
  }

  /* ---------- 3) 分块流式写盘：大视频 / 大 GIF 也不会把内存顶爆 ---------- */
  var chain = Promise.resolve();
  function enqueue(fn) {
    chain = chain.then(fn).catch(function () {});
    return chain;
  }

  function b64(u8) {
    var out = '';
    for (var i = 0; i < u8.length; i += 8192) {
      out += String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + 8192, u8.length)));
    }
    return btoa(out);
  }

  function extOf(name) {
    var m = /\.([a-z0-9]{2,5})(?=$|\?)/i.exec(name || '');
    return m ? m[1].toLowerCase() : '';
  }

  function mimeByName(name) {
    switch (extOf(name)) {
      case 'png': return 'image/png';
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'webp': return 'image/webp';
      case 'gif': return 'image/gif';
      case 'mp4': case 'm4v': return 'video/mp4';
      case 'webm': return 'video/webm';
      case 'mov': return 'video/quicktime';
      case 'zip': return 'application/zip';
      case 'json': return 'application/json';
      case 'cube': return 'text/plain';
      case 'heic': return 'image/heic';
      default: return 'application/octet-stream';
    }
  }

  function writeBlob(name, blob) {
    return enqueue(function () {
      return new Promise(function (resolve) {
        var bridge = window.IrisNative;
        if (!bridge) return resolve();
        var mime = blob.type || '';
        if (!mime || mime === 'application/octet-stream') mime = mimeByName(name);
        try { bridge.start(encodeURIComponent(name), mime); }
        catch (e) { try { bridge.note && bridge.note('导出未落盘：' + e); } catch (g) {} return resolve(); }

        var STEP = 49152;   /* 3 的整数倍，保证每块 base64 能独立解码 */
        var pos = 0, dead = false;

        function fail() {
          dead = true;
          try { bridge.abort(); } catch (e) {}
          resolve();
        }

        function step() {
          if (dead) return;
          if (pos >= blob.size) {
            try { bridge.finish(); } catch (e) {}
            return resolve();
          }
          var end = Math.min(pos + STEP, blob.size);
          blob.slice(pos, end).arrayBuffer().then(function (buf) {
            try {
              bridge.append(b64(new Uint8Array(buf)));
              pos = end;
              step();
            } catch (e) { fail(); }
          }).catch(fail);
        }
        step();
      });
    });
  }

  function dataUrlToBlob(url) {
    var comma = url.indexOf(',');
    var head = url.slice(5, comma);
    var mime = (head.split(';')[0] || 'application/octet-stream').trim();
    var isB64 = /;base64/i.test(head);
    var raw = isB64 ? atob(url.slice(comma + 1)) : decodeURIComponent(url.slice(comma + 1));
    var u8 = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) u8[i] = raw.charCodeAt(i);
    return new Blob([u8], { type: mime });
  }

  var written = {};   /* 同一个 blob URL 只写一次，防止两条拦截路径重复落盘 */

  function saveLink(link) {
    if (!window.IrisNative) return false;

    var href = link.href || '';
    var name = link.getAttribute('download') || link.download;
    if (!name) name = 'Iris_' + Date.now() + (href.indexOf('blob:') === 0 ? '' : '.bin');
    if (written[href]) return true;

    var blob = blobs.get(href);
    if (blob) {
      if (!payloadOk(name, blob.type || mimeByName(name), blob.size)) return false;
      written[href] = 1;
      writeBlob(name, blob);
      return true;
    }

    if (href.indexOf('data:') === 0) {
      try {
        var db = dataUrlToBlob(href);
        if (!payloadOk(name, db.type || mimeByName(name), db.size)) return false;
        written[href] = 1;
        writeBlob(name, db);
        return true;
      } catch (e) { return false; }
    }
    if (href.indexOf('blob:') === 0) {
      var guessMime = mimeByName(name);
      written[href] = 1;
      fetch(href).then(function (r) { return r.blob(); })
        .then(function (b) { if (payloadOk(name, b.type || guessMime, b.size)) writeBlob(name, b); })
        .catch(function () {});
      return true;
    }
    return false;
  }

  /* 页面所有的 downloadBlob() 最终都是「造 a 标签 + click」，从原型上拦下来 */
  var origClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    try {
      if (this.hasAttribute('download') && saveLink(this)) return;
    } catch (e) {}
    return origClick.apply(this, arguments);
  };

  window.addEventListener('click', function (ev) {
    var el = ev.target;
    while (el && el.tagName !== 'A') el = el.parentElement;
    if (!el || !el.hasAttribute('download')) return;
    if (saveLink(el)) ev.preventDefault();
  }, true);

  /* ---------- 4) 返回键：交给页面自己的 Escape 分支，并判断它是否真的收起了什么 ---------- */
  function visibleSignature() {
    var sel = '[class*="menu"],[class*="sheet"],[class*="modal"],[class*="pop"],[class*="sub"],[class*="panel"],[class*="overlay"],[class*="drawer"],[class*="cmd"]';
    var list = document.querySelectorAll(sel);
    var out = '';
    for (var i = 0; i < list.length; i++) {
      var e = list[i];
      var cs = getComputedStyle(e);
      out += (cs.display !== 'none' && cs.visibility !== 'hidden' && e.offsetParent !== null) ? '1' : '0';
    }
    return out + '|' + (document.body.className || '');
  }

  window.__irisBack = function () {
    try {
      var before = visibleSignature();
      window.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Escape', code: 'Escape', keyCode: 27, which: 27,
        bubbles: true, cancelable: true
      }));
      var after = visibleSignature();
      return before !== after;
    } catch (e) {
      return false;
    }
  };

  /* ---------- 5) 兜底：万一还有下载请求漏给 WebView，壳会把 URL 交回这里重试 ----------
     WebView 里没有下载器，漏出去等于文件消失，所以这一层必须能自己接住。 */
  window.__irisRescue = function (href) {
    try {
      var blob = blobs.get(href);
      if (!blob || !(blob.size > 64)) return false;
      var ext = { 'image/png': '.png', 'image/jpeg': '.jpg', 'image/webp': '.webp',
                  'image/gif': '.gif', 'image/heic': '.heic', 'video/mp4': '.mp4',
                  'video/webm': '.webm', 'video/quicktime': '.mov',
                  'application/zip': '.zip', 'application/json': '.json' }[blob.type];
      if (!ext) return false;
      writeBlob('Iris_' + Date.now() + ext, blob);
      return true;
    } catch (e) { return false; }
  };
})();
