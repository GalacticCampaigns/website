<#
.SYNOPSIS
    Campaign Registry Hydrator V2.4.2
.DESCRIPTION
    - Full Restoration: NSFW Reaction Scanning and Media Registry logic.
    - Python Parity: Implements .get() via Get-NormalizedProperty with $DefaultValue.
    - Deep Telemetry: Logs ID resolution methods and per-thread timestamps.
    - Dry Run: Simulation mode for safe testing.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($DryRun) {
    Write-Host "!!! DRY RUN MODE ACTIVE: Simulation only, no changes will be saved !!!`n" -ForegroundColor Red
}

# --- 1. Setup & Auth ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) { Write-Error "Manifest missing at $ManifestFilePath."; exit 1 }

$RegistryRaw = Get-Content $ManifestFilePath -Raw -Encoding UTF8
$RegistryData = $RegistryRaw | ConvertFrom-Json
$ActiveCampaignKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { $RegistryData.activeCampaign } else { $RequestedCampaignSlug.Trim() }
$TargetCampaignObj = $RegistryData.campaigns.$ActiveCampaignKey

if ($null -eq $TargetCampaignObj) { Write-Error "Campaign '${ActiveCampaignKey}' not found."; exit 1 }

$Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($Token) { $RequestHeaders.Add("Authorization", "Bearer $Token") }

# --- 2. Helper: Enhanced Property Lookup (.get Parity) ---
function Get-NormalizedProperty($InputObject, $DesiredPropertyName, $DefaultValue = $null) {
    if ($null -eq $InputObject) { return $DefaultValue } 
    try {
        $CurrentProperties = $InputObject.PSObject.Properties
        $FoundMatch = $CurrentProperties | Where-Object { 
            $_.Name -ieq $DesiredPropertyName -or 
            $_.Name -ieq $DesiredPropertyName.Replace('_','') 
        }
        if ($FoundMatch) { return [string]$FoundMatch[0].Value }
    } catch { return $DefaultValue }
    return $DefaultValue
}

# --- 3. Enhanced ID Resolver with Trace ---
function Resolve-ChannelIDWithTrace($MessageCollection) {
    if ($null -eq $MessageCollection -or $MessageCollection.Count -eq 0) { return @{ ID = $null; Method = "None" } }
    
    # Priority 1: Parent 1
    foreach ($msg in $MessageCollection) {
        $parent = Get-NormalizedProperty $msg.thread "parent_id"
        if ($parent -eq "1") {
            return @{ ID = [string](Get-NormalizedProperty $msg "channel_id"); Method = "Parent-1-Check" }
        }
    }

    # Priority 2: Majority Rule
    $ValidIDs = $MessageCollection | ForEach-Object { Get-NormalizedProperty $_ "channel_id" } | Where-Object { $_ -match '^\d{17,20}$' }
    if ($ValidIDs) {
        $Winner = ($ValidIDs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        return @{ ID = [string]$Winner; Method = "Majority-Rule" }
    }

    return @{ ID = $null; Method = "Failed" }
}

# --- 4. Paths & Media Registry Logic ---
$BaseFolder = $TargetCampaignObj.dataPath.Trim('./').Trim('/')
$SubFolder = $TargetCampaignObj.paths.json.Trim('/')
$FullRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $SubFolder } else { "$BaseFolder/$SubFolder" }

# Robust Property Injection for Media Registry
if ($null -eq $TargetCampaignObj.paths.PSObject.Properties['mediaRegistry']) {
    $TargetCampaignObj.paths | Add-Member -MemberType NoteProperty -Name "mediaRegistry" -Value $null -Force
}

$MediaRegistryFileName = "media-registry.json"
$MediaRegistryRemotePath = if ([string]::IsNullOrWhiteSpace($BaseFolder)) { $MediaRegistryFileName } else { "$BaseFolder/$MediaRegistryFileName" }
$MediaApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${MediaRegistryRemotePath}?ref=$($TargetCampaignObj.branch)"

try {
    $MediaCheck = Invoke-RestMethod -Uri $MediaApiUrl -Method Get -Headers $RequestHeaders
    $TargetCampaignObj.paths.mediaRegistry = $MediaRegistryFileName
    if ($EnableDebugMode) { Write-Host "[DEBUG] Media Registry active: $MediaRegistryFileName" -ForegroundColor Green }
} catch {
    $TargetCampaignObj.paths.mediaRegistry = $null
    if ($EnableDebugMode) { Write-Host "[DEBUG] No Media Registry found for this frequency." -ForegroundColor Gray }
}

