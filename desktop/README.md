# Iris 调色盘 · 桌面版（Windows / Linux / macOS）

Electron 31 外壳 + 原页面。**`app/assets/index.html` 与原 `iris.html` 逐字节一致（sha256 相同）**，
所有桌面能力都在外壳层补齐，页面一行未改。

## 下载后怎么用

| 平台 | 包 | 启动 |
|---|---|---|
| Windows x64 | `Iris-Palette-Windows-x64-1.0.0.zip` | 解压后双击 `Iris 调色盘.exe`（整个文件夹一起保留） |
| Linux x64 | `Iris-Palette-Linux-x64-1.0.0.tar.gz` | `tar -xzf …` 后 `./iris-palette` |
| macOS arm64 | `Iris-Palette-macOS-arm64-1.0.0.zip` | 解压得到 `Iris 调色盘.app`，首次请右键 →「打开」 |

未做代码签名：Windows 会弹 SmartScreen「未知发布者」（更多信息 → 仍要运行）；
macOS 会拦一次 Gatekeeper（右键打开，或 `xattr -dr com.apple.quarantine "Iris 调色盘.app"`）。

## 桌面端补了哪些接缝

页面本身是给浏览器写的，直接塞进壳里会有四处「能用但难用」的地方，这里逐条接上原生能力：

1. **打开文件** — 页面有 3 个 `<input type=file>`（照片/预设/LUT），在浏览器里点开的是 Chromium 文件选择器，
   `accept` 里混着 `.heic` / `.mov` / `.cube`，系统过滤器经常把文件藏起来。
   preload 在 document 捕获阶段接管所有 file input 的点击，改走 `dialog.showOpenDialog`，
   并按 `accept` 现场翻译成正确的扩展名过滤器；选完把文件塞回 `DataTransfer` + 派发 `change`，
   页面自己的 `loadFiles()` 完全照旧工作（实况照片 HEIC+MOV 多选也在）。
2. **保存/导出** — 页面所有导出最终都是 `a[download].href = URL.createObjectURL(blob); a.click()`。
   shim 复写 `URL.createObjectURL` 记下 Blob，再复写 `HTMLAnchorElement.prototype.click`，
   命中就改走 `dialog.showSaveDialog` + 4MB 分块流式落盘，并记住上次目录、系统通知 + 应用内轻提示。
   页面的 GIF / 视频 / 实况 ZIP / 全格式打包全部自动受益。
3. **原生菜单与快捷键** — 文件/编辑/视图/帮助四组菜单，菜单项不重新实现功能，而是把动作派发回页面：
   `Ctrl+S` → 页面自己的 `doExport()`，`Ctrl+K` → 命令面板，「使用说明书」→ 更多面板里的真实页面。
   页面原生的 `Ctrl+O / Ctrl+S / Ctrl+K / Ctrl+Z` 仍然保留可用。
4. **窗口与系统** — `iris://app` 自定义协议承载（standard + secure，localStorage/IndexedDB/WebGL 与 http 同权）、
   窗口大小位置记忆、深色 `#08080A` 防白闪、固定窗口标题、单实例、`Ctrl/Cmd+O` 打开、
   拖拽到窗口任意位置都不会把窗口导航走（stage 内拖放照旧）、命令行带文件可直接开、外部链接走系统浏览器。

顺带修了一处桌面尺寸下的观感问题：宽屏时顶栏浮在照片上、照片一亮标题就被冲淡，
桌面层把顶栏上沿压深（保留毛玻璃），不影响手机布局。

## 目录

```
iris-desktop/
├─ app/                 # 进 asar 的应用本体
│  ├─ assets/index.html # 原 iris.html（逐字节一致）
│  ├─ main.js           # 主进程：窗口/菜单/对话框/保存/单实例/协议
│  ├─ preload.js        # 上下文隔离桥 + 主世界注入
│  ├─ shim.js           # 打开/保存/菜单/拖拽 的接管逻辑
│  └─ ui/               # icon.png / .ico / .icns
├─ scripts/build.js     # 组装三端目录（resedit 改 exe 图标与版本，Linux 上可出 Windows 包）
├─ scripts/pack_release.py
├─ .cache/              # electron 三端运行时（构建缓存）
├─ dist/                # win / linux / mac 未压缩目录
└─ release/             # 三端发布包 + checksums.json
```

## 重新构建

```bash
npm install                 # electron + @electron/asar + resedit
bash build.sh               # = node scripts/build.js all && python3 scripts/pack_release.py
```

只打某一端：`node scripts/build.js win|linux|mac`。

## 已知限制

- Windows / macOS 包本次在 Linux 环境构建：exe 的图标与版本信息已用 `pefile` 校验结构（x64 / GUI 子系统 /
  资源完整），asar 内容与 Linux 包完全相同、且已在 Linux Electron 31 上实跑通过；但没有 Windows/macOS 真机启动验证。
- macOS 为 arm64 且未签名、未公证，需要用户手动放行。
- 超出内存的素材（极大视频）走的是整块读入内存 + 分块 IPC，未做流式管线。
