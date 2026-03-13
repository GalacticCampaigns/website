# .github/workflows/scripts/manifest-gen.ps1
param ([switch]$ForceUpdate = $false)

$manifestPath = "assets/campaign-registry.json"
$droppedItems = @()

if (-not (Test-Path $manifestPath)) {
    Write-Error "Registry not found at $manifestPath"; exit 1
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

        $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}

        foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
            $jsonData = Invoke-RestMethod -Uri $f.download_url
            $messages = if ($jsonData.PSObject.Properties.Name -contains 'messages') { $jsonData.messages } else { $jsonData }
            
            $firstMsg = $messages | Select-Object -First 1
            $primaryID = if ($firstMsg.thread -and $firstMsg.thread.parent_id) { [string]$firstMsg.thread.parent_id } else { [string]$firstMsg.channel_id }
            
            # DEBUG: Uncomment this if the problem persists to see ID mismatches
            # Write-Host "DEBUG: File $($f.name) resolved to ID: $primaryID"
            
            $foundChannelIDs += $primaryID

            $logEntry = $camp.logs | Where-Object { [string]$_.channelID -eq $primaryID }

            if (-not $logEntry) {
                Write-Host "    + New Chapter detected! ID: $primaryID (File: $($f.name))"
                $logEntry = [PSCustomObject]@{ 
                    channelID = $primaryID; title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                    fileName = [string]$f.name; isActive = $true; isNSFW = $false; threads = @(); preview = ""; messageCount = 0
                }
                if ($null -eq $camp.logs) { $camp.logs = @() }
                $camp.logs += $logEntry
            }

            $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
            $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            
            $sortedMsgs = $messages | Sort-Object timestamp
            $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sortedMsgs[-1].timestamp) -Force
            $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count -Force

            # Handle Threads... (kept standard)
            $threadGroups = $messages | Where-Object { $_.thread -and $_.thread.id } | Group-Object { $_.thread.id }
            foreach ($group in $threadGroups) {
                $tID = [string]$group.Name
                $threadEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                if (-not $threadEntry) {
                    $threadEntry = [PSCustomObject]@{ threadID = $tID; displayName = [string]$group.Group[0].thread.name; isNSFW = $false }
                    if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                    $logEntry.threads += $threadEntry
                }
                $threadEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
            }
        }
    }

    foreach ($log in $camp.logs) {
        $idStr = [string]$log.channelID
        if ($foundChannelIDs -notcontains $idStr) {
            $log | Add-Member -NotePropertyName "isActive" -NotePropertyValue $false -Force
            $droppedItems += "Campaign: $($camp.name) | Log: $($log.title) (ID: $idStr)"
        }
    }
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8