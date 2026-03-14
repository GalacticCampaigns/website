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
    $newLogList = @() 
    
    $persistMap = @{}
    if ($camp.logs) { foreach($l in $camp.logs) { $persistMap[$l.fileName] = $l } }

    $apiUrl = "https://api.github.com/repos/$($camp.repository)/contents/$($camp.dataPath)$($camp.paths.json)?ref=$($camp.branch)"
    try { $files = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers @{"Accept"="application/vnd.github.v3+json"} } catch { continue }

    foreach ($f in $files | Where-Object { $_.name -like "*.json" }) {
        Write-Host "  > Processing File: $($f.name)"
        $processedFiles += $f.name
        
        $msgList = @(); $foundThreads = @();
        $oldRecord = $persistMap[$f.name]

        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            $msgList = if ($rawJson.messages) { $rawJson.messages } else { $rawJson }
        } catch { Write-Warning "    ! Download/Parse failed."; continue }

        $msgList = @($msgList)
        if ($msgList.Count -eq 0) { continue }

        # --- 1. PERSISTENT FIELD RESOLUTION (Chapter Level) ---
        # Prioritize registry values for channelID, title, isNSFW, isActive, preview, order
        
        $finalChannelID = if ($oldRecord.channelID -and $oldRecord.channelID.Length -gt 10) { $oldRecord.channelID } else { "" }
        $finalTitle = if ($oldRecord.title) { $oldRecord.title } else { ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper() }
        $finalNSFW = if ($null -ne $oldRecord.isNSFW) { $oldRecord.isNSFW } else { $false }
        $finalActive = if ($null -ne $oldRecord.isActive) { $oldRecord.isActive } else { $true }
        $finalPreview = if ($oldRecord.preview) { $oldRecord.preview } else { "" }
        $finalOrder = if ($null -ne $oldRecord.order) { $oldRecord.order } else { if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 } }

        # Auto-detect channelID ONLY if registry is blank
        if (-not $finalChannelID) {
            $parentCounts = @{}
            foreach ($m in $msgList) {
                $curP = if ($m.thread -and $m.thread.parent_id) { [string]$m.thread.parent_id } else { "" }
                $curC = if ($m.channel_id) { [string]$m.channel_id } else { "" }
                $idToCount = if ($curP) { $curP } else { $curC }
                if ($idToCount -and $idToCount.Length -gt 10) {
                    if (-not $parentCounts.ContainsKey($idToCount)) { $parentCounts[$idToCount] = 0 }
                    $parentCounts[$idToCount]++
                }
            }
            if ($parentCounts.Count -gt 0) {
                $finalChannelID = ($parentCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
            }
        }

        # --- 2. PERSISTENT FIELD RESOLUTION (Thread Level) ---
        $storyTypes = @(0, 19, "Default", "Reply")
        $threadGroups = $msgList | Where-Object { $_.thread -and $_.thread.id -and [string]$_.thread.id -ne $finalChannelID } | Group-Object { [string]$_.thread.id }
        
        foreach ($g in $threadGroups) {
            $tID = [string]$g.Name
            # Look for existing thread data in the old record to persist manually updated displayName
            $oldThread = if ($oldRecord.threads) { $oldRecord.threads | Where-Object { $_.threadID -eq $tID } } else { $null }
            
            $finalThreadID = if ($oldThread.threadID) { $oldThread.threadID } else { $tID }
            $finalDisplayName = if ($oldThread.displayName) { $oldThread.displayName } else { [string]$g.Group[0].thread.name }
            
            $threadMsgCount = ($g.Group | Where-Object { $storyTypes -contains $_.type }).Count
            
            $foundThreads += [PSCustomObject]@{
                threadID = $finalThreadID
                displayName = $finalDisplayName
                isActive = if ($null -ne $oldThread.isActive) { $oldThread.isActive } else { $true }
                isNSFW = if ($null -ne $oldThread.isNSFW) { $oldThread.isNSFW } else { $false }
                messageCount = [int]$threadMsgCount
            }
        }

        # --- 3. DYNAMIC DATA UPDATES ---
        $newCount = ($msgList | Where-Object { $storyTypes -contains $_.type }).Count
        $sorted = $msgList | Sort-Object timestamp
        $newTs = if ($sorted) { [string]$sorted[-1].timestamp } else { "" }

        $newLogList += [PSCustomObject]@{
            title = $finalTitle
            channelID = [string]$finalChannelID
            fileName = [string]$f.name
            isActive = $finalActive
            isNSFW = $finalNSFW
            preview = $finalPreview
            order = $finalOrder
            messageCount = [int]$newCount
            lastMessageTimestamp = $newTs
            threads = $foundThreads
        }
    }

    # Handle Orphans
    foreach ($oldKey in $persistMap.Keys) {
        if ($processedFiles -notcontains $oldKey) {
            $orphan = $persistMap[$oldKey]
            $orphan.isActive = $false
            $newLogList += $orphan
        }
    }
    $camp.logs = $newLogList
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"