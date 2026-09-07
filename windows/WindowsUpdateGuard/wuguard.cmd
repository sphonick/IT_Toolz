@echo off
REM ===========================================================================
REM  wuguard.cmd - Windows Update Guard
REM
REM  Undoes the "pause / defer Windows Update" state that something on the box
REM  keeps re-applying, and installs itself as a scheduled task so it runs
REM  shortly after every boot and periodically thereafter.
REM
REM  Usage (elevated; double-clicking works too, it self-elevates):
REM
REM    wuguard.cmd install      Copy to %ProgramData% and register the boot task
REM    wuguard.cmd uninstall    Remove the scheduled task
REM    wuguard.cmd repair       Apply the fix once, right now
REM    wuguard.cmd repair /gpo  ...and also clear the local Group Policy cache
REM    wuguard.cmd audit        Read-only dump of the current update policy state
REM    wuguard.cmd status       Scheduled task state + last log lines
REM
REM  With no argument, "repair" is assumed - that is what the task invokes.
REM  Log: %ProgramData%\IT_Toolz\WindowsUpdateGuard\wuguard.log
REM
REM  NOTE: no "!" characters in log messages - delayed expansion eats them.
REM ===========================================================================

setlocal EnableExtensions EnableDelayedExpansion

set "SELF=%~f0"
set "INSTDIR=%ProgramData%\IT_Toolz\WindowsUpdateGuard"
set "INSTALLED=%INSTDIR%\wuguard.cmd"
set "LOG=%INSTDIR%\wuguard.log"
set "TASKNAME=\IT_Toolz\WindowsUpdateGuard"
set "BOOTDELAY=0002:00"
set "REPEATMINS=240"

set "ACTION=%~1"
if not defined ACTION set "ACTION=repair"
set "OPT=%~2"

set "UX=HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
set "POL=HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
set "AU=HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
set "MDM=HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
set "SVCROOT=HKLM\SYSTEM\CurrentControlSet\Services"

set "CHANGES=0"
set "PROBLEMS=0"

if /i "%ACTION%"=="status" goto :dispatch

REM --- everything except "status" needs to be elevated -----------------------
fltmc >nul 2>&1
if errorlevel 1 (
    echo [wuguard] Not elevated - relaunching as administrator...
    powershell -NoProfile -Command "Start-Process cmd.exe -Verb RunAs -ArgumentList '/k',[char]34+'%SELF%'+[char]34+' %ACTION% %OPT%'" >nul 2>&1
    if errorlevel 1 echo [wuguard] Elevation failed. Right-click the file and choose "Run as administrator".
    exit /b 1
)

if not exist "%INSTDIR%" mkdir "%INSTDIR%" >nul 2>&1

:dispatch
if /i "%ACTION%"=="install"   goto :install
if /i "%ACTION%"=="uninstall" goto :uninstall
if /i "%ACTION%"=="repair"    goto :repair
if /i "%ACTION%"=="audit"     goto :audit
if /i "%ACTION%"=="status"    goto :status
echo Unknown action "%ACTION%".  Use: install ^| uninstall ^| repair ^| audit ^| status
exit /b 2


REM ===========================================================================
REM  REPAIR
REM ===========================================================================
:repair
call :log "==== repair start (user=%USERNAME% host=%COMPUTERNAME%) ===="

call :log "-- clearing the Settings-app pause window (UX\Settings)"
for %%V in (
    PauseUpdatesExpiryTime
    PauseUpdatesStartTime
    PauseFeatureUpdatesStartTime
    PauseFeatureUpdatesEndTime
    PauseQualityUpdatesStartTime
    PauseQualityUpdatesEndTime
    PausedFeatureStatus
    PausedQualityStatus
    PausedFeatureDate
    PausedQualityDate
    FlightSettingsMaxPauseDays
) do call :delval "%UX%" "%%V"

call :log "-- clearing deferral / pause policy (Policies\...\WindowsUpdate)"
for %%V in (
    DeferFeatureUpdates
    DeferFeatureUpdatesPeriodInDays
    DeferQualityUpdates
    DeferQualityUpdatesPeriodInDays
    PauseFeatureUpdates
    PauseFeatureUpdatesStartTime
    PauseQualityUpdates
    PauseQualityUpdatesStartTime
    DeferUpgrade
    DeferUpgradePeriod
    DeferUpdatePeriod
    BranchReadinessLevel
    TargetReleaseVersion
    TargetReleaseVersionInfo
    ProductVersion
    SetDisableUXWUAccess
    SetDisablePauseUXAccess
    DisableWindowsUpdateAccess
    DoNotConnectToWindowsUpdateInternetLocations
    ExcludeWUDriversInQualityUpdate
) do call :delval "%POL%" "%%V"

