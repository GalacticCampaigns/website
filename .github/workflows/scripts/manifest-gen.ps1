<#
.SYNOPSIS
    Campaign Registry Hydrator V2.0.0 - Final Remote Build
.DESCRIPTION
    Hydrates campaign-registry.json via GitHub API. 
    Strict Parent 1/Locked 8 logic. 0% reserved variable usage.
#>
param (
    [string]$RequestedCampaignSlug,
    [switch]$EnableDebugMode
)

$ErrorActionPreference = "Stop"

# --- 1. Setup & Auth ---
$ManifestFilePath = "assets/campaign-registry.json"
if (-not (Test-Path $ManifestFilePath)) { Write-Error "Manifest missing at $ManifestFilePath."; exit 1 }

$RegistryData = Get-Content $ManifestFilePath -Raw -Encoding UTF8 | ConvertFrom-Json

# FIX: Added .Trim() to prevent "Campaign Not Found" due to trailing spaces in Action inputs
$ActiveKey = if ([string]::IsNullOrWhiteSpace($RequestedCampaignSlug)) { 
    $RegistryData.activeCampaign 
} else { 
    $RequestedCampaignSlug.Trim() 
}

$TargetCampaign = $RegistryData.campaigns.$ActiveKey

if ($null -eq $TargetCampaign) { 
    Write-Error "CRITICAL: Campaign '${ActiveKey}' not found in registry. Check for typos or leading/trailing spaces."
    exit 1 
}

# Setup Authentication Headers
$RequestHeaders = @{ "Accept" = "application/vnd.github.v3+json" }
if ($env:GITHUB_TOKEN) { 
    $RequestHeaders.Add("Authorization", "Bearer $env:GITHUB_TOKEN") 
}

# SANITIZE PATH: Remove leading/trailing slashes to prevent 404 in API construction
$CleanJsonPath = $TargetCampaign.paths.json.Trim('/')
$RemoteApiUrl = "https://api.github.com/repos/$($TargetCampaign.repository)/contents/${CleanJsonPath}?ref=$($TargetCampaign.branch)"

Write-Host "`n>>> Initializing Hydration: $($TargetCampaign.name)" -ForegroundColor Cyan
if ($EnableDebugMode) { Write-Host "[DEBUG] API Endpoint: $RemoteApiUrl" -ForegroundColor Gray }

try {
    # Fetch file list
    $RemoteFiles = Invoke-RestMethod -Uri $RemoteApiUrl -Method Get -Headers $RequestHeaders
    $ValidFiles = $RemoteFiles | Where-Object { $_.name -like "*.json" }
    Write-Host ">>> Found $($ValidFiles.Count) files to process." -ForegroundColor Green
} catch {
    Write-Error "API Access Failed: $($_.Exception.Message). Ensure path '${CleanJsonPath}' exists in branch '$($TargetCampaign.branch)'."
    exit 1
}

$ProcessedIdentifiers = New-Object 'System.Collections.Generic.HashSet[string]'

# --- 2. Helper: Hardened Property Lookup ---
# Ensures we find 'channel_id' regardless of casing or format (e.g., channelID)
function Get-PropertySafe($Object, $PropName) {
    if ($null -eq $Object) { return $null }
    $Found = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $PropName -or $_.Name -ieq $PropName.Replace('_','') }
    if ($Found) { return [string]$Found[0].Value }
    return $null
}

