# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Campaign Registry not found at $manifestPath"; exit 1
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
            Write-Warning "Could not access repo for $campaignKey."; continue
        }

        foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
            # --- CRITICAL FIX: Reset variables for every file to prevent "Chapter Smearing" ---
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
            
            # Handle different JSON structures (wrapped in 'messages' key or a flat array)
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            if (-not $messages -or $messages.Count -eq 0) { 
                Write-Warning "    ! No messages found in $($f.name)"; continue 
            }

            # --- ROBUST ID RESOLUTION ---
            # Instead of just the first message, find the first message that has a valid ID
            foreach ($msg in $messages) {
                $candidateID = $null
                # If it's a thread, the parent_id is the Chapter ID we want
                if ($msg.thread -and $msg.thread.parent_id -and [string]$msg.thread.parent_id.Length -gt 10) {
                    $candidateID = [string]$msg.thread.parent_id
                } elseif ($msg.channel_id -and [string]$msg.channel_id.Length -gt 10) {
                    $candidateID = [string]$msg.channel_id
                }

                if ($candidateID) {
                    $primaryID = $candidateID
                    break # Stop looking, we found the ID for this file
                }
            }

            if (-not $primaryID) {
                Write-Warning "    ! Could not resolve a valid Channel ID for $($f.name). Skipping."; continue
            }

            $foundChannelIDs += $primaryID

            # --- MATCHING LOGIC ---
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

            # --- UPDATE DATA (Force Property creation to avoid Exception setting errors) ---
            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            
            $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
            $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

            # Accurate count: Excludes system messages and blanks
            $validMsgs = $messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $validMsgs.Count -Force

            # --- THREAD INVENTORY ---
            $foundThreadIDs = @()
            # 1. Filter out messages that are just the "Thread Starter" notification (Thread ID == Primary ID)
            $actualThreads = $messages | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $primaryID }
            
            if ($actualThreads) {
                # 2. Group by thread ID to count correctly
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
                    
                    $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                    # 3. Count messages inside the thread group, excluding non-narrative posts
                    $tMsgCount = ($group.Group | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
                    $threadEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $tMsgCount -Force
                }
            }

            # Cleanup inactive threads in this file
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

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