$GitHubApiUrl = "https://api.github.com/repos/$($TargetCampaignObj.repository)/contents/${FullRemotePath}?ref=$($TargetCampaignObj.branch)"
Write-Host "`n>>> Initializing Hydration: $($TargetCampaignObj.name)" -ForegroundColor Cyan

try {
    $RemoteListing = Invoke-RestMethod -Uri $GitHubApiUrl -Method Get -Headers $RequestHeaders
    $ValidJsonFiles = $RemoteListing | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidJsonFiles.Count) files in remote repository." -ForegroundColor Green
} catch {
    Write-Error "GitHub API Access Failed: $($_.Exception.Message)"; exit 1
}

$GlobalProcessedIDs = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 5. Main Processing Loop ---
foreach ($RemoteFileRef in $ValidJsonFiles) {
    $CurrentFileName = $RemoteFileRef.name
    try {
        # Raw Download to bypass API encoding issues
        $FileWebResponse = Invoke-WebRequest -Uri $RemoteFileRef.download_url -Headers $RequestHeaders -UseBasicParsing
        $FileStringContent = $FileWebResponse.Content
        if ($FileStringContent.StartsWith([char]0xfeff)) { $FileStringContent = $FileStringContent.Substring(1) }

        $ParsedJson = $FileStringContent | ConvertFrom-Json
        $MessageList = if ($ParsedJson.PSObject.Properties.Name -contains "messages") { $ParsedJson.messages } else { $ParsedJson }
        if ($MessageList -isnot [array]) { $MessageList = @($MessageList) }

        # --- NSFW SCANNER ---
        $GlobalNsfwCounter = 0
        $NsfwEmojiMatch = [char]::ConvertFromUtf32(0x1F51E) # Literal 🔞
        foreach ($msg in $MessageList) {
            $isPostNsfw = $false
            if ($msg.reactions) {
                foreach ($reaction in $msg.reactions) {
                    if ($reaction.emoji.name -eq ${NsfwEmojiMatch} -or $reaction.emoji.name -eq "underage") {
                        $isPostNsfw = $true; break
                    }
                }
            }
            if ($isPostNsfw) {
                if (-not ($msg.PSObject.Properties.Name -contains "isNSFW")) {
                    $msg | Add-Member -MemberType NoteProperty -Name "isNSFW" -Value $true -Force
                }
                $GlobalNsfwCounter++
            }
        }
        $NsfwRatio = if ($MessageList.Count -gt 0) { $GlobalNsfwCounter / $MessageList.Count } else { 0 }
        $AutoFlagLog = $NsfwRatio -ge 0.9

        # --- ID RESOLUTION TRACE ---
        $Res = Resolve-ChannelIDWithTrace $MessageList
        $ResolvedID = $Res.ID
        
        if ($EnableDebugMode) {
            $color = if ($CurrentFileName -match "Ch2") { "Magenta" } else { "Cyan" }
            Write-Host "[TRACE] ${CurrentFileName} resolved via $($Res.Method) -> ${ResolvedID}" -ForegroundColor $color
        }

        if ($null -eq $ResolvedID) { 
            Write-Warning "!! Skipping ${CurrentFileName}: No Snowflake ID found."
            continue 
        }
        [void]$GlobalProcessedIDs.Add($ResolvedID)

        # --- NARRATIVE TALLYING ---
        $NarrativeTypeRegex = "^(0|19|Default|Reply)$"
        $AllNarrative = $MessageList | Where-Object { [string]$_.type -match $NarrativeTypeRegex }
        
        # Breakdown: Treat matching threads as Main Channel content
        $MainChannelMsgs = $AllNarrative | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            ($_.channel_id -eq $ResolvedID -and $null -eq $_.thread) -or ($tId -eq $ResolvedID)
        }
        $SubThreadMsgs = $AllNarrative | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            $null -ne $_.thread -and $tId -ne $ResolvedID 
        }
        
        $NarrativeTally = if ($null -ne $AllNarrative) { $AllNarrative.Count } else { 0 }
        $NewestTimestamp = ($MessageList | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Match Manifest Record (Case-Insensitive fallback)
        $ExistingRecord = $TargetCampaignObj.logs | Where-Object { 
            ([string]$_.channelID -eq $ResolvedID) -or ($_.fileName -ieq $CurrentFileName)
        }

        if ($null -eq $ExistingRecord) {
            $MaxOrder = if ($TargetCampaignObj.logs.Count -gt 0) { ($TargetCampaignObj.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $ExistingRecord = [PSCustomObject]@{
                title = $CurrentFileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; 
                fileName = $CurrentFileName; isActive = $true; isNSFW = $AutoFlagLog; preview = ""; order = $MaxOrder + 1;
                messageCount = $NarrativeTally; lastMessageTimestamp = $NewestTimestamp; threads = @()
            }
            $TargetCampaignObj.logs += $ExistingRecord
            Write-Host "  [NEW] Registered: $($ExistingRecord.title)" -ForegroundColor Yellow
        } else {
            $ExistingRecord.channelID = [string]$ResolvedID
            $ExistingRecord.fileName = $CurrentFileName
            $ExistingRecord.messageCount = $NarrativeTally
            $ExistingRecord.lastMessageTimestamp = $NewestTimestamp
            $ExistingRecord.isActive = $true
            if ($ExistingRecord.isNSFW -eq $false) { $ExistingRecord.isNSFW = $AutoFlagLog }
        }

        # --- THREAD DISCOVERY & TELEMETRY ---
        $UpdatedThreads = New-Object System.Collections.Generic.List[PSObject]
        $Groups = $MessageList | Where-Object { 
            $tId = Get-NormalizedProperty $_.thread "id"
            return (-not [string]::IsNullOrWhiteSpace($tId) -and $tId -ne $ResolvedID)
        } | Group-Object { [string]$_.thread.id }

        foreach ($Group in $Groups) {
            $tID = [string]$Group.Name
            $tName = $Group.Group[0].thread.name
            
            $TNarrative = $Group.Group | Where-Object { [string]$_.type -match $NarrativeTypeRegex }
            $TCount = if ($null -ne $TNarrative) { $TNarrative.Count } else { 0 }
            $TNsfwCount = ($Group.Group | Where-Object { $_.isNSFW -eq $true }).Count
            $TIsNsfw = if ($TCount -gt 0) { ($TNsfwCount / $TCount) -ge 0.9 } else { $false }
            $TLastTime = ($Group.Group | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

            if ($EnableDebugMode) { 
                Write-Host "    > Thread: ${tName} | Posts: ${TCount} | Last: ${TLastTime}" -ForegroundColor DarkGray 
            }

            $StoredT = $ExistingRecord.threads | Where-Object { [string]$_.threadID -eq $tID }
            if ($null -ne $StoredT) {
                $StoredT.messageCount = $TCount
                $StoredT.isActive = $true
                if ($StoredT.isNSFW -eq $false) { $StoredT.isNSFW = $TIsNsfw }
                $UpdatedThreads.Add($StoredT)
            } else {
                $UpdatedThreads.Add([PSCustomObject]@{ 
                    threadID = $tID; displayName = $tName; isActive = $true; isNSFW = $TIsNsfw; messageCount = $TCount 
                })
            }
        }
        $ExistingRecord.threads = $UpdatedThreads.ToArray()

        $logStatus = "Main: $($MainChannelMsgs.Count) | Threads: $($SubThreadMsgs.Count)"
        Write-Host "  [OK] Processed ${CurrentFileName} ($logStatus) | NSFW: $([Math]::Round($NsfwRatio*100,1))%" -ForegroundColor Gray

    } catch { 
        Write-Warning "!! Error in ${CurrentFileName}: $($_.Exception.Message)" 
    }
}

# --- 6. Orphan Deactivation ---
$ActiveCount = 0
foreach ($Log in $TargetCampaignObj.logs) {
    if ($GlobalProcessedIDs.Contains([string]$Log.channelID)) {
        $ActiveCount++
        $Log.isActive = $true
    } else {
        if ($Log.isActive -ne $false) {
            Write-Warning "  [ORPHAN] $($Log.title) ($($Log.channelID)) deactivated."
            $Log.isActive = $false
        }
    }
}

# --- 7. Export ---
if (-not $DryRun) {
    $FinalJson = $RegistryData | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ManifestFilePath, $FinalJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "`n>>> Success: Hydration V2.4.2 Complete." -ForegroundColor Green
} else {
    Write-Host "`n>>> DRY RUN COMPLETE: No changes saved." -ForegroundColor Yellow
}

Write-Host ">>> Summary: $ActiveCount Active Logs | $($ValidJsonFiles.Count) Files Scanned." -ForegroundColor Cyan