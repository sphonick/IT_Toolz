#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only hunt for whatever keeps pausing Windows Update on this machine.

.DESCRIPTION
    Changes nothing. Dumps every mechanism that can defer or pause updates,
    ranked roughly by how often it turns out to be the actual cause:

      1. Local Group Policy cache (Registry.pol) - re-applies every ~90 min
      2. MDM / Intune policy channel
      3. Third-party "debloat" / update-blocker tools and their persistence
      4. Boot-time persistence: Run keys, startup folders, services, tasks
      5. The pause/defer registry state itself
      6. Metered connections and WSUS redirection

    Run elevated:
        powershell -ExecutionPolicy Bypass -File .\Find-UpdateBlocker.ps1

.PARAMETER EnableAuditing
    Additionally turns on registry auditing for the Windows Update keys so the
    Security event log records *which process* modifies them (event ID 4657).
    This is the only reliable way to catch a blocker you cannot find by name.
    It is the one thing in this script that writes.
#>
[CmdletBinding()]
param(
    [switch]$EnableAuditing
)

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

function Write-Hit  { param([string]$m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "  [X] $m" -ForegroundColor Red }
function Write-Ok   { param([string]$m) Write-Host "  [ ] $m" -ForegroundColor DarkGray }

$suspects = 'Windows Update Blocker|StopUpdates10|WuMgr|Update MiniTool|ShutUp10|O&O ShutUp|' +
            'Winaero|Sophia|WinUtil|Chris Titus|Spybot|Anti-Beacon|W10Privacy|Blackbird|' +
            'NTLite|Update Freezer|WPD|Destroy Windows|Windows10Debloater|Optimizer|' +
            'DisableWinTracking|Privatezilla|Tron'

Write-Host ''
Write-Host "Windows Update blocker hunt - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "$($os.Caption)  build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)   last boot: $($os.LastBootUpTime)"

# --------------------------------------------------------------------------
Write-Section '1. Local Group Policy cache  (most common cause of "it comes back")'
$pol = "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
if (Test-Path $pol) {
    $bytes = [System.IO.File]::ReadAllBytes($pol)
    $text  = [System.Text.Encoding]::Unicode.GetString($bytes)
    Write-Hit "Registry.pol exists  ($((Get-Item $pol).Length) bytes, modified $((Get-Item $pol).LastWriteTime))"
    if ($text -match 'WindowsUpdate') {
        Write-Bad 'It contains WindowsUpdate policy. Group Policy re-applies this every ~90 minutes,'
        Write-Bad 'which is why deleting the registry values by hand never sticks.'
        [regex]::Matches($text, '[\x20-\x7E]{6,}') |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -match 'Pause|Defer|NoAutoUpdate|AUOptions|TargetRelease|BranchReadiness' } |
            Select-Object -Unique | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
        Write-Host ''
        Write-Host '        Fix: open gpedit.msc -> Computer Configuration -> Administrative' -ForegroundColor Gray
        Write-Host '        Templates -> Windows Components -> Windows Update, set the offending' -ForegroundColor Gray
        Write-Host '        settings to Not Configured. Or run:  wuguard.cmd repair /gpo' -ForegroundColor Gray
    } else {
        Write-Ok 'Registry.pol exists but does not mention WindowsUpdate.'
    }
} else {
    Write-Ok 'No local Registry.pol - local Group Policy is not the cause.'
}
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain) { Write-Hit "Domain-joined ($($cs.Domain)) - a domain GPO can push this too. Run: gpresult /h gp.html" }
else { Write-Ok 'Not domain-joined.' }

# --------------------------------------------------------------------------
Write-Section '2. MDM / Intune policy channel'
$mdm = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
if (Test-Path $mdm) {
    Write-Bad 'MDM update policy is present - this device is managed. Deleting registry'
    Write-Bad 'values locally is futile; the MDM channel re-syncs them.'
    Get-ItemProperty $mdm | Select-Object -Property * -Exclude PS* |
        Format-List | Out-String -Width 120 | Write-Host
} else {
    Write-Ok 'No MDM update policy.'
}
$enroll = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
          Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).EnrollmentState -eq 1 }
if ($enroll) { Write-Hit "Active MDM enrollment(s): $($enroll.PSChildName -join ', ')" }

# --------------------------------------------------------------------------
Write-Section '3. Installed software known to block updates'
$found = @()
foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    $found += Get-ItemProperty $root -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -match $suspects } |
              Select-Object DisplayName, DisplayVersion, InstallLocation
}
if ($found) { $found | Format-Table -AutoSize | Out-String -Width 140 | Write-Host }
else { Write-Ok 'No known blocker tools found in the uninstall registry.' }

