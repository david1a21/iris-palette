; Iris 调色盘 · Windows 安装器（NSIS）
; 由 scripts/make_setup.sh 调用，版本号与源目录通过 -D 传入：
;   makensis -DVERSION=1.0.39 -DSRCDIR=/abs/dist/win -DOUTFILE=/abs/release/xxx.exe installer.nsi
; 安装内容 = dist/win 整个目录（Electron 运行时 + resources/app.asar），
; 安装后写入「应用和功能」卸载项，卸载会清掉开始菜单、桌面快捷方式与安装目录。

Unicode true
!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "1.0.0"
!endif
!ifndef SRCDIR
  !error "缺少 -DSRCDIR（dist/win 的绝对路径）"
!endif
!ifndef OUTFILE
  !define OUTFILE "Iris-Palette-Windows-x64-Setup.exe"
!endif

!define APPNAME "Iris 调色盘"
!define APPEXE "Iris 调色盘.exe"
!define PUBLISHER "Iris"
!define REGPATH "Software\Microsoft\Windows\CurrentVersion\Uninstall\IrisPalette"
!define APPPATH "Software\Iris\IrisPalette"

Name "${APPNAME} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKLM "${APPPATH}" "InstallDir"
RequestExecutionLevel admin

SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDatablockOptimize on
CRCCheck on

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APPNAME} 安装程序"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "${PUBLISHER}"
VIAddVersionKey /LANG=2052 "LegalCopyright" ""

!ifdef ICONABS
  !define MUI_ICON "${ICONABS}"
  !define MUI_UNICON "${ICONABS}"
!else
  !define MUI_ICON "app/ui/icon.ico"
  !define MUI_UNICON "app/ui/icon.ico"
!endif
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "安装 ${APPNAME} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "将把 ${APPNAME} 安装到你的电脑。$\r$\n$\r$\n这是一个端侧运行的调色工具：所有照片只在本机处理，不联网、不上传。安装包内含 Electron 运行时，约 240 MB。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APPEXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 ${APPNAME}"
!define MUI_FINISHPAGE_LINK "查看更新与其它平台版本"
!define MUI_FINISHPAGE_LINK_LOCATION "https://github.com/david1a21/iris-palette/releases"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

!include "FileFunc.nsh"

Section "主程序（必需）" SEC_MAIN
  SectionIn RO

  SetOutPath "$INSTDIR"
  File /r "${SRCDIR}/*.*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${APPEXE}" "" "$INSTDIR\${APPEXE}" 0
  CreateShortcut "$SMPROGRAMS\${APPNAME}\卸载 ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "${APPPATH}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APPPATH}" "Version" "${VERSION}"

  WriteRegStr HKLM "${REGPATH}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${REGPATH}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${REGPATH}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${REGPATH}" "DisplayIcon" "$INSTDIR\${APPEXE}"
  WriteRegStr HKLM "${REGPATH}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${REGPATH}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${REGPATH}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${REGPATH}" "NoModify" 1
  WriteRegDWORD HKLM "${REGPATH}" "NoRepair" 1

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${REGPATH}" "EstimatedSize" "$0"
SectionEnd

Section "创建桌面快捷方式" SEC_DESKTOP
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${APPEXE}" "" "$INSTDIR\${APPEXE}" 0
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\卸载 ${APPNAME}.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"

  ; 先删卸载器自身之外的文件，再收尾
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKLM "${REGPATH}"
  DeleteRegKey HKLM "${APPPATH}"
SectionEnd

Function .onInit
  ; 已装过就默认沿用上次目录
  ReadRegStr $0 HKLM "${APPPATH}" "InstallDir"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
  ${EndIf}
FunctionEnd
