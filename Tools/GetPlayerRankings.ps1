# ==========================================
# GetPlayerRankings.ps1
# Builds TeamBalanceRatings.ini for the MutTeamBalance mutator from the
# FlawsFightNight bot's UT2004 player profiles, checks it, and uploads it to
# the game server by FTP. Runs in a loop every $IntervalSeconds.
#
# Alt GUIDs: every GUID registered to one member profile gets the same
# numbers, taken from the profile's most-played GUID (lowest Sigma).
# ==========================================

# ==========================================
# CONFIGURATION
# ==========================================
# Paths and FTP login live in GetPlayerRankings.config.psd1 next to this
# script. That file is NOT in git; copy GetPlayerRankings.config.example.psd1
# to it and fill in the real values.
$ConfigFile = Join-Path $PSScriptRoot "GetPlayerRankings.config.psd1"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "Missing $ConfigFile - copy GetPlayerRankings.config.example.psd1 to it and fill it in." -ForegroundColor Red
    exit 1
}
$Config = Import-PowerShellDataFile -Path $ConfigFile

$StatsFolder  = $Config.StatsFolder
$ProfilesPath = $Config.ProfilesPath
$OutputFile   = $Config.OutputFile
$LogFile      = $Config.LogFile
$SectionName  = "TeamBalance.TeamBalanceRatings"
$PropertyName = "PlayerRatings"

# FTP Configuration
$FtpServer    = $Config.FtpServer
$FtpUsername  = $Config.FtpUsername
$FtpPassword  = $Config.FtpPassword
$FtpUseSsl    = [bool]$Config.FtpUseSsl   # explicit FTPS, if the host supports it

# Validation & Execution Settings
$IntervalSeconds = 120  # 2 Minutes
$MinEntries      = 50   # Minimum entries required to proceed
$FormatVersion   = 1    # Mutator format version

# Regex for strict 32-character hex GUID check
$GuidRegex = "^[0-9a-f]{32}$"

# The game only reads '.' as the decimal point, whatever the PC's region settings
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Remembers what was last uploaded, so an unchanged file is not sent again
$UploadedHashFile = "$OutputFile.uploaded"

# ==========================================
# LOGGING FUNCTION
# ==========================================
function Write-UploadLog {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"

    switch ($Level) {
        "INFO"    { Write-Host $LogEntry -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $LogEntry -ForegroundColor Green }
        "WARNING" { Write-Host $LogEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $LogEntry -ForegroundColor Red }
    }

    $LogDir = Split-Path $LogFile
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    # Pure ASCII append for log file
    [System.IO.File]::AppendAllText($LogFile, "$LogEntry`r`n", [System.Text.Encoding]::ASCII)
}

# Helper to format numbers cleanly (up to 3 decimals, always '.' as the decimal point)
function Format-RatingNum {
    param ([double]$Val)
    return $Val.ToString("0.###", $Invariant)
}

# Hash of the ratings lines only (not GeneratedAt), to spot an unchanged file
function Get-ContentHash {
    param ([string[]]$Lines)
    $Bytes = [System.Text.Encoding]::ASCII.GetBytes(($Lines -join "`n"))
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($Sha.ComputeHash($Bytes)) }
    finally { $Sha.Dispose() }
}

# ==========================================
# FTP HELPERS
# ==========================================
function New-FtpRequest {
    param ([string]$Uri, [string]$Method)
    $Request = [System.Net.FtpWebRequest]::Create($Uri)
    $Request.Method      = $Method
    $Request.Credentials = New-Object System.Net.NetworkCredential($FtpUsername, $FtpPassword)
    $Request.EnableSsl   = $FtpUseSsl
    $Request.UseBinary   = $true
    $Request.KeepAlive   = $false
    return $Request
}

function Invoke-FtpRequest {
    param ([System.Net.FtpWebRequest]$Request)
    $Response = $Request.GetResponse()
    $Response.Close()
}

