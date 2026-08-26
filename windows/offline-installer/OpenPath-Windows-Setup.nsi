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

; The executable evidence lane reads a two-byte marker from %TEMP%. Keep the
; stage values stable and the exit value bounded to one byte; the marker must
; never contain configuration, command lines, or installer output.
!define OFFLINE_STATUS_SENTINEL 255
!define OFFLINE_STAGE_READ_TRAILER_START 10
!define OFFLINE_STAGE_READ_TRAILER_EXIT 11
!define OFFLINE_STAGE_READ_TRAILER_OK 12
!define OFFLINE_STAGE_EXTRACT_START 20
!define OFFLINE_STAGE_EXTRACT_OK 21
!define OFFLINE_STAGE_RUN_INSTALLER_START 30
!define OFFLINE_STAGE_RUN_INSTALLER_EXIT 31
!define OFFLINE_STATUS_EXEC_TIMEOUT 253
!define OFFLINE_STATUS_EXEC_ERROR 254

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
    Delete "$TEMP\OpenPathOfflineSetup-$EXEFILE-status-*.txt"
    Delete "$TEMP\OpenPathOfflineSetup-$EXEFILE-trailer-status.txt"
FunctionEnd

Function NormalizeOfflineStatusByte
    ; ExecWait normally returns a numeric process exit code, but it can return
    ; a string when Windows cannot start the child or the timeout is reached.
    ; Never pass those strings to FileWriteByte: NSIS would coerce them to an
    ; ambiguous zero byte. Reserve two values for these launch outcomes.
    Pop $R0
    StrCmp $R0 "" offline_status_exec_error
    StrCmp $R0 "error" offline_status_exec_error
    StrCmp $R0 "timeout" offline_status_exec_timeout
    Push $R0
    Return
offline_status_exec_error:
    Push "${OFFLINE_STATUS_EXEC_ERROR}"
    Return
offline_status_exec_timeout:
    Push "${OFFLINE_STATUS_EXEC_TIMEOUT}"
    Return
FunctionEnd

Function WriteOfflineStage
    ; Stack arguments are stage byte, then exit byte. FileWriteByte avoids any
    ; text encoding or locale ambiguity in this diagnostic-only marker.
    Pop $R0
    Pop $R1
    Push $R0
    Call NormalizeOfflineStatusByte
    Pop $R0
    FileOpen $R2 "$TEMP\OpenPathOfflineSetup-$EXEFILE-status.txt" w
    FileWriteByte $R2 $R1
    FileWriteByte $R2 $R0
    FileClose $R2
    FileOpen $R3 "$TEMP\OpenPathOfflineSetup-$EXEFILE-status-$R1.txt" w
    FileWriteByte $R3 $R1
    FileWriteByte $R3 $R0
    FileClose $R3
FunctionEnd

Page InstFiles
ShowInstDetails show

Section "ReadTrailer" SEC00
    Push "${OFFLINE_STAGE_READ_TRAILER_START}"
    Push "${OFFLINE_STATUS_SENTINEL}"
    Call WriteOfflineStage

    ; The trailer reader runs before the complete package is extracted. Stage
    ; only its two local validation dependencies in the temporary root first.
    SetOutPath "$INSTDIR\lib\internal"
    File "/oname=CapabilityStorage.ps1" "${REPO_ROOT}\windows\lib\internal\CapabilityStorage.ps1"
    SetOutPath "$INSTDIR\lib\install"
    File "/oname=Installer.Offline.ps1" "${REPO_ROOT}\windows\lib\install\Installer.Offline.ps1"
    SetOutPath "$INSTDIR"
    File "/oname=scripts\Read-Trailer.ps1" "${REPO_ROOT}\windows\offline-installer\scripts\Read-Trailer.ps1"

    ; Windows may deny a second reader while the running installer image is
    ; held open. Validate an exact byte-for-byte temporary copy of this same
    ; executable; it contains the same trailer and no second runtime.
    ClearErrors
    CopyFiles /SILENT "$EXEDIR\$EXEFILE" "$INSTDIR"
    IfErrors trailer_copy_error

    ; Validate the versioned trailer before extracting anything. A template
    ; that was never customized carries a placeholder slot and aborts here.
    ; Remove stale output before invoking the reader. A successful reader
    ; commits its validated configuration by creating this file.
    Delete "$INSTDIR\offline-config.json"
    ClearErrors
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\scripts\Read-Trailer.ps1" -ExecutablePath "$INSTDIR\$EXEFILE" -OutputConfigPath "$INSTDIR\offline-config.json" -StatusPath "$TEMP\OpenPathOfflineSetup-$EXEFILE-trailer-status.txt"' $0
    IfErrors trailer_exec_error
    ; Branch before any evidence publication so the child result controls the
    ; installer outcome rather than a diagnostic copy operation.
    ; ExecWait exposes the child result through a user variable. Reject the
    ; documented launch-error sentinel, then require the canonical reader's
    ; output file. That file is written only after trailer, payload, and JSON
    ; validation, and this output-file commit is stable across NSIS numeric
    ; representations on the real Windows runtime.
    StrCmp $0 "" trailer_exec_error
    StrCmp $0 "error" trailer_exec_error
    IfFileExists "$INSTDIR\offline-config.json" trailer_ok trailer_failed
trailer_failed:
    Push "${OFFLINE_STAGE_READ_TRAILER_EXIT}"
    Push $0
    Call WriteOfflineStage
        DetailPrint "Trailer validation failed with code $0"
        SetErrorLevel 10
        Abort
trailer_ok:
    Push "${OFFLINE_STAGE_READ_TRAILER_EXIT}"
    Push "0"
    Call WriteOfflineStage
    Push "${OFFLINE_STAGE_READ_TRAILER_OK}"
    Push "0"
    Call WriteOfflineStage
    ; The diagnostic is already a bounded two-byte marker in %TEMP%; it is
    ; never used to decide whether installation passes.
    Goto trailer_done
trailer_exec_error:
    StrCpy $0 "${OFFLINE_STATUS_EXEC_ERROR}"
    Push "${OFFLINE_STAGE_READ_TRAILER_EXIT}"
    Push $0
    Call WriteOfflineStage
    SetErrorLevel 10
    Abort
trailer_copy_error:
    DetailPrint "Could not stage a private executable copy for trailer validation"
    SetErrorLevel 10
    Abort
trailer_done:
SectionEnd

Section "ExtractAndVerify" SEC01
    Push "${OFFLINE_STAGE_EXTRACT_START}"
    Push "${OFFLINE_STATUS_SENTINEL}"
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
    Push "${OFFLINE_STAGE_EXTRACT_OK}"
    Push "0"
    Call WriteOfflineStage
SectionEnd

Section "RunInstaller" SEC02
    Push "${OFFLINE_STAGE_RUN_INSTALLER_START}"
    Push "${OFFLINE_STATUS_SENTINEL}"
    Call WriteOfflineStage
    ClearErrors
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-OpenPath.ps1" -OfflineConfigPath "$INSTDIR\offline-config.json" -Unattended' $1
    IfErrors installer_exec_error
    Push "${OFFLINE_STAGE_RUN_INSTALLER_EXIT}"
    Push $1
    Call WriteOfflineStage
    SetErrorLevel $1
    Goto installer_done
installer_exec_error:
    Push "${OFFLINE_STAGE_RUN_INSTALLER_EXIT}"
    Push "${OFFLINE_STATUS_EXEC_ERROR}"
    Call WriteOfflineStage
    SetErrorLevel 1
installer_done:
SectionEnd
