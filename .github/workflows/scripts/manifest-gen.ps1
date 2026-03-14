# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$ForceUpdate = $false
)

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found."; exit 1 }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# 1. Selection: Process one or all campaigns
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
    } catch { continue }

    foreach ($f in $remoteFiles | Where-Object { $_.name -like "*.json" }) {
        # --- RESET PER-FILE VARIABLES ---
        $primaryID = $null; $messages = @(); $rawJson = $null; $logEntry = $null; $foundThreadIDs = @()
        $processedFileNames += $f.name

        Write-Host "  > Processing: $($f.name)"
        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            if ($rawJson.PSObject.Properties.Name -contains 'messages') { $messages = $rawJson.messages }
            else { $messages = $rawJson }
        } catch { continue }

        if ($messages.Count -eq 0) { continue }

        # --- ID RESOLUTION ---
        # Look for the first valid message to determine Chapter ID
        foreach ($msg in $messages) {
            $tid = [string]$msg.thread.id
            $pid = [string]$msg.thread.parent_id
            $cid = [string]$msg.channel_id

            # If it's a thread export, the Parent ID is the Chapter ID
            if ($pid -and $pid.Length -gt 10 -and $pid -ne "1") { $primaryID = $pid; break }
            # Otherwise, use the Channel ID
            elseif ($cid -and $cid.Length -gt 10) { $primaryID = $cid; break }
        }

        # --- MATCHING (Primary key is Filename) ---
        $logEntry = $camp.logs | Where-Object { $_.fileName -eq $f.name -or $_.file -eq $f.name }

        if (-not $logEntry) {
            Write-Host "    + Adding new entry to registry..."
            $logEntry = [PSCustomObject]@{ 
                title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                fileName = [string]$f.name
                channelID = if($primaryID){$primaryID}else{""}
                isActive = $true
                threads = @()
                messageCount = 0
            }
            if ($null -eq $camp.logs) { $camp.logs = @() }
            $camp.logs += $logEntry
        }

        # --- PROPERTY SYNCHRONIZATION ---
        # This ensures we don't have 'file' in some and 'fileName' in others
        if ($logEntry.PSObject.Properties['file']) { $logEntry.PSObject.Properties.Remove('file') }
        $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
        $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
        
        # Only update channelID if we successfully found one in the file
        if ($primaryID) { $logEntry | Add-Member -NotePropertyName "channelID" -NotePropertyValue $primaryID -Force }
        
        # Stats
        $sorted = $messages | Sort-Object timestamp
        $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sorted[-1].timestamp) -Force
        $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count -Force
        $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue (if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }) -Force

        # --- THREADS (Filtered to avoid double-dipping) ---
        $threadMsgs = $messages | Where-Object { 
            $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $logEntry.channelID 
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
        # Mark missing threads inactive
        foreach ($t in $logEntry.threads) { if ($foundThreadIDs -notcontains [string]$t.threadID) { $t.isActive = $false } }
    }

    # --- ORPHAN CLEANUP ---
    foreach ($log in $camp.logs) {
        if ($processedFileNames -notcontains $log.fileName) { $log.isActive = $false }
    }
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"