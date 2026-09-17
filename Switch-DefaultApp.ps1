<#
.SYNOPSIS
    Reassigns every file type (and optionally every protocol) whose default app is
    one application so that it defaults to another application instead.

.DESCRIPTION
    Windows 10/11 protect each per-user default ("UserChoice") with a hash, and
    recent builds add a second protected key ("UserChoiceLatest") plus a driver
    (UCPD.sys) that blocks direct writes to .pdf, http and https. A plain registry
    edit is therefore reset by Windows with an "An app default was reset" notice.

    This script does the discovery and orchestration itself, and delegates the
    protected writes to SFTA.ps1 (PS-SFTA), which computes both hashes:
        https://github.com/computerserviceips/PS-SFTA   (maintained fork)
    Download SFTA.ps1 and place it next to this script (or pass -SftaPath).

    Workflow:
      1. Finds every extension (and protocol, with -IncludeProtocols) whose current
         default ProgId resolves to the -From app (matched against the ProgId name,
         its open command line, or its packaged-app AppUserModelId).
      2. For each one, works out the correct ProgId for the -To app, preferring the
         app's own registered Capabilities, then OpenWithProgids / OpenWithList,
         then Applications\<exe>, and finally (if -To is a full path) registers a
         per-user ProgId for it.
      3. Writes a CSV backup of the current state, applies the changes, and
         restarts Explorer once.

    Always run with -WhatIf first to review the list.

.PARAMETER From
    Text identifying the current app: exe name ('AcroRd32.exe', 'Acrobat.exe'),
    full path, ProgId fragment ('AcroExch'), or packaged app id fragment
    ('Microsoft.Windows.Photos'). Matching is a case-insensitive "contains".

.PARAMETER To
    The replacement app: exe name ('SumatraPDF.exe'), full path to the exe, or
    packaged app id fragment. Use a full path if the app is not registered with
    Windows (i.e. it never appears in "Open with").

.PARAMETER ToProgId
    Force a specific ProgId for every item instead of resolving one per extension.

.PARAMETER IncludeProtocols
    Also switch URL protocols (http, https, mailto, etc.).

.PARAMETER UserChoiceOnly
    Only consider types the user has explicitly chosen a default for. By default
    the script also includes machine-level defaults (HKCR\.ext) that point to the
    -From app.

.PARAMETER Exclude
    Extensions/protocols to leave alone, e.g. -Exclude .xml,.txt

.PARAMETER BackupPath
    Where to write the pre-change CSV. Defaults to the script folder.

.PARAMETER RestoreFrom
    Restore associations from a backup CSV produced by an earlier run.

.PARAMETER SftaPath
    Path to SFTA.ps1. Defaults to the script folder.

.PARAMETER NoExplorerRestart
    Do not restart Explorer at the end (changes then take effect at next sign-in).

.EXAMPLE
    .\Switch-DefaultApp.ps1 -From Acrobat.exe -To SumatraPDF.exe -WhatIf

.EXAMPLE
    .\Switch-DefaultApp.ps1 -From msedge.exe -To chrome.exe -IncludeProtocols

.EXAMPLE
    .\Switch-DefaultApp.ps1 -From notepad.exe -To "C:\Program Files\Notepad++\notepad++.exe" -Exclude .log

.EXAMPLE
    .\Switch-DefaultApp.ps1 -RestoreFrom .\DefaultAppBackup_20260918_101500.csv

.NOTES
    Run as the user whose defaults are to change (associations live in HKCU).
    Where .pdf, http or https are involved, run Windows PowerShell 5.1 elevated
    from that same account so SFTA can work around UCPD.sys. Do not elevate with a
    different administrator account, as that changes a different user's profile.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Switch')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Switch')]
    [string]$From,

    [Parameter(ParameterSetName = 'Switch')]
    [string]$To,

    [Parameter(ParameterSetName = 'Switch')]
    [string]$ToProgId,

    [Parameter(ParameterSetName = 'Switch')]
    [switch]$IncludeProtocols,

    [Parameter(ParameterSetName = 'Switch')]
    [switch]$UserChoiceOnly,

    [Parameter(ParameterSetName = 'Switch')]
    [string[]]$Exclude = @(),

    [Parameter(ParameterSetName = 'Switch')]
    [string]$BackupPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [string]$RestoreFrom,

    [string]$SftaPath,

    [switch]$NoExplorerRestart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $SftaPath) { $SftaPath = Join-Path $ScriptDir 'SFTA.ps1' }

$HKCR        = 'Registry::HKEY_CLASSES_ROOT'
$FileExtsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$UrlAssocKey = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'

#region Helpers ---------------------------------------------------------------

function Get-DefaultValue {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValue('') }
    catch { return $null }
}