call :log "-- re-enabling automatic updates (Policies\...\WindowsUpdate\AU)"
call :delval "%AU%" "NoAutoUpdate"
call :delval "%AU%" "AUOptions"
call :delval "%AU%" "NoAutoRebootWithLoggedOnUsers"

REM WSUS and MDM are usually deliberate in a managed fleet - report, never
REM silently remove, or you break patching instead of fixing it.
call :warnif "%AU%" "UseWUServer"  "UseWUServer is set - this box takes updates from WSUS, not Microsoft Update"
call :warnif "%POL%" "WUServer"    "WUServer is set - WSUS redirection is in effect"
reg query "%MDM%" >nul 2>&1 && call :warn "MDM/Intune update policy present under PolicyManager - local edits get re-synced away; fix it at the MDM console"

REM Known cause, confirmed 2026-09-06: an unattend answer file registers a
REM boot-triggered task that re-pauses updates. Report, do not auto-delete -
REM deleting someone's scheduled task is not this tool's call to make.
if exist "%SystemRoot%\Setup\Scripts\PauseWindowsUpdate.ps1" call :warn "unattend artifact C:\Windows\Setup\Scripts\PauseWindowsUpdate.ps1 is present"
schtasks /Query /TN "\PauseWindowsUpdate" >nul 2>&1 && call :warn "task \PauseWindowsUpdate exists - it re-pauses updates every boot. Remove: schtasks /Delete /TN \PauseWindowsUpdate /F"
schtasks /Query /TN "\MoveActiveHours" >nul 2>&1 && call :warn "task \MoveActiveHours exists - it slides Active Hours so installs never run. Remove: schtasks /Delete /TN \MoveActiveHours /F"

call :log "-- restoring update service start types"
call :svc wuauserv        demand
call :svc UsoSvc          auto
call :svc WaaSMedicSvc    demand
call :svc BITS            demand
call :svc DoSvc           delayed-auto
call :svc cryptsvc        auto
call :svc TrustedInstaller demand

call :log "-- re-enabling disabled Windows Update scheduled tasks"
set "TASKSFIXED=0"
for /f "usebackq tokens=1 delims=," %%A in (`schtasks /Query /FO CSV /NH 2^>nul`) do call :entask "%%~A"
call :log "   update-related scheduled tasks confirmed enabled: !TASKSFIXED!"

if /i "%OPT%"=="/gpo" call :cleargpo

call :log "-- kicking off an update scan"
sc start wuauserv >nul 2>&1
if exist "%SystemRoot%\System32\UsoClient.exe" (
    start "" /b "%SystemRoot%\System32\UsoClient.exe" StartScan
    call :log "   UsoClient StartScan issued"
) else (
    call :log "   UsoClient.exe not present - skipped scan trigger"
)

call :log "==== repair done: !CHANGES! value(s) changed, !PROBLEMS! warning(s) ===="
echo.
echo Done. !CHANGES! change(s), !PROBLEMS! warning(s).
echo Log: %LOG%
exit /b 0


REM ===========================================================================
REM  INSTALL / UNINSTALL / STATUS
REM ===========================================================================
:install
call :log "==== install ===="
if /i not "%SELF%"=="%INSTALLED%" (
    copy /y "%SELF%" "%INSTALLED%" >nul 2>&1
    if errorlevel 1 (
        echo Could not copy to "%INSTALLED%".
        exit /b 1
    )
    call :log "copied to %INSTALLED%"
)

schtasks /Query /TN "%TASKNAME%" >nul 2>&1 && (
    call :log "existing task found - replacing it"
    schtasks /Delete /TN "%TASKNAME%" /F >nul 2>&1
)

REM INSTALLED has no spaces by construction (C:\ProgramData\IT_Toolz\...),
REM which keeps the /TR quoting sane.
set "TASKCMD=cmd.exe /c %INSTALLED% repair"

REM Boot trigger plus a periodic repeat. /RI with /DU is not accepted on every
REM build, so fall back to a boot-only task if the first form is rejected.
schtasks /Create /TN "%TASKNAME%" /TR "%TASKCMD%" /SC ONSTART /DELAY %BOOTDELAY% /RI %REPEATMINS% /DU 9999:59 /RU "SYSTEM" /RL HIGHEST /F >nul 2>&1
if errorlevel 1 (
    call :log "repeating trigger rejected by schtasks - creating a boot-only task"
    schtasks /Create /TN "%TASKNAME%" /TR "%TASKCMD%" /SC ONSTART /DELAY %BOOTDELAY% /RU "SYSTEM" /RL HIGHEST /F >nul 2>&1
)
schtasks /Query /TN "%TASKNAME%" >nul 2>&1
if errorlevel 1 (
    call :warn "task creation FAILED"
    echo Task creation failed. See %LOG%
    exit /b 1
)
call :log "task %TASKNAME% registered (SYSTEM, %BOOTDELAY% after boot, repeat %REPEATMINS% min)"

