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
        $oldRecord = $persistMap[$f.name]
        
        $msgList = @(); $foundThreads = @(); $resolvedID = ""

        try {
            $rawJson = Invoke-RestMethod -Uri $f.download_url
            if ($rawJson.messages) { $msgList = $rawJson.messages } else { $msgList = $rawJson }
        } catch { Write-Warning "    ! Download/Parse failed."; continue }

        $msgList = @($msgList)
        if ($msgList.Count -eq 0) { continue }

        # --- 1. CHANNEL ID RESOLUTION (Persistent) ---
        if ($oldRecord.channelID) {
            $resolvedID = [string]$oldRecord.channelID
        } else {
            $parentCounts = @{}
            foreach ($m in $msgList) {
                $curP = if ($m.thread -and $m.thread.parent_id) { [string]$m.thread.parent_id } else { "" }
                $curC = if ($m.channel_id) { [string]$m.channel_id } else { "" }
                $idToCount = if ($curP) { $curP } else { $curC }
                
                if ($idToCount) {
                    if (-not $parentCounts.ContainsKey($idToCount)) { $parentCounts[$idToCount] = 0 }
                    $parentCounts[$idToCount]++
                }
            }
            if ($parentCounts.Count -gt 0) {
                $resolvedID = [string]($parentCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
            }
        }

        # --- 2. THREAD RESOLUTION (Persistent & Type-Forced) ---
        # 0 = Default, 19 = Reply. Forced to strings for comparison.
        $storyTypes = @("0", "19", "Default", "Reply")
        
        $threadGroups = $msgList | Where-Object { $_.thread -and $_.thread.id } | Group-Object { [string]$_.thread.id }
        
        foreach ($g in $threadGroups) {
            $tID = [string]$g.Name
            if ($tID -eq $resolvedID) { continue }

            $oldThread = if ($oldRecord.threads) { $oldRecord.threads | Where-Object { [string]$_.threadID -eq $tID } } else { $null }
            
            # Type-forcing comparison to ensure counts work
            $threadMsgCount = ($g.Group | Where-Object { $storyTypes -contains [string]$_.type }).Count
            
            $foundThreads += [PSCustomObject]@{
                threadID = if ($oldThread.threadID) { [string]$oldThread.threadID } else { $tID }
                displayName = if ($oldThread.displayName) { [string]$oldThread.displayName } else { [string]$g.Group[0].thread.name }
                isActive = if ($null -ne $oldThread.isActive) { $oldThread.isActive } else { $true }
                isNSFW = if ($null -ne $oldThread.isNSFW) { $oldThread.isNSFW } else { $false }
                messageCount = [int]$threadMsgCount
            }
        }

        # --- 3. DYNAMIC DATA & PERSISTENT FIELD MERGE ---
        $newCount = ($msgList | Where-Object { $storyTypes -contains [string]$_.type }).Count
        $sorted = $msgList | Sort-Object timestamp
        $newTs = if ($sorted) { [string]$sorted[-1].timestamp } else { "" }
        
        # Persist manually updated fields
        $finalTitle = if ($oldRecord.title) { $oldRecord.title } else { ($f.name -replace '\.json$', '' -replace '_', ' ').ToUpper() }
        $finalActive = if ($null -ne $oldRecord.isActive) { $oldRecord.isActive } else { $true }
        $finalNSFW = if ($null -ne $oldRecord.isNSFW) { $oldRecord.isNSFW } else { $false }
        $finalPreview = if ($oldRecord.preview) { $oldRecord.preview } else { "" }
        $finalOrder = if ($null -ne $oldRecord.order) { $oldRecord.order } else { if ($f.name -match '(\d+)') { [int]$matches[1] } else { 0 } }

        if ($DebugLog) {
            Write-DebugHost "    [ID Update] '$([string]$oldRecord.channelID)' -> '$resolvedID'"
            Write-DebugHost "    [Count Update] $($oldRecord.messageCount) -> $newCount"
            Write-DebugHost "    [Threads] Found $($foundThreads.Count) active threads."
        }

        $newLogList += [PSCustomObject]@{
            title = [string]$finalTitle
            channelID = [string]$resolvedID
            fileName = [string]$f.name
            isActive = $finalActive
            isNSFW = $finalNSFW
            preview = [string]$finalPreview
            order = [int]$finalOrder
            messageCount = [int]$newCount
            lastMessageTimestamp = [string]$newTs
            threads = $foundThreads
        }
    }

    foreach ($oldKey in $persistMap.Keys) {
        if ($processedFiles -notcontains $oldKey) {
            $orphan = $persistMap[$oldKey]; $orphan.isActive = $false; $newLogList += $orphan
        }
    }
    $camp.logs = $newLogList
}

$manifest | ConvertTo-Json -Depth 10 | Out-File $manifestPath -Encoding UTF8
Write-Host "--- Hydration Complete ---"