# --- 3. Robust ID Resolver ---
function Resolve-TargetChannelID($MessageList) {
    if ($null -eq $MessageList -or $MessageList.Count -eq 0) { return $null }

    # Priority 1: Parent 1 Rule
    foreach ($m in $MessageList) {
        $ThreadParent = Get-PropertySafe $m.thread "parent_id"
        if ($null -ne $ThreadParent -and $ThreadParent -eq "1") {
            $ResID = Get-PropertySafe $m "channel_id"
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 1 (Parent 1) matched: $ResID" -ForegroundColor Gray }
            return $ResID
        }
    }

    # Priority 2: Thread Export Logic (Valid Snowflake Parent)
    foreach ($m in $MessageList) {
        $ThreadParent = Get-PropertySafe $m.thread "parent_id"
        if ($null -ne $ThreadParent -and $ThreadParent.Length -gt 10 -and $ThreadParent -ne "1") {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 2 (Snowflake Parent) matched: $ThreadParent" -ForegroundColor Gray }
            return $ThreadParent
        }
    }

    # Priority 3: Standard Export (Majority Rule)
    $IdTally = $MessageList | ForEach-Object { Get-PropertySafe $_ "channel_id" } | Where-Object { $_ -ne "1" -and $_ -ne "0" -and -not [string]::IsNullOrWhiteSpace($_) }
    if ($null -ne $IdTally) {
        $Winner = ($IdTally | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($EnableDebugMode) { Write-Host "[DEBUG] ID RESOLUTION: Priority 3 (Majority Rule) matched: $Winner" -ForegroundColor Gray }
        return $Winner
    }

    return $null
}

# --- 4. Main Loop ---
foreach ($RemoteFile in $ValidFiles) {
    $FileName = $RemoteFile.name
    try {
        if ($EnableDebugMode) { Write-Host "`n[DEBUG] --- Processing: ${FileName} ---" -ForegroundColor Cyan }
        
        $MessagesRaw = Invoke-RestMethod -Uri $RemoteFile.download_url -Headers $RequestHeaders
        $Messages = if ($MessagesRaw.PSObject.Properties.Name -contains "messages") { $MessagesRaw.messages } else { $MessagesRaw }
        if ($Messages -isnot [array]) { $Messages = @($Messages) }

        $ResolvedID = Resolve-TargetChannelID $Messages
        
        # Dual-Key Match
        $Record = $TargetCampaign.logs | Where-Object { [string]$_.channelID -eq $ResolvedID -and -not [string]::IsNullOrWhiteSpace($ResolvedID) }
        $MatchStyle = "ID Match"
        if ($null -eq $Record) {
            $Record = $TargetCampaign.logs | Where-Object { $_.fileName -ieq $FileName }
            $MatchStyle = "Filename Match"
        }

        # Narrative Filter
        $Filter = "^(0|19|Default|Reply)$"
        $MainChapterMessages = $Messages | Where-Object { 
            $MsgType = [string]$_.type
            $IsNarrative = -not [string]::IsNullOrWhiteSpace($MsgType) -and $MsgType -match $Filter
            $MsgChan = Get-PropertySafe $_ "channel_id"
            # Logic: Only count toward main chapter if it matches resolved ID OR has no thread metadata
            return ($IsNarrative -and ($MsgChan -eq $ResolvedID -or $null -eq $_.thread))
        }
        
        $PostCount = $MainChapterMessages.Count
        $LastTimestamp = ($Messages | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

        # Thread Grouping (Excluding self-parenting loops and the main resolved ID)
        $ThreadGroups = $Messages | Where-Object { 
            $Tid = Get-PropertySafe $_.thread "id"
            $Tpid = Get-PropertySafe $_.thread "parent_id"
            -not [string]::IsNullOrWhiteSpace($Tid) -and $Tid -ne $ResolvedID -and $Tid -ne $Tpid
        } | Group-Object { [string]$_.thread.id }

        # LOG SUMMARY
        $DispName = if ($FileName.Length -gt 25) { $FileName.Substring(0, 22) + "..." } else { $FileName.PadRight(25) }
        Write-Host "File: ${DispName} | ID: $($ResolvedID.PadRight(20)) | Posts: $($PostCount.ToString().PadLeft(4)) | Threads: $($ThreadGroups.Count)" -ForegroundColor Gray

        if ($null -eq $Record) {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Initializing New Record." -ForegroundColor Yellow }
            $MaxOrderVal = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
            $Record = [PSCustomObject]@{
                title = $FileName.Split('.')[0].Replace("_", " "); channelID = [string]$ResolvedID; fileName = $FileName;
                isActive = $true; isNSFW = $false; preview = ""; order = $MaxOrderVal + 1;
                messageCount = $PostCount; lastMessageTimestamp = $LastTimestamp; threads = @()
            }
            $TargetCampaign.logs += $Record
        } else {
            if ($EnableDebugMode) { Write-Host "[DEBUG] ACTION: Merging via ${MatchStyle}: '$($Record.title)'" -ForegroundColor Yellow }
            if ([string]::IsNullOrWhiteSpace($Record.channelID)) { $Record.channelID = [string]$ResolvedID }
            if ([string]::IsNullOrWhiteSpace($Record.title)) { $Record.title = $FileName.Split('.')[0].Replace("_", " ") }
            if ($null -eq $Record.order) { 
                $InternalMax = if ($TargetCampaign.logs.Count -gt 0) { ($TargetCampaign.logs | Measure-Object -Property order -Maximum).Maximum } else { -1 }
                $Record.order = $InternalMax + 1 
            }
            if ($Record.isActive -ne $false) { $Record.isActive = $true }
            $Record.fileName = $FileName
            $Record.messageCount = $PostCount
            $Record.lastMessageTimestamp = $LastTimestamp
        }

        # Threads Management (Preserving manual display names)
        $FinalThreadList = New-Object System.Collections.Generic.List[PSObject]
        foreach ($G in $ThreadGroups) {
            $LookupTid = [string]$G.Name
            $StoredT = $Record.threads | Where-Object { [string]$_.threadID -eq $LookupTid }
            $TCount = ($G.Group | Where-Object { [string]$_.type -match $Filter }).Count
            if ($null -ne $StoredT) {
                $StoredT.messageCount = $TCount
                if ([string]::IsNullOrWhiteSpace($StoredT.displayName)) { $StoredT.displayName = $G.Group[0].thread.name }
                $FinalThreadList.Add($StoredT)
            } else {
                $FinalThreadList.Add([PSCustomObject]@{ threadID = $LookupTid; displayName = $G.Group[0].thread.name; isActive = $true; isNSFW = $false; messageCount = $TCount })
            }
        }
        $Record.threads = $FinalThreadList.ToArray()
        if (-not [string]::IsNullOrWhiteSpace($Record.channelID)) { [void]$ProcessedIdentifiers.Add($Record.channelID) }

    } catch { 
        Write-Warning "!! Error in ${FileName}: $($_.Exception.Message)" 
    }
}

# --- 5. Orphan Deactivation ---
foreach ($Entry in $TargetCampaign.logs) {
    if (-not $ProcessedIdentifiers.Contains($Entry.channelID) -and -not [string]::IsNullOrWhiteSpace($Entry.channelID)) {
        if ($EnableDebugMode) { Write-Host "[DEBUG] ORPHAN: '$($Entry.title)' deactivated." -ForegroundColor Red }
        $Entry.isActive = $false
    }
}

# --- 6. Export ---
$RegistryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ManifestFilePath -Encoding UTF8 -Force
Write-Host "`n>>> Success: Registry updated and manual locks preserved." -ForegroundColor Green