Write-Host '  Loose executables in common spots:'
$paths = @("$env:ProgramData","$env:ProgramFiles","${env:ProgramFiles(x86)}","$env:LOCALAPPDATA","$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop","C:\Tools","C:\Temp")
$loose = foreach ($p in $paths) {
    if (Test-Path $p) {
        Get-ChildItem $p -Recurse -Depth 2 -Include *.exe,*.cmd,*.bat,*.ps1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $suspects -or $_.BaseName -match 'wu(block|off)|noupdate|disableupdate|pauseupdate' }
    }
}
if ($loose) { $loose | Select-Object FullName, LastWriteTime | Format-Table -AutoSize | Out-String -Width 140 | Write-Host }
else { Write-Ok 'Nothing obvious on disk.' }

# --------------------------------------------------------------------------
Write-Section '4. Boot-time persistence'
Write-Host '  Run / RunOnce entries:'
$runHits = @()
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
    if (Test-Path $k) {
        (Get-ItemProperty $k).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object { $runHits += [pscustomobject]@{Key=$k; Name=$_.Name; Command=$_.Value} }
    }
}
$flagged = $runHits | Where-Object { $_.Command -match $suspects -or $_.Command -match 'wuauserv|UsoSvc|Pause.*Update|Update.*Pause|reg .*WindowsUpdate' }
if ($flagged) { $flagged | Format-List | Out-String -Width 140 | Write-Host }
else { Write-Ok "None of the $($runHits.Count) Run entries look update-related." }

Write-Host '  Startup folders:'
$sf = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup")
$sfItems = $sf | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -File -ErrorAction SilentlyContinue }
if ($sfItems) { $sfItems | Select-Object FullName, LastWriteTime | Format-Table -AutoSize | Out-String -Width 140 | Write-Host }
else { Write-Ok 'Startup folders are empty.' }

Write-Host '  Non-Microsoft scheduled tasks referencing updates:'
$rogue = Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
    ForEach-Object {
        $t = $_
        foreach ($a in $t.Actions) {
            $exec = $a.PSObject.Properties['Execute']
            $args = $a.PSObject.Properties['Arguments']
            $cmd = "$(if($exec){$exec.Value}) $(if($args){$args.Value})"
            if ($cmd -match $suspects -or $cmd -match 'wuauserv|UsoSvc|WaaSMedic|WindowsUpdate|Pause.*Update') {
                [pscustomobject]@{ Task = "$($t.TaskPath)$($t.TaskName)"; State = $t.State; Command = $cmd.Trim() }
            }
        }
    }
if ($rogue) { $rogue | Format-List | Out-String -Width 140 | Write-Host }
else { Write-Ok 'No third-party scheduled task touches Windows Update.' }

Write-Host '  Non-Microsoft services with update-ish names:'
$svc = Get-CimInstance Win32_Service |
    Where-Object { $_.PathName -match $suspects -or $_.DisplayName -match $suspects }
if ($svc) { $svc | Select-Object Name, DisplayName, State, StartMode, PathName | Format-List | Out-String -Width 140 | Write-Host }
else { Write-Ok 'None.' }

# --------------------------------------------------------------------------
Write-Section '5. Current pause / defer state'
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings',
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU') {
    Write-Host "  $k"
    if (Test-Path $k) {
        $props = (Get-ItemProperty $k).PSObject.Properties |
                 Where-Object { $_.Name -notlike 'PS*' -and ($_.Name -match 'Pause|Defer|NoAuto|AUOptions|Target|Branch|Disable|Exclude|WUServer|UseWU') }
        if ($props) { $props | ForEach-Object { Write-Hit "$($_.Name) = $($_.Value)" } }
        else { Write-Ok 'no pause/defer values' }
    } else { Write-Ok 'key absent' }
}

Write-Host '  Service start types (4 = Disabled):'
foreach ($s in 'wuauserv','UsoSvc','WaaSMedicSvc','BITS','DoSvc') {
    $sk = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (Test-Path $sk) {
        $st = (Get-ItemProperty $sk).Start
        $name = @{0='Boot';1='System';2='Automatic';3='Manual';4='DISABLED'}[[int]$st]
        if ($st -eq 4) { Write-Bad "$s = $st ($name)" } else { Write-Ok "$s = $st ($name)" }
        $deny = (Get-Acl $sk).Access | Where-Object AccessControlType -eq 'Deny'
        if ($deny) { Write-Bad "  ^ $s has a DENY ACE - something locked the key: $($deny.IdentityReference -join ', ')" }
    }
}

