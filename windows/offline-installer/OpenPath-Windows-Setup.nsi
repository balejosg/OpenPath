; OpenPath Windows offline installer template (generic, wrapper-agnostic).
; CI compiles this with pinned NSIS 3.10, appends the versioned trailer
; placeholder at EOF, and publishes OpenPath-Windows-Setup-Template.exe.
; Customization replaces only the trailer slot bytes; the template payload
; itself is never modified after compilation.
;
; Build-time overrides (pass with makensis -DKEY=VALUE):
;   REPO_ROOT            repo checkout root (defaults to ..\..)
;   PAYLOAD_MANIFEST     built payload-manifest.json (defaults to ..\build\)
;   EXTENSION_BUILD_DIR  firefox-extension build output root

Unicode true
ManifestDPIAware true

!define PRODUCT_NAME "OpenPath"
!define PRODUCT_DESCRIPTION "Strict Internet Access Control - offline classroom installer"

!ifndef REPO_ROOT
    !define REPO_ROOT "..\.."
!endif
!ifndef PAYLOAD_MANIFEST
    !define PAYLOAD_MANIFEST "..\build\payload-manifest.json"
!endif
!ifndef EXTENSION_BUILD_DIR
    !define EXTENSION_BUILD_DIR "${REPO_ROOT}\firefox-extension\build"
!endif
!ifndef PAYLOADS_DIR
    !define PAYLOADS_DIR "..\build\payloads"
!endif

Name "${PRODUCT_NAME}"
OutFile "..\build\OpenPath-Windows-Setup.exe"
InstallDir "$TEMP\OpenPathOfflineSetup"
SetCompressor /SOLID lzma
RequestExecutionLevel admin

VIProductVersion "1.0.0.0"
VIAddVersionKey /LANG=1033 "ProductName" "${PRODUCT_NAME} Offline Installer Template"
VIAddVersionKey /LANG=1033 "FileDescription" "${PRODUCT_DESCRIPTION}"

Page InstFiles
ShowInstDetails show

Section "ReadTrailer" SEC00
    SetOutPath "$INSTDIR"
    File "/oname=scripts\Read-Trailer.ps1" "scripts\Read-Trailer.ps1"

    ; Validate the versioned trailer before extracting anything. A template
    ; that was never customized carries a placeholder slot and aborts here.
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\scripts\Read-Trailer.ps1" -ExecutablePath "$EXEPATH" -OutputConfigPath "$INSTDIR\offline-config.json"'
    Pop $0
    IntCmp $0 0 +3 0 +3
        DetailPrint "Trailer validation failed with code $0"
        SetErrorLevel 10
        Abort
SectionEnd

Section "ExtractAndVerify" SEC01
    File /r "${REPO_ROOT}\windows\*.*"
    File /r "${REPO_ROOT}\runtime\*.*"
    File /oname=VERSION "${REPO_ROOT}\VERSION"
    File /oname=payload-manifest.json "${PAYLOAD_MANIFEST}"
    File /oname=payloads\acrylic\Acrylic-Portable.zip "${PAYLOADS_DIR}\acrylic\Acrylic-Portable.zip"
    File /oname=payloads\firefox-esr\Firefox-Setup-esr.exe "${PAYLOADS_DIR}\firefox-esr\Firefox-Setup-esr.exe"
    File /nonfatal /a /r "${EXTENSION_BUILD_DIR}\firefox-release\*.*"
    File /nonfatal /a /r "${EXTENSION_BUILD_DIR}\chromium-managed\*.*"
SectionEnd

Section "RunInstaller" SEC02
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-OpenPath.ps1" -OfflineConfigPath "$INSTDIR\offline-config.json" -Unattended'
    Pop $1
    SetErrorLevel $1
SectionEnd