# Upload under a temporary name, then rename over the live file, so the game
# server never reads a half-written file if it restarts during an upload.
function Send-RatingsFile {
    param ([string]$LocalFile)

    $TempUri  = "$FtpServer.tmp"
    $LiveName = [System.IO.Path]::GetFileName(([Uri]$FtpServer).AbsolutePath)

    # 1. Upload to <name>.tmp
    $Bytes = [System.IO.File]::ReadAllBytes($LocalFile)
    $Request = New-FtpRequest -Uri $TempUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
    $Request.ContentLength = $Bytes.Length
    $Stream = $Request.GetRequestStream()
    try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Close() }
    Invoke-FtpRequest $Request

    # 2. Rename over the live file. Some FTP servers refuse to rename onto an
    #    existing file; then delete the old one first (a moment without a file
    #    is still safer than a half-written one).
    try {
        $Request = New-FtpRequest -Uri $TempUri -Method ([System.Net.WebRequestMethods+Ftp]::Rename)
        $Request.RenameTo = $LiveName
        Invoke-FtpRequest $Request
    }
    catch {
        Write-UploadLog -Message "Rename over the live file refused ($($_.Exception.Message)); deleting it first and retrying" -Level "WARNING"
        try {
            Invoke-FtpRequest (New-FtpRequest -Uri $FtpServer -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile))
        }
        catch {
            # Nothing to delete is fine; the rename below reports any real problem
        }
        $Request = New-FtpRequest -Uri $TempUri -Method ([System.Net.WebRequestMethods+Ftp]::Rename)
        $Request.RenameTo = $LiveName
        Invoke-FtpRequest $Request
    }
}

