# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$DebugLog = $false,
    [switch]$ForceUpdate = $false
)

function Write-DebugHost {
    param($msg)
    if ($DebugLog) { Write-Host "DEBUG: $msg" -ForegroundColor Cyan }
}

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found."; exit 1 }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# 1. Selection logic
$campaignKeys = $manifest.campaigns.PSObject.Properties.Name
if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
    $campaignKeys = $campaignKeys | Where-Object { $_ -eq $CampaignId }
}

foreach ($campaignKey in $campaignKeys) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating: $($camp.name) ---"
    $processedFileNames = @()
    
    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    try { 
        $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"} 
    } catch { 
        Write-Warning "Could not access remote repo for $campaignKey"; continue 
    }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        # --- RESET: Prevent cross-file pollution ---
        $resolvedID = $null; $messages = @(); $rawJson = $null; $logEntry = $null; $foundThreadIDs = @()
        $processedFileNames += $f.name

        Write-Host "  > Processing File: $($f.name)"
        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            $messages = if ($rawJson.PSObject.Properties.Name -contains 'messages') { $rawJson.messages } else { $rawJson }
        } catch { continue }

        if ($null -eq $messages -or $messages.Count -eq 0) { continue }

        # --- ID RESOLUTION ---
        foreach ($msg in $messages) {
            $mC = if ($msg.channel_id) { [string]$msg.channel_id } else { "" }
            $mP = if ($msg.thread -and $msg.thread.parent_id) { [string]$msg.thread.parent_id } else { "" }

            # If parent_id exists and isn't a placeholder "1", it's a thread export: use the parent Chapter ID.
            if ($mP -and $mP -ne "1" -and $mP.Length -gt 10) {
                $resolvedID = $mP
                Write-DebugHost "Resolved ID via Parent: $resolvedID"
                break
            } 
            # Otherwise, use the standard channel_id.
            elseif ($mC -and $mC.Length -gt 10) {
                $resolvedID = $mC
                Write-DebugHost "Resolved ID via Channel: $resolvedID"
                break
            }
        }

        # --- MATCHING LOGIC (Priority 1: ID | Priority 2: Filename) ---
        if ($resolvedID) {
            $logEntry = $camp.logs | Where-Object { [string]$_.channelID -eq $resolvedID }
        }
        
        # If no ID match (or no ID found in file), check for Filename
        if (-not $logEntry) {
            $logEntry = $camp.logs | Where-Object { $_.fileName -eq $f.name -or $_.file -eq $f.name }
            if ($logEntry) { Write-DebugHost "Matched existing record via Filename backup." }
        }

        # If still no match, create new record
        if (-not $logEntry) {
            Write-Host "    + New Chapter detected. Initializing record..."
            $logEntry = [PSCustomObject]@{ 
                channelID = if($resolvedID){$resolvedID}else{""}
                title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                fileName = [string]$f.name
                isActive = $true
                threads = @()
                messageCount = 0
                order = 0
            }
            if ($null -eq $camp.logs) { $camp.logs = @() }
            $camp.logs += $logEntry
        }

        # --- DATA SYNC ---
        # Cleanup 'file' key, ensure 'fileName' is standard
        if ($logEntry.PSObject.Properties['file']) { $logEntry.PSObject.Properties.Remove('file') }
        $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
        $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
        
        # Update Channel ID if one was successfully extracted
        if ($resolvedID) {
            $logEntry | Add-Member -NotePropertyName "channelID" -NotePropertyValue $resolvedID -Force
        }

        # Sync Stats
        $sorted = $messages | Sort-Object timestamp
        $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sorted[-1].timestamp) -Force
        $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count -Force
        
        $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
        $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

        # --- THREADS (Exclude Chapter Starter) ---
        $threadMsgs = $messages | Where-Object { 
            $_.thread -and $_.thread.id -and [string]$_.thread.id -ne [string]$logEntry.channelID 
        }

        if ($threadMsgs) {
            $groups = $threadMsgs | Group-Object { [string]$_.thread.id }
            foreach ($g in $groups) {
                $tID = [string]$g.Name
                $foundThreadIDs += $tID
                if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                $tEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                
                if (-not $tEntry) {
                    $tEntry = [PSCustomObject]@{ threadID = $tID; displayName = [string]$g.Group[0].thread.name; isNSFW = $false }
                    $logEntry.threads += $tEntry
                }
                $tEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                $tEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($g.Count) -Force
            }
        }
        foreach ($t in $logEntry.threads) { if ($foundThreadIDs -notcontains [string]$t.threadID) { $t.isActive = $false } }
    }

    # Orphan Cleanup: If a fileName in registry is no longer in the folder, mark inactive
    foreach ($log in $camp.logs) {
        if ($processedFileNames -notcontains $log.fileName) { $log.isActive = $false }
    }
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
