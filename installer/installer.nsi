; ============================================================================
; Ringopus Remote (producer app) - Windows installer
;
; Packages the Flutter release build produced by:
;   flutter build windows --release
; (output: build\windows\x64\runner\Release\) into a single Setup.exe.
;
; Build:
;   "C:\Program Files (x86)\NSIS\makensis.exe" installer\installer.nsi
; or just run installer\build.ps1, which also runs `flutter build` first.
;
; Output:
;   installer\Output\RingopusRemoteSetup.exe
;
; Only stock NSIS includes are used (MUI2, x64, FileFunc, WordFunc, LogicLib) -
; all of these ship with any standard NSIS installation, so no third-party
; plugins need to be downloaded separately.
; ============================================================================

Unicode true

; --------------------------- Configurable variables ------------------------
; Update these when the product identity, version, or publisher changes.
; PRODUCT_APP_ID must stay the same across releases (it's the upgrade/
; duplicate-install identity key) - only regenerate it if this ever becomes
; a genuinely different product.
!define PRODUCT_NAME             "Ringopus Remote"
!define PRODUCT_EXE              "ringopus_remote_producer.exe"
!define PRODUCT_PUBLISHER        "Ringopus"
!define PRODUCT_VERSION          "1.0.0.1"   ; must be X.X.X.X, keep in sync with pubspec.yaml's version+build
!define PRODUCT_VERSION_DISPLAY  "1.0.0"     ; human-readable, shown in Add/Remove Programs
!define PRODUCT_APP_ID           "8F1E4C2A-9B3D-4A6E-8C71-2D5E9F6A1B34"

!define RELEASE_DIR              "..\build\windows\x64\runner\Release"
!define ICON_FILE                "..\windows\runner\resources\app_icon.ico"
!define OUTPUT_FILE              "Output\RingopusRemoteSetup.exe"

!define UNINST_KEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_APP_ID}"
!define INSTALLER_MUTEX "Global\${PRODUCT_APP_ID}_SetupMutex"
; ----------------------------------------------------------------------------

!include "MUI2.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"
!include "WordFunc.nsh"
!include "LogicLib.nsh"

; ------------------------------- General ------------------------------------
Name "${PRODUCT_NAME}"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey HKLM "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey "ProductName"     "${PRODUCT_NAME}"
VIAddVersionKey "CompanyName"     "${PRODUCT_PUBLISHER}"
VIAddVersionKey "LegalCopyright"  "Copyright (C) ${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} Installer"
VIAddVersionKey "FileVersion"     "${PRODUCT_VERSION_DISPLAY}"
VIAddVersionKey "ProductVersion"  "${PRODUCT_VERSION_DISPLAY}"

; --------------------------------- MUI2 --------------------------------------
!define MUI_ABORTWARNING
!define MUI_ICON   "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${PRODUCT_NAME}"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ------------------------------ Installer init --------------------------------
Function .onInit
  SetRegView 64

  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "${PRODUCT_NAME} requires 64-bit Windows."
    Abort
  ${EndIf}

  ; Prevent two copies of the installer running at once.
  System::Call 'kernel32::CreateMutexW(i 0, i 0, w "${INSTALLER_MUTEX}") i .r1 ?e'
  Pop $R0
  ${If} $R0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "${PRODUCT_NAME} setup is already running."
    Abort
  ${EndIf}

  ; Detect an existing installation and offer to upgrade (uninstall old copy first).
  ReadRegStr $R1 HKLM "${UNINST_KEY}" "UninstallString"
  ${If} $R1 != ""
    ReadRegStr $R2 HKLM "${UNINST_KEY}" "DisplayVersion"

    ${IfNot} ${Silent}
      MessageBox MB_YESNO|MB_ICONQUESTION \
        "${PRODUCT_NAME} version $R2 is already installed.$\r$\n$\r$\nClick Yes to remove it and install version ${PRODUCT_VERSION_DISPLAY}, or No to cancel setup." \
        IDYES do_run_uninst
      Abort
    ${EndIf}

    do_run_uninst:
      ; Close a running instance so its files can be replaced.
      nsExec::Exec 'taskkill /F /IM "${PRODUCT_EXE}"'
      ExecWait '$R1 /S _?=$INSTDIR'
  ${EndIf}
FunctionEnd

Function un.onInit
  SetRegView 64
FunctionEnd

; --------------------------------- Install ------------------------------------
Section "MainSection" SEC01
  SectionIn RO

  ; Make sure no running instance locks the files we're about to overwrite.
  nsExec::Exec 'taskkill /F /IM "${PRODUCT_EXE}"'

  SetOutPath "$INSTDIR"
  ; Recursively package the entire Flutter release output - exe, flutter_windows.dll,
  ; icudtl.dat, data\ (assets, app.so), every plugin DLL, etc. New files added by a
  ; future `flutter build` (e.g. a new plugin's DLL) are picked up automatically
  ; without touching this script.
  File /r "${RELEASE_DIR}\*.*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Start Menu / Desktop shortcuts
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"
  CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall ${PRODUCT_NAME}.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"

  ; Add/Remove Programs registration
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName"          "${PRODUCT_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion"       "${PRODUCT_VERSION_DISPLAY}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher"             "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation"       "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon"           "$INSTDIR\${PRODUCT_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString"       '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString"  '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

; -------------------------------- Uninstall -----------------------------------
Section "Uninstall"
  nsExec::Exec 'taskkill /F /IM "${PRODUCT_EXE}"'

  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
