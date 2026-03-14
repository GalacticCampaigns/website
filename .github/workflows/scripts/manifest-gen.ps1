# .github/workflows/scripts/manifest-gen.ps1
param (
    [string]$CampaignId = "",
    [switch]$DebugLog = $false,
    [switch]$ForceUpdate = $false
)

function Write-DebugHost { param($msg); if ($DebugLog) { Write-Host "DEBUG: $msg" -ForegroundColor Cyan } }

$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) { Write-Error "Registry not found."; exit 1 }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$campaignKeys = $manifest.campaigns.PSObject.Properties.Name
if ($CampaignId) { $campaignKeys = $campaignKeys | Where-Object { $_ -eq $CampaignId } }

foreach ($campaignKey in $campaignKeys) {
    $camp = $manifest.campaigns.$campaignKey
    Write-Host "--- Hydrating: $($camp.name) ($campaignKey) ---"
    
    $processedFiles = @()
    $newLogList = @() # We will rebuild this list
    
    # Map existing logs by filename for persistence lookup
    $persistMap = @{}
    foreach($l in $camp.logs) { $persistMap[$l.fileName] = $l }

    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    try { $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"} } catch { continue }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        Write-Host "  > Processing File: $($f.name)"
        $processedFiles += $f.name
        
        # Local state for this file
        $msgList = @(); $foundChapterID = $null; $foundThreads = @(); $rawJson = $null;

        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            $msgList = if ($rawJson.PSObject.Properties.Name -contains 'messages') { $rawJson.messages } else { $rawJson }
        } catch { Write-Warning "    ! Download failed."; continue }

        if ($null -eq $msgList -or $msgList.Count -eq 0) { continue }

        # 1. RESOLVE CHAPTER ID
        foreach ($m in $msgList) {
            $cid = if ($m.channel_id) { [string]$m.channel_id } else { "" }
            $pid = if ($m.thread -and $m.thread.parent_id) { [string]$m.thread.parent_id } else { "" }
            if ($pid -and $pid -ne "1" -and $pid.Length -gt 10) { $foundChapterID = $pid; break }
            elseif ($cid -and $cid.Length -gt 10) { $foundChapterID = $cid; break }
        }

        # 2. RESOLVE THREADS
        $threadGroups = $msgList | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $foundChapterID } | Group-Object { [string]$_.thread.id }
        foreach ($g in $threadGroups) {
            $foundThreads += [PSCustomObject]@{
                threadID = [string]$g.Name
                displayName = [string]$g.Group[0].thread.name
                isActive = $true
                isNSFW = $false
                messageCount = $g.Count
            }
            if ($DebugLog) { Write-DebugHost "    [Thread Found] ID: $($g.Name) | Name: $($g.Group[0].thread.name) | Count: $($g.Count)" }
        }

        # 3. SMART REBUILD: Merge Persistent with New
        $oldRecord = $persistMap[$f.name]
        
        # Calculate changing fields
        $newCount = ($msgList | Where-Object { $_.content -ne "" -and ($_.type -eq "Default" -or $_.type -eq 0) }).Count
        $sorted = $msgList | Sort-Object timestamp
        $newTs = [string]$sorted[-1].timestamp
        $orderVal = if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 }

        if ($DebugLog) {
            Write-DebugHost "    [ID Update] '$($oldRecord.channelID)' -> '$foundChapterID'"
            Write-DebugHost "    [Count Update] $($oldRecord.messageCount) -> $newCount"
            Write-DebugHost "    [Order] $orderVal"
            Write-DebugHost "    [Threads] Found $($foundThreads.Count) active threads."
        }

        # Assemble the clean object
        $newLogList += [PSCustomObject]@{
            title = if ($oldRecord.title) { $oldRecord.title } else { ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper() }
            channelID = [string]$foundChapterID
            fileName = [string]$f.name
            isActive = $true
            isNSFW = if ($null -ne $oldRecord.isNSFW) { $oldRecord.isNSFW } else { $false }
            preview = if ($oldRecord.preview) { $oldRecord.preview } else { "" }
            order = $orderVal
            messageCount = [int]$newCount
            lastMessageTimestamp = $newTs
            threads = $foundThreads
        }
    }

    # 4. ORPHAN HANDLING: Keep old records that weren't in the folder but mark them inactive
    foreach ($oldKey in $persistMap.Keys) {
        if ($processedFiles -notcontains $oldKey) {
            $orphan = $persistMap[$oldKey]
            $orphan.isActive = $false
            $newLogList += $orphan
            Write-DebugHost "    [Orphan] $($oldKey) marked inactive."
        }
    }

    # Assign the rebuilt array back to the manifest
    $camp.logs = $newLogList
}

# 5. FINAL EXPORT: Depth 10 is mandatory for nested thread arrays
$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"