# ==========================================
# CORE GENERATION, VALIDATION & UPLOAD
# ==========================================
function Update-RatingFiles {
    Write-UploadLog -Message "Processing player rating files..." -Level "INFO"

    # 1. Read Member Profiles to build the Alias Map (GUID -> all GUIDs of that member)
    $GuidMap = @{}
    $MemberFiles = Get-ChildItem -Path $ProfilesPath -ErrorAction SilentlyContinue

    foreach ($File in $MemberFiles) {
        try {
            $ProfileData = Get-Content -Raw -Path $File.FullName | ConvertFrom-Json
            $Guids = @($ProfileData.MemberProfile.RegisteredUT2004GUIDs |
                ForEach-Object { $_.ToString().Trim().ToLower() } |
                Where-Object { $_ -match $GuidRegex })

            if ($Guids.Count -gt 0) {
                foreach ($g in $Guids) {
                    $GuidMap[$g] = $Guids
                }
            }
        }
        catch {
            Write-UploadLog -Message "Failed to parse member profile JSON: $($File.Name)" -Level "WARNING"
        }
    }

    # 2. Read every player profile: one stats object per GUID that has played
    $OwnStats = @{}
    $StatFiles = Get-ChildItem -Path $StatsFolder -Filter "*.json"
    $Unreadable = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $StatFiles) {
        try {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $plaprofile = $content.PlayerProfile

            if ($plaprofile -and $plaprofile.Guid) {
                $RawGuid = $plaprofile.Guid.ToString().Trim().ToLower()

                # Check for bad GUID format
                if ($RawGuid -notmatch $GuidRegex) {
                    Write-UploadLog -Message "Skipping malformed GUID '$RawGuid' in $($file.Name)" -Level "WARNING"
                    continue
                }

                # Extract and validate metrics
                $EloVal    = $plaprofile.CaptureTheFlagElo.Rating
                $MuVal     = $plaprofile.CaptureTheFlagRating.Mu
                $SigmaVal  = $plaprofile.CaptureTheFlagRating.Sigma
                $RatingVal = $plaprofile.CaptureTheFlagRating.Rating

                # Numeric type sanity checks
                if ($null -eq $EloVal -or $null -eq $MuVal -or $null -eq $SigmaVal) {
                    Write-UploadLog -Message "Skipping $RawGuid - Missing non-numeric Elo/Mu/Sigma" -Level "WARNING"
                    continue
                }

                $Elo    = [double]$EloVal
                $Mu     = [double]$MuVal
                $Sigma  = [double]$SigmaVal
                $Rating = if ($null -ne $RatingVal) { [double]$RatingVal } else { $Mu - (3.0 * $Sigma) }

                # Range warnings
                if ($Sigma -le 0 -or $Mu -lt 0 -or $Mu -gt 60) {
                    Write-UploadLog -Message "WARNING: Odd numbers for $RawGuid (mu=$Mu, sigma=$Sigma)" -Level "WARNING"
                }

                $OwnStats[$RawGuid] = [PSCustomObject]@{
                    Elo    = $Elo
                    Mu     = $Mu
                    Sigma  = $Sigma
                    Rating = $Rating
                }
            }
        }
        catch {
            # Usually a file locked while the bot writes it; it is picked up next run
            $Unreadable.Add($file.Name)
        }
    }

    if ($Unreadable.Count -gt 0) {
        Write-UploadLog -Message "Could not read $($Unreadable.Count) player file(s), left out this run: $($Unreadable -join ', ')" -Level "WARNING"
    }

    # 3. Roll-ups: every GUID of a member gets the numbers of that member's
    #    most-played GUID (lowest Sigma; on a tie, the higher Rating).
    #    Unused alts sit at the default Sigma, so they never win over a
    #    GUID with real history, whatever its Rating.
    $RatingsDict = @{}

    foreach ($Guid in $OwnStats.Keys) {
        if (-not $GuidMap.ContainsKey($Guid)) {
            $RatingsDict[$Guid] = $OwnStats[$Guid]
        }
    }

    $DoneGroups = @{}
    foreach ($Guids in $GuidMap.Values) {
        $GroupKey = ($Guids | Sort-Object) -join ","
        if ($DoneGroups.ContainsKey($GroupKey)) { continue }
        $DoneGroups[$GroupKey] = $true

        $Best = $null
        foreach ($g in $Guids) {
            if (-not $OwnStats.ContainsKey($g)) { continue }
            $s = $OwnStats[$g]
            if ($null -eq $Best -or $s.Sigma -lt $Best.Sigma -or
                ($s.Sigma -eq $Best.Sigma -and $s.Rating -gt $Best.Rating)) {
                $Best = $s
            }
        }

        # A member none of whose GUIDs has played yet is left out (unknown to the mutator)
        if ($null -ne $Best) {
            foreach ($g in $Guids) {
                $RatingsDict[$g] = $Best
            }
        }
    }

    $EntryCount = $RatingsDict.Count

    # ==========================================
    # SANITY CHECKS (Validation Net)
    # ==========================================
    # Check 1: Minimum entry threshold
    if ($EntryCount -lt $MinEntries) {
        Write-UploadLog -Message "SANITY CHECK FAILED: Generated $EntryCount entries, which is below the minimum required ($MinEntries). Aborting upload!" -Level "ERROR"
        return
    }

    # Check 2: Drop protection relative to previous generated file
    if (Test-Path $OutputFile) {
        try {
            $PrevLines = Get-Content -Path $OutputFile
            $PrevCount = ($PrevLines | Where-Object { $_ -match "^PlayerRatings=" }).Count
            if ($PrevCount -gt 0 -and $EntryCount -lt ($PrevCount * 0.8)) {
                Write-UploadLog -Message "SANITY CHECK FAILED: Entry count dropped significantly ($EntryCount entries vs $PrevCount in previous file). Aborting upload!" -Level "ERROR"
                return
            }
        }
        catch {
            Write-UploadLog -Message "Could not inspect previous output file for count comparison: $_" -Level "WARNING"
        }
    }

    # ==========================================
    # BUILD INI FILE WITH METADATA HEADERS
    # ==========================================
    $RatingLines = [System.Collections.Generic.List[string]]::new()
    foreach ($Key in ($RatingsDict.Keys | Sort-Object)) {
        $st = $RatingsDict[$Key]
        $RatingLines.Add("$PropertyName=(Guid=""$Key"",Elo=$(Format-RatingNum $st.Elo),Mu=$(Format-RatingNum $st.Mu),Sigma=$(Format-RatingNum $st.Sigma),Rating=$(Format-RatingNum $st.Rating))")
    }

    # Nothing changed since the last successful upload: don't write or send it again
    $NewHash = Get-ContentHash $RatingLines
    if ((Test-Path $UploadedHashFile) -and ((Get-Content -Raw $UploadedHashFile).Trim() -eq $NewHash)) {
        Write-UploadLog -Message "No rating changes ($EntryCount entries) - nothing to upload." -Level "INFO"
        return
    }

    $UtcStamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'", $Invariant)

    $iniLines = [System.Collections.Generic.List[string]]::new()
    $iniLines.Add("[$SectionName]")
    $iniLines.Add("FormatVersion=$FormatVersion")
    $iniLines.Add("GeneratedAt=$UtcStamp")
    $iniLines.Add("ExpectedCount=$EntryCount")
    $iniLines.AddRange($RatingLines)

    # Convert array to Windows CRLF line endings string
    $ContentString = ($iniLines -join "`r`n") + "`r`n"
    $AsciiBytes = [System.Text.Encoding]::ASCII.GetBytes($ContentString)

    # Atomic Save via temporary file (.tmp)
    $TempFile = "$OutputFile.tmp"
    [System.IO.File]::WriteAllBytes($TempFile, $AsciiBytes)

    # Verify written temp file integrity
    try {
        $ReadBackBytes = [System.IO.File]::ReadAllBytes($TempFile)
        $StartsWithBracket = ($ReadBackBytes.Length -gt 0 -and $ReadBackBytes[0] -eq 91) # ASCII '[' is 91
        $IsPureAscii = -not ($ReadBackBytes | Where-Object { $_ -gt 127 })

        if (-not ($StartsWithBracket -and $IsPureAscii)) {
            Remove-Item $TempFile -Force -ErrorAction SilentlyContinue
            Write-UploadLog -Message "SELF-CHECK FAILED: Temporary INI failed ASCII or header verification - nothing uploaded!" -Level "ERROR"
            return
        }

        # Replace live destination file with validated temp file
        Move-Item -Path $TempFile -Destination $OutputFile -Force
    }
    catch {
        Write-UploadLog -Message "Self-check execution error: $_" -Level "ERROR"
        return
    }

    # ==========================================
    # FTP UPLOAD
    # ==========================================
    try {
        Send-RatingsFile -LocalFile (Resolve-Path $OutputFile).Path
        [System.IO.File]::WriteAllText($UploadedHashFile, $NewHash)
        Write-UploadLog -Message "Upload Complete. Generated pure ASCII INI with $EntryCount validated entries (FormatVersion=$FormatVersion) and uploaded to the game server by FTP." -Level "SUCCESS"
    }
    catch {
        # The hash is not saved, so the next run tries again
        Write-UploadLog -Message "FTP Upload failed: $_" -Level "ERROR"
    }
}

# ==========================================
# SCHEDULED EXECUTION LOOP (EVERY 2 MINUTES)
# ==========================================
Write-UploadLog -Message "Starting Validated Ratings Sync Service (2-Minute Loop)..." -Level "INFO"

while ($true) {
    Update-RatingFiles
    Write-UploadLog -Message "Sleeping for $IntervalSeconds seconds ($($IntervalSeconds / 60) minutes)..." -Level "INFO"
    Start-Sleep -Seconds $IntervalSeconds
}
