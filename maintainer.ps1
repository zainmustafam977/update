<#
.SYNOPSIS
    Ultimate System Maintenance Suite
.DESCRIPTION
    - Updates all packages (Winget + Microsoft Store)
    - Verifies update completion
    - Performs comprehensive cleanup
    - Handles errors gracefully
.NOTES
    Version: 2.1
    Requires: PowerShell 5.1+ (Run as Administrator)
#>

# -------------------------------
# CONFIGURATION
# -------------------------------
$LogFile = "$env:TEMP\SystemMaintenance_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$ForceUpdates = $false             # Use --force for stubborn packages
$CleanupWindowsUpdate = $true     # Run cleanmgr for Windows Update files
$RunDismCleanup = $true           # Perform DISM component cleanup
$RetryFailedUpdates = 2           # Retry attempts for failed updates

# -------------------------------
# FUNCTIONS
# -------------------------------
function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "INFO",
        [switch]$NoNewLine
    )
    $Color = @{
        "SUCCESS" = "Green"; "ERROR" = "Red"; "WARNING" = "Yellow"
        "INFO" = "Cyan"; "PROGRESS" = "Magenta"; "SYSTEM" = "Blue"
    }[$Status.ToUpper()]
    $Timestamp = Get-Date -Format "HH:mm:ss"
    $Output = "[$Timestamp] [$Status] $Message"
    if ($Color) { Write-Host $Output -ForegroundColor $Color -NoNewline:($NoNewLine) }
    else { Write-Host $Output -NoNewline:($NoNewLine) }
    Add-Content -Path $LogFile -Value $Output
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-WingetPackages {
    $Attempt = 1
    while ($Attempt -le $RetryFailedUpdates) {
        Write-Status "🔄 Winget Update Attempt $Attempt/$RetryFailedUpdates" -Status PROGRESS
        $WingetArgs = "upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements"
        if ($ForceUpdates) { $WingetArgs += " --force" }
        
        $Result = winget $WingetArgs.Split() 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "✅ Winget updates applied successfully" -Status SUCCESS
            return $true
        }
        $Attempt++
        Start-Sleep -Seconds 5
    }
    Write-Status "❌ Failed to update all Winget packages after $RetryFailedUpdates attempts" -Status ERROR
    return $false
}

function Verify-WingetUpdates {
    Write-Status "🔍 Verifying all packages are up-to-date..." -Status INFO
    $Outdated = winget upgrade --include-unknown --accept-source-agreements | Where-Object { $_ -match "available" }
    if ($Outdated) {
        Write-Status "⚠️ Outdated packages detected:" -Status WARNING
        $Outdated | ForEach-Object { Write-Status "    $_" -Status WARNING }
        
        # Attempt forced update
        Write-Status "🔄 Attempting forced update of remaining packages..." -Status PROGRESS
        try {
            winget upgrade --all --force --silent --accept-package-agreements --accept-source-agreements
            Write-Status "✅ Force-update attempt completed" -Status INFO
        } catch {
            Write-Status "⚠️ Could not force update packages: $_" -Status WARNING
        }
        return $false
    }
    Write-Status "✅ All Winget packages are current" -Status SUCCESS
    return $true
}

function Update-StoreApps {
    try {
        Write-Status "🛒 Checking Microsoft Store updates..." -Status INFO
        
        # Method 1: Reset Store cache
        try {
            Start-Process "wsreset.exe" -Wait -WindowStyle Hidden
            Write-Status "🔄 Reset Microsoft Store cache" -Status INFO
        } catch {
            Write-Status "⚠️ Could not reset Store cache: $_" -Status WARNING
        }

        # Method 2: Modern Store API
        try {
            $Store = New-Object -ComObject "Microsoft.Store.PartnerCenter.StoreContext"
            $Updates = $Store.GetAppAndOptionalStorePackageUpdatesAsync().GetAwaiter().GetResult()
            
            if ($Updates.Count -gt 0) {
                Write-Status "⬇️ Downloading $($Updates.Count) Store updates..." -Status PROGRESS
                $Store.RequestDownloadAndInstallStorePackageUpdatesAsync($Updates).GetAwaiter().GetResult()
                Write-Status "✅ Store updates installed" -Status SUCCESS
                return $true
            } else {
                Write-Status "✅ No Store updates available" -Status INFO
                return $true
            }
        } catch {
            Write-Status "⚠️ Modern Store API failed, trying manual method..." -Status WARNING
        }

        # Method 3: URI Scheme
        try {
            $Result = Start-Process "ms-windows-store://downloadsandupdates" -PassThru
            Start-Sleep -Seconds 15  # Allow time for Store to open
            Write-Status "✅ Triggered Store updates check" -Status SUCCESS
            return $true
        } catch {
            Write-Status "❌ Store update failed: $_" -Status ERROR
            return $false
        }
    } catch {
        Write-Status "❌ All Store update methods failed: $_" -Status ERROR
        return $false
    }
}