echo.
echo Installed.
echo   Script : %INSTALLED%
echo   Task   : %TASKNAME%
echo   Log    : %LOG%
echo.
echo Running the repair once now...
echo.
call :repair
exit /b 0

:uninstall
call :log "==== uninstall ===="
schtasks /Delete /TN "%TASKNAME%" /F >nul 2>&1
if errorlevel 1 (
    echo No scheduled task named "%TASKNAME%" was present.
) else (
    call :log "task %TASKNAME% deleted"
    echo Scheduled task removed. Script and log left in %INSTDIR%
)
exit /b 0

:status
echo === Scheduled task ===
schtasks /Query /TN "%TASKNAME%" /V /FO LIST 2>nul | findstr /i /c:"TaskName" /c:"Status" /c:"Next Run" /c:"Last Run" /c:"Last Result" /c:"Schedule Type" /c:"Repeat"
if errorlevel 1 echo   (task not installed)
echo.
echo === Current pause state ===
reg query "%UX%" 2>nul | findstr /i "Pause"
if errorlevel 1 echo   (no pause values present - updates are not paused)
echo.
echo === Last 15 log lines ===
if not exist "%LOG%" (
    echo   (no log yet^)
) else (
    powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 15" 2>nul || type "%LOG%"
)
exit /b 0


REM ===========================================================================
REM  AUDIT - read-only
REM ===========================================================================
:audit
echo ================= Windows Update policy audit =================
echo Host: %COMPUTERNAME%   %DATE% %TIME%
echo.
echo --- UX\Settings (the Settings-app pause window) ---
reg query "%UX%" 2>nul || echo   (key absent)
echo.
echo --- Policies\Microsoft\Windows\WindowsUpdate ---
reg query "%POL%" 2>nul || echo   (key absent - no local/GPO update policy)
echo.
echo --- ...\WindowsUpdate\AU ---
reg query "%AU%" 2>nul || echo   (key absent)
echo.
echo --- MDM / Intune (PolicyManager) ---
reg query "%MDM%" 2>nul || echo   (not MDM-managed for Update)
echo.
echo --- Unattend setup scripts (%SystemRoot%\Setup\Scripts) ---
if exist "%SystemRoot%\Setup\Scripts\*" (
    echo   PRESENT. These are dropped by an unattended-install answer file and run
    echo   during Windows Setup. They can register boot-triggered scheduled tasks.
    echo   CONFIRMED CAUSE 2026-09-06: PauseWindowsUpdate.ps1 re-stamps a rolling
    echo   7-day pause window at every boot. See Scripts\README.md in the repo.
    dir /b "%SystemRoot%\Setup\Scripts" 2>nul
) else (
    echo   not present
)
echo.
echo --- Local Group Policy cache ---
if exist "%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol" (
    echo   Registry.pol EXISTS - Group Policy re-applies its contents at boot and
    echo   every ~90 minutes, which is why hand-edited registry values do not stick.
    dir /-c "%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol" | findstr /i "Registry.pol"
    echo   Run Find-UpdateBlocker.ps1 to see whether it contains update policy.
) else (
    echo   no Registry.pol - local Group Policy is not the cause
)
echo.
echo --- Service start types (4 = disabled) ---
for %%S in (wuauserv UsoSvc WaaSMedicSvc BITS DoSvc) do call :showsvc %%S
echo.
echo --- Scheduled tasks outside \Microsoft\ mentioning update/pause ---
set "ROGUE=0"
for /f "usebackq tokens=1 delims=," %%A in (`schtasks /Query /FO CSV /NH 2^>nul`) do call :flagtask "%%~A"
if "!ROGUE!"=="0" echo   (none found)
echo.
echo --- Disabled update-related scheduled tasks ---
set "DISCOUNT=0"
for /f "usebackq tokens=2,4 delims=," %%A in (`schtasks /Query /FO CSV /NH /V 2^>nul`) do call :dtask "%%~A" "%%~B"
if "!DISCOUNT!"=="0" echo   (none disabled)
echo.
echo --- Metered connection cost (2 = metered, holds updates back) ---
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost" 2>nul | findstr /i "Ethernet WiFi 3G 4G" || echo   (defaults)
echo.
echo ===============================================================
exit /b 0


REM ===========================================================================
REM  SUBROUTINES
REM ===========================================================================

:delval
REM  %1 = key, %2 = value name. Delete only if present; record the old value.
reg query "%~1" /v "%~2" >nul 2>&1 || goto :eof
set "OLDVAL=?"
for /f "tokens=2,*" %%A in ('reg query "%~1" /v "%~2" 2^>nul ^| findstr /i /c:"%~2"') do set "OLDVAL=%%B"
reg delete "%~1" /v "%~2" /f >nul 2>&1
if errorlevel 1 (
    call :warn "could not delete %~2 from %~1 - access denied"
) else (
    call :log "   removed %~2  (was: !OLDVAL!)"
    set /a CHANGES+=1
)
set "OLDVAL="
goto :eof

