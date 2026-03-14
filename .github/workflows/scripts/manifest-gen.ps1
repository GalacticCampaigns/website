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

# --- 1. Environment & Remote API Resolution ---
$manifestPath = "assets/campaign-registry.json"
$registry = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetKey = if ([string]::IsNullOrWhiteSpace($CampaignId)) { $registry.activeCampaign } else { $CampaignId }
$campaign = $registry.campaigns.$targetKey

# Construct the API URL for the REMOTE repository
# Example: https://api.github.com/repos/alicia86/SW_ForgottenOnes/contents/Chapter_Logs/JSON/
$apiBase = "https://api.github.com/repos/$($campaign.repository)/contents/$($campaign.paths.json)?ref=$($campaign.branch)"

if ($DebugLog) { Write-Host "[DEBUG] Target Repo: $($campaign.repository) | API: $apiBase" -ForegroundColor Cyan }

try {
    # Fetch the list of files from the remote GitHub Repo
        $remoteFiles = Invoke-RestMethod -Uri $apiBase -Method Get -Headers @{
                "Accept" = "application/vnd.github.v3+json"
                        # If you hit rate limits, you'll need to pass the GITHUB_TOKEN here
                            }
                            } catch {
                                Write-Error "CRITICAL: Could not access remote files at $apiBase. Check repository permissions."
                                    exit 1
                                    }

                                    $processedIds = New-Object 'System.Collections.Generic.HashSet[string]'
                                    $logFiles = $remoteFiles | Where-Object { $_.name -like "*.json" }
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

# --- 3. Core Hydration Loop (Updated for Remote) ---
foreach ($file in $logFiles) {
    try {
        # Use the 'download_url' provided by the API to get the actual JSON content
        $fileRaw = Invoke-RestMethod -Uri $file.download_url
        
        # Determine if it's nested or flat (Format A vs B)
        $messages = if ($fileRaw.PSObject.Properties.Name -contains "messages") { $fileRaw.messages } else { $fileRaw }
        if ($messages -isnot [array]) { $messages = @($messages) }

        $resolvedId = Get-TargetChannelId $messages
        
        # Dual-Key Matching (ID first, then Filename)
        # Use $file.name instead of $file.Name (API returns lowercase 'name')
        $logEntry = $campaign.logs | Where-Object { [string]$_.channelID -eq $resolvedId -and -not [string]::IsNullOrWhiteSpace($resolvedId) }
        if ($null -eq $logEntry) {
            $logEntry = $campaign.logs | Where-Object { $_.fileName -eq $file.name }
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
            $logEntry.fileName = $file.name
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
