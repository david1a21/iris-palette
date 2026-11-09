/* Iris 调色盘 · 桌面 shim（注入页面主世界，页面源码不改）
 *
 * 补的四个接缝：
 *  ① 打开文件   —— <input type=file> 改走系统原生对话框（.heic/.mov/.cube 不会被过滤器藏起来）
 *  ② 保存文件   —— a[download].click() 改走系统"另存为"，分块流式落盘
 *  ③ 菜单 / 快捷键 —— 原生菜单项复用页面自己的处理逻辑，不重复实现
 *  ④ 拖拽 / 外部打开 —— 防止拖到窗口任意处把窗口导航走；命令行带文件可直接开
 */
(() => {
  const N = window.irisDesktop;
  if (!N || window.__irisShim) return;
  window.__irisShim = true;

  const isMac = N.platform === 'darwin';
  const modKey = isMac ? 'metaKey' : 'ctrlKey';
  const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

  /* ---------- ① 打开：原生对话框 ---------- */
  const toFile = (it) => new File([it.data], it.name, {
    type: it.mime || '', lastModified: Date.now(),
  });

  async function fillInput(input, items) {
    const dt = new DataTransfer();
    items.forEach((it) => dt.items.add(toFile(it)));
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  async function pickInto(input) {
    const items = await N.pick({
      accept: input.getAttribute('accept') || '',
      multiple: !!input.multiple,
      title: input.id === 'cubeFile' ? '导入 LUT（.cube）'
        : input.id === 'jsonFile' ? '导入预设（.json）' : '打开照片',
    });
    if (!items.length) return false;
    await fillInput(input, items);
    return true;
  }

  // 拦截所有 file input 的点击（页面里 $('#file').click() 等全部会走到这里）
  document.addEventListener('click', (e) => {
    const el = e.target;
    if (!el || el.tagName !== 'INPUT' || el.type !== 'file') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    pickInto(el);
  }, true);

  /* ---------- ② 保存：原生另存为 ---------- */
  const blobByUrl = new Map();
  const rawCreate = URL.createObjectURL.bind(URL);
  const rawRevoke = URL.revokeObjectURL.bind(URL);

  URL.createObjectURL = (obj) => {
    const url = rawCreate(obj);
    try {
      if (obj instanceof Blob) {
        if (blobByUrl.size > 160) blobByUrl.delete(blobByUrl.keys().next().value);
        blobByUrl.set(url, obj);
      }
    } catch { /* ignore */ }
    return url;
  };
  URL.revokeObjectURL = (url) => {
    // 保留引用到下一次保存结束，避免页面立刻 revoke 导致我们拿不到数据
    setTimeout(() => blobByUrl.delete(url), 8000);
    return rawRevoke(url);
  };

  let lastSavedPath = null;
  let lastDir = null;
  let saving = 0;

  function toastSaved(name, size) {
    const el = document.createElement('div');
    el.textContent = `已保存 · ${name}`;
    el.style.cssText = [
      'position:fixed', 'left:50%', 'bottom:34px', 'transform:translateX(-50%)',
      'padding:10px 18px', 'border-radius:999px', 'z-index:2147483647',
      'background:rgba(20,20,23,.92)', 'color:#f3f3f5', 'font:500 13px/1.4 system-ui,sans-serif',
      'box-shadow:0 10px 30px rgba(0,0,0,.5)', 'border:1px solid rgba(227,182,92,.35)',
      'pointer-events:none', 'opacity:0', 'transition:opacity .2s ease',
    ].join(';');
    document.body.appendChild(el);
    requestAnimationFrame(() => { el.style.opacity = '1'; });
    setTimeout(() => {
      el.style.opacity = '0';
      setTimeout(() => el.remove(), 260);
    }, 2200);
    void size;
  }

  async function saveBlob(blob, name) {
    saving++;
    try {
      const begin = await N.saveBegin({ name, mime: blob.type || '', lastDir });
      if (!begin) return null;
      const CHUNK = 4 * 1024 * 1024;
      for (let off = 0; off < blob.size; off += CHUNK) {
        const part = new Uint8Array(await blob.slice(off, off + CHUNK).arrayBuffer());
        await N.saveChunk(begin.token, part);
      }
      const res = await N.saveEnd(begin.token);
      if (res) {
        lastSavedPath = res.path;
        lastDir = res.dir;
        toastSaved(res.path.split(/[\\/]/).pop(), res.size);
      }
      return res;
    } catch (err) {
      console.error('[iris] 保存失败', err);
      return null;
    } finally {
      saving--;
    }
  }

  // 页面里所有的下载都走 "造 a 标签 + click"，这里接管
  const rawAnchorClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function patchedClick() {
    try {
      const href = this.href;
      const dl = this.download;
      if (dl && blobByUrl.has(href)) {
        saveBlob(blobByUrl.get(href), dl);
        return;
      }
    } catch { /* 落回原生行为 */ }
    return rawAnchorClick.apply(this, arguments);
  };

  /* ---------- ③ 菜单动作 ---------- */
  function clickEl(el) {
    if (!el) return false;
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    return true;
  }

  function key(k, opts = {}) {
    window.dispatchEvent(new KeyboardEvent('keydown', Object.assign({
      key: k, bubbles: true, cancelable: true,
    }, opts)));
  }

  const toolTab = (name) => [...document.querySelectorAll('.tool')]
    .find((el) => (el.innerText || '').trim() === name);

  const byText = (text, root = document) => [...root.querySelectorAll('button, .em-item, .tool')]
    .find((el) => (el.innerText || '').trim() === text);

  async function openExport(act) {
    const menuEl = document.querySelector('#exportMenu');
    if (!menuEl || !menuEl.classList.contains('show')) {
      clickEl(document.querySelector('#btnSave'));
      await tick(120);
    }
    const item = document.querySelector(`#exportMenu .em-item[data-act="${act}"]`);
    if (!item) return false;
    clickEl(item);
    return true;
  }

  async function openHelpPage(text) {
    if (!toolTab('更多') || !toolTab('更多').classList.contains('active')) {
      clickEl(toolTab('更多'));
      await tick(160);
    }
    return clickEl(byText(text));
  }

  async function openPresetOrLut() {
    const items = await N.pick({
      accept: '.json,.cube', multiple: false, title: '导入预设 / LUT',
    });
    if (!items.length) return;
    const it = items[0];
    const isLut = /\.cube$/i.test(it.name);
    const input = document.querySelector(isLut ? '#cubeFile' : '#jsonFile');
    if (input) await fillInput(input, items);
  }

  async function openByPath(paths) {
    const items = [];
    for (const p of paths) {
      try {
        const it = await N.readFile(p);
        if (it) items.push(it);
      } catch { /* ignore */ }
    }
    const input = document.querySelector('#file');
    if (input && items.length) await fillInput(input, items);
  }

  N.onMenu(({ action }) => {
    switch (action) {
      case 'open': clickEl(document.querySelector('#file')); break;
      case 'open-preset': openPresetOrLut(); break;
      case 'reveal-last': if (lastSavedPath) N.reveal(lastSavedPath); break;
      case 'export-photo': key('s', { [modKey]: true }); break;
      case 'export-gif': openExport('gif'); break;
      case 'export-video': openExport('video'); break;
      case 'export-bundle': openExport('bundle'); break;
      case 'undo': key('z', { [modKey]: true }); break;
      case 'redo': key('z', { [modKey]: true, shiftKey: true }); break;
      case 'command': key('k', { [modKey]: true }); break;
      case 'compare': {
        const cmpBtn = document.querySelector('#cmp');
        if (!cmpBtn) break;
        const opts = { bubbles: true, cancelable: true, pointerId: 1, isPrimary: true };
        cmpBtn.dispatchEvent(new PointerEvent('pointerdown', opts));
        setTimeout(() => cmpBtn.dispatchEvent(new PointerEvent('pointerup', opts)), 1400);
        break;
      }
      case 'manual': openHelpPage('使用说明书'); break;
      case 'shortcuts': openHelpPage('快捷键总表'); break;
      default: break;
    }
  });

  N.onOpenFiles((paths) => { if (Array.isArray(paths) && paths.length) openByPath(paths); });

  /* ---------- ④ 拖拽兜底 ---------- */
  // 只 preventDefault、不 stopPropagation：页面 stage 自己的 drop 仍然照常工作，
  // 但拖到窗口其它区域时不会再让 Chromium 把窗口导航到 file:// 去。
  ['dragenter', 'dragover', 'drop'].forEach((t) => {
    window.addEventListener(t, (e) => { e.preventDefault(); }, false);
  });

  // 桌面端光标提示：按住空格对比等提示已由页面提供，这里只补窗口级拖放提示
  window.addEventListener('drop', (e) => {
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return;
    // 页面 stage 自己会处理；只有落点在 stage 外才兜底喂给 #file
    const onStage = e.target && e.target.closest && e.target.closest('#stage');
    if (!onStage) {
      const input = document.querySelector('#file');
      if (input) {
        const dt = new DataTransfer();
        for (const f of files) dt.items.add(f);
        input.files = dt.files;
        input.dispatchEvent(new Event('change', { bubbles: true }));
      }
    }
  }, false);

  /* ---------- 桌面观感补丁（只作用于宽屏，不动手机布局） ---------- */
  // 宽屏时顶栏是浮在照片上的半透明条：照片一亮，标题就被冲淡。
  // 保留毛玻璃，只把上沿压深一点，保证任何照片下标题都清楚。
  function applyDesktopCss() {
    if (document.getElementById('iris-desktop-polish')) return;
    const styleEl = document.createElement('style');
    styleEl.id = 'iris-desktop-polish';
    styleEl.textContent = `
@media (min-width:900px){
  .topbar{
    background:linear-gradient(rgba(5,5,7,.95) 0%,rgba(5,5,7,.62) 62%,rgba(5,5,7,.28) 100%) !important;
    -webkit-backdrop-filter:blur(24px) saturate(115%) !important;
    backdrop-filter:blur(24px) saturate(115%) !important;
  }
  .stage canvas#hist{opacity:.88}
}`;
    (document.head || document.documentElement).appendChild(styleEl);
  }
  if (document.head || document.documentElement) applyDesktopCss();
  document.addEventListener('DOMContentLoaded', applyDesktopCss, { once: true });

  console.info('[Iris] 桌面适配已就绪：原生打开 / 原生保存 / 原生菜单');
})();
