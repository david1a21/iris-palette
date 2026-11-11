/* 打包：把 app/ 打成 asar，并改写 Windows 的 exe 图标 / 版本信息
 * 纯 JS 实现（rcedit 需要 wine，这里用 resedit 直接改 PE 资源，Linux 上也能出 Windows 包）
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const CACHE = path.join(ROOT, '.cache');
const DIST = path.join(ROOT, 'dist');
const APP = path.join(ROOT, 'app');
const UI = path.join(APP, 'ui');
const VERSION = '1.0.5';

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: 'inherit', ...opts });

function extract(zipName, outDir) {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  run('unzip', ['-q', path.join(CACHE, zipName), '-d', outDir]);
}

async function packAsar(destAsar) {
  const asar = require('@electron/asar');
  fs.mkdirSync(path.dirname(destAsar), { recursive: true });
  fs.rmSync(destAsar, { force: true });
  await asar.createPackage(APP, destAsar);
  return destAsar;
}

/* ---------- Windows ---------- */
function patchWindowsExe(srcExe, dstExe) {
  const RE = require('resedit');
  const exe = RE.NtExecutable.from(fs.readFileSync(srcExe), { ignoreCert: true });
  const res = RE.NtExecutableResource.from(exe);

  // 图标
  const iconFile = RE.Data.IconFile.from(fs.readFileSync(path.join(UI, 'icon.ico')));
  const groups = RE.Resource.IconGroupEntry.fromEntries(res.entries);
  if (groups.length) {
    RE.Resource.IconGroupEntry.replaceIconsForResource(
      res.entries, groups[0].id, groups[0].lang, iconFile.icons.map((i) => i.data),
    );
  }

  // 版本信息
  const vis = RE.Resource.VersionInfo.fromEntries(res.entries);
  if (vis.length) {
    const vi = vis[0];
    vi.setFileVersion(1, 0, 0, 0);
    vi.setProductVersion(1, 0, 0, 0);
    vi.setStringValues({ lang: 1033, codepage: 1200 }, {
      ProductName: 'Iris 调色盘',
      FileDescription: 'Iris 调色盘 —— 语义感知的端侧照片编辑器',
      CompanyName: 'Iris',
      LegalCopyright: '© 2026 Iris',
      OriginalFilename: path.basename(dstExe),
      InternalName: 'iris-palette',
      FileVersion: VERSION,
      ProductVersion: VERSION,
    });
    vi.outputToResourceEntries(res.entries);
  }

  res.outputResource(exe);
  fs.writeFileSync(dstExe, Buffer.from(exe.generate()));
}

async function buildWindows() {
  const out = path.join(DIST, 'win');
  extract('electron-win32-x64.zip', out);
  const resources = path.join(out, 'resources');
  fs.rmSync(path.join(resources, 'default_app.asar'), { force: true });
  await packAsar(path.join(resources, 'app.asar'));

  const srcExe = path.join(out, 'electron.exe');
  const dstExe = path.join(out, 'Iris 调色盘.exe');
  patchWindowsExe(srcExe, dstExe);
  fs.rmSync(srcExe, { force: true });
  console.log('  windows exe:', dstExe, Math.round(fs.statSync(dstExe).size / 1024), 'KB');
  return out;
}

