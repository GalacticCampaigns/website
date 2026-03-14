# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$DebugLog = $false,
    [switch]$ForceUpdate = $false
)

function Write-DebugHost { param($msg); if ($DebugLog) { Write-Host "DEBUG: $msg" -ForegroundColor Cyan } }

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found at $manifestPath"; exit 1 }

# Read manifest
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# 1. Campaign Selection
$campaignKeys = $manifest.campaigns.PSObject.Properties.Name
if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
    Write-Host "Targeting specific campaign: $CampaignId"
    $campaignKeys = $campaignKeys | Where-Object { $_ -eq $CampaignId }
}

foreach ($campaignKey in $campaignKeys) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating Campaign: $($camp.name) ($campaignKey) ---"
    
    if (-not $camp.repository) { 
        Write-Warning "No repository defined for $campaignKey. Skipping."
        continue 
    }

    $processedFileNames = @()
    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    
    Write-DebugHost "Fetching file list from: $apiUrl"
    try {
        $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}
    } catch {
        Write-Warning "Could not access remote repository for $campaignKey."
        continue
    }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        # --- RESET: Prevent data bleeding between files ---
        $foundID = $null; $messages = @(); $rawJson = $null; $foundThreadIDs = @()
        $processedFileNames += $f.name

        Write-Host "  > Processing File: $($f.name)"
        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            # NORMALIZATION: Handle both Object {messages:[]} and Array []
            if ($rawJson.PSObject.Properties.Name -contains 'messages') { 
                $messages = $rawJson.messages 
                Write-DebugHost "Format: Nested 'messages' object."
            } else { 
                $messages = $rawJson 
                Write-DebugHost "Format: Flat Array."
            }
        } catch { 
            Write-Warning "    ! Failed to download or parse $($f.name)"
            continue 
        }

        if ($null -eq $messages -or $messages.Count -eq 0) {
            Write-Warning "    ! No messages found in $($f.name). Skipping."
            continue
        }

        # --- ID RESOLUTION SCAN ---
        foreach ($msg in $messages) {
            $mC = if ($msg.channel_id) { [string]$msg.channel_id } else { "" }
            $mP = if ($msg.thread -and $msg.thread.parent_id) { [string]$msg.thread.parent_id } else { "" }

            if ($mP -and $mP -ne "1" -and $mP.Length -gt 10) {
                $foundID = $mP
                Write-DebugHost "ID Resolved via Thread Parent: $foundID"
                break
            } elseif ($mC -and $mC.Length -gt 10) {
                $foundID = $mC
                Write-DebugHost "ID Resolved via Channel ID: $foundID"
                break
            }
        }

        # --- MATCHING LOGIC (Direct Registry Patching) ---
        $logIndex = -1
        for ($i=0; $i -lt $camp.logs.Count; $i++) {
            if ($camp.logs[$i].fileName -eq $f.name -or $camp.logs[$i].file -eq $f.name) {
                $logIndex = $i; break
            }
        }

        if ($logIndex -ge 0) {
            # --- PATCH EXISTING ---
            $target = $camp.logs[$logIndex]
            Write-DebugHost "Found existing entry. Patching volatile fields..."
            
            # Standardize filename property
            if ($target.PSObject.Properties['file']) { $target.PSObject.Properties.Remove('file') }
            $target | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force

            # Only update ID if we actually found a valid one in the file
            if ($foundID) { $target.channelID = $foundID }
            
            $target.isActive = $true
            
            $sorted = $messages | Sort-Object timestamp
            $target.lastMessageTimestamp = [string]$sorted[-1].timestamp
            $target.messageCount = ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count

            if (-not $target.order -and $f.name -match '(\d+)') { $target.order = [int]$matches[1] }

            # --- THREADS (Filtered to avoid Chapter Starter) ---
            $threadMsgs = $messages | Where-Object { 
                $_.thread -and $_.thread.id -and [string]$_.thread.id -ne [string]$target.channelID 
            }

            if ($threadMsgs) {
                $groups = $threadMsgs | Group-Object { [string]$_.thread.id }
                foreach ($g in $groups) {
                    $tID = [string]$g.Name
                    $foundThreadIDs += $tID
                    if ($null -eq $target.threads) { $target.threads = @() }
                    $tEntry = $target.threads | Where-Object { [string]$_.threadID -eq $tID }
                    
                    if (-not $tEntry) {
                        $tEntry = [PSCustomObject]@{ 
                            threadID = $tID; displayName = [string]$g.Group[0].thread.name; 
                            isActive = $true; isNSFW = $false; messageCount = $g.Count 
                        }
                        $target.threads += $tEntry
                    } else {
                        $tEntry.isActive = $true
                        $tEntry.messageCount = $g.Count
                    }
                }
            }
            # Mark missing threads as inactive in this specific log
            foreach ($t in $target.threads) { if ($foundThreadIDs -notcontains [string]$t.threadID) { $t.isActive = $false } }

        } else {
            # --- CREATE NEW ---
            Write-Host "    + New file detected. Creating initial entry..."
            $newEntry = [PSCustomObject]@{
                title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                channelID = if($foundID){$foundID}else{""}
                fileName = [string]$f.name
                isActive = $true
                isNSFW = $false
                threads = @()
                preview = ""
                messageCount = 0
                order = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
            }
            if ($null -eq $camp.logs) { $camp.logs = @() }
            $camp.logs += $newEntry
        }
    }

    # --- GLOBAL CLEANUP ---
    foreach ($log in $camp.logs) {
        if ($processedFileNames -notcontains $log.fileName) {
            $log.isActive = $false
        }
    }
}

# Final Export with proper depth
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
