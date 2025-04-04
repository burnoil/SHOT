###############################################################################
# SystemMonitor.ps1 - Renamed to SHOT (System Health Observation Tool)
###############################################################################

# Ensure $PSScriptRoot is defined for older versions
if (-not $PSScriptRoot) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $ScriptDir = $PSScriptRoot
}

# Define version
$ScriptVersion = "1.1.0"

# ============================================================
# MODULE: Configuration Management
# ============================================================
function Get-DefaultConfig {
    return @{
        RefreshInterval       = 30
        LogRotationSizeMB     = 5
        DefaultLogLevel       = "INFO"
        ContentDataUrl        = "ContentData.json"
        ContentFetchInterval  = 60
        YubiKeyAlertDays      = 7
        IconPaths             = @{
            Main    = "icon.ico"
            Warning = "warning.ico"
        }
        YubiKeyLastCheck      = @{
            Date   = "1970-01-01 00:00:00"
            Result = "YubiKey Certificate: Not yet checked"
        }
        AnnouncementsLastState = @{}
        Version               = $ScriptVersion
        PatchInfoFilePath     = "C:\\temp\\patch_fixlets.txt"  # Updated to your desired path
    }
}

function Load-Configuration {
    param(
        [string]$Path = (Join-Path $ScriptDir "SHOT.config.json")
    )
    $defaultConfig = Get-DefaultConfig
    if (Test-Path $Path) {
        try {
            $config = Get-Content $Path -Raw | ConvertFrom-Json
            Write-Log "Loaded config from $Path" -Level "INFO"
            foreach ($key in $defaultConfig.Keys) {
                if (-not $config.PSObject.Properties.Match($key)) {
                    $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaultConfig[$key]
                }
            }
            if (-not $config.AnnouncementsLastState) {
                $config.AnnouncementsLastState = @{}
            }
            return $config
        }
        catch {
            Write-Log "Error loading config, reverting to default: $_" -Level "ERROR"
            return $defaultConfig
        }
    }
    else {
        $defaultConfig | ConvertTo-Json -Depth 3 | Out-File $Path -Force
        Write-Log "Created default config at $Path" -Level "INFO"
        return $defaultConfig
    }
}

function Save-Configuration {
    param(
        [psobject]$Config,
        [string]$Path = (Join-Path $ScriptDir "SHOT.config.json")
    )
    $Config | ConvertTo-Json -Depth 3 | Out-File $Path -Force
}

# ============================================================
# MODULE: Performance Optimizations – Caching
# ============================================================
$global:StaticSystemInfo = $null
$global:LastContentFetch = $null
$global:CachedContentData = $null

function Get-StaticSystemInfo {
    $systemInfo = @{}
    try {
        $machine = Get-CimInstance -ClassName Win32_ComputerSystem
        $systemInfo.MachineType = "$($machine.Manufacturer) $($machine.Model)"
    } catch {
        $systemInfo.MachineType = "Unknown"
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $osVersion = "$($os.Caption) (Build $($os.BuildNumber))"
        try {
            $displayVersion = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction SilentlyContinue).DisplayVersion
            if ($displayVersion) { $osVersion += " $displayVersion" }
        } catch {}
        $systemInfo.OSVersion = $osVersion
    } catch {
        $systemInfo.OSVersion = "Unknown"
    }
    return $systemInfo
}

# ============================================================
# A) Advanced Logging & Error Handling
# ============================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $logPath = if ($LogFilePath) { $LogFilePath } else { Join-Path $ScriptDir "SHOT.log" }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logPath -Value $logEntry -ErrorAction SilentlyContinue
}

function Handle-Error {
    param(
        [string]$ErrorMessage,
        [string]$Source = ""
    )
    if ($Source) { $ErrorMessage = "[$Source] $ErrorMessage" }
    Write-Log $ErrorMessage -Level "ERROR"
}

function Log-DotNetVersion {
    try {
        $dotNetVersion = [System.Environment]::Version.ToString()
        Write-Log ".NET Version: $dotNetVersion" -Level "INFO"
        try {
            $frameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            Write-Log ".NET Framework Description: $frameworkDescription" -Level "INFO"
        }
        catch {
            Write-Log "RuntimeInformation not available." -Level "WARNING"
        }
    }
    catch {
        Write-Log "Error capturing .NET version: $_" -Level "ERROR"
    }
}

# ============================================================
# B) External Configuration Setup
# ============================================================
$LogFilePath = Join-Path $ScriptDir "SHOT.log"
$config = Load-Configuration

$mainIconPath = Join-Path $ScriptDir $config.IconPaths.Main
$warningIconPath = Join-Path $ScriptDir $config.IconPaths.Warning
$mainIconUri = "file:///" + ($mainIconPath -replace '\\','/')

# Default content data now expects arrays for Links
$defaultContentData = @{
    Announcements = @{
        Text    = "No announcements at this time."
        Details = "Check back later for updates."
        Links   = @(
            @{ Name = "Announcement Link 1"; Url = "https://company.com/news1" },
            @{ Name = "Announcement Link 2"; Url = "https://company.com/news2" }
        )
    }
    EarlyAdopter = @{
        Text  = "Join our beta program!"
        Links = @(
            @{ Name = "Early Adopter Link 1"; Url = "https://beta.company.com/signup" },
            @{ Name = "Early Adopter Link 2"; Url = "https://beta.company.com/info" }
        )
    }
    Support = @{
        Text  = "Contact IT Support: support@company.com | Phone: 1-800-555-1234"
        Links = @(
            @{ Name = "Support Link 1"; Url = "https://support.company.com/help" },
            @{ Name = "Support Link 2"; Url = "https://support.company.com/tickets" }
        )
    }
}

# ============================================================
# C) Log File Setup & Rotation
# ============================================================
$LogDirectory = Split-Path $LogFilePath
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    Write-Log "Created log directory: $LogDirectory" -Level "INFO"
}

function Rotate-LogFile {
    try {
        if (Test-Path $LogFilePath) {
            $fileInfo = Get-Item $LogFilePath
            $maxSizeBytes = $config.LogRotationSizeMB * 1MB
            if ($fileInfo.Length -gt $maxSizeBytes) {
                $archivePath = "$LogFilePath.$(Get-Date -Format 'yyyyMMddHHmmss').archive"
                Rename-Item -Path $LogFilePath -NewName $archivePath
                Write-Log "Log file rotated. Archived as $archivePath" -Level "INFO"
            }
        }
    }
    catch {
        Write-Log "Failed to rotate log file: $_" -Level "ERROR"
    }
}
Rotate-LogFile

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = $config.DefaultLogLevel
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFilePath -Value $logEntry -ErrorAction SilentlyContinue
}

