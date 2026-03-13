# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Campaign Registry not found at $manifestPath. Please create the seed file first."
    exit 1
}

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
            Write-Warning "Could not access repo for $campaignKey."
            continue
        }

        foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
            Write-Host "  > Processing $($f.name)..."
            $jsonData = Invoke-RestMethod -Uri $f.download_url
            
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            if (-not $messages) { continue }

            # --- ID RESOLUTION ---
            # We look for the first message that has a proper Snowflake ID
            $firstMsg = $messages | Select-Object -First 1
            $chanID = [string]$firstMsg.channel_id
            
            # Logic: If this file is a thread export, the 'channel_id' IS the Thread ID. 
            # We need the 'parent_id' to find the Chapter. 
            # If parent_id is missing or "1", then this file is the Chapter itself.
            $primaryID = $chanID
            if ($firstMsg.thread -and $firstMsg.thread.parent_id -and [string]$firstMsg.thread.parent_id -ne "1") {
                $primaryID = [string]$firstMsg.thread.parent_id
            }
            
            $foundChannelIDs += $primaryID

            # --- MATCHING ---
            # Standardize comparison to strings to prevent scientific notation mismatches
            $logEntry = $camp.logs | Where-Object { [string]$_.channelID -eq $primaryID }
            
            if (-not $logEntry) {
                Write-Host "    + New Chapter detected! ID: $primaryID (File: $($f.name))"
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

            # --- METADATA UPDATES ---
            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            
            if ($f.name -match '(\d+)') { $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue ([int]$matches[1]) -Force }

            # Total Count (Excludes System Messages)
            $validMsgs = $messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $validMsgs.Count -Force

            # --- THREAD INVENTORY ---
            $foundThreadIDs = @()
            # Filter out any message where the thread ID is the same as the Chapter (Parent) ID
            $actualThreads = $messages | Where-Object { 
                $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $primaryID 
            }
            
            if ($actualThreads) {
                $threadGroups = $actualThreads | Group-Object { [string]$_.thread.id }
                
                foreach ($group in $threadGroups) {
                    $tID = [string]$group.Name
                    $foundThreadIDs += $tID
                    
                    if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                    $threadEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                    
                    if (-not $threadEntry) {
                        $threadEntry = [PSCustomObject]@{ 
                            threadID = $tID
                            displayName = [string]$group.Group[0].thread.name
                            isNSFW = $false
                            isActive = $true
                            messageCount = 0
                        }
                        $logEntry.threads += $threadEntry
                    }
                    
                    # Correct count: count valid messages belonging to this thread group
                    $tCount = ($group.Group | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
                    $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                    $threadEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $tCount -Force
                }
            }

            # Cleanup inactive threads in this log
            foreach ($t in $logEntry.threads) {
                if ($foundThreadIDs -notcontains [string]$t.threadID) { 
                    $t | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force 
                }
            }
        }
    }

    # --- GLOBAL ORPHAN CLEANUP ---
    foreach ($log in $camp.logs) {
        $idStr = [string]$log.channelID
        if ($foundChannelIDs -notcontains $idStr) {
            $log | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $idStr)"
        }
    }
}

# Depth 10 is vital to prevent PowerShell from truncating the 'threads' array in output
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"