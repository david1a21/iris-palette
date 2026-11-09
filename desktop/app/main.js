/* Iris 调色盘 · Electron 主进程
 * 设计原则：页面（assets/index.html）逐字节保留，不修改任何一行；
 * 桌面能力全部在这一层补齐 —— 原生文件对话框、原生保存、菜单、窗口、通知。
 */
const {
  app, BrowserWindow, Menu, dialog, ipcMain, shell, protocol, net,
  Notification, nativeImage,
} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const { pathToFileURL, fileURLToPath } = require('node:url');

const APP_DIR = __dirname;
const ASSETS_DIR = path.join(APP_DIR, 'assets');
const IS_MAC = process.platform === 'darwin';
const IS_WIN = process.platform === 'win32';

// 名称（任务栏 / 菜单 / 关于面板）
app.setName('Iris 调色盘');
if (IS_WIN) app.setAppUserModelId('com.iris.palette');

// ---------- 单实例 ----------
const locked = app.requestSingleInstanceLock();
if (!locked) app.quit();

// ---------- 自定义协议：iris://app/ ----------
// 用标准 + 安全协议承载页面，保证 localStorage / IndexedDB / WebGL 与 http(s) 同权，
// 也避免 file:// origin 在部分系统上 localStorage 被隔离。
protocol.registerSchemesAsPrivileged([{
  scheme: 'iris',
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true },
}]);

const MIME = {
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp',
  gif: 'image/gif', bmp: 'image/bmp', tif: 'image/tiff', tiff: 'image/tiff',
  heic: 'image/heic', heif: 'image/heif', avif: 'image/avif', svg: 'image/svg+xml',
  mp4: 'video/mp4', m4v: 'video/x-m4v', mov: 'video/quicktime', webm: 'video/webm',
  mkv: 'video/x-matroska', avi: 'video/x-msvideo',
  mp3: 'audio/mpeg', wav: 'audio/wav', ogg: 'audio/ogg', m4a: 'audio/mp4', aac: 'audio/aac',
  cube: 'text/plain', json: 'application/json', txt: 'text/plain',
};
const mimeOf = (name) => MIME[path.extname(name).slice(1).toLowerCase()] || 'application/octet-stream';

// ---------- 窗口状态 ----------
const stateFile = () => path.join(app.getPath('userData'), 'window-state.json');
function loadWindowState() {
  try {
    const s = JSON.parse(fs.readFileSync(stateFile(), 'utf8'));
    if (Number.isFinite(s.width) && Number.isFinite(s.height)) return s;
  } catch {}
  return { width: 1320, height: 860 };
}
function saveWindowState(win) {
  try {
    const b = win.getNormalBounds();
    fs.writeFileSync(stateFile(), JSON.stringify({
      x: b.x, y: b.y, width: b.width, height: b.height, maximized: win.isMaximized(),
    }));
  } catch {}
}

let mainWin = null;
let pendingOpen = [];   // 启动 / 二次启动时命令行带进来的媒体文件

function createWindow() {
  let st = loadWindowState();
  if (process.env.IRIS_TEST_SIZE) {
    const [w, h] = process.env.IRIS_TEST_SIZE.split('x').map(Number);
    if (w && h) st = { width: w, height: h };
  }
  mainWin = new BrowserWindow({
    x: st.x, y: st.y, width: st.width, height: st.height,
    minWidth: 960, minHeight: 660,
    backgroundColor: '#08080A',
    show: false,
    title: 'Iris 调色盘',
    icon: path.join(APP_DIR, 'ui', 'icon.png'),
    autoHideMenuBar: false,
    webPreferences: {
      preload: path.join(APP_DIR, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: false,
      backgroundThrottling: false,
      enableBlinkFeatures: 'WebGL2',
    },
  });

  if (st.maximized) mainWin.maximize();

  mainWin.once('ready-to-show', () => {
    mainWin.show();
    mainWin.focus();
    // 首发文件（命令行 / macOS open-file）
    if (pendingOpen.length) {
      sendOpenFiles(pendingOpen);
      pendingOpen = [];
    }
  });

  // 页面标题很长，窗口标题固定为产品名
  mainWin.on('page-title-updated', (e) => { e.preventDefault(); mainWin.setTitle('Iris 调色盘'); });

  let saveTimer = null;
  const rememberWin = () => {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => mainWin && saveWindowState(mainWin), 400);
  };
  mainWin.on('resize', rememberWin);
  mainWin.on('move', rememberWin);
  mainWin.on('close', () => mainWin && saveWindowState(mainWin));

  mainWin.loadURL('iris://app/index.html');
  mainWin.webContents.on('did-finish-load', () => mainWin && mainWin.setTitle('Iris 调色盘'));

  // 安全：不允许页面把窗口导航走 / 开新窗口
  mainWin.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith('iris://app/')) e.preventDefault();
  });
  mainWin.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  // 页面内的 <input type=file> 由 preload 拦截并改走原生对话框；这里只做兜底
  mainWin.webContents.on('before-input-event', () => {});
}

