# Settings for GetPlayerRankings.ps1.
# Copy this file to GetPlayerRankings.config.psd1 (same folder) and fill in
# the real values. GetPlayerRankings.config.psd1 is ignored by git: never
# commit the real FTP login.
@{
    # FlawsFightNight bot data
    StatsFolder  = "C:\FFN\Databases\UT2004PlayerProfiles"
    ProfilesPath = "C:\FFN\Databases\MemberProfiles\*.json"

    # Where the generated ratings file and the upload log are written
    OutputFile   = "C:\FFN\Ranking\TeamBalanceRatings.ini"
    LogFile      = "C:\FFN\Ranking\UploadHistory.log"

    # Game server FTP: full path to TeamBalanceRatings.ini in the server's System folder
    FtpServer    = "ftp://your-server.example.com:21/System/TeamBalanceRatings.ini"
    FtpUsername  = "your-ftp-user"
    FtpPassword  = "your-ftp-password"

    # $true = encrypted FTP (explicit FTPS). Only if your host supports it.
    FtpUseSsl    = $false
}
