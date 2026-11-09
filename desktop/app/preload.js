/* Iris 调色盘 · preload
 * 1) 用 contextBridge 把桌面能力暴露给页面（只暴露需要的，Node 不落到页面里）
 * 2) 把 shim.js 注入到页面主世界 —— 页面自己不需要改一行代码
 */
const { contextBridge, ipcRenderer, webFrame } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const api = {
  platform: process.platform,
  electron: process.versions.electron,
  pick: (opts) => ipcRenderer.invoke('iris:pick', opts || {}),
  readFile: (p) => ipcRenderer.invoke('iris:read', p),
  saveBegin: (opts) => ipcRenderer.invoke('iris:save:begin', opts || {}),
  saveChunk: (token, bytes) => ipcRenderer.invoke('iris:save:chunk', token, bytes),
  saveEnd: (token) => ipcRenderer.invoke('iris:save:end', token),
  reveal: (p) => ipcRenderer.invoke('iris:reveal', p),
  appInfo: () => ipcRenderer.invoke('iris:app:info'),
  onMenu: (cb) => ipcRenderer.on('iris:menu', (_e, d) => cb(d)),
  onOpenFiles: (cb) => ipcRenderer.on('iris:open-files', (_e, paths) => cb(paths)),
};

contextBridge.exposeInMainWorld('irisDesktop', api);

// 主世界注入：页面脚本解析前就装好拦截器
try {
  const shim = fs.readFileSync(path.join(__dirname, 'shim.js'), 'utf8');
  webFrame.executeJavaScript(shim).catch((err) => console.error('[iris] shim 注入失败', err));
} catch (err) {
  console.error('[iris] shim 读取失败', err);
}