# ============================================================
# D) Import Required Assemblies
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# E) XAML Layout Definition
# ============================================================
# The Announcements, Support, and EarlyAdopter sections now include a container (StackPanel)
# for dynamic link creation.
$xamlString = @"
<?xml version="1.0" encoding="utf-8"?>
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SHOT - System Health Observation Tool"
    WindowStartupLocation="Manual"
    SizeToContent="WidthAndHeight"
    MinWidth="350" MinHeight="500"
    ResizeMode="CanResize"
    ShowInTaskbar="False"
    Visibility="Hidden"
    Topmost="True"
    Background="#f0f0f0">
  <Grid Margin="3">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <!-- Title Section -->
    <Border Grid.Row="0" Background="#0078D7" Padding="4" CornerRadius="2" Margin="0,0,0,4">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
        <Image Source="$mainIconUri" Width="20" Height="20" Margin="0,0,4,0"/>
        <TextBlock Text="System Health Observation Tool"
                   FontSize="14" FontWeight="Bold" Foreground="White"
                   VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    <!-- Content Area -->
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel VerticalAlignment="Top">
        <!-- Information Section -->
        <Expander Header="Information" ToolTip="View system details" FontSize="12" Foreground="#00008B" IsExpanded="True" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="LoggedOnUserText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="MachineTypeText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="OSVersionText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="SystemUptimeText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="UsedDiskSpaceText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="IpAddressText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="YubiKeyCertExpiryText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Announcements Section -->
        <Expander x:Name="AnnouncementsExpander" ToolTip="View latest announcements" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Expander.Header>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Announcements" VerticalAlignment="Center"/>
              <Ellipse x:Name="AnnouncementsAlertIcon" Width="10" Height="10" Margin="4,0,0,0" Fill="Red" Visibility="Hidden"/>
            </StackPanel>
          </Expander.Header>
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="AnnouncementsText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <TextBlock x:Name="AnnouncementsDetailsText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <StackPanel x:Name="AnnouncementsLinksPanel" Orientation="Vertical" Margin="2"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Patching and Updates Section -->
        <Expander Header="Patching and Updates" ToolTip="View patching status" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="PatchingUpdatesText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Support Section -->
        <Expander Header="Support" ToolTip="Contact IT support" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="SupportText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <StackPanel x:Name="SupportLinksPanel" Orientation="Vertical" Margin="2"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Early Adopter Section -->
        <Expander Header="Open Early Adopter Testing" ToolTip="Join beta program" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="EarlyAdopterText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
              <StackPanel x:Name="EarlyAdopterLinksPanel" Orientation="Vertical" Margin="2"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Compliance Section -->
        <Expander x:Name="ComplianceExpander" ToolTip="Check compliance status" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Expander.Header>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Compliance" VerticalAlignment="Center"/>
              <Ellipse x:Name="ComplianceStatusIndicator" Width="10" Height="10" Margin="4,0,0,0" Fill="Red" Visibility="Hidden"/>
            </StackPanel>
          </Expander.Header>
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <Border BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2" x:Name="AntivirusBorder">
                <StackPanel>
                  <TextBlock Text="Antivirus Status" FontSize="11" FontWeight="Bold" Margin="2" Foreground="#28a745"/>
                  <TextBlock x:Name="AntivirusStatusText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
                </StackPanel>
              </Border>
              <Border x:Name="BitLockerBorder" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
                <StackPanel>
                  <TextBlock Text="BitLocker Status" FontSize="11" FontWeight="Bold" Margin="2" Foreground="#6c757d"/>
                  <TextBlock x:Name="BitLockerStatusText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
                </StackPanel>
              </Border>
              <Border x:Name="BigFixBorder" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
                <StackPanel>
                  <TextBlock Text="BigFix (BESClient) Status" FontSize="11" FontWeight="Bold" Margin="2" Foreground="#4b0082"/>
                  <TextBlock x:Name="BigFixStatusText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
                </StackPanel>
              </Border>
              <Border x:Name="Code42Border" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
                <StackPanel>
                  <TextBlock Text="Code42 Service Status" FontSize="11" FontWeight="Bold" Margin="2" Foreground="#800080"/>
                  <TextBlock x:Name="Code42StatusText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
                </StackPanel>
              </Border>
              <Border x:Name="FIPSBorder" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
                <StackPanel>
                  <TextBlock Text="FIPS Compliance Status" FontSize="11" FontWeight="Bold" Margin="2" Foreground="#FF4500"/>
                  <TextBlock x:Name="FIPSStatusText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>
        </Expander>
        <!-- Logs Section -->
        <Expander Header="Logs" ToolTip="View recent logs" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <ListView x:Name="LogListView" FontSize="10" Margin="2" Height="120">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Timestamp" Width="100" DisplayMemberBinding="{Binding Timestamp}" />
                    <GridViewColumn Header="Message" Width="150" DisplayMemberBinding="{Binding Message}" />
                  </GridView>
                </ListView.View>
              </ListView>
              <Button x:Name="ExportLogsButton" Content="Export Logs" Width="80" Margin="2" HorizontalAlignment="Right" ToolTip="Save logs to a file"/>
            </StackPanel>
          </Border>
        </Expander>
        <!-- About Section -->
        <Expander Header="About" ToolTip="View app info and changelog" FontSize="12" Foreground="#00008B" IsExpanded="False" Margin="0,2,0,2">
          <Border BorderBrush="#00008B" BorderThickness="1" Padding="3" CornerRadius="2" Background="White" Margin="2">
            <StackPanel>
              <TextBlock x:Name="AboutText" FontSize="11" Margin="2" TextWrapping="Wrap" MaxWidth="300">
                <TextBlock.Text><![CDATA[
SHOT v1.1.0
© 2025 SHOT. All rights reserved.
Built with PowerShell and WPF.

Changelog:
- v1.1.0: Added modular configuration management and caching for improved performance.
         Toast popup and dynamic links for Announcements, Support, and Early Adopter allow data-driven updates.
- v1.0.0: Initial release
                ]]></TextBlock.Text>
              </TextBlock>
            </StackPanel>
          </Border>
        </Expander>
      </StackPanel>
    </ScrollViewer>
    <!-- Footer Section -->
    <TextBlock Grid.Row="2" Text="© 2025 SHOT" FontSize="10" Foreground="Gray" HorizontalAlignment="Center" Margin="0,4,0,0"/>
  </Grid>
</Window>
"@


# ============================================================
# F) Load and Verify XAML
# ============================================================
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.LoadXml($xamlString)
$reader = New-Object System.Xml.XmlNodeReader $xmlDoc
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
	$window.Width = 350
$window.Height = 500
$window.Left = 100  # Set initial position but don’t show yet
$window.Top = 100
$window.WindowState = 'Normal'
Write-Log "Initial window setup: Left=100, Top=100, Width=350, Height=500, State=$($window.WindowState)" -Level "INFO"
# Do NOT set Visibility or Hide here; let Toggle-WindowVisibility handle it
}
catch {
    Handle-Error "Failed to load the XAML layout: $_" -Source "XAML"
    exit
}
if ($window -eq $null) {
    Handle-Error "Failed to load the XAML layout. Check the XAML syntax for errors." -Source "XAML"
    exit
}

# Optionally set the window title programmatically
$window.Title = "SHOT - System Health Observation Tool"

