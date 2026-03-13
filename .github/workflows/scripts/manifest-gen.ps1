# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$ForceUpdate = $false
)

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found."; exit 1 }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Identify which campaigns to process
$campaignKeys = $manifest.campaigns.PSObject.Properties.Name
if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
    $campaignKeys = $campaignKeys | Where-Object { $_ -eq $CampaignId }
}

foreach ($campaignKey in $campaignKeys) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Updating: $($camp.name) ---"
    
    $processedFileNames = @()

    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    try {
        $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"}
    } catch { continue }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        # 1. CLEAN START: Prevent data leaking from the previous file
        $primaryID = $null; $messages = $null; $rawJson = $null; $logEntry = $null; $foundThreadIDs = @()
        $processedFileNames += $f.name

        Write-Host "  > File: $($f.name)"
        $rawJson = Invoke-RestMethod -Uri $f.download_url

        # 2. NORMALIZE: Convert both JSON types to a flat array
        if ($rawJson.PSObject.Properties.Name -contains 'messages') { $messages = @($rawJson.messages) }
        else { $messages = @($rawJson) }
        if (-not $messages) { continue }

        # 3. SCAN FOR ID: Look through messages to find a real Snowflake ID
        foreach ($msg in $messages) {
            if ($msg.thread -and $msg.thread.parent_id -and ([string]$msg.thread.parent_id).Length -gt 10 -and [string]$msg.thread.parent_id -ne "1") {
                $primaryID = [string]$msg.thread.parent_id; break
            } elseif ($msg.channel_id -and ([string]$msg.channel_id).Length -gt 10) {
                $primaryID = [string]$msg.channel_id; break
            }
        }

        # 4. MATCH BY FILENAME: This is the most stable method
        # We check both 'fileName' and the old 'file' property
        $logEntry = $camp.logs | Where-Object { $_.fileName -eq $f.name -or $_.file -eq $f.name }

        if (-not $logEntry) {
            Write-Host "    + New Log Entry created for $($f.name)"
            $logEntry = [PSCustomObject]@{ 
                channelID = if($primaryID){$primaryID}else{""}
                title = ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper()
                fileName = [string]$f.name
                isActive = $true
                threads = @()
                preview = ""
                messageCount = 0
                order = 0
            }
            if ($null -eq $camp.logs) { $camp.logs = @() }
            $camp.logs += $logEntry
        }

        # 5. FORCE STANDARDIZATION: Cleanup old properties and sync data
        if ($logEntry.PSObject.Properties['file']) { $logEntry.PSObject.Properties.Remove('file') }
        $logEntry | Add-Member -NotePropertyName "fileName" -NotePropertyValue ([string]$f.name) -Force
        $logEntry | Add-Member -NotePropertyName "channelID" -NotePropertyValue ([string]$primaryID) -Force
        $logEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
        
        $sorted = $messages | Sort-Object timestamp
        $logEntry | Add-Member -NotePropertyName "lastMessageTimestamp" -NotePropertyValue ([string]$sorted[-1].timestamp) -Force
        $logEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($messages | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count -Force
        
        $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }
        $logEntry | Add-Member -NotePropertyName "order" -NotePropertyValue $orderVal -Force

        # 6. THREADS: Filter out the "Parent as Thread" bug
        $actualThreads = $messages | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $primaryID }
        if ($actualThreads) {
            $threadGroups = $actualThreads | Group-Object { [string]$_.thread.id }
            foreach ($group in $threadGroups) {
                $tID = [string]$group.Name
                $foundThreadIDs += $tID
                $tEntry = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tID }
                if (-not $tEntry) {
                    $tEntry = [PSCustomObject]@{ threadID = $tID; displayName = [string]$group.Group[0].thread.name; isActive = $true }
                    if ($null -eq $logEntry.threads) { $logEntry.threads = @() }
                    $logEntry.threads += $tEntry
                }
                $tEntry | Add-Member -NotePropertyName "isActive" -NotePropertyValue $true -Force
                $tEntry | Add-Member -NotePropertyName "messageCount" -NotePropertyValue ($group.Group | Where-Object { $_.content -ne "" }).Count -Force
            }
        }
        foreach ($t in $logEntry.threads) { if ($foundThreadIDs -notcontains [string]$t.threadID) { $t.isActive = $false } }
    }

    # 7. SILENT ORPHAN CLEANUP: Only mark inactive, no warnings.
    foreach ($log in $camp.logs) {
        if ($processedFileNames -notcontains $log.fileName) { $log.isActive = $false }
    }
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"