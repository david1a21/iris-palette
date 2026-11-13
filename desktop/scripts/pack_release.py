#!/usr/bin/env python3
"""把 dist/{win,linux,mac} 打成发布包（UTF-8 文件名 + 保留可执行位/符号链接）"""
import os, shutil, subprocess, zipfile, hashlib, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, 'dist')
OUT = os.path.join(ROOT, 'release')
VER = '1.0.9'
os.makedirs(OUT, exist_ok=True)

README_MAC = """Iris 调色盘 · macOS（未签名）
================================

架构：本包为 {arch} 版本。Apple 芯片（M1/M2/M3/M4）请用 arm64 包，Intel 机器请用 x64 包。
系统要求：macOS 12 Monterey 及以上（10.15 及更早版本未测试）。

首次打开
- 未做代码签名与公证，双击若提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」：
  打开「访达」找到 App → 右键（或按住 Control 点按）→ 打开 → 再点「打开」。
  或在「系统设置 → 隐私与安全性」页面底部点「仍要打开」。
- 若提示「已损坏，无法打开」（多见于从网盘下载后带隔离属性），在终端执行：
  xattr -dr com.apple.quarantine "/Applications/Iris 调色盘.app"

说明
- 应用为纯本地运行，不联网、不上传照片；页面与安装包内嵌同一份 index.html。
- 卸载：把 App 拖进废纸篓即可，配置保存在 ~/Library/Application Support/Iris 调色盘。
"""

README_WIN = """Iris 调色盘 · Windows x64
================================

启动：双击「Iris 调色盘.exe」

说明
- 免安装。整个文件夹要一起保留，不要只拷贝 exe（Electron 运行时在同目录）。
- 未做代码签名，首次启动 Windows SmartScreen 可能提示「未知发布者」：
  点「更多信息」→「仍要运行」。也可右键 exe → 属性 → 解除锁定。
- 原生能力：打开/保存走系统对话框，导出文件默认落在上次保存的目录；
  支持把照片拖进窗口，Ctrl+O 打开、Ctrl+S 导出、Ctrl+K 全局搜索。

卸载：直接删除文件夹。
"""

README_LINUX = """Iris 调色盘 · Linux x64
=======================

启动：./iris-palette
装进系统菜单：把 iris-palette.desktop 复制到 ~/.local/share/applications/，
并把 iris-palette.png 复制到 ~/.local/share/icons/（或 ~/.icons/）。

依赖：libnss3 / libgtk-3-0 / libgbm1 / libasound2（多数桌面发行版已自带）。

全部释放后需要保留可执行位：chmod +x iris-palette
"""

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def zip_dir(src, arcroot, dest, extra=None):
    if os.path.exists(dest):
        os.remove(dest)
    with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED, compresslevel=6, strict_timestamps=False) as z:
        for base, dirs, files in os.walk(src):
            dirs.sort(); files.sort()
            for name in files:
                full = os.path.join(base, name)
                rel = os.path.relpath(full, src)
                z.write(full, os.path.join(arcroot, rel))
        for name, content in (extra or {}).items():
            z.writestr(os.path.join(arcroot, name), content)
    return dest

def tar_dir(src, arcroot, dest):
    if os.path.exists(dest):
        os.remove(dest)
    subprocess.run(['tar', '-czf', dest, '-C', os.path.dirname(src), os.path.basename(src)], check=True)
    # 重命名根目录
    work = os.path.join('/tmp', arcroot)
    shutil.rmtree(work, ignore_errors=True)
    subprocess.run(['tar', '-xzf', dest, '-C', '/tmp'], check=True)
    srcname = os.path.join('/tmp', os.path.basename(src))
    if srcname != work:
        shutil.move(srcname, work)
    subprocess.run(['tar', '-czf', dest, '-C', '/tmp', arcroot], check=True)
    shutil.rmtree(work, ignore_errors=True)
    return dest

results = []

# Windows
win = os.path.join(DIST, 'win')
if os.path.isdir(win):
    out = os.path.join(OUT, f'Iris-Palette-Windows-x64-{VER}.zip')
    zip_dir(win, 'IrisPalette-Windows-x64', out, {'启动说明.txt': README_WIN})
    results.append(('Windows', out))

# Linux（tar.gz 保留执行权限）
linux = os.path.join(DIST, 'linux')
if os.path.isdir(linux):
    out = os.path.join(OUT, f'Iris-Palette-Linux-x64-{VER}.tar.gz')
    tmp = os.path.join('/tmp', 'IrisPalette-Linux-x64')
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(linux, tmp, symlinks=True)
    with open(os.path.join(tmp, '启动说明.txt'), 'w') as f:
        f.write(README_LINUX)
    subprocess.run(['tar', '-czf', out, '-C', '/tmp', 'IrisPalette-Linux-x64'], check=True)
    shutil.rmtree(tmp, ignore_errors=True)
    results.append(('Linux', out))

# macOS（zip -y 保留 .app 内部符号链接）
mac = os.path.join(DIST, 'mac')
if os.path.isdir(mac):
    out = os.path.join(OUT, f'Iris-Palette-macOS-arm64-{VER}.zip')
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, LANG='C.UTF-8', LC_ALL='C.UTF-8')
    txt = os.path.join(mac, '启动说明.txt')
    open(txt, 'w', encoding='utf-8').write(README_MAC.format(arch='arm64（Apple 芯片）'))
    subprocess.run(['zip', '-qry', out, 'Iris 调色盘.app', '启动说明.txt'], cwd=mac, check=True, env=env)
    os.remove(txt)
    results.append(('macOS', out))

# macOS Intel（x86_64，兼容 macOS 12 Monterey 及以上）
macx64 = os.path.join(DIST, 'mac-x64')
if os.path.isdir(macx64):
    out = os.path.join(OUT, f'Iris-Palette-macOS-x64-{VER}.zip')
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, LANG='C.UTF-8', LC_ALL='C.UTF-8')
    txt = os.path.join(macx64, '启动说明.txt')
    open(txt, 'w', encoding='utf-8').write(README_MAC.format(arch='x86_64（Intel）'))
    subprocess.run(['zip', '-qry', out, 'Iris 调色盘.app', '启动说明.txt'], cwd=macx64, check=True, env=env)
    os.remove(txt)
    results.append(('macOS Intel', out))

print('\n=== release ===')
meta = []
for name, path in results:
    size = os.path.getsize(path)
    digest = sha256(path)
    meta.append({'target': name, 'file': os.path.basename(path), 'bytes': size, 'sha256': digest})
    print(f'{name:8s} {size/1048576:7.1f} MB  {os.path.basename(path)}  {digest[:16]}')

with open(os.path.join(OUT, 'checksums.json'), 'w') as f:
    json.dump({'version': VER, 'files': meta}, f, ensure_ascii=False, indent=1)