# ============================================================
# G) Access UI Elements
# ============================================================
$LoggedOnUserText    = $window.FindName("LoggedOnUserText")
$MachineTypeText     = $window.FindName("MachineTypeText")
$OSVersionText       = $window.FindName("OSVersionText")
$SystemUptimeText    = $window.FindName("SystemUptimeText")
$UsedDiskSpaceText   = $window.FindName("UsedDiskSpaceText")
$IpAddressText       = $window.FindName("IpAddressText")
$YubiKeyCertExpiryText = $window.FindName("YubiKeyCertExpiryText")

$AntivirusStatusText = $window.FindName("AntivirusStatusText")
$BitLockerStatusText = $window.FindName("BitLockerStatusText")
$BigFixStatusText    = $window.FindName("BigFixStatusText")
$Code42StatusText    = $window.FindName("Code42StatusText")
$FIPSStatusText      = $window.FindName("FIPSStatusText")
$AboutText           = $window.FindName("AboutText")

$AnnouncementsExpander = $window.FindName("AnnouncementsExpander")
$AnnouncementsAlertIcon = $window.FindName("AnnouncementsAlertIcon")
$AnnouncementsText   = $window.FindName("AnnouncementsText")
$AnnouncementsDetailsText = $window.FindName("AnnouncementsDetailsText")
$AnnouncementsLinksPanel = $window.FindName("AnnouncementsLinksPanel")
$PatchingUpdatesText = $window.FindName("PatchingUpdatesText")
$SupportText         = $window.FindName("SupportText")
$SupportLinksPanel   = $window.FindName("SupportLinksPanel")
$EarlyAdopterText    = $window.FindName("EarlyAdopterText")
$EarlyAdopterLinksPanel = $window.FindName("EarlyAdopterLinksPanel")
$ComplianceExpander  = $window.FindName("ComplianceExpander")
$ComplianceStatusIndicator = $window.FindName("ComplianceStatusIndicator")
$LogListView         = $window.FindName("LogListView")
$ExportLogsButton    = $window.FindName("ExportLogsButton")

$BitLockerBorder     = $window.FindName("BitLockerBorder")
$BigFixBorder        = $window.FindName("BigFixBorder")
$Code42Border        = $window.FindName("Code42Border")
$FIPSBorder          = $window.FindName("FIPSBorder")

# ============================================================
# Global Variables for Jobs, Caching, and Data
# ============================================================
$global:yubiKeyJob = $null
$global:contentData = $null
$global:announcementAlertActive = $false
$global:yubiKeyAlertShown = $false

# ============================================================
# H) Modularized System Information Functions
# ============================================================
function Fetch-ContentData {
    try {
        Write-Log "Config object: $($config | ConvertTo-Json -Depth 3)" -Level "INFO"  # Log entire config
        $url = $config.ContentDataUrl
        Write-Log "Raw ContentDataUrl from config: '$url'" -Level "INFO"  # Log exact value
        if ($global:LastContentFetch -and ((Get-Date) - $global:LastContentFetch).TotalSeconds -lt $config.ContentFetchInterval) {
            Write-Log "Using cached content data" -Level "INFO"
            return $global:CachedContentData
        }
        Write-Log "Attempting to fetch content from: $url" -Level "INFO"
        if ($url -match "^(?i)(http|https)://") {
            Write-Log "Detected HTTP/HTTPS URL, using Invoke-WebRequest" -Level "INFO"
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
            Write-Log "Raw content: $($response.Content)" -Level "INFO"
            $contentString = $response.Content.Trim()
            $contentData = $contentString | ConvertFrom-Json
            Write-Log "Fetched content data from URL: $url" -Level "INFO"
        }
        elseif ($url -match "^\\\\") {
            Write-Log "Detected network path" -Level "INFO"
            if (-not (Test-Path $url)) { throw "Network path not accessible: $url" }
            $rawContent = Get-Content -Path $url -Raw
            $contentData = $rawContent | ConvertFrom-Json
        }
        else {
            Write-Log "Assuming local file path" -Level "INFO"
            $fullPath = if ([System.IO.Path]::IsPathRooted($url)) { $url } else { Join-Path $ScriptDir $url }
            Write-Log "Resolved full path: $fullPath" -Level "INFO"
            if (-not (Test-Path $fullPath)) { throw "Local path not found: $fullPath" }
            $rawContent = Get-Content -Path $fullPath -Raw
            $contentData = $rawContent | ConvertFrom-Json
        }
        $global:CachedContentData = $contentData
        $global:LastContentFetch = Get-Date
        return $contentData
    }
    catch {
        Write-Log "Failed to fetch content data from ${url}: $_" -Level "ERROR"
        return $defaultContentData
    }
}

function Get-YubiKeyCertExpiryDays {
    try {
        if (-not (Test-Path "C:\Program Files\Yubico\Yubikey Manager\ykman.exe")) {
            throw "ykman.exe not found at C:\Program Files\Yubico\Yubikey Manager\ykman.exe"
        }
        Write-Log "ykman.exe found at C:\Program Files\Yubico\Yubikey Manager\ykman.exe" -Level "INFO"
        $yubiKeyInfo = & "C:\Program Files\Yubico\Yubikey Manager\ykman.exe" info 2>$null
        if (-not $yubiKeyInfo) {
            Write-Log "No YubiKey detected" -Level "INFO"
            return "YubiKey not present"
        }
        Write-Log "YubiKey detected: $yubiKeyInfo" -Level "INFO"
        $pivInfo = & "C:\Program Files\Yubico\Yubikey Manager\ykman.exe" "piv" "info" 2>$null
        if ($pivInfo) {
            Write-Log "PIV info: $pivInfo" -Level "INFO"
        } else {
            Write-Log "No PIV info available" -Level "WARNING"
        }
        $slots = @("9a", "9c", "9d", "9e")
        $certPem = $null
        $slotUsed = $null
        foreach ($slot in $slots) {
            Write-Log "Checking slot $slot for certificate" -Level "INFO"
            $certPem = & "C:\Program Files\Yubico\Yubikey Manager\ykman.exe" "piv" "certificates" "export" $slot "-" 2>$null
            if ($certPem -and $certPem -match "-----BEGIN CERTIFICATE-----") {
                $slotUsed = $slot
                Write-Log "Certificate found in slot $slot" -Level "INFO"
                break
            } else {
                Write-Log "No valid certificate in slot $slot" -Level "INFO"
            }
        }
        if (-not $certPem) { throw "No certificate found in slots 9a, 9c, 9d, or 9e" }
        $tempFile = [System.IO.Path]::GetTempFileName()
        $certPem | Out-File $tempFile -Encoding ASCII
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $cert.Import($tempFile)
        $today = Get-Date
        $expiryDate = $cert.NotAfter
        $daysUntilExpiry = ($expiryDate - $today).Days
        Remove-Item $tempFile -Force
        if ($daysUntilExpiry -lt 0) {
            return "YubiKey Certificate (Slot $slotUsed): Expired ($(-$daysUntilExpiry) days ago)"
        } else {
            return "YubiKey Certificate (Slot $slotUsed): $daysUntilExpiry days until expiry ($expiryDate)"
        }
    }
    catch {
        if ($_.Exception.Message -ne "No YubiKey detected by ykman") {
            Write-Log "Error retrieving YubiKey certificate expiry: $_" -Level "ERROR"
            return "YubiKey Certificate: Unable to determine expiry date - $_"
        }
    }
}

