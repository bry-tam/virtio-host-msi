[CmdletBinding()]
param(
    [string]$MsiPath,
    [string]$MsiUrl = 'http://virtio-msi-host.virtio-msi-host.svc.cluster.local:8080/virtio-win-gt-x64.msi',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\Windows\Temp\virtio-cleanup.log' -Append | Out-Null

$Expected = 'C:\Program Files\Virtio-Win\Balloon\blnsvr.exe'

function Get-BalloonExe {
    $s = Get-CimInstance Win32_Service -Filter "Name='BalloonService'"
    if ($s -and $s.PathName -match '^\s*"?(.+?\.exe)') { return $Matches[1] }
}

function Write-RedBlock([string[]]$Lines) {
    $width = ($Lines | Measure-Object -Property Length -Maximum).Maximum + 2
    try { $width = [Math]::Min($width, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }
    Write-Host ''
    foreach ($l in (@('') + $Lines + @(''))) {
        Write-Host (' ' + $l).PadRight($width) -ForegroundColor White -BackgroundColor Red
    }
    Write-Host ''
}

function Get-RerunCommand($Bound, [string]$Script) {
    $q = "'"
    $parts = @('& ' + $q + ($Script -replace $q, ($q + $q)) + $q)
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $parts += '-' + $k }
        } else {
            $parts += '-' + $k + ' ' + $q + ("$v" -replace $q, ($q + $q)) + $q
        }
    }
    if (-not $Bound.ContainsKey('Force')) { $parts += '-Force' }
    $parts -join ' '
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole('Administrators')) { throw 'Run as Administrator.' }

# Pre-flight: stop before changing anything if the wrong-case directory cannot be told apart safely
$dirs  = [IO.Directory]::GetDirectories('C:\Windows')
$wrong = $dirs | Where-Object { (Split-Path $_ -Leaf) -ceq 'Drivers' }
$right = $dirs | Where-Object { (Split-Path $_ -Leaf) -ceq 'drivers' }
if ($wrong -and $right -and -not $Force) {
    Write-RedBlock @(
        'STOPPED - NOTHING HAS BEEN CHANGED',
        '',
        "Both 'Drivers' and 'drivers' exist under C:\Windows.",
        'Windows resolves paths case-insensitively and may delete the wrong one.',
        'Test on a clone first. If you want to continue, run the script again with -Force:',
        '',
        (Get-RerunCommand $PSBoundParameters $PSCommandPath)
    )
    Stop-Transcript | Out-Null
    exit 2
}

# Pre-flight: a leftover from an earlier run that stopped after the rename needs a manual look
$DupName = 'Drivers_dup'
$DupDir  = "C:\Windows\$DupName"
if ($dirs | Where-Object { (Split-Path $_ -Leaf) -ieq $DupName }) {
    throw "$DupDir already exists, probably left by an earlier run that stopped after renaming. Nothing has been changed. Inspect it and C:\Windows\drivers, then remove or restore it before re-running."
}

Write-Output "BalloonService exe before: $(Get-BalloonExe)"

# 1. Stop the service and any running blnsvr so the old files are unlocked
$svc = Get-Service BalloonService -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service BalloonService -Force }
Get-Process blnsvr -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. Install the VirtIO Guest Tools
if (-not $MsiPath) {
    $MsiPath = 'C:\Windows\Temp\virtio-win-gt-x64.msi'
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($MsiUrl, $MsiPath)
    $want = ($wc.DownloadString("$MsiUrl.sha256").Trim() -split '\s+')[0]
    $have = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash
    if ($have -ine $want) { throw "SHA256 mismatch for $MsiUrl (expected $want, got $have)" }
    Write-Output "Downloaded and verified $MsiUrl"
}
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
    "/i `"$MsiPath`" /qn /norestart /l*v `"C:\Windows\Temp\virtio-gt-msi.log`""
if ($p.ExitCode -notin 0, 3010) { throw "MSI failed, exit code $($p.ExitCode)" }
if ($p.ExitCode -eq 3010) { Write-Warning 'MSI requested a reboot (3010). Schedule one.' }
if (-not (Test-Path -LiteralPath $Expected)) { throw "MSI did not install $Expected" }

# 3. Make sure the service points at the new exe and is running
if ((Get-BalloonExe) -ine $Expected) {
    sc.exe config BalloonService binPath= "`"$Expected`"" | Out-Null
}
Start-Service BalloonService
if ((Get-BalloonExe) -ine $Expected -or (Get-Service BalloonService).Status -ne 'Running') {
    throw "BalloonService not running from $Expected (now: $(Get-BalloonExe))"
}
Write-Output "BalloonService verified: $(Get-BalloonExe)"

# 4. Remove the wrong-case 'Drivers' directory (exact-case match only).
# It is renamed first and checked, so a case-insensitive path that resolved to the
# wrong directory is caught while the data still exists. Nothing is deleted until the check passes.
function Get-WindowsDirNames {
    [IO.Directory]::GetDirectories('C:\Windows') | ForEach-Object { Split-Path $_ -Leaf }
}

if ($wrong) {
    if (-not (Test-Path -LiteralPath "$wrong\VirtIO")) {
        throw "No VirtIO directory found in $wrong. Refusing to remove it. Inspect $wrong manually."
    }

    Rename-Item -LiteralPath $wrong -NewName $DupName -ErrorAction Stop
    Write-Output "Renamed $wrong to $DupDir"

    $names = Get-WindowsDirNames
    if (-not ($names -ccontains $DupName) -or ($names -ccontains 'Drivers') -or
        ($right -and -not ($names -ccontains 'drivers'))) {
        throw "Unexpected directory layout after the rename (found: $($names -join ', ')). Nothing was deleted. Inspect C:\Windows manually; $DupDir is left in place."
    }
    if ($right -and (Test-Path -LiteralPath "$right\VirtIO")) {
        throw "VirtIO directory found in $right, which is not expected. Nothing was deleted. Inspect $right and $DupDir manually; $DupDir is left in place."
    }
    if (-not (Test-Path -LiteralPath "$DupDir\VirtIO")) {
        throw "VirtIO directory not found in $DupDir after the rename. Nothing was deleted. Inspect $DupDir manually; it is left in place."
    }
    Write-Output "Validation passed: VirtIO is in $DupDir and not in the real 'drivers' directory"

    Remove-Item -LiteralPath $DupDir -Recurse -Force -ErrorAction Stop
    $after = Get-WindowsDirNames
    if ($after -ccontains 'Drivers') { throw 'Wrong-case Drivers directory still present.' }
    if ($after -ccontains $DupName) { throw "$DupDir still present." }
    if ($right -and -not ($after -ccontains 'drivers')) { throw "The real 'drivers' directory was removed instead!" }
    Write-Output "Removed $wrong (via $DupDir)"
} else {
    Write-Output "No wrong-case 'Drivers' directory found."
}

# 5. Sanity check: neither directory should be writable by Everyone/Users
foreach ($path in 'C:\Windows\drivers', 'C:\Program Files\Virtio-Win') {
    if (-not (Test-Path -LiteralPath $path)) { Write-Warning "$path not found, ACL not checked."; continue }
    Write-Output "ACL for ${path}:"
    icacls $path
    $bad = (Get-Acl -LiteralPath $path).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        $_.IdentityReference -match 'Everyone|BUILTIN\\Users|Authenticated Users' -and
        $_.FileSystemRights -match 'Write|Modify|FullControl' }
    if ($bad) { Write-Warning "$path has user-writable ACEs:"; $bad | Format-Table }
}

Stop-Transcript | Out-Null
