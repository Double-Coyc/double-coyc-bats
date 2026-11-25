@echo off
setlocal EnableExtensions
title Fix service folder ACL (trusted principals)

rem ===========================================================================
rem  Fix-Service-Folder-ACL.bat  v1.0
rem
rem  Fix: Windows refuses to register a service running as LocalSystem when
rem  the service binary lives in a folder that is not owned by a trusted
rem  principal, or that non-admin users can write to. Installers (Inno Setup,
rem  InstallShield) then fail with:
rem
rem    "Owner is outside the trusted system principals"
rem    "Access control entry grants rights outside the trusted system principals"
rem
rem  Typical cause: the folder was created by a regular user account (or on
rem  another machine / another install of Windows), so its owner is a user SID
rem  that is not in the trusted principals set, and the folder inherits
rem  "Users: Modify" from the parent.
rem
rem  What this script does (target folder only, nothing else is touched):
rem    owner -> BUILTIN\Administrators   (trusted principal)
rem    ACL   -> SYSTEM:F, Administrators:F, Users:RX
rem
rem  Usage:
rem    Fix-Service-Folder-ACL.bat "D:\Programs\Happ"
rem    Fix-Service-Folder-ACL.bat "D:\Programs\Happ" --check
rem    Fix-Service-Folder-ACL.bat "D:\Programs\Happ" --restore
rem    Fix-Service-Folder-ACL.bat --help
rem
rem  You can also drag and drop a folder onto the .bat file.
rem
rem  Options:
rem    --check    report the current owner/ACL, change nothing
rem    --restore  drop the strict ACL, restore inherited defaults
rem    --help     show this text
rem
rem  The script is idempotent: repeated runs produce the same ACL and never
rem  duplicate ACE entries.
rem ===========================================================================

set "VER=1.0"
set "MODE=prepare"
set "TARGET="

rem --- Values passed from the elevated re-launch (avoids quoting problems) ----
if defined SERVICE_ACL_MODE   set "MODE=%SERVICE_ACL_MODE%"
if defined SERVICE_ACL_TARGET set "TARGET=%SERVICE_ACL_TARGET%"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--help"    goto :usage
if /i "%~1"=="-h"        goto :usage
if /i "%~1"=="/?"        goto :usage
if /i "%~1"=="--check"   ( set "MODE=check"   & shift & goto :parse_args )
if /i "%~1"=="--restore" ( set "MODE=restore" & shift & goto :parse_args )
if defined TARGET (
    echo [ERROR] Unexpected argument: %~1
    echo.
    goto :usage_exit
)
set "TARGET=%~1"
shift
goto :parse_args

:args_done
if not defined TARGET (
    echo [ERROR] No target folder specified.
    echo.
    goto :usage_exit
)

rem Strip a trailing backslash, but keep the drive root intact for the check.
if "%TARGET:~-1%"=="\" set "TARGET=%TARGET:~0,-1%"
if "%TARGET:~-1%"==":" (
    echo [ERROR] Refusing to process a drive root. Point the script at a folder.
    goto :fail
)

rem --- Elevation (not needed for --check) ------------------------------------
if /i "%MODE%"=="check" goto :elevated
net session >nul 2>&1
if not errorlevel 1 goto :elevated
echo [INFO] Administrator rights are required, elevating...
set "SERVICE_ACL_MODE=%MODE%"
set "SERVICE_ACL_TARGET=%TARGET%"
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
echo ===========================================================================
echo   Fix service folder ACL v%VER%
echo   Mode  : %MODE%
echo   Target: %TARGET%
echo ===========================================================================
echo.

if /i "%MODE%"=="check"   goto :run_check
if /i "%MODE%"=="restore" goto :run_restore
goto :run_prepare

rem --- prepare ---------------------------------------------------------------
:run_prepare
if exist "%TARGET%" goto :prepare_exists
echo [1/3] Folder does not exist yet, creating it with the correct ACL...
mkdir "%TARGET%" >nul 2>&1
if not exist "%TARGET%" (
    echo [ERROR] Cannot create "%TARGET%".
    goto :fail
)
goto :prepare_owner

:prepare_exists
echo [1/3] Folder exists.

:prepare_owner
echo [2/3] Setting owner to BUILTIN\Administrators (trusted principal)...
takeown /F "%TARGET%" /A /R /D Y >nul 2>&1
if errorlevel 1 echo       [WARN] takeown skipped some files, this is usually harmless.

echo [3/3] Setting ACL: SYSTEM=F, Administrators=F, Users=RX...
call :apply_acl
goto :report

rem --- restore ---------------------------------------------------------------
:run_restore
if not exist "%TARGET%" (
    echo [ERROR] Folder not found: "%TARGET%"
    goto :fail
)
echo [1/1] Removing the strict ACL, restoring inherited permissions...
icacls "%TARGET%" /inheritance:e /Q >nul 2>&1
icacls "%TARGET%" /reset /T /C /Q >nul 2>&1
if errorlevel 1 echo       [WARN] icacls reported an error, check the folder manually.
echo       Done. The folder is back to inherited defaults.
goto :report