function Get-ValueNames {
    param([string]$Path)
    try { return @((Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueNames() | Where-Object { $_ }) }
    catch { return @() }
}

function Get-ProgIdForChoice {
    # Prefer UserChoiceLatest (newer Windows 11 builds) over UserChoice.
    param([string]$KeyPath)
    foreach ($sub in 'UserChoiceLatest', 'UserChoice') {
        try {
            $p = (Get-ItemProperty -LiteralPath "$KeyPath\$sub" -ErrorAction Stop).ProgId
            if ($p) { return $p }
        } catch { }
    }
    return $null
}

$HandlerCache = @{}
function Get-ProgIdHandler {
    # Returns a string describing what a ProgId launches: the ProgId itself,
    # its packaged-app AUMID (if any) and its default verb command line.
    param([string]$ProgId)
    if ([string]::IsNullOrWhiteSpace($ProgId)) { return '' }
    if ($HandlerCache.ContainsKey($ProgId)) { return $HandlerCache[$ProgId] }

    $base  = "$HKCR\$ProgId"
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($ProgId)

    try {
        $aumid = (Get-ItemProperty -LiteralPath "$base\Application" -ErrorAction Stop).AppUserModelId
        if ($aumid) { $parts.Add($aumid) }
    } catch { }

    $verbs = @()
    $defaultVerb = Get-DefaultValue "$base\shell"
    if ($defaultVerb) { $verbs += ($defaultVerb -split '[,\s]+')[0] }
    $verbs += 'open'
    foreach ($v in ($verbs | Select-Object -Unique)) {
        $cmd = Get-DefaultValue "$base\shell\$v\command"
        if ($cmd) { $parts.Add([Environment]::ExpandEnvironmentVariables($cmd)); break }
    }

    $result = $parts -join ' | '
    $HandlerCache[$ProgId] = $result
    return $result
}

function Test-Token {
    param([string]$Haystack, [string]$Token)
    if ([string]::IsNullOrEmpty($Haystack) -or [string]::IsNullOrEmpty($Token)) { return $false }
    return $Haystack.IndexOf($Token, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-MatchToken {
    # A full path is reduced to its file name so that differing path forms
    # (8.3 names, %ProgramFiles%, etc.) still match.
    param([string]$Value)
    if ($Value -match '[\\/]') { return [IO.Path]::GetFileName($Value) }
    return $Value
}

#endregion

#region Loading SFTA -----------------------------------------------------------

function Assert-Sfta {
    if (-not (Test-Path -LiteralPath $SftaPath)) {
        throw (("SFTA.ps1 not found at '{0}'. Download it from " +
                "https://github.com/computerserviceips/PS-SFTA and place it next to this script, " +
                "or pass -SftaPath.") -f $SftaPath)
    }
}

function Invoke-SetAssociation {
    # SFTA is written for default (non-strict, Continue) settings; run it that way.
    param([string]$ProgId, [string]$Name)
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    $r = Set-FTA -ProgId $ProgId -Extension $Name -SkipExplorerRestart -PassThru -Silent
    return ($r | Select-Object -Last 1)
}

function Restart-Explorer {
    if ($NoExplorerRestart) {
        Write-Host "Explorer not restarted; changes apply at next sign-in." -ForegroundColor Yellow
        return
    }
    Write-Host "Restarting Explorer..." -ForegroundColor Cyan
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe')
    }
}

#endregion

#region Restore mode -----------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    $rows = Import-Csv -LiteralPath $RestoreFrom
    Assert-Sfta
    . $SftaPath
    $changed = 0
    foreach ($row in $rows) {
        if (-not $row.ProgId) { continue }
        if ($PSCmdlet.ShouldProcess("$($row.Name)", "Restore default to '$($row.ProgId)'")) {
            try {
                $null = Invoke-SetAssociation -ProgId $row.ProgId -Name $row.Name
                $changed++
            } catch {
                Write-Warning "Failed to restore $($row.Name): $($_.Exception.Message)"
            }
        }
    }
    if ($changed -gt 0) { Restart-Explorer }
    Write-Host "Restored $changed association(s)." -ForegroundColor Green
    return
}

#endregion

#region Switch mode: discovery -------------------------------------------------

if (-not $To -and -not $ToProgId) { throw 'Specify -To (or -ToProgId).' }

$FromToken = Get-MatchToken $From
$ToToken   = if ($To) { Get-MatchToken $To } else { $null }
$ToIsPath  = [bool]($To -and ($To -match '[\\/]') -and (Test-Path -LiteralPath $To -PathType Leaf))
$ExcludeSet = @{}
foreach ($e in $Exclude) { $ExcludeSet[$e.ToLowerInvariant()] = $true }

Write-Host "Scanning current associations for '$FromToken'..." -ForegroundColor Cyan

$current = New-Object System.Collections.Generic.List[object]
$seen    = @{}

# 1. Per-user choices for file extensions
foreach ($key in (Get-ChildItem -LiteralPath $FileExtsKey -ErrorAction SilentlyContinue)) {
    $ext = $key.PSChildName
    if (-not $ext.StartsWith('.')) { continue }
    $progId = Get-ProgIdForChoice $key.PSPath
    if ($progId) {
        $current.Add([pscustomobject]@{ Type = 'Extension'; Name = $ext; ProgId = $progId; Source = 'User choice' })
        $seen[$ext.ToLowerInvariant()] = $true
    }
}

# 2. Machine-level defaults where the user has made no choice
if (-not $UserChoiceOnly) {
    $cr = [Microsoft.Win32.Registry]::ClassesRoot
    foreach ($name in $cr.GetSubKeyNames()) {
        if (-not $name.StartsWith('.') -or $seen.ContainsKey($name.ToLowerInvariant())) { continue }
        $k = $null
        try {
            $k = $cr.OpenSubKey($name)
            $progId = if ($k) { $k.GetValue('') } else { $null }
        } catch { $progId = $null }
        finally { if ($k) { $k.Close() } }
        if ($progId) {
            $current.Add([pscustomobject]@{ Type = 'Extension'; Name = $name; ProgId = [string]$progId; Source = 'System default' })
        }
    }
}

# 3. Protocols
if ($IncludeProtocols) {
    foreach ($key in (Get-ChildItem -LiteralPath $UrlAssocKey -ErrorAction SilentlyContinue)) {
        $progId = Get-ProgIdForChoice $key.PSPath
        if ($progId) {
            $current.Add([pscustomobject]@{ Type = 'Protocol'; Name = $key.PSChildName; ProgId = $progId; Source = 'User choice' })
        }
    }
}

$matched = @($current | Where-Object {
    -not $ExcludeSet.ContainsKey($_.Name.ToLowerInvariant()) -and
    (Test-Token (Get-ProgIdHandler $_.ProgId) $FromToken)
})

if ($matched.Count -eq 0) {
    Write-Host "No file types or protocols currently default to '$FromToken'." -ForegroundColor Yellow
    return
}

#endregion

#region Switch mode: resolve the target ProgId per item ------------------------

# Registered Capabilities of the target app (the cleanest source of ProgIds).
$TargetCaps = @{}
if ($ToToken -and -not $ToProgId) {
    $regRoots = @(
        @{ Root = 'HKLM:\SOFTWARE\RegisteredApplications';             Hive = 'HKLM:' },
        @{ Root = 'HKLM:\SOFTWARE\WOW6432Node\RegisteredApplications'; Hive = 'HKLM:' },
        @{ Root = 'HKCU:\SOFTWARE\RegisteredApplications';             Hive = 'HKCU:' }
    )
    foreach ($rr in $regRoots) {
        $regKey = Get-Item -LiteralPath $rr.Root -ErrorAction SilentlyContinue
        if (-not $regKey) { continue }
        foreach ($appName in $regKey.GetValueNames()) {
            $capPath = "$($rr.Hive)\$($regKey.GetValue($appName))"
            $assoc = @{}
            foreach ($sub in 'FileAssociations', 'URLAssociations') {
                $k = Get-Item -LiteralPath "$capPath\$sub" -ErrorAction SilentlyContinue
                if ($k) { foreach ($n in $k.GetValueNames()) { if ($n) { $assoc[$n.ToLowerInvariant()] = [string]$k.GetValue($n) } } }
            }
            if ($assoc.Count -eq 0) { continue }
            # Decide whether this registration belongs to the target by what its ProgIds launch.
            $isTarget = $false
            foreach ($pg in ($assoc.Values | Select-Object -Unique | Select-Object -First 5)) {
                if (Test-Token (Get-ProgIdHandler $pg) $ToToken) { $isTarget = $true; break }
            }
            if ($isTarget) {
                foreach ($n in $assoc.Keys) { if (-not $TargetCaps.ContainsKey($n)) { $TargetCaps[$n] = $assoc[$n] } }
            }
        }
    }
}

function Resolve-TargetProgId {
    param($Item)
    if ($ToProgId) { return @{ ProgId = $ToProgId; Via = 'Specified'; Register = $false } }

    $n = $Item.Name.ToLowerInvariant()
    if ($TargetCaps.ContainsKey($n)) {
        return @{ ProgId = $TargetCaps[$n]; Via = 'App capabilities'; Register = $false }
    }

    if ($Item.Type -eq 'Extension') {
        foreach ($pg in (Get-ValueNames "$HKCR\$($Item.Name)\OpenWithProgids")) {
            if (Test-Token (Get-ProgIdHandler $pg) $ToToken) {
                return @{ ProgId = $pg; Via = 'OpenWithProgids'; Register = $false }
            }
        }
        $owl = Get-Item -LiteralPath "$HKCR\$($Item.Name)\OpenWithList" -ErrorAction SilentlyContinue
        if ($owl) {
            foreach ($vn in $owl.GetValueNames()) {
                $exe = [string]$owl.GetValue($vn)
                if ($exe -and $exe.Equals($ToToken, [StringComparison]::OrdinalIgnoreCase)) {
                    return @{ ProgId = "Applications\$exe"; Via = 'OpenWithList'; Register = $false }
                }
            }
        }
        if ($ToToken -and (Test-Path -LiteralPath "$HKCR\Applications\$ToToken\shell")) {
            return @{ ProgId = "Applications\$ToToken"; Via = 'Applications key'; Register = $false }
        }
    }

    if ($ToIsPath) {
        $pgNew = 'SFTA.' + ([IO.Path]::GetFileNameWithoutExtension($To) -replace '\s', '') + $Item.Name
        return @{ ProgId = $pgNew; Via = 'New per-user ProgId'; Register = $true }
    }
    return $null
}

$plan = foreach ($item in $matched) {
    $r = Resolve-TargetProgId $item
    [pscustomobject]@{
        Type       = $item.Type
        Name       = $item.Name
        Source     = $item.Source
        FromProgId = $item.ProgId
        ToProgId   = if ($r) { $r.ProgId } else { $null }
        Via        = if ($r) { $r.Via } else { 'UNRESOLVED' }
        Register   = if ($r) { $r.Register } else { $false }
    }
}
$plan = @($plan | Sort-Object Type, Name)

$plan | Format-Table Type, Name, Source, FromProgId, ToProgId, Via -AutoSize | Out-Host

$unresolved = @($plan | Where-Object { -not $_.ToProgId })
if ($unresolved.Count -gt 0) {
    Write-Warning (("{0} item(s) could not be mapped to '{1}' and will be skipped. " +
        "Pass -To as the full path to the exe, or use -ToProgId.") -f $unresolved.Count, $To)
}

$actionable = @($plan | Where-Object { $_.ToProgId -and ($_.ToProgId -ne $_.FromProgId) })
if ($actionable.Count -eq 0) { Write-Host 'Nothing to change.' -ForegroundColor Yellow; return }

#endregion

#region Switch mode: backup and apply ------------------------------------------

if (-not $WhatIfPreference) {
    Assert-Sfta
    . $SftaPath
    if (-not $BackupPath) {
        $BackupPath = Join-Path $ScriptDir ('DefaultAppBackup_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    $actionable | Select-Object Type, Name, @{ n = 'ProgId'; e = { $_.FromProgId } }, Source |
        Export-Csv -LiteralPath $BackupPath -NoTypeInformation -Encoding UTF8
    Write-Host "Backup written to $BackupPath" -ForegroundColor Green
}

$ok = 0; $failed = 0
foreach ($p in $actionable) {
    if (-not $PSCmdlet.ShouldProcess("$($p.Name)", "Change default from '$($p.FromProgId)' to '$($p.ToProgId)'")) { continue }
    try {
        if ($p.Register) {
            # Minimal per-user ProgId so an unregistered exe can be a default.
            $cls = "HKEY_CURRENT_USER\Software\Classes"
            [Microsoft.Win32.Registry]::SetValue("$cls\$($p.ToProgId)\shell\open\command", '', ('"{0}" "%1"' -f $To))
            [Microsoft.Win32.Registry]::SetValue("$cls\$($p.ToProgId)\DefaultIcon", '', ('"{0}",0' -f $To))
            if ($p.Type -eq 'Extension') {
                [Microsoft.Win32.Registry]::SetValue("$cls\$($p.Name)\OpenWithProgids", $p.ToProgId,
                    [byte[]]@(), [Microsoft.Win32.RegistryValueKind]::None)
            } else {
                [Microsoft.Win32.Registry]::SetValue("$cls\$($p.ToProgId)", 'URL Protocol', '')
            }
        }
        $res = Invoke-SetAssociation -ProgId $p.ToProgId -Name $p.Name
        if ($res -and ($res.PSObject.Properties.Name -contains 'Changed') -and -not $res.Changed) {
            Write-Warning "$($p.Name): SFTA reported no change (already set, or the write was blocked)."
        }
        $ok++
    } catch {
        $failed++
        Write-Warning "Failed on $($p.Name): $($_.Exception.Message)"
    }
}

if ($ok -gt 0) {
    Restart-Explorer
    Write-Host "Changed $ok association(s); $failed failure(s)." -ForegroundColor Green
    Write-Host "To undo: .\Switch-DefaultApp.ps1 -RestoreFrom `"$BackupPath`"" -ForegroundColor Gray
}

#endregion