function Clear-Caches {
    # Winget Cache
    try {
        Write-Status "🗑️ Cleaning Winget cache..." -Status INFO
        winget cache clean --silent | Out-Null
        Write-Status "✅ Winget cache cleared" -Status SUCCESS
    } catch {
        Write-Status "⚠️ Winget cache cleanup failed: $_" -Status WARNING
    }

    # Microsoft Store Cache
    $StoreCachePaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore*\TempState",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore*\LocalCache",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore*\AC\INetCache"
    )
    $StoreCachePaths | ForEach-Object {
        if (Test-Path $_) {
            try {
                Remove-Item $_ -Recurse -Force -ErrorAction Stop
                Write-Status "✅ Cleared: $_" -Status SUCCESS
            } catch {
                Write-Status "⚠️ Failed to clear $_`: $_" -Status WARNING
            }
        }
    }

    # Windows Update Cleanup
    if ($CleanupWindowsUpdate) {
        try {
            Write-Status "🧹 Running Windows Update cleanup..." -Status INFO
            Start-Process "cleanmgr" -ArgumentList "/sagerun:1" -Wait -WindowStyle Hidden
            Write-Status "✅ Windows Update cleanup completed" -Status SUCCESS
        } catch {
            Write-Status "⚠️ Windows Update cleanup failed: $_" -Status WARNING
        }
    }

    # DISM Component Cleanup
    if ($RunDismCleanup) {
        try {
            Write-Status "🧪 Running DISM cleanup..." -Status SYSTEM
            $DismProcess = Start-Process "dism.exe" -ArgumentList "/Online", "/Cleanup-Image", "/StartComponentCleanup", "/Quiet" -PassThru -Wait -NoNewWindow
            if ($DismProcess.ExitCode -eq 0) {
                Write-Status "✅ DISM cleanup completed" -Status SUCCESS
            } else {
                Write-Status "⚠️ DISM completed with exit code $($DismProcess.ExitCode)" -Status WARNING
            }
        } catch {
            Write-Status "❌ DISM cleanup failed: $_" -Status ERROR
        }
    }

    # System Temp Files
    try {
        Write-Status "🧽 Cleaning system temp files..." -Status INFO
        Remove-Item "$env:TEMP\*", "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Status "✅ System temp files cleaned" -Status SUCCESS
    } catch {
        Write-Status "⚠️ Temp file cleanup failed: $_" -Status WARNING
    }
}
function Install-Winget {
    Write-Status "🔍 Verifying Winget installation..." -Status INFO
    
    # Check if winget command works
    try {
        $null = winget --version
        Write-Status "✅ Winget is already installed" -Status SUCCESS
        return $true
    } catch {
        Write-Status "⚠️ Winget not found or broken, attempting repair..." -Status WARNING
    }

    # Installation methods from most to least reliable
    $installMethods = @(
        {
            Write-Status "🔄 Method 1: Installing via Microsoft Store" -Status INFO
            Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1" -Wait
            Start-Sleep -Seconds 15
        },
        {
            Write-Status "🔄 Method 2: Installing via WinGet.Client module" -Status INFO
            Install-PackageProvider -Name NuGet -Force | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
            Import-Module Microsoft.WinGet.Client
            Install-WinGetPackageManager -AcceptPackageAgreements
        },
        {
            Write-Status "🔄 Method 3: Manual download from GitHub" -Status INFO
            $releases = Invoke-RestMethod "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
            $asset = $releases.assets | Where-Object { $_.name -match "\.msixbundle$" }
            $tempFile = "$env:TEMP\winget-latest.msixbundle"
            Invoke-WebRequest $asset.browser_download_url -OutFile $tempFile
            Add-AppxPackage -Path $tempFile
            Remove-Item $tempFile
        }
    )

    # Try each method until one succeeds
    foreach ($method in $installMethods) {
        try {
            & $method
            # Verify installation
            if (winget --version) {
                Write-Status "✅ Winget installed successfully" -Status SUCCESS
                return $true
            }
        } catch {
            Write-Status "⚠️ Installation attempt failed: $_" -Status WARNING
        }
    }

    Write-Status "❌ All Winget installation methods failed" -Status ERROR
    return $false
}


# -------------------------------
# MAIN EXECUTION
# -------------------------------
Clear-Host
Write-Host "`n▄▀▄▀▄ SYSTEM MAINTENANCE SUITE v2.1 ▄▀▄▀▄`n" -ForegroundColor Cyan

if (-not (Test-Admin)) {
    Write-Status "This script requires Administrator privileges." -Status ERROR
    exit 1
}

Write-Status "🚀 Starting maintenance process..." -Status INFO
$StartTime = Get-Date

if (-not (Install-Winget)) {
    Write-Status "❌ Critical: Winget is required but couldn't be installed" -Status ERROR
    exit 1
}

# Phase 1: Updates
Update-WingetPackages
Update-StoreApps

# Phase 2: Verification
Verify-WingetUpdates

# Phase 3: Cleanup
Clear-Caches

# Completion
$Duration = (Get-Date) - $StartTime
Write-Status "`n✨ Maintenance completed in $($Duration.ToString('mm\:ss'))" -Status SUCCESS
Write-Status "📜 Full log saved to: $LogFile" -Status INFO

# Show remaining outdated packages if any
$Outdated = winget upgrade --include-unknown --accept-source-agreements | Where-Object { $_ -match "available" }
if ($Outdated) {
    Write-Status "`n⚠️ Manual attention needed for these packages:" -Status WARNING
    $Outdated | ForEach-Object { Write-Status "    $_" -Status WARNING }
}

# Final recommendations
Write-Status "`n🛠️ Recommended next steps:" -Status INFO
Write-Status "1. Reboot if any system components were updated" -Status INFO
Write-Status "2. Check Windows Update for additional patches" -Status INFO
Write-Status "3. Run 'winget upgrade' manually if any packages remain outdated" -Status INFO

# Optional: Open log file
try {
    Start-Process notepad.exe $LogFile -ErrorAction SilentlyContinue
} catch {}