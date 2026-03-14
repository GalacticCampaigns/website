<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Final Production Build
.DESCRIPTION
    Hydrates the campaign-registry.json manifest with data from Discord JSON exports.
    Adheres to "Parent 1" resolution and the "Locked 8" persistence rules.
#>
param (
    [string]$CampaignId,
    [switch]$DebugLog
)

$ErrorActionPreference = "Stop"

# --- 1. Environment & Path Resolution ---
$manifestPath = "assets/campaign-registry.json"
if (-not (Test-Path $manifestPath)) {
    Write-Error "CRITICAL: Manifest not found at $manifestPath."
    exit 1
}

# Strict UTF8 Reading to prevent Snowflake corruption
$registry = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetKey = if ([string]::IsNullOrWhiteSpace($CampaignId)) { $registry.activeCampaign } else { $CampaignId }
$campaign = $registry.campaigns.$targetKey

if ($null -eq $campaign) {
    Write-Error "CRITICAL: Campaign '$targetKey' not found in registry."
    exit 1
}

$jsonSourcePath = Join-Path $campaign.dataPath $campaign.paths.json
if (-not (Test-Path $jsonSourcePath)) {
    Write-Warning "Source path $jsonSourcePath missing. Skipping processing."
    exit 0
}

$logFiles = Get-ChildItem -Path $jsonSourcePath -Filter "*.json"
$processedIds = New-Object 'System.Collections.Generic.HashSet[string]'

if ($DebugLog) { Write-Host "[DEBUG] Processing '$targetKey' | Target: $jsonSourcePath" -ForegroundColor Cyan }

# --- 2. Advanced ID Resolution (Parent 1 Logic) ---
function Get-TargetChannelId($messages) {
    if ($null -eq $messages -or $messages.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule (The definitive anchor)
    foreach ($msg in $messages) {
        if ($null -ne $msg.thread -and [string]$msg.thread.parent_id -eq "1") {
            return [string]$msg.channel_id
        }
    }

    # Priority 2: Valid Snowflake Parent
    foreach ($msg in $messages) {
        $pid = [string]$msg.thread.parent_id
        if ($null -ne $pid -and $pid.Length -gt 10 -and $pid -ne "1") {
            return $pid
        }
    }

    # Priority 3: Standard Export ID (First valid snowflake)
    foreach ($msg in $messages) {
        $cid = [string]$msg.channel_id
        if ($null -ne $cid -and $cid.Length -gt 10) { return $cid }
    }

    # Priority 4: Majority Rule Fallback (With Strict Junk Filter)
    $validIds = $messages | ForEach-Object { [string]$_.channel_id } | Where-Object { 
        $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) 
    }
    if ($null -ne $validIds) {
        $groups = $validIds | Group-Object | Sort-Object Count -Descending
        return [string]$groups[0].Name
    }

    return $null
}

