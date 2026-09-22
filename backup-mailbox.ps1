<#
.SYNOPSIS
    Backs up a single M365 mailbox to a .pst file via the M365Backup console app.

.PARAMETER Mailbox
    The mailbox email address to back up. If omitted, you'll be prompted for it.

.PARAMETER From
    Optional start date (yyyy-MM-dd, inclusive) - for chunking a large mailbox
    year over year instead of backing up everything in one run.

.PARAMETER To
    Optional end date (yyyy-MM-dd, exclusive) - paired with -From.

.EXAMPLE
    .\backup-mailbox.ps1
    .\backup-mailbox.ps1 -Mailbox someone@example.com
    .\backup-mailbox.ps1 -Mailbox someone@example.com -From 2023-01-01 -To 2024-01-01
#>
param(
    [string]$Mailbox,
    [string]$From,
    [string]$To
)

if (-not $Mailbox) {
    $Mailbox = Read-Host "Enter the mailbox email address to back up"
}

if ($Mailbox -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Write-Error "'$Mailbox' doesn't look like a valid email address."
    exit 1
}

# PST directory and filename (including the [MONYYYY-MONYYYY] chunk label, if
# -From/-To are given) are computed by Program.cs itself - see
# DefaultBackupDirectory()/DefaultPstFileName() - so there's one source of
# truth for that naming instead of two copies drifting apart.
Write-Host "Target mailbox : $Mailbox"
Write-Host ""

Push-Location $PSScriptRoot
try {
    $dotnetArgs = @($Mailbox)
    if ($From) { $dotnetArgs += @("--from", $From) }
    if ($To) { $dotnetArgs += @("--to", $To) }

    dotnet run -- @dotnetArgs
}
finally {
    Pop-Location
}
