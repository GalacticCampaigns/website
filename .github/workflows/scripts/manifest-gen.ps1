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
        $remoteFiles = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}
    } catch { 
        Write-Warning "Could not access API for $campaignKey"; continue 
    }

    foreach ($f in $remoteFiles | Where-Object { $_.name -like "*.json" }) {
        # --- RESET ---
        $primaryID = $null; $messages = @(); $rawJson = $null; $logEntry = $null; $foundThreadIDs = @()
        $processedFileNames += $f.name

        Write-Host "  > Processing: $($f.name)"
        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            if ($rawJson.PSObject.Properties.Name -contains 'messages') { 
                $messages = $rawJson.messages 
                Write-DebugHost "Detected 'messages' key format."
            } else { 
                $messages = $rawJson 
                Write-DebugHost "Detected flat array format."
            }
        } catch { continue }

        if ($null -eq $messages -or $messages.Count -eq 0) {
            Write-Warning "    ! No messages found in $($f.name)"; continue
        }

        # --- ID RESOLUTION SCAN ---
        foreach ($msg in $messages) {
            $cid = [string]$msg.channel_id
            $pid = if ($msg.thread) { [string]$msg.thread.parent_id } else { $null }

            Write-DebugHost "Checking Msg $($msg.id): chanID='$cid', parentID='$pid'"

            # Priority Logic: Use Parent ID if it's a valid Snowflake
            if ($pid -and $pid.Length -gt 15 -and $pid -ne "1") { 
                $primaryID = $pid
                Write-DebugHost "Found valid Parent ID: $primaryID. Marking as Chapter ID."
                break 
            }
            # Otherwise, use Channel ID if it's a valid Snowflake
            elseif ($cid -and $cid.Length -gt 15) { 
                $primaryID = $cid
                Write-DebugHost "Found valid Channel ID: $primaryID. Marking as Chapter ID."
                break 
            }
        }

        # --- MATCHING ---
        # Match by Filename first (keeps your manual updates safe)
        $logEntry = $camp.logs | Where-Object { $_.fileName -eq $f.name -or $_.file -eq $f.name }

        if (-not $logEntry) {
            Write-Host "    + Adding NEW registry entry..."
            $logEntry = [PSCustomObject]@{ 
                title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                fileName = [string]$f.name
                channelID = if($primaryID){$primaryID}else{""}
                isActive = $true
                threads = @()
                messageCount = 0
                preview = ""
            }
            if ($null -eq $camp.logs) { $camp.logs = @() }
            $camp.logs += $logEntry
        } else {
            Write-DebugHost "Matched existing entry by FileName: $($f.name)"
        }

        # --- UPDATE ---
        if ($logEntry.PSObject.Properties['file']) { $logEntry.PSObject.Properties.Remove('file') }
        $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
        $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
        
        # PRESERVATION: Only overwrite channelID if we found a valid one in the file
        if ($primaryID) {
            Write-DebugHost "Syncing ID: $($logEntry.channelID) -> $primaryID"
            $logEntry | Add-Member -NotePropertyName "channelID" -NotePropertyValue $primaryID -Force 
        } else {
            Write-Warning "    ! No ID found in file. Keeping existing registry ID: $($logEntry.channelID)"
        }
        
        $sorted = $messages | Sort-Object timestamp
        $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sorted[-1].timestamp) -Force
        
        $validMsgs = $messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0 -or -not $_.type) }
        $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $validMsgs.Count -Force
        Write-DebugHost "Counted $($validMsgs.Count) narrative messages."

        # --- THREADS ---
        # 1. Identify valid threads that are NOT the main channel
        $threadMsgs = $messages | Where-Object { 
            $_.thread -and $_.thread.id -and [string]$_.thread.id -ne [string]$logEntry.channelID 
        }

        if ($threadMsgs) {
            $groups = $threadMsgs | Group-Object { [string]$_.thread.id }
            Write-DebugHost "Found $($groups.Count) unique threads."
            foreach ($g in $groups) {
                $tID = [string]$g.Name
                $foundThreadIDs += $tID
                if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                $tEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                
                if (-not $tEntry) {
                    Write-DebugHost "New Thread Detected: $tID ($($g.Group[0].thread.name))"
                    $tEntry = [PSCustomObject]@{ threadID = $tID; displayName = [string]$g.Group[0].thread.name; isNSFW = $false }
                    $logEntry.threads += $tEntry
                }
                
                $tEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                # Count actual messages inside this specific group
                $tEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($g.Count) -Force
            }
        }
        foreach ($t in $logEntry.threads) { if ($foundThreadIDs -notcontains [string]$t.threadID) { $t.isActive = $false } }
    }

    # Orphan Cleanup
    foreach ($log in $camp.logs) {
        if ($processedFileNames -notcontains $log.fileName) { $log.isActive = $false }
    }
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"