function Start-YubiKeyCertCheckAsync {
    if ($global:yubiKeyJob -and $global:yubiKeyJob.State -eq "Running") {
        Write-Log "YubiKey certificate check already in progress." -Level "INFO"
        return
    }
    $global:yubiKeyJob = Start-Job -ScriptBlock {
        param($ykmanPath, $LogFilePathPass)
        function Write-Log {
            param(
                [string]$Message,
                [ValidateSet("INFO", "WARNING", "ERROR")]
                [string]$Level = "INFO"
            )
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logEntry = "[$timestamp] [$Level] $Message"
            Add-Content -Path $LogFilePathPass -Value $logEntry -ErrorAction SilentlyContinue
        }
        try {
            if (-not (Test-Path $ykmanPath)) { throw "ykman.exe not found at $ykmanPath" }
            Write-Log "ykman.exe found at $ykmanPath" -Level "INFO"
            $yubiKeyInfo = & $ykmanPath info 2>$null
            if (-not $yubiKeyInfo) {
                Write-Log "No YubiKey detected" -Level "INFO"
                return "YubiKey not present"
            }
            Write-Log "YubiKey detected: $yubiKeyInfo" -Level "INFO"
            $pivInfo = & $ykmanPath "piv" "info" 2>$null
            if ($pivInfo) { Write-Log "PIV info: $pivInfo" -Level "INFO" } else { Write-Log "No PIV info available" -Level "WARNING" }
            $slots = @("9a", "9c", "9d", "9e")
            $certPem = $null
            $slotUsed = $null
            foreach ($slot in $slots) {
                Write-Log "Checking slot $slot for certificate" -Level "INFO"
                $certPem = & $ykmanPath "piv" "certificates" "export" $slot "-" 2>$null
                if ($certPem -and $certPem -match "-----BEGIN CERTIFICATE-----") {
                    $slotUsed = $slot
                    Write-Log "Certificate found in slot $slot" -Level "INFO"
                    break
                } else {
                    Write-Log "No valid certificate in slot $slot" -Level "INFO"
                }
            }
            if (-not $certPem) { throw "No certificate found in slots 9a, 9c, 9d, or 9e" }
            $tempFile = [System.IO.Path]::GetTempFileName()
            $certPem | Out-File $tempFile -Encoding ASCII
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            $cert.Import($tempFile)
            $today = Get-Date
            $expiryDate = $cert.NotAfter
            $daysUntilExpiry = ($expiryDate - $today).Days
            Remove-Item $tempFile -Force
            if ($daysUntilExpiry -lt 0) {
                return "YubiKey Certificate (Slot $slotUsed): Expired ($(-$daysUntilExpiry) days ago)"
            } else {
                return "YubiKey Certificate (Slot $slotUsed): $daysUntilExpiry days until expiry ($expiryDate)"
            }
        }
        catch {
            if ($_.Exception.Message -ne "No YubiKey detected by ykman") {
                Write-Log "Error retrieving YubiKey certificate expiry: $_" -Level "ERROR"
                return "YubiKey Certificate: Unable to determine expiry date - $_"
            }
        }
    } -ArgumentList "C:\Program Files\Yubico\Yubikey Manager\ykman.exe", $LogFilePath
    Write-Log "Started async YubiKey certificate check job." -Level "INFO"
}

function Update-SystemInfo {
    try {
        $window.Dispatcher.Invoke({ $LoggedOnUserText.Text = "Logged-in User: Checking..." })
        $user = [System.Environment]::UserName
        $window.Dispatcher.Invoke({ $LoggedOnUserText.Text = "Logged-in User: $user" })
        Write-Log "Logged-in User: $user" -Level "INFO"

        if (-not $global:StaticSystemInfo) {
            $global:StaticSystemInfo = Get-StaticSystemInfo
        }
        $machineType = $global:StaticSystemInfo.MachineType
        $osVersion = $global:StaticSystemInfo.OSVersion
        $window.Dispatcher.Invoke({ $MachineTypeText.Text = "Machine Type: $machineType" })
        Write-Log "Machine Type: $machineType" -Level "INFO"
        $window.Dispatcher.Invoke({ $OSVersionText.Text = "OS Version: $osVersion" })
        Write-Log "OS Version: $osVersion" -Level "INFO"

        $osDynamic = Get-CimInstance -ClassName Win32_OperatingSystem
        $uptime = (Get-Date) - $osDynamic.LastBootUpTime
        $systemUptime = "$([math]::Floor($uptime.TotalDays)) days $($uptime.Hours) hours"
        $window.Dispatcher.Invoke({ $SystemUptimeText.Text = "System Uptime: $systemUptime" })
        Write-Log "System Uptime: $systemUptime" -Level "INFO"

        $drive = Get-PSDrive -Name C
        $usedDiskSpace = "$([math]::Round(($drive.Used / 1GB), 2)) GB of $([math]::Round((($drive.Free + $drive.Used) / 1GB), 2)) GB"
        $window.Dispatcher.Invoke({ $UsedDiskSpaceText.Text = "Used Disk Space: $usedDiskSpace" })
        Write-Log "Used Disk Space: $usedDiskSpace" -Level "INFO"

        $ipv4s = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -notin @("0.0.0.0","255.255.255.255") -and $_.PrefixOrigin -ne "WellKnown"
        } | Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue
        if ($ipv4s) {
            $ipList = $ipv4s -join ", "
            $window.Dispatcher.Invoke({ $IpAddressText.Text = "IPv4 Address(es): $ipList" })
            Write-Log "IP Address(es): $ipList" -Level "INFO"
        }
        else {
            $window.Dispatcher.Invoke({ $IpAddressText.Text = "IPv4 Address(es): None detected" })
            Write-Log "No valid IPv4 addresses found." -Level "WARNING"
        }

        if ($global:yubiKeyJob -and $global:yubiKeyJob.State -eq "Completed") {
            $yubiKeyResult = Receive-Job -Job $global:yubiKeyJob
            $yubiKeyResultString = if ($yubiKeyResult -is [string]) { $yubiKeyResult } else { $yubiKeyResult.ToString() }
            $window.Dispatcher.Invoke({ $YubiKeyCertExpiryText.Text = $yubiKeyResultString })
            $config.YubiKeyLastCheck.Date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $config.YubiKeyLastCheck.Result = $yubiKeyResultString
            Save-Configuration -Config $config
            Remove-Job -Job $global:yubiKeyJob -Force
            $global:yubiKeyJob = $null
            Write-Log "YubiKey certificate check completed and saved: $yubiKeyResultString" -Level "INFO"
            if ($yubiKeyResultString -match "(\d+) days until expiry" -and [int]$matches[1] -le $config.YubiKeyAlertDays -and -not $global:yubiKeyAlertShown) {
                $days = [int]$matches[1]
                $TrayIcon.ShowBalloonTip(5000, "YubiKey Expiry Alert", "YubiKey certificate expires in $days days!", [System.Windows.Forms.ToolTipIcon]::Warning)
                Write-Log "YubiKey expiry alert triggered: $days days remaining" -Level "WARNING"
                $global:yubiKeyAlertShown = $true
            }
        }
        elseif (-not $global:yubiKeyJob) {
            $checkYubiKey = ((Get-Date) - [DateTime]::Parse($config.YubiKeyLastCheck.Date)).TotalMinutes -ge 5
            if ($checkYubiKey) {
                $window.Dispatcher.Invoke({ $YubiKeyCertExpiryText.Text = "Checking YubiKey certificate..." })
                Start-YubiKeyCertCheckAsync
            } else {
                $window.Dispatcher.Invoke({ $YubiKeyCertExpiryText.Text = $config.YubiKeyLastCheck.Result })
            }
        }
    }
    catch {
        Handle-Error "Error updating system information: $_" -Source "Update-SystemInfo"
    }
}

