# .github/workflows/scripts/manifest-gen.ps1
param (
    [switch]$ForceUpdate = $false
)

# Configuration: We now use the registry as the single source of truth
$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Campaign Registry not found at $manifestPath. Please create the seed file first."
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# --- Logic: Loop through each campaign defined in the registry ---
foreach ($campaignKey in $manifest.campaigns.PSObject.Properties.Name) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating Campaign: $($camp.name) ($campaignKey) ---"
    
    # Track discovered IDs in this run to identify orphans
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

            # 1. Identify Primary Channel ID (Chapter ID)
            # We look at the first message's channel_id or the thread's parent_id
            $firstMsg = $messages | Select-Object -First 1
            $primaryID = if ($firstMsg.thread -and $firstMsg.thread.parent_id) { [string]$firstMsg.thread.parent_id } else { [string]$firstMsg.channel_id }
            $foundChannelIDs += $primaryID

            # 2. Find or Create the Log Entry
            $logEntry = $camp.logs | Where-Object { $_.channelID -eq $primaryID }
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
                $camp.logs += $logEntry
            }

            # 3. Update Dynamic Metadata (Force properties to exist)
            $logEntry | Add-Member -MemberType NoteProperty -Name "fileName" -Value ([string]$f.name) -Force
            $logEntry | Add-Member -MemberType NoteProperty -Name "isActive" -Value $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry.lastMessageTimestamp = [string]$sortedMsgs[-1].timestamp
            $logEntry.order = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }

            # 4. Accurate Message Counting
            $validMsgs = $messages | Where-Object { 
                $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0 -or -not $_.type) 
            }
            $logEntry.messageCount = $validMsgs.Count

            # 5. Thread Inventory
            $foundThreadIDs = @()
            $threadGroups = $messages | Where-Object { $_.thread -and $_.thread.id } | Group-Object { $_.thread.id }
            
            foreach ($group in $threadGroups) {
                $tID = [string]$group.Name
                $foundThreadIDs += $tID
                $threadEntry = $logEntry.threads | Where-Object { $_.threadID -eq $tID }
                
                if (-not $threadEntry) {
                    $threadEntry = [PSCustomObject]@{ 
                        threadID = $tID
                        displayName = [string]$group.Group[0].thread.name
                        isNSFW = $false
                        isActive = $true # Initialize here
                        messageCount = 0
                    }
                    $logEntry.threads += $threadEntry
                }
                
                # Use Add-Member to bypass the "Property not found" error for threads
                $threadEntry | Add-Member -MemberType NoteProperty -Name "isActive" -Value $true -Force
                $threadEntry.messageCount = ($group.Group | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
            }
        }
    }

    # 6. Global Cleanup: Mark orphaned logs as inactive
    foreach ($log in $camp.logs) {
        if ($foundChannelIDs -notcontains $log.channelID) {
            $log.isActive = $false
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $($log.channelID))"
        }
    }
}

# --- Final Step: Save and Report ---
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"

if ($droppedItems.Count -gt 0) {
    $report = "DROPPED IDs DETECTED:`n" + ($droppedItems -join "`n")
    Write-Host "##[warning]$report"
    $report | Out-File "dropped_report.txt" -Encoding UTF8

}