function sendOpenFiles(files) {
  if (!mainWin) return;
  mainWin.webContents.send('iris:open-files', files);
}

function switchTo(win) {
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

app.on('second-instance', (_e, argv) => {
  if (!mainWin) return;
  switchTo(mainWin);
  const files = mediaFromArgv(argv);
  if (files.length) sendOpenFiles(files);
});

app.on('open-file', (e, p) => {           // macOS 双击文件
  e.preventDefault();
  if (mainWin && mainWin.webContents) sendOpenFiles([p]);
  else pendingOpen.push(p);
});

function mediaFromArgv(argv) {
  return argv.slice(1).filter((a) => {
    if (!a || a.startsWith('-')) return false;
    try { return fs.statSync(a).isFile() && !!MIME[path.extname(a).slice(1).toLowerCase()]; } catch { return false; }
  });
}

// ---------- 文件对话框（正确的过滤器，避免 .heic / .cube 被系统藏起来） ----------
const EXT_SETS = {
  'image/*': ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff', 'heic', 'heif', 'avif', 'svg'],
  'video/*': ['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'],
  'audio/*': ['mp3', 'wav', 'ogg', 'm4a', 'aac'],
};
const LABEL = { image: '图片', video: '视频', audio: '音频' };

function filtersFromAccept(accept) {
  const groups = {};
  String(accept || '').split(',').map((s) => s.trim()).filter(Boolean).forEach((tok) => {
    if (EXT_SETS[tok]) groups[tok] = groups[tok] || new Set();
    if (EXT_SETS[tok]) EXT_SETS[tok].forEach((x) => groups[tok].add(x));
    else if (tok.startsWith('.')) {
      const kind = ['mov', 'mp4', 'm4v', 'webm', 'mkv'].includes(tok.slice(1)) ? 'video/*' : '图片/预设';
      groups[kind] = groups[kind] || new Set();
      groups[kind].add(tok.slice(1));
    }
  });
  const out = [];
  for (const [k, set] of Object.entries(groups)) {
    if (!set.size) continue;
    const name = k === 'image/*' ? '图片' : k === 'video/*' ? '视频' : k === 'audio/*' ? '音频' : k;
    out.push({ name, extensions: [...set] });
  }
  out.push({ name: '全部文件', extensions: ['*'] });
  return out;
}

ipcMain.handle('iris:pick', async (_e, opts = {}) => {
  // 自测桩：跳过系统对话框，直接把指定路径当作选择结果
  if (process.env.IRIS_TEST_PICK) {
    const paths = process.env.IRIS_TEST_PICK.split('|');
    const list = [];
    for (const p of paths) {
      const buf = await fsp.readFile(p);
      list.push({ name: path.basename(p), path: p, mime: mimeOf(p), size: buf.length, data: new Uint8Array(buf) });
    }
    return list;
  }
  const win = BrowserWindow.getFocusedWindow() || mainWin;
  const res = await dialog.showOpenDialog(win, {
    title: opts.title || '打开照片',
    properties: opts.multiple ? ['openFile', 'multiSelections'] : ['openFile'],
    filters: filtersFromAccept(opts.accept),
    defaultPath: opts.defaultPath || app.getPath('pictures'),
  });
  if (res.canceled || !res.filePaths.length) return [];
  const out = [];
  for (const p of res.filePaths) {
    try {
      const buf = await fsp.readFile(p);
      out.push({ name: path.basename(p), path: p, mime: mimeOf(p), size: buf.length, data: new Uint8Array(buf) });
    } catch (err) {
      dialog.showErrorBox('无法读取文件', `${path.basename(p)}\n${err.message}`);
    }
  }
  return out;
});

// ---------- 原生保存（页面里 a.click + blob 的桌面版实现） ----------
const saves = new Map();
let saveSeq = 0;

ipcMain.handle('iris:save:begin', async (_e, { name, mime, lastDir }) => {
  const win = BrowserWindow.getFocusedWindow() || mainWin;
  const safeName = String(name || 'iris.png').replace(/[\\/:*?"<>|]/g, '_');
  const dir = lastDir || app.getPath('pictures');

  // 自测桩：跳过"另存为"对话框
  if (process.env.IRIS_TEST_SAVE_DIR) {
    fs.mkdirSync(process.env.IRIS_TEST_SAVE_DIR, { recursive: true });
    const filePath = path.join(process.env.IRIS_TEST_SAVE_DIR, safeName);
    const token = ++saveSeq;
    const stream = fs.createWriteStream(filePath);
    saves.set(token, { stream, path: filePath, mime, bytes: 0 });
    return { token, path: filePath, dir: process.env.IRIS_TEST_SAVE_DIR };
  }

  const res = await dialog.showSaveDialog(win, {
    title: '保存',
    defaultPath: path.join(dir, safeName),
    filters: [{ name: '文件', extensions: ['*'] }],
    properties: ['createDirectory', 'showOverwriteConfirmation'],
  });
  if (res.canceled || !res.filePath) return null;
  const token = ++saveSeq;
  const stream = fs.createWriteStream(res.filePath);
  saves.set(token, { stream, path: res.filePath, mime, bytes: 0 });
  return { token, path: res.filePath, dir: path.dirname(res.filePath) };
});

ipcMain.handle('iris:save:chunk', (_e, token, chunk) => {
  const s = saves.get(token);
  if (!s) return false;
  const buf = Buffer.from(chunk);
  s.bytes += buf.length;
  return new Promise((resolve) => {
    s.stream.write(buf, () => resolve(true));
  });
});

ipcMain.handle('iris:save:end', async (_e, token) => {
  const s = saves.get(token);
  if (!s) return null;
  await new Promise((r) => s.stream.end(r));
  saves.delete(token);
  const size = s.bytes;
  if (Notification.isSupported()) {
    new Notification({
      title: '已保存',
      body: `${path.basename(s.path)} · ${(size / 1048576).toFixed(size > 1048576 ? 1 : 2)} MB`,
      silent: true,
    }).show();
  }
  return { path: s.path, dir: path.dirname(s.path), size };
});

ipcMain.handle('iris:reveal', (_e, p) => {
  if (!p) return false;
  shell.showItemInFolder(p);
  return true;
});

ipcMain.handle('iris:read', async (_e, p) => {
  try {
    const buf = await fsp.readFile(p);
    return { name: path.basename(p), path: p, mime: mimeOf(p), size: buf.length, data: new Uint8Array(buf) };
  } catch {
    return null;
  }
});

ipcMain.handle('iris:app:info', () => ({
  version: app.getVersion(),
  platform: process.platform,
  locale: app.getLocale(),
  userData: app.getPath('userData'),
  downloads: app.getPath('downloads'),
  isPackaged: app.isPackaged,
}));

// ---------- 兜底：绕过拦截的下载（data: URL 等） ----------
function installDownloadFallback() {
  const { session } = require('electron');
  session.defaultSession.on('will-download', (e, item) => {
    if (!mainWin) return;
    const name = item.getFilename() || 'iris-export';
    const dir = path.join(app.getPath('downloads'), 'Iris');
    try { fs.mkdirSync(dir, { recursive: true }); } catch {}
    item.setSavePath(path.join(dir, name));
    item.once('done', (_ev, state) => {
      if (state === 'completed' && Notification.isSupported()) {
        new Notification({ title: '已保存到下载目录', body: name, silent: true }).show();
      }
    });
  });
}

// ---------- 菜单 ----------
function send(action, payload) {
  if (mainWin) mainWin.webContents.send('iris:menu', { action, payload });
}

function buildMenu() {
  const isDev = !app.isPackaged;
  const template = [];

  if (IS_MAC) {
    template.push({
      label: 'Iris 调色盘',
      submenu: [
        { role: 'about', label: '关于 Iris 调色盘' },
        { type: 'separator' },
        { role: 'hide', label: '隐藏' },
        { role: 'hideOthers', label: '隐藏其他' },
        { role: 'unhide', label: '全部显示' },
        { type: 'separator' },
        { role: 'quit', label: '退出 Iris 调色盘' },
      ],
    });
  }

  template.push({
    label: '文件',
    submenu: [
      { label: '打开照片…', accelerator: 'CmdOrCtrl+O', click: () => send('open') },
      { label: '导入预设 / LUT…', click: () => send('open-preset') },
      { label: '在文件夹中显示上次导出的文件', click: () => send('reveal-last') },
      { type: 'separator' },
      { label: '导出照片', accelerator: 'CmdOrCtrl+S', click: () => send('export-photo') },
      { label: '导出 GIF 动图', click: () => send('export-gif') },
      { label: '导出视频', click: () => send('export-video') },
      { label: '打包全格式', click: () => send('export-bundle') },
      { type: 'separator' },
      IS_MAC ? { role: 'close', label: '关闭窗口' } : { role: 'quit', label: '退出' },
    ],
  });

  template.push({
    label: '编辑',
    submenu: [
      { label: '撤销', accelerator: 'CmdOrCtrl+Z', click: () => send('undo') },
      { label: '重做', accelerator: 'Shift+CmdOrCtrl+Z', click: () => send('redo') },
      { type: 'separator' },
      { role: 'cut', label: '剪切' },
      { role: 'copy', label: '复制' },
      { role: 'paste', label: '粘贴' },
      { role: 'selectAll', label: '全选' },
      { type: 'separator' },
      { label: '全局搜索', accelerator: 'CmdOrCtrl+K', click: () => send('command') },
      { label: '按住对比原图', click: () => send('compare') },
    ],
  });

  template.push({
    label: '视图',
    submenu: [
      { label: '实际大小', accelerator: 'CmdOrCtrl+0', click: () => mainWin.webContents.setZoomFactor(1) },
      { label: '放大', accelerator: 'CmdOrCtrl+Plus', click: () => mainWin.webContents.setZoomFactor(Math.min(2, mainWin.webContents.getZoomFactor() + 0.1)) },
      { label: '缩小', accelerator: 'CmdOrCtrl+-', click: () => mainWin.webContents.setZoomFactor(Math.max(0.5, mainWin.webContents.getZoomFactor() - 0.1)) },
      { type: 'separator' },
      { role: 'togglefullscreen', label: '全屏' },
      ...(isDev ? [{ role: 'toggleDevTools', label: '开发者工具' }, { role: 'reload', label: '重新载入' }] : []),
    ],
  });

  template.push({
    label: '帮助',
    submenu: [
      { label: '使用说明书', click: () => send('manual') },
      { label: '快捷键总表', click: () => send('shortcuts') },
      ...(IS_MAC ? [] : [{ type: 'separator' }, {
        label: '关于 Iris 调色盘',
        click: () => dialog.showMessageBox(mainWin, {
          type: 'info',
          title: '关于',
          message: 'Iris 调色盘',
          detail: `版本 ${app.getVersion()}\n语义感知的端侧照片编辑器\n所有运算在本地完成，照片不会上传。`,
          buttons: ['好'],
        }),
      }]),
    ],
  });

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------- 生命周期 ----------
app.whenReady().then(() => {
  protocol.handle('iris', async (req) => {
    const url = new URL(req.url);
    if (url.hostname !== 'app') return new Response('Not Found', { status: 404 });
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
    const full = path.join(ASSETS_DIR, path.normalize(rel));
    if (!full.startsWith(ASSETS_DIR)) return new Response('Bad Request', { status: 400 });
    try {
      return await net.fetch(pathToFileURL(full).toString());
    } catch {
      return new Response('Not Found', { status: 404 });
    }
  });

  installDownloadFallback();
  buildMenu();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (!IS_MAC) app.quit();
});

// 无 GPU 的 CI/虚拟机里用软件 WebGL 跑（普通用户不受影响）
if (process.env.IRIS_SOFTWARE_GL === '1') {
  app.commandLine.appendSwitch('enable-unsafe-swiftshader');
  app.commandLine.appendSwitch('use-angle', 'swiftshader');
}

/* ---------- 仅测试环境：自动截图 + 探针（IRIS_SHOT=/path/shot.png） ---------- */
if (process.env.IRIS_SHOT) {
  app.on('browser-window-created', (_e, win) => {
    win.webContents.once('did-finish-load', async () => {
      await new Promise((r) => setTimeout(r, 5000));
      try {
        let probe = await win.webContents.executeJavaScript(`(() => {
          const gl = document.createElement('canvas').getContext('webgl2');
          const out = {
            bridge: typeof window.irisDesktop,
            shim: !!window.__irisShim,
            anchorPatched: HTMLAnchorElement.prototype.click.name === 'patchedClick',
            webgl2: !!gl,
            renderer: gl ? (gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info')?.UNMASKED_RENDERER_WEBGL || gl.RENDERER)) : null,
            title: document.title,
            origin: location.origin,
            fileAccept: document.querySelector('#file')?.getAttribute('accept'),
            ls: (() => { try { localStorage.setItem('__t','1'); return localStorage.getItem('__t') === '1'; } catch(e){ return false; } })(),
            canvas: [document.querySelector('#gl')?.width, document.querySelector('#gl')?.height],
          };
          return JSON.stringify(out);
        })()`);
        if (process.env.IRIS_TEST_OPEN) {
          await win.webContents.executeJavaScript(`(document.querySelector('#file') || {}).click?.()`);
          await new Promise((r) => setTimeout(r, Number(process.env.IRIS_TEST_WAIT || 6000)));
          await win.webContents.executeJavaScript(`(() => {
            const z = document.querySelector('#zMode');
            if (z && z.innerText.includes('适应')) z.click();
          })()`);
          await new Promise((r) => setTimeout(r, 900));
        }
        if (process.env.IRIS_SELFTEST) {
          // 打开链路：点 #file.click() → shim 拦成原生对话框 → 桩返回文件 → 页面 change 事件载入
          await win.webContents.executeJavaScript(`(document.querySelector('#file') || {}).click?.()`);
          await new Promise((r) => setTimeout(r, 6000));
          let loaded = await win.webContents.executeJavaScript(`(() => {
            const gl = document.querySelector('#gl');
            return JSON.stringify({ canvas: gl ? [gl.width, gl.height] : null });
          })()`);
          const saveRes = await win.webContents.executeJavaScript(`new Promise((resolve) => {
            const N = 8 * 1024 * 1024;
            const bytes = new Uint8Array(N);
            for (let i = 0; i < N; i++) bytes[i] = i % 251;
            const blob = new Blob([bytes], { type: 'application/octet-stream' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = 'selftest-8mb.bin';
            a.click();
            setTimeout(() => resolve({ size: N, href: a.href.slice(0, 8) }), 12000);
          })`);
          await new Promise((r) => setTimeout(r, 1500));
          probe = JSON.parse(probe);
          probe.selfTest = saveRes;
          probe.loaded = JSON.parse(loaded);
        }
        fs.writeFileSync(process.env.IRIS_SHOT + '.json',
          typeof probe === 'string' ? probe : JSON.stringify(probe));
      } catch (err) {
        fs.writeFileSync(process.env.IRIS_SHOT + '.json', JSON.stringify({ error: String(err) }));
      }
      try {
        const img = await win.webContents.capturePage();
        fs.writeFileSync(process.env.IRIS_SHOT, img.toPNG());
      } catch (err) {
        console.error('capture failed', err);
      }
      app.quit();
    });
  });
}