function Get-BigFixStatus {
    try {
        $besService = Get-Service -Name BESClient -ErrorAction SilentlyContinue
        if ($besService) {
            if ($besService.Status -eq 'Running') {
                return $true, "BigFix (BESClient) Service: Running"
            }
            else {
                return $false, "BigFix (BESClient) is Installed but NOT Running (Status: $($besService.Status))"
            }
        }
        else {
            return $false, "BigFix (BESClient) not installed or not detected."
        }
    }
    catch {
        return $false, "Error retrieving BigFix status: $_"
    }
}

function Get-BitLockerStatus {
    try {
        $shell = New-Object -ComObject Shell.Application
        $bitlockerValue = $shell.NameSpace("C:").Self.ExtendedProperty("System.Volume.BitLockerProtection")
        switch ($bitlockerValue) {
            0 { return $false, "BitLocker is NOT Enabled on Drive C:" }
            1 { return $true,  "BitLocker is Enabled (Locked) on Drive C:" }
            2 { return $true,  "BitLocker is Enabled (Unlocked) on Drive C:" }
            3 { return $true,  "BitLocker is Enabled (Unknown State) on Drive C:" }
            6 { return $true,  "BitLocker is Fully Encrypted (Unlocked) on Drive C:" }
            default { return $false, "BitLocker code: $bitlockerValue (Unmapped status)" }
        }
    }
    catch {
        return $false, "Error retrieving BitLocker info: $_"
    }
}

function Get-AntivirusStatus {
    try {
        $antivirus = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName "AntiVirusProduct"
        if ($antivirus) {
            $antivirusNames = $antivirus | ForEach-Object { $_.displayName } | Sort-Object -Unique
            return $true, "Antivirus Detected: $($antivirusNames -join ', ')"
        }
        else {
            return $false, "No Antivirus Detected."
        }
    }
    catch {
        return $false, "Error retrieving antivirus information: $_"
    }
}

function Get-Code42Status {
    try {
        $code42Process = Get-Process -Name "Code42Service" -ErrorAction SilentlyContinue
        if ($code42Process) {
            return $true, "Code42 Service: Running (PID: $($code42Process.Id))"
        }
        else {
            $servicePath = "C:\Program Files\Code42\Code42Service.exe"
            if (Test-Path $servicePath) {
                return $false, "Code42 Service: Installed but NOT running."
            }
            else {
                return $false, "Code42 Service: Not installed."
            }
        }
    }
    catch {
        return $false, "Error checking Code42 Service: $_"
    }
}

function Get-FIPSStatus {
    try {
        $fipsSetting = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name "Enabled" -ErrorAction SilentlyContinue
        if ($fipsSetting -and $fipsSetting.Enabled -eq 1) {
            return $true, "FIPS Compliance: Enabled"
        }
        else {
            return $false, "FIPS Compliance: Not Enabled"
        }
    }
    catch {
        return $false, "FIPS Compliance: Unknown (error: $_)"
    }
}

# --- UPDATED Compare-Announcements function for dynamic links ---
function Compare-Announcements {
    param($current, $last)
    $changes = @()
    $currentText = if ($current.PSObject.Properties.Match("Text")) { $current.Text } else { "" }
    $lastText = if ($last.PSObject.Properties.Match("Text")) { $last.Text } else { "" }
    $currentDetails = if ($current.PSObject.Properties.Match("Details")) { $current.Details } else { "" }
    $lastDetails = if ($last.PSObject.Properties.Match("Details")) { $last.Details } else { "" }
    if ($currentText -ne $lastText) { $changes += "Text changed from '$lastText' to '$currentText'" }
    if ($currentDetails -ne $lastDetails) { $changes += "Details changed from '$lastDetails' to '$currentDetails'" }
    for ($i = 0; $i -lt $current.Links.Count; $i++) {
        if ($i -ge $last.Links.Count) {
            $changes += "New link added: '$($current.Links[$i].Name) ($($current.Links[$i].Url))'"
        }
        elseif (($current.Links[$i].Name -ne $last.Links[$i].Name) -or ($current.Links[$i].Url -ne $last.Links[$i].Url)) {
            $changes += "Link " + ($i+1) + " changed from '$($last.Links[$i].Name) ($($last.Links[$i].Url))' to '$($current.Links[$i].Name) ($($current.Links[$i].Url))'"
        }
    }
    return $changes
}

function Update-Announcements {
    try {
        if (-not $global:contentData.Announcements) { throw "Announcements data missing" }
        if (-not $global:contentData.Announcements.Text) { throw "Announcements.Text missing" }
        if (-not $global:contentData.Announcements.Links -or ($global:contentData.Announcements.Links.Count -lt 1)) { 
            throw "Announcements.Links missing required links" 
        }
        $currentAnnouncements = $global:contentData.Announcements
        $lastAnnouncements = $config.AnnouncementsLastState
        Write-Log "Current Announcements: $($currentAnnouncements | ConvertTo-Json -Depth 3)" -Level "INFO"
        Write-Log "Last Announcements: $($lastAnnouncements | ConvertTo-Json -Depth 3)" -Level "INFO"
        $changes = Compare-Announcements -current $currentAnnouncements -last $lastAnnouncements
        if ($changes.Count -gt 0 -and -not $AnnouncementsExpander.IsExpanded) {
            Write-Log "Announcements changed detected: $($changes -join '; ')" -Level "INFO"
            $window.Dispatcher.Invoke({
                $AnnouncementsAlertIcon.Visibility = "Visible"
                $TrayIcon.ShowBalloonTip(5000, "SHOT Announcements", $currentAnnouncements.Text, [System.Windows.Forms.ToolTipIcon]::Info)
            })
            Write-Log "Announcements red dot set to visible and toast popup displayed" -Level "INFO"
            $global:announcementAlertActive = $true
        }
        else {
            Write-Log "No changes detected in Announcements or section already expanded" -Level "INFO"
        }
        $window.Dispatcher.Invoke({
            $AnnouncementsText.Text = $currentAnnouncements.Text
            $AnnouncementsDetailsText.Text = if ($currentAnnouncements.Details) { $currentAnnouncements.Details } else { "" }
            # Dynamically populate the links panel for Announcements
            $AnnouncementsLinksPanel.Children.Clear()
            foreach ($link in $currentAnnouncements.Links) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $hp = New-Object System.Windows.Documents.Hyperlink
                $hp.NavigateUri = [Uri]$link.Url
                $hp.Inlines.Add($link.Name)
                $hp.Add_RequestNavigate({
                    param($sender, $e)
                    Start-Process $e.Uri.AbsoluteUri
                    $e.Handled = $true
                    Write-Log "Clicked Announcement Link: $($e.Uri.AbsoluteUri)" -Level "INFO"
                })
                $tb.Inlines.Add($hp)
                $AnnouncementsLinksPanel.Children.Add($tb)
            }
        })
        $config.AnnouncementsLastState = $currentAnnouncements
        Save-Configuration -Config $config
        Write-Log "Announcements updated: $($AnnouncementsText.Text)" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update announcements: $_" -Level "ERROR"
        $window.Dispatcher.Invoke({
            $AnnouncementsText.Text = "Error fetching announcements."
            $AnnouncementsDetailsText.Text = ""
            $AnnouncementsLinksPanel.Children.Clear()
        })
    }
}