Write-Host '  Disabled Windows Update scheduled tasks:'
$dis = Get-ScheduledTask -ErrorAction SilentlyContinue |
       Where-Object { $_.TaskPath -match 'UpdateOrchestrator|WindowsUpdate|WaaSMedic|InstallService' -and $_.State -eq 'Disabled' }
if ($dis) { $dis | ForEach-Object { Write-Bad "$($_.TaskPath)$($_.TaskName)" } }
else { Write-Ok 'none disabled' }

# --------------------------------------------------------------------------
Write-Section '6. Network-level brakes'
$mc = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost'
if (Test-Path $mc) {
    (Get-ItemProperty $mc).PSObject.Properties |
        Where-Object { $_.Name -in 'Ethernet','WiFi','3G','4G' } |
        ForEach-Object {
            if ($_.Value -eq 2) { Write-Bad "$($_.Name) is marked METERED - Windows holds updates on metered links" }
            else { Write-Ok "$($_.Name) = $($_.Value) (unrestricted)" }
        }
}
$wu = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
if ($wu.WUServer) { Write-Hit "WSUS redirection: $($wu.WUServer)" } else { Write-Ok 'No WSUS redirection.' }

# --------------------------------------------------------------------------
Write-Section '7. Recent Windows Update client history'
try {
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 15 -ErrorAction Stop |
        Select-Object TimeCreated, Id, @{n='Message';e={($_.Message -split "`r?`n")[0]}} |
        Format-Table -AutoSize | Out-String -Width 160 | Write-Host
} catch { Write-Ok 'No WindowsUpdateClient events in the last 30 days.' }

Write-Host '  Registry-change audit events (4657) for update keys, if auditing is on:'
try {
    $ev = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4657; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 200 -ErrorAction Stop |
          Where-Object { $_.Message -match 'WindowsUpdate' }
    if ($ev) {
        $ev | Select-Object -First 20 TimeCreated,
            @{n='Process';e={ if ($_.Message -match 'Process Name:\s+(.+)') { $Matches[1].Trim() } }},
            @{n='Value';e={ if ($_.Message -match 'Value Name:\s+(.+)') { $Matches[1].Trim() } }} |
            Format-Table -AutoSize | Out-String -Width 160 | Write-Host
    } else { Write-Ok 'None (auditing probably not enabled - see -EnableAuditing).' }
} catch { Write-Ok 'None (auditing probably not enabled - see -EnableAuditing).' }

# --------------------------------------------------------------------------
if ($EnableAuditing) {
    Write-Section 'Enabling registry auditing on the Windows Update keys'
    & auditpol.exe /set /subcategory:"Registry" /success:enable | Out-Null
    Write-Host '  auditpol: Registry / success auditing enabled.'
    $rule = New-Object System.Security.AccessControl.RegistryAuditRule(
        'Everyone',
        [System.Security.AccessControl.RegistryRights]::SetValue -bor
        [System.Security.AccessControl.RegistryRights]::CreateSubKey -bor
        [System.Security.AccessControl.RegistryRights]::Delete,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AuditFlags]::Success)
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings',
                    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate') {
        try {
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            $acl = Get-Acl -Path $k -Audit
            $acl.AddAuditRule($rule)
            Set-Acl -Path $k -AclObject $acl
            Write-Host "  SACL applied: $k" -ForegroundColor Green
        } catch {
            Write-Bad "Could not set SACL on $k : $($_.Exception.Message)"
            Write-Host '        (needs SeSecurityPrivilege - try running this as SYSTEM,' -ForegroundColor Gray
            Write-Host '         e.g. via a scheduled task, or set it by hand in regedit:' -ForegroundColor Gray
            Write-Host '         right-click key > Permissions > Advanced > Auditing.)' -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host '  Now reboot. After the next pause happens, re-run this script and read' -ForegroundColor White
    Write-Host '  section 7 - event 4657 will name the process that wrote the value.' -ForegroundColor White
}

Write-Host ''
Write-Host 'Done. Nothing was modified.' -ForegroundColor White
if (-not $EnableAuditing) {
    Write-Host 'If nothing above is conclusive, re-run with -EnableAuditing, reboot, and' -ForegroundColor White
    Write-Host 'let the Security log name the culprit process for you.' -ForegroundColor White
}
