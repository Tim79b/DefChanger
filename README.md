# DefChanger
Simple Powershell Script to Bulk change all filetypes associated with one Windows App to another

## DESCRIPTION
    Windows 10/11 protect each per-user default ("UserChoice") with a hash, and
    recent builds add a second protected key ("UserChoiceLatest") plus a driver
    (UCPD.sys) that blocks direct writes to .pdf, http and https. A plain registry
    edit is therefore reset by Windows with an "An app default was reset" notice.

    ** This script does the discovery and orchestration itself, and delegates the **
    protected writes to SFTA.ps1 (PS-SFTA), which computes both hashes:
        https://github.com/computerserviceips/PS-SFTA   (maintained fork)
    Download SFTA.ps1 and place it next to this script (or pass -SftaPath).**

### Workflow:
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

## ARGUMENTS

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