/* ---------- Linux ---------- */
async function buildLinux() {
  const out = path.join(DIST, 'linux');
  extract('electron-linux-x64.zip', out);
  const resources = path.join(out, 'resources');
  fs.rmSync(path.join(resources, 'default_app.asar'), { force: true });
  await packAsar(path.join(resources, 'app.asar'));

  fs.renameSync(path.join(out, 'electron'), path.join(out, 'iris-palette'));
  fs.chmodSync(path.join(out, 'iris-palette'), 0o755);

  fs.writeFileSync(path.join(out, 'iris-palette.desktop'), [
    '[Desktop Entry]',
    'Type=Application',
    'Name=Iris 调色盘',
    'Name[zh_CN]=Iris 调色盘',
    'Comment=语义感知的端侧照片编辑器',
    'Exec=iris-palette %f',
    'Icon=iris-palette',
    'Terminal=false',
    'Categories=Graphics;Photography;',
    'MimeType=image/jpeg;image/png;image/heic;image/webp;',
    'StartupWMClass=Iris 调色盘',
    '',
  ].join('\n'));

  fs.copyFileSync(path.join(UI, 'icon.png'), path.join(out, 'iris-palette.png'));
  fs.writeFileSync(path.join(out, 'README.txt'), [
    'Iris 调色盘 (Linux x64)',
    '启动：./iris-palette',
    '安装到系统菜单：把 iris-palette.desktop 复制到 ~/.local/share/applications/',
    '若提示缺少库，请安装 libnss3 / libgtk-3-0 / libgbm1 / libasound2。',
    '',
  ].join('\n'));
  return out;
}

/* ---------- macOS（未签名，需右键打开） ---------- */
async function buildMac(zipName = 'electron-darwin-arm64.zip', dirName = 'mac') {
  const out = path.join(DIST, dirName);
  extract(zipName, out);
  const appName = 'Iris 调色盘.app';
  const appPath = path.join(out, appName);
  fs.renameSync(path.join(out, 'Electron.app'), appPath);

  const contents = path.join(appPath, 'Contents');
  const resources = path.join(contents, 'Resources');
  fs.rmSync(path.join(resources, 'default_app.asar'), { force: true });
  await packAsar(path.join(resources, 'app.asar'));
  fs.copyFileSync(path.join(UI, 'icon.icns'), path.join(resources, 'icon.icns'));

  // 可执行文件改名（Info.plist 的 CFBundleExecutable 必须与之一致）
  const macosDir = path.join(contents, 'MacOS');
  const oldExec = path.join(macosDir, 'Electron');
  const newExec = path.join(macosDir, 'Iris 调色盘');
  fs.renameSync(oldExec, newExec);
  fs.chmodSync(newExec, 0o755);

  const plistPath = path.join(contents, 'Info.plist');
  let plist = fs.readFileSync(plistPath, 'utf8');
  const setKey = (key, value) => {
    const re = new RegExp(`(<key>${key}</key>\\s*<string>)[^<]*(</string>)`);
    if (re.test(plist)) plist = plist.replace(re, `$1${value}$2`);
  };
  setKey('CFBundleExecutable', 'Iris 调色盘');
  setKey('CFBundleName', 'Iris 调色盘');
  setKey('CFBundleDisplayName', 'Iris 调色盘');
  setKey('CFBundleIdentifier', 'com.iris.palette');
  setKey('CFBundleIconFile', 'icon.icns');
  setKey('CFBundleShortVersionString', VERSION);
  setKey('CFBundleVersion', VERSION);
  setKey('LSApplicationCategoryType', 'public.app-category.photography');
  setKey('LSMinimumSystemVersion', '10.15');
  fs.writeFileSync(plistPath, plist);

  // 辅助进程也改个名字，避免活动监视器里显示 Electron Helper
  return out;
}

async function main() {
  fs.mkdirSync(DIST, { recursive: true });
  const which = process.argv[2] || 'all';
  const outDirs = {};
  if (which === 'all' || which === 'win') outDirs.win = await buildWindows();
  if (which === 'all' || which === 'linux') outDirs.linux = await buildLinux();
  if (which === 'all' || which === 'mac') outDirs.mac = await buildMac('electron-darwin-arm64.zip', 'mac');
  if (which === 'all' || which === 'macx64') outDirs.macx64 = await buildMac('electron-darwin-x64.zip', 'mac-x64');

  fs.writeFileSync(path.join(DIST, 'build-info.json'), JSON.stringify({
    version: VERSION,
    electron: '31.7.7',
    builtAt: new Date().toISOString(),
    targets: Object.keys(outDirs),
  }, null, 2));
  console.log('done:', outDirs);
}

main().catch((e) => { console.error(e); process.exit(1); });
