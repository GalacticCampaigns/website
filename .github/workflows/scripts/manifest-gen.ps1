# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Registry not found at $manifestPath"; exit 1
}

# Read manifest
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

foreach ($campaignKey in $manifest.campaigns.PSObject.Properties.Name) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating Campaign: $($camp.name) ---"
    $foundChannelIDs = @()

    if ($camp.repository) {
        $apiBase = "https://api.github.com/repos/$($camp.repository)/contents/"
        $jsonRelativePath = "$($camp.dataPath)$($camp.paths.json)".TrimStart('/')
        $apiUrl = "$($apiBase)$($jsonRelativePath)?ref=$($camp.branch)"

        try {
            $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}
        } catch {
            Write-Warning "Could not access repo for $campaignKey."; continue
        }

        foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
            # --- CRITICAL: Reset variables for every file to prevent data leakage ---
            $primaryID = $null
            $messages = $null
            $jsonData = $null
            $logEntry = $null

            Write-Host "  > Processing $($f.name)..."
            try {
                $jsonData = Invoke-RestMethod -Uri $f.download_url
            } catch {
                Write-Warning "    ! Failed to download $($f.name)"; continue
            }
            
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            if (-not $messages -or $messages.Count -eq 0) { continue }

            # --- ID RESOLUTION ---
            $firstMsg = $messages | Select-Object -First 1
            # Check for a valid Snowflake (Discord IDs are ~18 digits). 
            # We ignore parent_id if it's "1" or too short.
            if ($firstMsg.thread -and $firstMsg.thread.parent_id -and [string]$firstMsg.thread.parent_id.Length -gt 10) {
                $primaryID = [string]$firstMsg.thread.parent_id
            } else {
                $primaryID = [string]$firstMsg.channel_id
            }

            # Safety: If we still don't have a valid ID, skip this file
            if ([string]::IsNullOrWhiteSpace($primaryID) -or $primaryID -eq "0") {
                Write-Warning "    ! Could not resolve a valid Channel ID for $($f.name). Skipping."; continue
            }

            $foundChannelIDs += $primaryID

            # --- MATCHING ---
            $logEntry = $camp.logs | Where-Object { [string]$_.channelID -eq $primaryID }

            if (-not $logEntry) {
                Write-Host "    + New Chapter detected! ID: $primaryID"
                $logEntry = [PSCustomObject]@{ 
                    channelID = $primaryID
                    title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                    fileName = [string]$f.name
                    isActive = $true
                    isNSFW = $false
                    threads = @()
                    preview = ""
                    messageCount = 0
                    lastMessageTimestamp = ""
                    order = 0
                }
                if ($null -eq $camp.logs) { $camp.logs = @() }
                $camp.logs += $logEntry
            }

            # --- UPDATE DATA (Force Property creation) ---
            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            
            $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
            $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

            # Count valid narrative messages
            $validMsgs = $messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $validMsgs.Count -Force

            # --- THREADS ---
            $foundThreadIDs = @()
            # Filter: only valid threads, excluding the main parent channel itself
            $actualThreads = $messages | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $primaryID }
            
            if ($actualThreads) {
                $threadGroups = $actualThreads | Group-Object { [string]$_.thread.id }
                foreach ($group in $threadGroups) {
                    $tID = [string]$group.Name
                    $foundThreadIDs += $tID
                    $threadEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                    
                    if (-not $threadEntry) {
                        $threadEntry = [PSCustomObject]@{ 
                            threadID = $tID
                            displayName = [string]$group.Group[0].thread.name
                            isNSFW = $false
                        }
                        if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                        $logEntry.threads += $threadEntry
                    }
                    
                    # Update thread stats
                    $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                    # Count valid messages inside this specific thread group
                    $tMsgCount = ($group.Group | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
                    $threadEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $tMsgCount -Force
                }
            }

            # Mark inactive threads
            foreach ($t in $logEntry.threads) {
                if ($foundThreadIDs -notcontains [string]$t.threadID) { 
                    $t | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force 
                }
            }
        }
    }

    # --- ORPHAN CLEANUP ---
    foreach ($log in $camp.logs) {
        $idStr = [string]$log.channelID
        if ($foundChannelIDs -notcontains $idStr) {
            $log | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $idStr)"
        }
    }
}

# Save with Depth 10 to ensure nested threads aren't lost
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"