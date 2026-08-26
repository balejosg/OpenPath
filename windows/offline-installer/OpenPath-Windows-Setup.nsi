; OpenPath Windows offline installer template (generic, wrapper-agnostic).
; CI compiles this with pinned NSIS 3.10, appends the versioned trailer
; placeholder at EOF, and publishes OpenPath-Windows-Setup-Template.exe.
; Customization replaces only the trailer slot bytes; the template payload
; itself is never modified after compilation.
;
; Build-time overrides (pass with makensis -DKEY=VALUE):
;   REPO_ROOT            repo checkout root (defaults to ..\..)
;   BUILD_DIR            generated installer output and payload root
;   PAYLOAD_MANIFEST     built payload-manifest.json (defaults below)
;   EXTENSION_BUILD_DIR  firefox-extension build output root

Unicode true
ManifestDPIAware true

!define PRODUCT_NAME "OpenPath"
!define PRODUCT_DESCRIPTION "Strict Internet Access Control - offline classroom installer"

!ifndef REPO_ROOT
    !define REPO_ROOT "..\.."
!endif
!ifndef BUILD_DIR
    !define BUILD_DIR "${REPO_ROOT}\windows\offline-installer\build"
!endif
!ifndef PAYLOAD_MANIFEST
    !define PAYLOAD_MANIFEST "${BUILD_DIR}\payload-manifest.json"
!endif
!ifndef EXTENSION_BUILD_DIR
    !define EXTENSION_BUILD_DIR "${REPO_ROOT}\firefox-extension\build"
!endif
!ifndef PAYLOADS_DIR
    !define PAYLOADS_DIR "${BUILD_DIR}\payloads"
!endif

Name "${PRODUCT_NAME}"
OutFile "${BUILD_DIR}\OpenPath-Windows-Setup.exe"
InstallDir "$TEMP\OpenPathOfflineSetup"
SetCompressor /SOLID lzma
RequestExecutionLevel admin

VIProductVersion "1.0.0.0"
VIAddVersionKey /LANG=1033 "ProductName" "${PRODUCT_NAME} Offline Installer Template"
VIAddVersionKey /LANG=1033 "FileDescription" "${PRODUCT_DESCRIPTION}"

Function .onInit
    InitPluginsDir
    StrCpy $INSTDIR "$PLUGINSDIR\OpenPathOfflineSetup"
    ; Leave only a bounded, non-sensitive stage marker for the executable
    ; evidence lane. Delete a marker left by an earlier failed attempt before
    ; this run starts so stale diagnostics cannot be mistaken for progress.
    Delete "$TEMP\OpenPathOfflineSetup-$EXEFILE-status.txt"
FunctionEnd

Function WriteOfflineStage
    ; This file contains only an allow-listed stage name or numeric exit code.
    ; It exists solely to diagnose a non-zero child-process result without
    ; uploading installer logs, command lines, or configuration material.
    Exch $0
    FileOpen $1 "$TEMP\OpenPathOfflineSetup-$EXEFILE-status.txt" w
    FileWrite $1 "$0$\r$\n"
    FileClose $1
    Pop $0
FunctionEnd

Page InstFiles
ShowInstDetails show

Section "ReadTrailer" SEC00
    Push "read-trailer-start"
    Call WriteOfflineStage

    ; The trailer reader runs before the complete package is extracted. Stage
    ; only its two local validation dependencies in the temporary root first.
    SetOutPath "$INSTDIR\lib\internal"
    File "/oname=CapabilityStorage.ps1" "${REPO_ROOT}\windows\lib\internal\CapabilityStorage.ps1"
    SetOutPath "$INSTDIR\lib\install"
    File "/oname=Installer.Offline.ps1" "${REPO_ROOT}\windows\lib\install\Installer.Offline.ps1"
    SetOutPath "$INSTDIR"
    File "/oname=scripts\Read-Trailer.ps1" "${REPO_ROOT}\windows\offline-installer\scripts\Read-Trailer.ps1"

    ; Validate the versioned trailer before extracting anything. A template
    ; that was never customized carries a placeholder slot and aborts here.
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\scripts\Read-Trailer.ps1" -ExecutablePath "$EXEDIR\$EXEFILE" -OutputConfigPath "$INSTDIR\offline-config.json"'
    Pop $0
    Push "read-trailer-exit-$0"
    Call WriteOfflineStage
    IntCmp $0 0 trailer_ok trailer_failed trailer_failed
trailer_failed:
        DetailPrint "Trailer validation failed with code $0"
        SetErrorLevel 10
        Abort
trailer_ok:
    Push "read-trailer-ok"
    Call WriteOfflineStage
SectionEnd

Section "ExtractAndVerify" SEC01
    Push "extract-start"
    Call WriteOfflineStage

    ; Keep the extracted package layout aligned with the offline manifest:
    ; Windows sources are rooted at $INSTDIR, runtime assets under runtime\,
    ; and extension release artifacts under their own named directories.
    ; The build directory contains inputs and outputs for this compilation and
    ; must never be copied into the installer payload.
    SetOutPath "$INSTDIR"
    File /r /x "offline-installer\build" "${REPO_ROOT}\windows\*.*"
    File /oname=VERSION "${REPO_ROOT}\VERSION"
    File /oname=payload-manifest.json "${PAYLOAD_MANIFEST}"
    SetOutPath "$INSTDIR\runtime"
    File /r "${REPO_ROOT}\runtime\*.*"
    SetOutPath "$INSTDIR\payloads\acrylic"
    File /oname=Acrylic-Portable.zip "${PAYLOADS_DIR}\acrylic\Acrylic-Portable.zip"
    SetOutPath "$INSTDIR\payloads\firefox-esr"
    File /oname=Firefox-Setup-esr.exe "${PAYLOADS_DIR}\firefox-esr\Firefox-Setup-esr.exe"
    SetOutPath "$INSTDIR\firefox-release"
    File /nonfatal /a /r "${EXTENSION_BUILD_DIR}\firefox-release\*.*"
    SetOutPath "$INSTDIR\chromium-managed"
    File /nonfatal /a /r "${EXTENSION_BUILD_DIR}\chromium-managed\*.*"
    SetOutPath "$INSTDIR"
    Push "extract-ok"
    Call WriteOfflineStage
SectionEnd

Section "RunInstaller" SEC02
    Push "run-installer-start"
    Call WriteOfflineStage
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-OpenPath.ps1" -OfflineConfigPath "$INSTDIR\offline-config.json" -Unattended'
    Pop $1
    Push "run-installer-exit-$1"
    Call WriteOfflineStage
    SetErrorLevel $1
SectionEnd