# --- 3. Core Hydration Loop ---
foreach ($file in $logFiles) {
    try {
        $fileRaw = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $messages = if ($fileRaw.PSObject.Properties.Name -contains "messages") { $fileRaw.messages } else { $fileRaw }
        if ($messages -isnot [array]) { $messages = @($messages) }

        $resolvedId = Get-TargetChannelId $messages
        
        # Identity Matching (Dual-Key Strategy)
        $logEntry = $campaign.logs | Where-Object { [string]$_.channelID -eq $resolvedId -and -not [string]::IsNullOrWhiteSpace($resolvedId) }
        if ($null -eq $logEntry) {
            $logEntry = $campaign.logs | Where-Object { $_.fileName -eq $file.Name }
        }

        # Narrative Stats: String-forced comparison with null-coalescing safety
        $narrativeMsgs = $messages | Where-Object { 
            $t = [string]$_.type
            -not [string]::IsNullOrWhiteSpace($t) -and $t -match "^(0|19|Default|Reply)$" 
        }
        $msgCount = $narrativeMsgs.Count
        $lastTimestamp = ($messages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        if ($null -eq $logEntry) {
            # INITIALIZATION: For brand-new records
            $maxOrder = if ($campaign.logs.Count -gt 0) { ($campaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            
            $logEntry = [PSCustomObject]@{
                title                = $file.BaseName.Replace("_", " ")
                channelID            = [string]$resolvedId
                fileName             = $file.Name
                isActive             = $true
                isNSFW               = $false
                preview              = ""
                order                = $maxOrder + 1
                messageCount         = $msgCount
                lastMessageTimestamp = $lastTimestamp
                threads              = @()
            }
            $campaign.logs += $logEntry
        } else {
            # THE "LOCKED 8" MERGE: Protect persistent manual edits
            if ([string]::IsNullOrWhiteSpace($logEntry.channelID)) { $logEntry.channelID = [string]$resolvedId }
            
            # 1. title: Update only if blank
            if ([string]::IsNullOrWhiteSpace($logEntry.title)) { $logEntry.title = $file.BaseName.Replace("_", " ") }
            
            # 2. order: Update only if null (allowing 0 as valid manual entry)
            if ($null -eq $logEntry.order) { 
                $currMax = if ($campaign.logs.Count -gt 0) { ($campaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $logEntry.order = $currMax + 1 
            }
            
            # 3. isActive: Preserve manual deactivation (False -> False)
            if ($logEntry.isActive -ne $false) { $logEntry.isActive = $true }

            # Volatile updates
            $logEntry.fileName = $file.Name
            $logEntry.messageCount = $msgCount
            $logEntry.lastMessageTimestamp = $lastTimestamp
        }

        # --- Thread Management (Preserve manual displayName) ---
        $threadGroups = $messages | Where-Object { 
            $tid = [string]$_.thread.id
            $tid -ne $resolvedId -and -not [string]::IsNullOrWhiteSpace($tid) 
        } | Group-Object { [string]$_.thread.id }

        $newThreads = New-Object System.Collections.Generic.List[PSObject]
        foreach ($group in $threadGroups) {
            $tid = [string]$group.Name
            $existingThread = $logEntry.threads | Where-Object { [string]$_.threadID -eq $tid }
            
            # Thread message count (using same narrative filter)
            $tCount = ($group.Group | Where-Object { 
                $t = [string]$_.type
                -not [string]::IsNullOrWhiteSpace($t) -and $t -match "^(0|19|Default|Reply)$" 
            }).Count

            if ($null -ne $existingThread) {
                # Update volatile count
                $existingThread.messageCount = $tCount
                # Lock displayName: Only update if it is currently blank
                if ([string]::IsNullOrWhiteSpace($existingThread.displayName)) {
                    $existingThread.displayName = $group.Group[0].thread.name
                }
                $newThreads.Add($existingThread)
            } else {
                $newThreads.Add([PSCustomObject]@{
                    threadID     = $tid
                    displayName  = $group.Group[0].thread.name
                    isActive     = $true
                    isNSFW       = $false
                    messageCount = $tCount
                })
            }
        }
        $logEntry.threads = $newThreads.ToArray()
        
        if (-not [string]::IsNullOrWhiteSpace($logEntry.channelID)) {
            [void]$processedIds.Add($logEntry.channelID)
        }

    } catch {
        Write-Warning "Failed to hydrate file '$($file.Name)': $($_.Exception.Message)"
    }
}

# --- 4. Orphan & Deactivation Logic ---
foreach ($log in $campaign.logs) {
    if (-not $processedIds.Contains($log.channelID) -and -not [string]::IsNullOrWhiteSpace($log.channelID)) {
        Write-Warning "WARNING: Record '$($log.title)' ($($log.fileName)) not found in repository. Set to Inactive."
        $log.isActive = $false
    }
}

# --- 5. Export Strategy ---
# Depth 10: Ensures nested threads aren't truncated.
# Out-File UTF8: Ensures Snowflakes remain safe strings across environments.
$registry | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

Write-Host "Hydration Complete: All Locked fields preserved." -ForegroundColor Green
