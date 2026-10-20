param(
    [switch]$RunTask
)

# ---------------------------------------------------------------
# Result code helper
# ---------------------------------------------------------------
function Get-ResultDescription ($val) {
    switch ($val) {
        0 { "Not Started" }
        1 { "In Progress" }
        2 { "Succeeded" }
        3 { "Succeeded With Errors" }
        4 { "Failed" }
        5 { "Aborted" }
        default { "Unknown ($val)" }
    }
}

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
$TaskName   = "Get-WindowsUpdate"
$LogPath    = "C:\Temp\WindowsUpdate.log"

# ---------------------------------------------------------------
# MODE 1: Initial run - register and launch the scheduled task
# ---------------------------------------------------------------
if (-not $RunTask) {

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host "Existing task '$TaskName' found. Removing..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $Action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -RunTask"

    $Trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)

    $Settings  = New-ScheduledTaskSettingsSet `
                     -AllowStartIfOnBatteries `
                     -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    $Principal = New-ScheduledTaskPrincipal `
                     -UserId "SYSTEM" `
                     -LogonType ServiceAccount `
                     -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName `
                           -Action $Action `
                           -Trigger $Trigger `
                           -Settings $Settings `
                           -Principal $Principal `
                           -Force | Out-Null
                           
    # Ensure log file exists before tailing it
    if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
    if (-not (Test-Path $LogPath))  { New-Item -ItemType File -Path $LogPath | Out-Null }

    Write-Host "Scheduled task '$TaskName' registered. Updates will run in the background."
    Write-Host "Check the logs with: Get-Content '$LogPath' -Wait -Tail 50"

    exit
}


# ---------------------------------------------------------------
# MODE 2: Running inside the scheduled task
# ---------------------------------------------------------------

if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" | Out-Null
}

Start-Transcript -Path $LogPath -Append

function CleanUpdates {
    Write-Host "`nResetting Windows Update components - $(Get-Date)"

    $Stamp = Get-Date -Format "MM-dd-yyyy_HHmm"
    $Services = @("wuauserv", "cryptSvc", "bits", "msiserver")

    foreach ($svc in $Services) {
        try   { Stop-Service -Name $svc -Force -ErrorAction Stop; Write-Host "Stopped $svc" }
        catch { Write-Host "WARNING: Could not stop $svc - $($_.Exception.Message)" }
    }

    try {
        Rename-Item -Path "C:\Windows\SoftwareDistribution" -NewName "SoftwareDistribution.$Stamp" -ErrorAction Stop
        Write-Host "Renamed SoftwareDistribution"
    } catch { Write-Host "WARNING: SoftwareDistribution rename failed - $($_.Exception.Message)" }

    try {
        Rename-Item -Path "C:\Windows\System32\catroot2" -NewName "catroot2.$Stamp" -ErrorAction Stop
        Write-Host "Renamed catroot2"
    } catch { Write-Host "WARNING: catroot2 rename failed - $($_.Exception.Message)" }

    foreach ($svc in $Services) {
        try   { Start-Service -Name $svc -ErrorAction Stop; Write-Host "Started $svc" }
        catch { Write-Host "WARNING: Could not start $svc - $($_.Exception.Message)" }
    }

    Write-Host "Windows Update reset complete."
}

function UpdateOS {

    # ---------------------------------------------------------------
    # Update preferences - set to $true or $false
    # ---------------------------------------------------------------
    $IncludeOptional = $false   # Recommended/important updates only
    $IncludeDrivers  = $false   # Hardware driver updates
    # ---------------------------------------------------------------

    Write-Host "`nUpdating OS - $(Get-Date)"

    $CriteriaList = @("IsInstalled=0", "IsHidden=0")
    if (-not $IncludeOptional) { $CriteriaList += "BrowseOnly=0"; $CriteriaList += "AutoSelectOnWebSites=1" }
    if (-not $IncludeDrivers)  { $CriteriaList += "Type='Software'" }
    $Criteria = $CriteriaList -join " AND "

    Write-Host "Include optional updates : $IncludeOptional"
    Write-Host "Include driver updates   : $IncludeDrivers"

    Write-Host "Searching for updates..."
    $Searcher     = New-Object -ComObject Microsoft.Update.Searcher
    $SearchResult = $Searcher.Search($Criteria).Updates

    if ($SearchResult.Count -eq 0) {
        Write-Host "No updates found."
        return
    }

    Write-Host "$($SearchResult.Count) update(s) found.`n"

    $Session = New-Object -ComObject Microsoft.Update.Session

    for ($i = 0; $i -lt $SearchResult.Count; $i++) {

        $Update = $SearchResult.Item($i)

        if (-not $IncludeOptional -and ($Update.BrowseOnly -or -not $Update.AutoSelectOnWebSites)) {
            Write-Host "[$($i+1)/$($SearchResult.Count)] Skipping optional: $($Update.Title)"
            continue
        }
        if (-not $IncludeDrivers -and $Update.Driver) {
            Write-Host "[$($i+1)/$($SearchResult.Count)] Skipping driver: $($Update.Title)"
            continue
        }

        $UpdateColl = New-Object -ComObject Microsoft.Update.UpdateColl
        $UpdateColl.Add($Update) | Out-Null

        Write-Host "------------------------------------------------------------"
        Write-Host "[$($i+1)/$($SearchResult.Count)] $($Update.Title)"
        Write-Host "KB: $($Update.KBArticleIDs | Select-Object -First 1)"

        # Download
        Write-Host "$(Get-Date) - Downloading..."
        $Downloader         = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $UpdateColl
        $DownloadResult     = $Downloader.Download()
        Write-Host "Download Result     : $(Get-ResultDescription $DownloadResult.ResultCode)"

        # Install
        Write-Host "$(Get-Date) - Installing..."
        $Installer         = New-Object -ComObject Microsoft.Update.Installer
        $Installer.Updates = $UpdateColl
        $InstallResult     = $Installer.Install()

        $UpdateResult = $InstallResult.GetUpdateResult(0)
        Write-Host "Install Result      : $(Get-ResultDescription $UpdateResult.ResultCode)"
        Write-Host "Install HResult     : 0x$($UpdateResult.HResult.ToString('X8'))"

        if ($InstallResult.RebootRequired) {
            Write-Host "Reboot required after this update."
        }

        Write-Host "$(Get-Date) - Done.`n"
    }

    Write-Host "============================================================"
    Write-Host "All updates processed - $(Get-Date)"
}

CleanUpdates
UpdateOS

Stop-Transcript

# ---------------------------------------------------------------
# CLEANUP: Remove scheduled task, then self-delete the .ps1
# ---------------------------------------------------------------

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Start-Process powershell.exe -ArgumentList @(
    "-NonInteractive",
    "-NoProfile",
    "-Command",
    "Start-Sleep -Seconds 5; Remove-Item -LiteralPath '$ScriptPath' -Force"
) -WindowStyle Hidden