function Update-PatchingUpdates {
    try {
        $patchFilePath = if ([System.IO.Path]::IsPathRooted($config.PatchInfoFilePath)) {
            $config.PatchInfoFilePath
        } else {
            Join-Path $ScriptDir $config.PatchInfoFilePath
        }
        Write-Log "Resolved patch file path: $patchFilePath" -Level "INFO"

        if (Test-Path $patchFilePath -PathType Leaf) {
            Write-Log "File exists at $patchFilePath, attempting to read..." -Level "INFO"
            $patchContent = Get-Content -Path $patchFilePath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($patchContent)) {
                $patchText = "Patch info file is empty."
                Write-Log "File is empty at $patchFilePath" -Level "WARNING"
            } else {
                $patchText = $patchContent.Trim()
                Write-Log "Successfully read content: $patchText" -Level "INFO"
            }
        } else {
            $patchText = "Patch info file not found at $patchFilePath."
            Write-Log "File not found or inaccessible: $patchFilePath" -Level "ERROR"
            if (-not (Test-Path "C:\temp" -PathType Container)) {
                Write-Log "Directory C:\temp does not exist" -Level "ERROR"
            }
        }

        $window.Dispatcher.Invoke({ $PatchingUpdatesText.Text = $patchText })
        Write-Log "Patching status updated in UI: $patchText" -Level "INFO"
    }
    catch {
        # Use the exact syntax that worked in the test
        $errorMessage = "Error reading patch info file at ${patchFilePath}``: $_"
        Write-Log "Debug: patchFilePath = $patchFilePath" -Level "INFO"
        Write-Log "Debug: Error details = $_" -Level "INFO"
        Write-Log "Debug: errorMessage set to: $errorMessage" -Level "ERROR"
        $window.Dispatcher.Invoke({ $PatchingUpdatesText.Text = $errorMessage })
    }
}

function Update-Support {
    try {
        if (-not $global:contentData.Support) { throw "Support data missing" }
        if (-not $global:contentData.Support.Text) { throw "Support.Text missing" }
        if (-not $global:contentData.Support.Links -or ($global:contentData.Support.Links.Count -lt 1)) { 
            throw "Support.Links missing required links" 
        }
        $window.Dispatcher.Invoke({
            $SupportText.Text = $global:contentData.Support.Text
            # Dynamically populate Support links
            if ($SupportLinksPanel -ne $null) {
                $SupportLinksPanel.Children.Clear()
                foreach ($link in $global:contentData.Support.Links) {
                    $tb = New-Object System.Windows.Controls.TextBlock
                    $hp = New-Object System.Windows.Documents.Hyperlink
                    $hp.NavigateUri = [Uri]$link.Url
                    $hp.Inlines.Add($link.Name)
                    $hp.Add_RequestNavigate({
                        param($sender, $e)
                        Start-Process $e.Uri.AbsoluteUri
                        $e.Handled = $true
                        Write-Log "Clicked Support Link: $($e.Uri.AbsoluteUri)" -Level "INFO"
                    })
                    $tb.Inlines.Add($hp)
                    $SupportLinksPanel.Children.Add($tb)
                }
            }
        })
        Write-Log "Support info updated: $($SupportText.Text)" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update support: $_" -Level "ERROR"
        $window.Dispatcher.Invoke({
            $SupportText.Text = "Error loading support info."
            $SupportLinksPanel.Children.Clear()
        })
    }
}

function Update-EarlyAdopterTesting {
    try {
        if (-not $global:contentData.EarlyAdopter) { throw "EarlyAdopter data missing" }
        if (-not $global:contentData.EarlyAdopter.Text) { throw "EarlyAdopter.Text missing" }
        if (-not $global:contentData.EarlyAdopter.Links -or ($global:contentData.EarlyAdopter.Links.Count -lt 1)) { 
            throw "EarlyAdopter.Links missing required links" 
        }
        $window.Dispatcher.Invoke({
            $EarlyAdopterText.Text = $global:contentData.EarlyAdopter.Text
            # Dynamically populate Early Adopter links
            if ($EarlyAdopterLinksPanel -ne $null) {
                $EarlyAdopterLinksPanel.Children.Clear()
                foreach ($link in $global:contentData.EarlyAdopter.Links) {
                    $tb = New-Object System.Windows.Controls.TextBlock
                    $hp = New-Object System.Windows.Documents.Hyperlink
                    $hp.NavigateUri = [Uri]$link.Url
                    $hp.Inlines.Add($link.Name)
                    $hp.Add_RequestNavigate({
                        param($sender, $e)
                        Start-Process $e.Uri.AbsoluteUri
                        $e.Handled = $true
                        Write-Log "Clicked Early Adopter Link: $($e.Uri.AbsoluteUri)" -Level "INFO"
                    })
                    $tb.Inlines.Add($hp)
                    $EarlyAdopterLinksPanel.Children.Add($tb)
                }
            }
        })
        Write-Log "Early adopter info updated: $($EarlyAdopterText.Text)" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update early adopter: $_" -Level "ERROR"
        $window.Dispatcher.Invoke({
            $EarlyAdopterText.Text = "Error loading early adopter info."
            $EarlyAdopterLinksPanel.Children.Clear()
        })
    }
}

