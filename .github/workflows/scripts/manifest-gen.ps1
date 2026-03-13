# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

# Configuration
$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Campaign Registry not found at $manifestPath. Please create the seed file first."
    exit 1
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
            Write-Warning "Could not access repo for $campaignKey."
            continue
        }

        foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
            # --- RESET ALL VARIABLES: Prevents data from one file bleeding into the next ---
            $primaryID = $null
            $messages = $null
            $jsonData = $null
            $logEntry = $null
            $foundThreadIDs = @()

            Write-Host "  > Processing $($f.name)..."
            try {
                $jsonData = Invoke-RestMethod -Uri $f.download_url
            } catch {
                Write-Warning "    ! Failed to download $($f.name)"; continue
            }
            
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            if (-not $messages -or $messages.Count -eq 0) { continue }

            # --- ROBUST ID RESOLUTION ---
            # Search messages until we find a valid Snowflake ID (>10 chars)
            foreach ($msg in $messages) {
                $candidate = $null
                # Priority: If it's an export of a thread, we want the Parent ID (The Chapter)
                if ($msg.thread -and $msg.thread.parent_id -and ([string]$msg.thread.parent_id).Length -gt 10 -and [string]$msg.thread.parent_id -ne "1") {
                    $candidate = [string]$msg.thread.parent_id
                } elseif ($msg.channel_id -and ([string]$msg.channel_id).Length -gt 10) {
                    $candidate = [string]$msg.channel_id
                }

                if ($candidate) {
                    $primaryID = $candidate
                    break # Success: ID Found
                }
            }

            if (-not $primaryID) {
                Write-Warning "    ! Could not resolve a valid Channel ID for $($f.name). Skipping."; continue
            }

            $foundChannelIDs += $primaryID

            # --- MATCHING & CLEANUP ---
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

            # Standardize Property Names (Cleanup 'file' vs 'fileName')
            if ($logEntry.PSObject.Properties['file']) { $logEntry.PSObject.Properties.Remove('file') }
            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            
            $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
            $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

            # Total Count (Excludes System noise)
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count -Force

            # --- THREAD INVENTORY ---
            # Filter: Exclude messages where the Thread ID matches the Chapter ID (The "Starter" message)
            $actualThreads = $messages | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $primaryID }
            
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
                    
                    # Correct count for sub-messages
                    $tMsgCount = ($group.Group | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
                    $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                    $threadEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $tMsgCount -Force
                }
            }

            # Mark missing threads as inactive
            foreach ($t in $logEntry.threads) {
                if ($foundThreadIDs -notcontains [string]$t.threadID) { 
                    $t | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force 
                }
            }
        }
    }

    # --- GLOBAL CLEANUP ---
    foreach ($log in $camp.logs) {
        $idStr = [string]$log.channelID
        if ($idStr -and $foundChannelIDs -notcontains $idStr) {
            $log | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $idStr)"
        }
    }
}

# Depth 10 is required so the nested thread objects don't get turned into strings
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