rem --- check -----------------------------------------------------------------
:run_check
if not exist "%TARGET%" (
    echo [ERROR] Folder not found: "%TARGET%"
    goto :fail
)
goto :report

rem --- helpers ---------------------------------------------------------------
:apply_acl
icacls "%TARGET%" /reset /T /C /Q >nul 2>&1
icacls "%TARGET%" /inheritance:r /Q
icacls "%TARGET%" /grant:r "*S-1-5-18:(OI)(CI)F"      /Q >nul
icacls "%TARGET%" /grant:r "*S-1-5-32-544:(OI)(CI)F"  /Q >nul
icacls "%TARGET%" /grant:r "*S-1-5-32-545:(OI)(CI)RX" /Q >nul
exit /b 0

:report
echo.
echo ---------------------------------------------------------------------------
echo   ACL report
echo ---------------------------------------------------------------------------
call :aclcheck "%TARGET%"

set "OK=1"
if /i "%AC_OWNER%"=="S-1-5-32-544" set "OK=1"
if /i not "%AC_OWNER%"=="S-1-5-32-544" if /i not "%AC_OWNER%"=="S-1-5-18" set "OK=0"
if /i not "%AC_BAD%"=="none" set "OK=0"

echo   owner SID             : %AC_OWNER%
echo   Trusted owner         : %TRUST_OWNER%
echo   Write access, untrusted: %AC_BAD%
echo.
if /i "%MODE%"=="restore" (
    echo   RESULT: inherited defaults restored. The folder is NOT service-ready now,
    echo           which is expected after --restore.
    echo           Run "prepare" again before the next install or update.
    echo.
    echo ACL dump:
    icacls "%TARGET%"
    echo.
    echo Done.
    exit /b 0
)
if "%OK%"=="1" (
    echo   RESULT: OK - this folder is safe for a LocalSystem service binary.
    echo           You can run the installer now.
) else (
    echo   RESULT: FAILED - the folder is still not suitable for a service.
    echo           Run the script as Administrator and check the output above.
)
echo.
echo ACL dump:
icacls "%TARGET%"
echo.
echo Done. Safe to run again at any time.
if "%OK%"=="1" exit /b 0
exit /b 1

rem :aclcheck <path> -> AC_OWNER (owner SID), AC_BAD ("none" or SIDs with write),
rem                    AC_AUTH (yes/no: Authenticated Users can write)
rem  SIDs are used instead of account names, so this works on every locale.
:aclcheck
set "AC_OWNER=?"
set "AC_BAD=?"
set "AC_AUTH=?"
set "AC_PATH=%~1"
set "AC_TMP=%TEMP%\service_acl_check.txt"
del /f /q "%AC_TMP%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%AC_PATH%'; $a=Get-Acl -LiteralPath $p; function T($i){ try { ([Security.Principal.NTAccount]$i).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $i.Value } }; $w=@($a.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights.ToString() -match 'Write|Modify|FullControl') }); $u=@('S-1-5-32-545','S-1-1-0','S-1-5-11','S-1-5-4','S-1-5-7','S-1-5-32-546','S-1-5-2'); $bad=@($w | ForEach-Object { T $_.IdentityReference } | Where-Object { $u -contains $_ } | Select-Object -Unique); $auth=@($w | ForEach-Object { T $_.IdentityReference } | Where-Object { $_ -eq 'S-1-5-11' }); (T $a.Owner) + '|' + $(if ($bad.Count -gt 0) { $bad -join ',' } else { 'none' }) + '|' + $(if ($auth.Count -gt 0) { 'yes' } else { 'no' })" > "%AC_TMP%" 2>nul
if not exist "%AC_TMP%" exit /b 0
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%AC_TMP%") do (
    set "AC_OWNER=%%A"
    set "AC_BAD=%%B"
    set "AC_AUTH=%%C"
)
del /f /q "%AC_TMP%" >nul 2>&1
set "TRUST_OWNER=no"
if /i "%AC_OWNER%"=="S-1-5-32-544" set "TRUST_OWNER=yes"
if /i "%AC_OWNER%"=="S-1-5-18"    set "TRUST_OWNER=yes"
exit /b 0

rem --- usage -----------------------------------------------------------------
:usage
echo.
echo Fix-Service-Folder-ACL.bat v%VER%
echo.
echo Fixes "Owner is outside the trusted system principals" and
echo "Access control entry grants rights outside the trusted system principals"
echo errors that installers show when they register a Windows service.
echo.
echo Usage:
echo   %~nx0 "C:\path\to\service\folder"             prepare (default)
echo   %~nx0 "C:\path\to\service\folder" --check     report only, no changes
echo   %~nx0 "C:\path\to\service\folder" --restore   back to inherited defaults
echo   %~nx0 --help                                  this text
echo.
echo A folder can also be dragged and dropped onto the .bat file.
echo.
echo What prepare does to the target folder:
echo   owner = BUILTIN\Administrators
echo   ACL   = SYSTEM:F, Administrators:F, Users:RX
echo.
echo Only the target folder is modified. Its parent is never touched.
echo The script is idempotent: running it again changes nothing.
echo.
exit /b 0

:usage_exit
call :usage
pause
exit /b 2

:fail
echo.
echo Aborted.
pause
exit /b 1