function Update-Compliance {
    try {
        $antivirusStatus, $antivirusMessage = Get-AntivirusStatus
        $bitlockerStatus, $bitlockerMessage = Get-BitLockerStatus
        $bigfixStatus, $bigfixMessage = Get-BigFixStatus
        $code42Status, $code42Message = Get-Code42Status
        $fipsStatus, $fipsMessage = Get-FIPSStatus
        $window.Dispatcher.Invoke({
            $AntivirusStatusText.Text = $antivirusMessage
            $BitLockerStatusText.Text = $bitlockerMessage
            $BigFixStatusText.Text = $bigfixMessage
            $Code42StatusText.Text = $code42Message
            $FIPSStatusText.Text = $fipsMessage
            if ($antivirusStatus -and $bitlockerStatus -and $bigfixStatus -and $code42Status -and $fipsStatus) {
                $ComplianceStatusIndicator.Visibility = "Hidden"
            } else {
                $ComplianceStatusIndicator.Fill = "Red"
                $ComplianceStatusIndicator.Visibility = "Visible"
            }
        })
        Write-Log "Compliance updated: Antivirus=$antivirusStatus, BitLocker=$bitlockerStatus, BigFix=$bigfixStatus, Code42=$code42Status, FIPS=$fipsStatus" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update compliance: $_" -Level "ERROR"
        $window.Dispatcher.Invoke({
            $AntivirusStatusText.Text = "Error checking antivirus."
            $BitLockerStatusText.Text = "Error checking BitLocker."
            $BigFixStatusText.Text = "Error checking BigFix."
            $Code42StatusText.Text = "Error checking Code42."
            $FIPSStatusText.Text = "Error checking FIPS."
            $ComplianceStatusIndicator.Fill = "Red"
            $ComplianceStatusIndicator.Visibility = "Visible"
        })
    }
}

# ============================================================
# I) Tray Icon Management
# ============================================================
function Get-Icon {
    param(
        [string]$Path,
        [System.Drawing.Icon]$DefaultIcon
    )
    $fullPath = Join-Path $ScriptDir $Path
    if (-not (Test-Path $fullPath)) {
        Write-Log "$fullPath not found. Using default icon." -Level "WARNING"
        return $DefaultIcon
    }
    else {
        try {
            $icon = New-Object System.Drawing.Icon($fullPath)
            Write-Log "Custom icon loaded from ${fullPath}." -Level "INFO"
            return $icon
        }
        catch {
            Handle-Error "Error loading icon from ${fullPath}: $_" -Source "Get-Icon"
            return $DefaultIcon
        }
    }
}

function Update-TrayIcon {
    try {
        $antivirusStatus, $antivirusMessage = Get-AntivirusStatus
        $bitlockerStatus, $bitlockerMessage = Get-BitLockerStatus
        $bigfixStatus, $bigfixMessage = Get-BigFixStatus
        $code42Status, $code42Message = Get-Code42Status
        $fipsStatus, $fipsMessage = Get-FIPSStatus
        $yubiKeyCert = $YubiKeyCertExpiryText.Text
        $yubikeyStatus = $yubiKeyCert -notmatch "Unable to determine expiry date" -and $yubiKeyCert -ne "YubiKey not present"
        if ($antivirusStatus -and $bitlockerStatus -and $yubikeyStatus -and $code42Status -and $fipsStatus -and $bigfixStatus) {
            $TrayIcon.Icon = Get-Icon -Path $config.IconPaths.Main -DefaultIcon ([System.Drawing.SystemIcons]::Application)
            Write-Log "Tray icon set to icon.ico" -Level "INFO"
            $TrayIcon.Text = "SHOT - Healthy"
        }
        else {
            $TrayIcon.Icon = Get-Icon -Path $config.IconPaths.Warning -DefaultIcon ([System.Drawing.SystemIcons]::Application)
            Write-Log "Tray icon set to warning.ico" -Level "INFO"
            $TrayIcon.Text = "SHOT - Warning"
        }
        $TrayIcon.Visible = $true
        Write-Log "Tray icon and status updated." -Level "INFO"
    }
    catch {
        Handle-Error "Error updating tray icon: $_" -Source "Update-TrayIcon"
    }
}

# ============================================================
# J) Enhanced Logs Management (ListView)
# ============================================================
function Update-Logs {
    try {
        if (Test-Path $LogFilePath) {
            $logContent = Get-Content -Path $LogFilePath -Tail 100 -ErrorAction SilentlyContinue
            $logEntries = @()
            foreach ($line in $logContent) {
                if ($line -match "^\[(?<timestamp>[^\]]+)\]\s\[(?<level>[^\]]+)\]\s(?<message>.*)$") {
                    $logEntries += [PSCustomObject]@{
                        Timestamp = $matches['timestamp']
                        Message   = $matches['message']
                    }
                }
            }
            $window.Dispatcher.Invoke({ $LogListView.ItemsSource = $logEntries })
        }
        else {
            $window.Dispatcher.Invoke({ $LogListView.ItemsSource = @([PSCustomObject]@{Timestamp="N/A"; Message="Log file not found."}) })
        }
        Write-Log "Logs updated in GUI." -Level "INFO"
    }
    catch {
        Handle-Error "Error loading logs: $_" -Source "Update-Logs"
    }
}

function Export-Logs {
    try {
        $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveFileDialog.Filter = "Log Files (*.log)|*.log|All Files (*.*)|*.*"
        $saveFileDialog.FileName = "SHOT.log"
        if ($saveFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Copy-Item -Path $LogFilePath -Destination $saveFileDialog.FileName -Force
            Write-Log "Logs exported to $($saveFileDialog.FileName)" -Level "INFO"
        }
    }
    catch {
        Handle-Error "Error exporting logs: $_" -Source "Export-Logs"
    }
}

# ============================================================
# K) Window Visibility Management
# ============================================================
function Set-WindowPosition {
    try {
        $window.Dispatcher.Invoke({
            if ($window.ActualWidth -eq 0 -or $window.ActualHeight -eq 0) {
                $window.Width = 350
                $window.Height = 500
                $window.UpdateLayout()
            }

            $primary = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            Write-Log "Primary screen: X=$($primary.X), Y=$($primary.Y), Width=$($primary.Width), Height=$($primary.Height)" -Level "INFO"

            $left = $primary.X + ($primary.Width - $window.ActualWidth) / 2  # Center horizontally
            $top = $primary.Y + ($primary.Height - $window.ActualHeight) / 2  # Center vertically

            $left = [Math]::Max($primary.X, [Math]::Min($left, $primary.X + $primary.Width - $window.ActualWidth))
            $top = [Math]::Max($primary.Y, [Math]::Min($top, $primary.Y + $primary.Height - $window.ActualHeight))

            $window.Left = $left
            $window.Top = $top
            Write-Log "Window position set: Left=$left, Top=$top, Width=$($window.ActualWidth), Height=$($window.ActualHeight)" -Level "INFO"
        })
    }
    catch {
        Handle-Error "Error setting window position: $_" -Source "Set-WindowPosition"
    }
}

function Toggle-WindowVisibility {
    try {
        $window.Dispatcher.Invoke({
            if ($window.Visibility -eq 'Visible') {
                $window.Hide()
                Write-Log "Dashboard hidden via Toggle-WindowVisibility." -Level "INFO"
            }
            else {
                Set-WindowPosition
                $window.Show()
                $window.WindowState = 'Normal'
                $window.Activate()
                $window.Topmost = $true
                Start-Sleep -Milliseconds 500
                $window.Topmost = $false
                Write-Log "Dashboard shown via Toggle-WindowVisibility at Left=$($window.Left), Top=$($window.Top), Visibility=$($window.Visibility), State=$($window.WindowState)" -Level "INFO"
                Write-Log "Post-Show: IsVisible=$($window.IsVisible), IsActive=$($window.IsActive), ZOrder=$($window.Topmost)" -Level "INFO"
            }
        }, "Normal")
    }
    catch {
        Handle-Error "Error toggling window visibility: $_" -Source "Toggle-WindowVisibility"
    }
}