:svc
REM  %1 = service name, %2 = desired start type for sc config
sc query "%~1" >nul 2>&1 || goto :eof
set "SVCSTART="
for /f "tokens=3" %%R in ('reg query "%SVCROOT%\%~1" /v Start 2^>nul ^| findstr /i /c:"Start"') do set "SVCSTART=%%R"
sc config "%~1" start= %~2 >nul 2>&1
if errorlevel 1 (
    call :warn "could not set %~1 to %~2 - a deny ACE on the service key would do this"
    goto :eof
)
if /i "!SVCSTART!"=="0x4" (
    call :log "   %~1 was DISABLED, set to %~2"
    set /a CHANGES+=1
)
goto :eof

:entask
REM  %1 = task name from schtasks CSV. Enable it if it is update plumbing.
echo %~1 | findstr /i /c:"\Microsoft\Windows\UpdateOrchestrator\" /c:"\Microsoft\Windows\WindowsUpdate\" /c:"\Microsoft\Windows\InstallService\" /c:"\Microsoft\Windows\WaaSMedic\" >nul || goto :eof
schtasks /Change /TN "%~1" /ENABLE >nul 2>&1 && set /a TASKSFIXED+=1
goto :eof

:flagtask
REM  %1 = task name. Print it if it lives outside \Microsoft\ and looks
REM  update-related. Matching is on the NAME, so "PauseWindowsUpdate" is caught
REM  - the old keyword list missed it because "pauseupdate" is not a substring.
echo %~1 | findstr /i /c:"\Microsoft\" >nul && goto :eof
echo %~1 | findstr /i /c:"update" /c:"pause" /c:"defer" /c:"wsus" /c:"wuau" >nul || goto :eof
set /a ROGUE+=1
echo   TASK: %~1
for /f "tokens=1,* delims=:" %%X in ('schtasks /Query /TN "%~1" /FO LIST /V 2^>nul ^| findstr /i /c:"Task To Run"') do echo         RUN:%%Y
goto :eof

:dtask
REM  %1 = task name, %2 = Status column. Only column 4 counts as the state -
REM  grepping the whole CSV line for "Disabled" matches half a dozen other
REM  columns and reports Ready tasks as disabled.
if /i not "%~2"=="Disabled" goto :eof
echo %~1 | findstr /i /c:"UpdateOrchestrator" /c:"WindowsUpdate" /c:"WaaSMedic" /c:"InstallService" >nul || goto :eof
set /a DISCOUNT+=1
echo   %~1
goto :eof

:showsvc
set "SVCSTART=?"
for /f "tokens=3" %%R in ('reg query "%SVCROOT%\%~1" /v Start 2^>nul ^| findstr /i /c:"Start"') do set "SVCSTART=%%R"
echo   %~1 = !SVCSTART!
goto :eof

:cleargpo
REM  Clear the local Group Policy cache. Only reached with /gpo, because on a
REM  domain-joined box the DC pushes it straight back at the next refresh.
set "POLDIR=%SystemRoot%\System32\GroupPolicy"
if not exist "%POLDIR%\Machine\Registry.pol" (
    call :log "-- /gpo: no local Registry.pol to clear"
    goto :eof
)
for /f "tokens=1-4 delims=/-. " %%a in ("%DATE%") do set "STAMP=%%b%%c%%d"
for /f "tokens=1-2 delims=:." %%a in ("%TIME: =0%") do set "STAMP=!STAMP!_%%a%%b"
copy /y "%POLDIR%\Machine\Registry.pol" "%INSTDIR%\Registry.pol.bak_!STAMP!" >nul 2>&1
del /f /q "%POLDIR%\Machine\Registry.pol" >nul 2>&1
if exist "%POLDIR%\User\Registry.pol" del /f /q "%POLDIR%\User\Registry.pol" >nul 2>&1
call :log "-- /gpo: Registry.pol backed up to %INSTDIR%\Registry.pol.bak_!STAMP! and deleted"
set /a CHANGES+=1
gpupdate /force /wait:60 >nul 2>&1
call :log "-- /gpo: gpupdate /force completed"
goto :eof

:warnif
REM  %1 = key, %2 = value, %3 = message shown when the value exists
reg query "%~1" /v "%~2" >nul 2>&1 && call :warn "%~3"
goto :eof

:warn
call :log "** %~1"
set /a PROBLEMS+=1
goto :eof

:log
>>"%LOG%" 2>nul echo [%DATE% %TIME%] %~1
echo %~1
goto :eof
