# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

# Configuration: Single Source of Truth
$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Campaign Registry not found at $manifestPath. Please create the seed file first."
    exit 1
}

# Read manifest and ensure it is treated as a modifiable object
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# --- Logic: Loop through each campaign defined in the registry ---
foreach ($campaignKey in $manifest.campaigns.PSObject.Properties.Name) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating Campaign: $($camp.name) ($campaignKey) ---"
    
    # Track discovered IDs in this run to identify orphans later
    $foundChannelIDs = @()

    # Determine if we are looking at a remote GitHub Repo
    if ($camp.repository) {
        $apiBase = "https://api.github.com/repos/$($camp.repository)/contents/"
        $jsonRelativePath = "$($camp.dataPath)$($camp.paths.json)".TrimStart('/')
        $apiUrl = "$($apiBase)$($jsonRelativePath)?ref=$($camp.branch)"

        Write-Host "Fetching file list from: $apiUrl"
        try {
            $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}
        } catch {
            Write-Warning "Could not access repo for $campaignKey. Error: $($_.Exception.Message)"
            continue
        }

        # Ensure we only process .json files
        $targetFiles = $files | Where-Object { $_.name -like "*.json" }

        foreach ($f in $targetFiles) {
            Write-Host "  > Processing $($f.name)..."
            $jsonData = Invoke-RestMethod -Uri $f.download_url
            
            # Extract messages (handle different export formats)
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            if (-not $messages) { continue }

            # 1. Identify Primary Channel ID (Forced to String for reliable matching)
            $firstMsg = $messages | Select-Object -First 1
            $primaryID = if ($firstMsg.thread -and $firstMsg.thread.parent_id) { [string]$firstMsg.thread.parent_id } else { [string]$firstMsg.channel_id }
            $foundChannelIDs += $primaryID

            # 2. Find or Create the Log Entry (Match using String comparison)
            $logEntry = $camp.logs | Where-Object { [string]$_.channelID -eq $primaryID }
            
            if (-not $logEntry) {
                Write-Host "    + New Chapter detected! ID: $primaryID"
                $logEntry = [PSCustomObject]@{ 
                    channelID = [string]$primaryID
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
                # Initialize the logs array if it's currently null
                if ($null -eq $camp.logs) { $camp.logs = @() }
                $camp.logs += $logEntry
            }

            # 3. Update Dynamic Metadata (Force creation of properties to avoid Exception setting errors)
            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            
            $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
            $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

            # 4. Accurate Message Counting (Includes Threads, Excludes System Noise)
            $validMsgs = $messages | Where-Object { 
                $_.content -ne "" -and 
                ($_.type -eq "Default" -or $_.type -eq 0 -or -not $_.type) 
            }
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue $validMsgs.Count -Force

            # 5. Thread Inventory
            $foundThreadIDs = @()
            $threadGroups = $messages | Where-Object { $_.thread -and $_.thread.id } | Group-Object { $_.thread.id }
            
            foreach ($group in $threadGroups) {
                $tID = [string]$group.Name
                $foundThreadIDs += $tID
                $threadEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                
                if (-not $threadEntry) {
                    $threadEntry = [PSCustomObject]@{ 
                        threadID = $tID
                        displayName = [string]$group.Group[0].thread.name
                        isNSFW = $false
                        isActive = $true
                        messageCount = 0
                    }
                    if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                    $logEntry.threads += $threadEntry
                }
                
                $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                $threadEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($group.Count) -Force
            }

            # Mark missing threads as inactive within this log
            foreach ($t in $logEntry.threads) {
                if ($foundThreadIDs -notcontains [string]$t.threadID) { 
                    $t | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force 
                }
            }
        }
    }

    # 6. Global Cleanup: Mark orphaned logs as inactive
    foreach ($log in $camp.logs) {
        if ($foundChannelIDs -notcontains [string]$log.channelID) {
            $log | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $($log.channelID))"
        }
    }
}

# --- Final Step: Save and Report ---
# Depth 10 ensures nested arrays (threads) are not truncated in the JSON output
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"

if ($droppedItems.Count -gt 0) {
    $report = "DROPPED IDs DETECTED:`n" + ($droppedItems -join "`n")
    Write-Host "##[warning]$report"
    $report | Out-File "dropped_report.txt" -Encoding UTF8
}