# ============================================================
# L) Button and Event Handlers
# ============================================================
$ExportLogsButton.Add_Click({ Export-Logs })

# Static links for Support and Early Adopter are now dynamically generated, so no fixed hyperlink handlers are required.
$AnnouncementsExpander.Add_Expanded({
    if ($global:announcementAlertActive) {
        $window.Dispatcher.Invoke({ $AnnouncementsAlertIcon.Visibility = "Hidden" })
        $global:announcementAlertActive = $false
        Write-Log "Announcements red dot hidden on expand" -Level "INFO"
    }
})

# ============================================================
# M) Create & Configure Tray Icon with Collapsible Menu
# ============================================================
$TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$TrayIcon.Icon = Get-Icon -Path $config.IconPaths.Main -DefaultIcon ([System.Drawing.SystemIcons]::Application)
$TrayIcon.Text = "SHOT v$ScriptVersion"
$TrayIcon.Visible = $true
Write-Log "Tray icon initialized with icon.ico" -Level "INFO"
Write-Log "Note: To ensure the SHOT tray icon is always visible, right-click the taskbar, select 'Taskbar settings', scroll to 'Notification area', click 'Select which icons appear on the taskbar', and set 'SHOT' to 'On'." -Level "INFO"

$ContextMenu = New-Object System.Windows.Forms.ContextMenu
$MenuItemShow = New-Object System.Windows.Forms.MenuItem("Show Dashboard")
$MenuItemQuickActions = New-Object System.Windows.Forms.MenuItem("Quick Actions")
$MenuItemRefresh = New-Object System.Windows.Forms.MenuItem("Refresh Now")
$MenuItemExportLogs = New-Object System.Windows.Forms.MenuItem("Export Logs")
$MenuItemExit = New-Object System.Windows.Forms.MenuItem("Exit")
$MenuItemQuickActions.MenuItems.Add($MenuItemRefresh)
$MenuItemQuickActions.MenuItems.Add($MenuItemExportLogs)
$ContextMenu.MenuItems.Add($MenuItemShow)
$ContextMenu.MenuItems.Add($MenuItemQuickActions)
$ContextMenu.MenuItems.Add($MenuItemExit)
$TrayIcon.ContextMenu = $ContextMenu

$TrayIcon.add_MouseClick({
    param($sender, $e)
    try {
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Toggle-WindowVisibility
        }
    }
    catch {
        Handle-Error "Error handling tray icon mouse click: $_" -Source "TrayIcon"
    }
})

$MenuItemShow.add_Click({ Toggle-WindowVisibility })
$MenuItemRefresh.add_Click({ 
    $global:contentData = Fetch-ContentData
    Update-TrayIcon
    Update-SystemInfo
    Update-Logs
    Update-Announcements
    Update-PatchingUpdates
    Update-Support
    Update-EarlyAdopterTesting
    Update-Compliance
    Write-Log "Manual refresh triggered from tray menu" -Level "INFO"
})
$MenuItemExportLogs.add_Click({ Export-Logs })
$MenuItemExit.add_Click({
    try {
        Write-Log "Exit clicked by user." -Level "INFO"
        $dispatcherTimer.Stop()
        Write-Log "DispatcherTimer stopped." -Level "INFO"
        if ($global:yubiKeyJob) {
            Stop-Job -Job $global:yubiKeyJob -ErrorAction SilentlyContinue
            Remove-Job -Job $global:yubiKeyJob -Force -ErrorAction SilentlyContinue
            Write-Log "YubiKey job stopped and removed." -Level "INFO"
        }
        $TrayIcon.Visible = $false
        $TrayIcon.Dispose()
        Write-Log "Tray icon disposed." -Level "INFO"
        $window.Dispatcher.InvokeShutdown()
        Write-Log "Application exited via tray menu." -Level "INFO"
    }
    catch {
        Handle-Error "Error during application exit: $_" -Source "Exit"
    }
})

# ============================================================
# O) DispatcherTimer for Periodic Updates
# ============================================================
$dispatcherTimer = New-Object System.Windows.Threading.DispatcherTimer
$dispatcherTimer.Interval = [TimeSpan]::FromSeconds($config.RefreshInterval)
$dispatcherTimer.add_Tick({
    try {
        $global:contentData = Fetch-ContentData
        Update-TrayIcon
        Update-SystemInfo
        Update-Logs
        Update-Announcements
        Update-PatchingUpdates
        Update-Support
        Update-EarlyAdopterTesting
        Update-Compliance
        Write-Log "Dispatcher tick completed" -Level "INFO"
    }
    catch {
        Handle-Error "Error during timer tick: $_" -Source "DispatcherTimer"
    }
})
$dispatcherTimer.Start()
Write-Log "DispatcherTimer started with interval $($config.RefreshInterval) seconds" -Level "INFO"

# ============================================================
# P) Dispatcher Exception Handling
# ============================================================
function Handle-DispatcherUnhandledException {
    param(
        [object]$sender,
        [System.Windows.Threading.DispatcherUnhandledExceptionEventArgs]$args
    )
    Handle-Error "Unhandled Dispatcher exception: $($args.Exception.Message)" -Source "Dispatcher"
}

Register-ObjectEvent -InputObject $window.Dispatcher -EventName UnhandledException -Action {
    param($sender, $args)
    Handle-DispatcherUnhandledException -sender $sender -args $args
}

# ============================================================
# Q) Initial Update & Start Dispatcher
# ============================================================
try {
    $window.Add_Loaded({ Set-WindowPosition })
    $global:contentData = Fetch-ContentData
    Write-Log "Initial contentData set: $($global:contentData | ConvertTo-Json -Depth 3)" -Level "INFO"
    Update-SystemInfo
    Update-TrayIcon
    Update-Logs
    Update-Announcements
    Update-PatchingUpdates
    Update-Support
    Update-EarlyAdopterTesting
    Update-Compliance
    Log-DotNetVersion
    Write-Log "Initial update completed" -Level "INFO"
}
catch {
    Handle-Error "Error during initial update: $_" -Source "InitialUpdate"
}

$window.Add_Closing({
    param($sender, $eventArgs)
    try {
        $eventArgs.Cancel = $true
        $window.Hide()
        Write-Log "Dashboard hidden via window closing event." -Level "INFO"
    }
    catch {
        Handle-Error "Error handling window closing: $_" -Source "WindowClosing"
    }
})

Write-Log "About to call Dispatcher.Run()..." -Level "INFO"
[System.Windows.Threading.Dispatcher]::Run()
Write-Log "Dispatcher ended; script exiting." -Level "INFO"
