# DefChanger
Simple Powershell Script to Bulk change all filetypes associated with one Windows App to another

## DESCRIPTION
Windows 10/11 protect each per-user default ("UserChoice") with a hash, and recent builds add a second protected key ("UserChoiceLatest") plus a driver (UCPD.sys) that blocks direct writes to .pdf, http and https. A plain registry edit is therefore reset by Windows with an "An app default was reset" notice.

**This script does the discovery and orchestration itself, and delegates the protected writes to SFTA.ps1 (PS-SFTA), which computes both hashes: https://github.com/computerserviceips/PS-SFTA   (maintained fork).Download SFTA.ps1 and place it next to this script (or pass -SftaPath).**

## Instructions:
1. Download the Switch-DefaultApp.ps1 file from this repo
2. Download the SFTA.ps1 file from https://github.com/computerserviceips/PS-SFTA
3. Open an windows terminal with administrator privileges
4. Run **Set-ExecutionPolicy Unrestricted** to allow execution of unsigned scripts
5. Prepare your command for execution in line with the below.

### Workflow:
1. Finds every extension (and protocol, with -IncludeProtocols) whose current default ProgId resolves to the -From app (matched against the ProgId name, its open command line, or its packaged-app AppUserModelId).
2. For each one, works out the correct ProgId for the -To app, preferring the app's own registered Capabilities, then OpenWithProgids / OpenWithList, then Applications\<exe>, and finally (if -To is a full path) registers a per-user ProgId for it.
3. Writes a CSV backup of the current state, applies the changes, and restarts Explorer once.

**Always run with -WhatIf first to review the list.**

## ARGUMENTS

### From
    Text identifying the current app: exe name ('AcroRd32.exe', 'Acrobat.exe'),
    full path, ProgId fragment ('AcroExch'), or packaged app id fragment
    ('Microsoft.Windows.Photos'). Matching is a case-insensitive "contains".

### To
    The replacement app: exe name ('SumatraPDF.exe'), full path to the exe, or
    packaged app id fragment. Use a full path if the app is not registered with
    Windows (i.e. it never appears in "Open with").

### ToProgId
    Force a specific ProgId for every item instead of resolving one per extension.

### IncludeProtocols
    Also switch URL protocols (http, https, mailto, etc.).

### UserChoiceOnly
    Only consider types the user has explicitly chosen a default for. By default
    the script also includes machine-level defaults (HKCR\.ext) that point to the
    -From app.

### Exclude
    Extensions/protocols to leave alone, e.g. -Exclude .xml,.txt

### BackupPath
    Where to write the pre-change CSV. Defaults to the script folder.

### RestoreFrom
    Restore associations from a backup CSV produced by an earlier run.

### SftaPath
    Path to SFTA.ps1. Defaults to the script folder.

### NoExplorerRestart
    Do not restart Explorer at the end (changes then take effect at next sign-in).

## Examples
### Example 1
    .\Switch-DefaultApp.ps1 -From Acrobat.exe -To SumatraPDF.exe -WhatIf
This example provides a hypothetical indication of what file associations will change if you run the script

### Example 2
    .\Switch-DefaultApp.ps1 -From msedge.exe -To chrome.exe -IncludeProtocols
This example will change the association of all file types AND protocols from MS Edge to Chrome

### Example 3
    .\Switch-DefaultApp.ps1 -From notepad.exe -To "C:\Program Files\Notepad++\notepad++.exe" -Exclude .log
This example will change all file types associated with notepad.exe - except .log files - to be associated with notepad++ on a per user basis.

### Example 4
    .\Switch-DefaultApp.ps1 -RestoreFrom .\DefaultAppBackup_20260918_101500.csv
This example will restore the settings from the default backup file. That is, it will revert the changes made by the execution that created the backup csv.

### NOTES
Run as the user whose defaults are to change (associations live in HKCU). Where .pdf, http or https are involved, run Windows PowerShell 5.1 elevated from that same account so SFTA can work around UCPD.sys. Do not elevate with a different administrator account, as that changes a different user's profile.
