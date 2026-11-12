<#
.SYNOPSIS
  Window for Start-DesktopStream.ps1: pick a monitor, a program's window, a file or YouTube, set sound,
  subtitles, public link and quality, then Start and Stop. Links show up with Copy buttons.
  Drop a video or music file on the window (or on the program's icon) to pick it.
  The layout is StreamUI.xaml, the look is Theme.xaml, and the smaller windows are in Dialogs.ps1.
#>
param([string]$DroppedFile = "")

$ErrorActionPreference = "Stop"
$StreamScript = Join-Path $PSScriptRoot "Start-DesktopStream.ps1"
$OutLog = Join-Path $env:TEMP "VRVideoStreamer-out-$PID.txt"
$ErrLog = Join-Path $env:TEMP "VRVideoStreamer-err-$PID.txt"
$Title = "VR Video Streamer"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# This window is launched hidden, so anything that stops it opening has to be shown or nobody would see it.
# Exit code 2 tells the launcher the problem was already shown.
trap {
    [void][System.Windows.MessageBox]::Show("The program couldn't start:`n`n$($_.Exception.Message)", $Title, "OK", "Error")
    exit 2
}
# Files from a zip carry Windows' "downloaded from the internet" mark, and with it the hidden stream script
# hangs on start (Windows waits on a prompt nobody can see). The person chose to run this, so clear it.
Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch { } }
Add-Type -Name Win -Namespace UI -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO info);
// Flashes the taskbar button until the window is next brought to the front
public static void Flash(IntPtr h) {
    var f = new FLASHWINFO { hwnd = h, dwFlags = 3 | 12 };   // caption and taskbar, until in front
    f.cbSize = (uint)Marshal.SizeOf(f);
    FlashWindowEx(ref f);
}
'@
# Only the window should be visible, not the PowerShell console behind it
[void][UI.Win]::ShowWindow([UI.Win]::GetConsoleWindow(), 0)

# One window at a time: two copies would fight over the same ports and stop each other's streams.
# Opening it again just brings the existing window to the front.
$singleInstance = New-Object System.Threading.Mutex($false, "Local\VRVideoStreamer.UI")
$owned = $false
try { $owned = $singleInstance.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    $other = Get-Process powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq $Title -and $_.Id -ne $PID } | Select-Object -First 1
    if ($other) {
        [void][UI.Win]::ShowWindow($other.MainWindowHandle, 9)
        [void][UI.Win]::SetForegroundWindow($other.MainWindowHandle)
    }
    exit
}

# Earlier windows' leftovers. Only once this copy is the one that runs (opening the program again while it's
# open used to delete the running window's subtitle file first, so its next stream couldn't start), and never
# a file whose program is still running: the subtitle and sound files aren't held open between writes.
Get-ChildItem $env:TEMP -Filter "VRVideoStreamer-*" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in ".txt", ".log", ".jpg", ".tmp" } |
    Where-Object { -not ($_.BaseName -match '-(\d+)(-\d+)?$' -and [int]$Matches[1] -ne $PID -and (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) } |
    ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }

# Closing this window (X, Task Manager, crash) takes down everything it started: the stream script
# and its ffmpeg / MediaMTX / cloudflared, and the video file decoder
Add-Type -Path (Join-Path $PSScriptRoot "KillOnClose.cs")
[void][KillOnClose]::Enable()

# Video files play through PipePlayer (pause/seek); see PipePlayer.cs. Subtitles follow its position.
Add-Type -Path (Join-Path $PSScriptRoot "PipePlayer.cs"), (Join-Path $PSScriptRoot "SubtitleOverlay.cs"), (Join-Path $PSScriptRoot "SegmentProxy.cs"), (Join-Path $PSScriptRoot "SessionQuiet.cs"), (Join-Path $PSScriptRoot "RemoteProxy.cs") -ReferencedAssemblies System.Core

# The shared look applies to every window through this one application object
Add-Type -Path (Join-Path $PSScriptRoot "PreviewFeed.cs"), (Join-Path $PSScriptRoot "IntermissionCard.cs"), (Join-Path $PSScriptRoot "QrCode.cs") -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$app = New-Object System.Windows.Application
$app.ShutdownMode = "OnExplicitShutdown"
$app.Resources = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath (Join-Path $PSScriptRoot "Theme.xaml") -Raw -Encoding UTF8))
# A mistake in any button's code shouldn't close the window and end the stream for everyone watching
$app.Add_DispatcherUnhandledException({ param($s, $e)
        $e.Handled = $true
        if ($lblStatus) { $lblStatus.Text = "Something went wrong: $($e.Exception.Message)" }
    })

. (Join-Path $PSScriptRoot "FFmpegSetup.ps1")
. (Join-Path $PSScriptRoot "YouTube.ps1")
. (Join-Path $PSScriptRoot "Subtitles.ps1")
. (Join-Path $PSScriptRoot "Dialogs.ps1")
$toolsFolder = Join-Path $PSScriptRoot "tools"
$ffmpegExe = Find-FFmpeg $toolsFolder
if (-not $ffmpegExe) { $ffmpegExe = Install-FFmpegWithDialog $toolsFolder }
if (-not $ffmpegExe) { exit 2 }   # it already said why
$ffprobeExe = Join-Path (Split-Path $ffmpegExe) "ffprobe.exe"
$Fps = 30
$script:settings = Get-Settings

# Ask the stream script for monitors and audio inputs so the numbers always match what it uses.
# Continue: under Stop, a single warning line on stderr would count as a failure here.
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$ErrorActionPreference = "Continue"
$monitorLines = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $StreamScript -ListMonitors)
$audioDevices = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $StreamScript -ListAudio 2>$null)
$ErrorActionPreference = "Stop"
$hasNvidia = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" })
$hasAmd = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "AMD|Radeon" })
$hasIntel = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "Intel" })
# Having a graphics card doesn't mean it can encode (old card, old driver), and picking one that can't would
# stop the stream at Start. So actually try it: encode a few frames, which takes well under a second.
function Test-Encoder($codec) {
    $ErrorActionPreference = "Continue"
    & $ffmpegExe -hide_banner -loglevel quiet -nostdin -f lavfi -i "color=black:s=1280x720:r=30" -frames:v 5 -c:v $codec -f null - 2>$null
    $LASTEXITCODE -eq 0
}

# --- The window: every x:Name in StreamUI.xaml becomes a variable here ---
$windowXaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot "StreamUI.xaml") -Raw -Encoding UTF8
$window = New-AppWindow $windowXaml $null
foreach ($m in [regex]::Matches($windowXaml, 'x:Name="(\w+)"')) { Set-Variable -Name $m.Groups[1].Value -Value $window.FindName($m.Groups[1].Value) }
$window.Height = [Math]::Min($window.Height, [System.Windows.SystemParameters]::WorkArea.Height - 20)
$redBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F09595")
$mutedBrush = $window.FindResource("Muted")

foreach ($line in $monitorLines) {
    if ($line -match '^\[(\d+)\] (\d+)x(\d+).*?(\(primary\))?$') {
        $label = "Monitor $([int]$Matches[1] + 1)  -  $($Matches[2]) x $($Matches[3])" + $(if ($Matches[4]) { "  (main)" } else { "" })
        [void]$cbMonitor.Items.Add($label)
        if ($Matches[4]) { $cbMonitor.SelectedIndex = $cbMonitor.Items.Count - 1 }
    }
}
if ($cbMonitor.SelectedIndex -lt 0 -and $cbMonitor.Items.Count) { $cbMonitor.SelectedIndex = 0 }
if ("$($script:settings.Monitor)" -match '^\d+$' -and [int]$script:settings.Monitor -lt $cbMonitor.Items.Count) { $cbMonitor.SelectedIndex = [int]$script:settings.Monitor }

$script:windowProcs = @()
function Get-Programs {
    @(Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -ne $Title -and $_.Id -ne $PID } |
        Sort-Object ProcessName)
}
function Update-WindowList {
    $cbWindow.Items.Clear()
    $procs = Get-Programs
    $script:windowProcs = $procs
    foreach ($p in $procs) { [void]$cbWindow.Items.Add("$($p.ProcessName)  -  $($p.MainWindowTitle)") }
    # The program streamed last time, if it's open
    $want = if ($script:pickedProgram) { $script:pickedProgram } else { $script:settings.WindowProgram }
    for ($i = 0; $i -lt $procs.Count; $i++) { if ($want -and $procs[$i].ProcessName -eq $want) { $cbWindow.SelectedIndex = $i; break } }
}
Update-WindowList

# Public links go through Cloudflare only: a free quick link, or your own permanent one
$tunnels = @(@{ Name = "Cloudflare Temporary"; Value = "cloudflare" }, @{ Name = "Cloudflare Permanent"; Value = "permanent" })
foreach ($t in $tunnels) { [void]$cbTunnel.Items.Add($t.Name) }
$cbTunnel.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($tunnels | ForEach-Object { $_.Value }), "$($script:settings.Tunnel)"))
# The public link is the only way to watch, so it's always on (the box stays hidden, for the code that asks it)
$chkPublic.IsChecked = $true
$qualities = @(
    @{ Name = "1080p  (4 Mbps)"; Height = 1080; Bitrate = "4M"; Mbps = 4.0 },
    @{ Name = "720p  (2.5 Mbps)"; Height = 720; Bitrate = "2500k"; Mbps = 2.5 },
    @{ Name = "720p light  (1.5 Mbps)"; Height = 720; Bitrate = "1500k"; Mbps = 1.5 }
)
foreach ($q in $qualities) { [void]$cbQuality.Items.Add($q.Name) }
$cbQuality.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($qualities | ForEach-Object { $_.Name }), "$($script:settings.Quality)"))
$encoders = @(@{ Name = "CPU"; Value = "cpu"; Codec = "libx264" }, @{ Name = "NVIDIA GPU"; Value = "nvenc"; Codec = "h264_nvenc" },
              @{ Name = "AMD GPU"; Value = "amf"; Codec = "h264_amf" }, @{ Name = "Intel GPU"; Value = "qsv"; Codec = "h264_qsv" })
foreach ($e in $encoders) { [void]$cbEncoder.Items.Add($e.Name) }
# The one picked last time, if it still works (a new driver or graphics card can change that); otherwise the best one here
$savedEncoder = [array]::IndexOf(@($encoders | ForEach-Object { $_.Value }), "$($script:settings.Encoder)")
$cbEncoder.SelectedIndex = if ($savedEncoder -eq 0 -or ($savedEncoder -gt 0 -and (Test-Encoder $encoders[$savedEncoder].Codec))) { $savedEncoder }
                           elseif ($hasNvidia -and (Test-Encoder "h264_nvenc")) { 1 }
                           elseif ($hasAmd -and (Test-Encoder "h264_amf")) { 2 }
                           elseif ($hasIntel -and (Test-Encoder "h264_qsv")) { 3 }
                           else { 0 }

# Frames per second: 30 unless 60 was picked last time
$fpsChoices = @(30, 60)
foreach ($f in $fpsChoices) { [void]$cbFps.Items.Add("$f") }
$cbFps.SelectedIndex = [Math]::Max(0, [array]::IndexOf($fpsChoices, [int]"0$($script:settings.Fps)"))

$linkBoxes = @{ public = $tbPublic; remote = $tbRemote }
foreach ($pair in @(@($btnCopyPublic, $tbPublic), @($btnCopyRemote, $tbRemote))) {
    $pair[0].Tag = $pair[1]
    $pair[0].Add_Click({ param($s) if ($s.Tag.Text -match '^\w+://') {
                $lblStatus.Text = if (Copy-ToClipboard $s.Tag.Text) { "Copied: $($s.Tag.Text)" } else { "Couldn't copy, the clipboard is busy. Try again." }
            } })
}
foreach ($pair in @(@($btnQrPublic, $tbPublic, "Video player link"), @($btnQrRemote, $tbRemote, "Remote control"))) {
    $pair[0].Tag = @{ Box = $pair[1]; Title = $pair[2] }
    $pair[0].Add_Click({ param($s)
            if ($s.Tag.Box.Text -match '^\w+://') { Show-QrCode $window $s.Tag.Title $s.Tag.Box.Text }
            else { $lblStatus.Text = "That link isn't ready yet. Start streaming first." }
        })
}

# --- Behaviour ---
function Show-If($control, $visible) { $control.Visibility = if ($visible) { "Visible" } else { "Collapsed" } }

# --- The red warning for a PC that can't encode the stream in real time ---
# ffmpeg's "time=" is how much stream it has made. Compared with the real time passed (every 2 s, rather than
# ffmpeg's "speed=", an average since the start that a slow start keeps low for minutes), it shows whether encoding
# keeps up. When it doesn't, the picture falls behind the sound, which no syncing can fix: only lighter settings can.
function Reset-SlowWarning {
    $script:encLast = $null; $script:encSlow = 0; $script:encFast = 0
    Show-If $bdrSlow $false
}

function Update-SlowWarning($streamTime) {
    $made = [TimeSpan]::Zero
    if (-not [TimeSpan]::TryParse($streamTime, [Globalization.CultureInfo]::InvariantCulture, [ref]$made)) { return }   # "N/A" while starting
    $now = [Diagnostics.Stopwatch]::GetTimestamp() / [Diagnostics.Stopwatch]::Frequency
    $last = $script:encLast
    if (-not $last) { $script:encLast = @($made.TotalSeconds, $now); return }
    if ($now - $last[1] -lt 2) { return }
    $speed = ($made.TotalSeconds - $last[0]) / ($now - $last[1])
    $script:encLast = @($made.TotalSeconds, $now)
    if ($speed -lt 0.95) { $script:encSlow++; $script:encFast = 0 } else { $script:encFast++; $script:encSlow = 0 }
    # Shown after ~6 s too slow, gone after ~10 s keeping up, so a brief hiccup (a game loading) doesn't flash it
    if ($script:encSlow -ge 3) {
        $fixes = @()
        $gpu = if ($hasNvidia) { 1 } elseif ($hasAmd) { 2 } elseif ($hasIntel) { 3 } else { 0 }
        if ($script:streamEncoder -eq "cpu" -and $gpu) { $fixes += "set Encoder to $($encoders[$gpu].Name)" }
        if ($script:streamFps -eq 60) { $fixes += "set Frames per second to 30" }
        if ($script:streamQuality -lt $qualities.Count - 1) { $fixes += "pick a lower Quality" }
        $lblSlowTitle.Text = "Your PC can't encode the stream fast enough (only $([int]($speed * 100))% speed)"
        $lblSlowDetail.Text = "The picture is falling behind the sound, so viewers see them out of sync. " +
            $(if ($fixes) { "To fix it, press Stop, $($fixes -join ' or '), then Start streaming again." }
              else { "Your settings are already as light as they go, so close other demanding programs to free up the PC." })
        Show-If $bdrSlow $true
    } elseif ($script:encFast -ge 5) { Show-If $bdrSlow $false }
}

# Programs silenced on this PC come back whenever no stream is running (SessionQuiet.cs)
function Restore-QuietPrograms {
    if ($script:quietFile) { try { [SessionQuiet]::RestoreFromFile($script:quietFile) } catch { } }
}

function Update-Enabled {
    $running = [bool]$script:proc
    $isFile = [bool]$rbFile.IsChecked
    foreach ($c in $rbMonitor, $rbWindow, $rbFile, $cbMonitor, $pnlWindow, $pnlFile, $pnlOptions) { $c.IsEnabled = -not $running }
    Show-If $btnStart (-not $running)
    Show-If $btnStop $running
    $btnStart.IsEnabled = -not $script:startingYouTube -and $script:updateState -ne "downloading"
    Show-If $cbMonitor $rbMonitor.IsChecked
    Show-If $pnlWindow $rbWindow.IsChecked
    Show-If $pnlFile $isFile
    Show-If $pnlPlayer $isFile
    $pnlPlayer.IsEnabled = [bool]$script:player
    # A capture has no position of its own to follow, so its subtitles get a clock you can pause and restart
    Show-If $btnSubsPause (-not $isFile)
    Show-If $btnSubsRestart (-not $isFile)
    # The queue is for file streams: fill it before starting one, or at any time during one
    Show-If $pnlQueue $isFile
    Show-If $pnlSound (-not $isFile)
    if (-not $running) { Restore-QuietPrograms }
    $pnlQueue.IsEnabled = if ($running) { [bool]$script:player } else { $isFile }
}

# Sound choices: the program in the picture, sound devices and any other programs, in any combination.
# $script:soundPicked is what the user last ticked; until they tick something, each source has its own default.
$script:soundPicked = $null
$script:soundQuiet = $null   # sources to silence on this PC, by the same keys
$script:soundRebuilding = $false
# Saved choices name programs rather than their process numbers, which change every time a program starts
function Read-Lines($text) { @("$text" -split "`n" | Where-Object { $_ }) }
$script:soundVolumes = @{}
foreach ($line in Read-Lines $script:settings.SoundVolumes) { if ($line -match '^(.+)=(\d+)$') { $script:soundVolumes[$Matches[1]] = [int]$Matches[2] } }
function Request-SaveSettings { $script:settingsDirty = $true }
function Update-SoundList {
    $choices = @()
    if ($rbWindow.IsChecked) { $choices += @{ Key = "own"; Stable = "own"; Kind = "own"; Label = "The program being streamed" } }
    foreach ($d in $audioDevices) { $choices += @{ Key = "dev:$d"; Stable = "dev:$d"; Kind = "device"; Name = $d; Label = "Device: $d" } }
    foreach ($p in Get-Programs) { $choices += @{ Key = "app:$($p.Id)"; Stable = "prog:$($p.ProcessName)"; Kind = "app"; Id = $p.Id; Label = "Program: $($p.ProcessName)  -  $($p.MainWindowTitle)" } }
    $savedPicks = if ($null -ne $script:settings.SoundPicks) { Read-Lines $script:settings.SoundPicks }
    $picked = if ($null -ne $script:soundPicked) { $script:soundPicked }
              elseif ($null -ne $script:settings.SoundPicks) { @($choices | Where-Object { $savedPicks -contains $_.Stable } | ForEach-Object { $_.Key }) }
              elseif ($rbWindow.IsChecked) { @("own") } else { @() }
    $quietKeys = if ($null -ne $script:soundQuiet) { $script:soundQuiet } else { $saved = Read-Lines $script:settings.SoundQuiet; @($choices | Where-Object { $saved -contains $_.Stable } | ForEach-Object { $_.Key }) }
    $script:soundRebuilding = $true
    $lbSound.Items.Clear()
    foreach ($choice in $choices) {
        $row = New-Object System.Windows.Controls.DockPanel
        $mute = $null
        # A device isn't playing on this PC's speakers to begin with, so only programs get a switch
        if ($choice.Kind -ne "device") {
            $mute = New-Object System.Windows.Controls.CheckBox
            $mute.Style = $window.FindResource("ToggleSwitch")
            $mute.Margin = "8,0,2,0"
            $mute.ToolTip = "Silences this program on your PC while you stream, so you only hear it from the VR world. Viewers still hear it at its normal volume."
            [System.Windows.Automation.AutomationProperties]::SetName($mute, "Mute on PC: $($choice.Label)")
            $mute.IsChecked = $quietKeys -contains $choice.Key
            $mute.Add_Checked({ Save-SoundPicks })
            $mute.Add_Unchecked({ Save-SoundPicks })
            [System.Windows.Controls.DockPanel]::SetDock($mute, "Right")
            [void]$row.Children.Add($mute)
        }
        $box = New-Object System.Windows.Controls.CheckBox
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $choice.Label; $text.TextTrimming = "CharacterEllipsis"; $text.ToolTip = $choice.Label
        $box.Content = $text
        $box.IsChecked = $picked -contains $choice.Key
        $box.Add_Checked({ Save-SoundPicks })
        $box.Add_Unchecked({ Save-SoundPicks })
        # How loud viewers hear this one, under it while it's ticked
        $volume = New-Object System.Windows.Controls.DockPanel
        $volume.Margin = "26,1,0,3"
        $volumeText = New-Object System.Windows.Controls.TextBlock
        $volumeText.Style = $window.FindResource("MutedText")
        $volumeText.MinWidth = 40; $volumeText.TextAlignment = "Right"
        [System.Windows.Controls.DockPanel]::SetDock($volumeText, "Right")
        $slider = New-Object System.Windows.Controls.Slider
        $slider.Minimum = 0; $slider.Maximum = 200; $slider.SmallChange = 5; $slider.LargeChange = 10
        $slider.IsMoveToPointEnabled = $true
        $slider.ToolTip = "How loud viewers hear this. It doesn't change what you hear on your PC."
        [System.Windows.Automation.AutomationProperties]::SetName($slider, "Volume for viewers: $($choice.Label)")
        $percent = if ($script:soundVolumes.ContainsKey($choice.Stable)) { $script:soundVolumes[$choice.Stable] } else { 100 }
        $slider.Value = $percent
        $volumeText.Text = "$percent%"
        $slider.Tag = @{ Text = $volumeText; Stable = $choice.Stable }
        $slider.Add_ValueChanged({ param($s)
                $p = [int][Math]::Round($s.Value / 5) * 5
                $s.Tag.Text.Text = "$p%"
                $script:soundVolumes[$s.Tag.Stable] = $p
                $script:soundDirty = $true
                Request-SaveSettings
            })
        [void]$volume.Children.Add($volumeText)
        [void]$volume.Children.Add($slider)
        Show-If $volume $box.IsChecked
        $stack = New-Object System.Windows.Controls.StackPanel
        [void]$stack.Children.Add($box)
        [void]$stack.Children.Add($volume)
        [void]$row.Children.Add($stack)
        $row.Tag = @{ Choice = $choice; Box = $box; Mute = $mute; Volume = $volume }
        [void]$lbSound.Items.Add($row)
    }
    $script:soundRebuilding = $false
}
function Save-SoundPicks {
    if ($script:soundRebuilding) { return }
    foreach ($row in $lbSound.Items) { Show-If $row.Tag.Volume $row.Tag.Box.IsChecked }
    $script:soundPicked = @($lbSound.Items | Where-Object { $_.Tag.Box.IsChecked } | ForEach-Object { $_.Tag.Choice.Key })
    $script:soundQuiet = @($lbSound.Items | Where-Object { $_.Tag.Mute -and $_.Tag.Mute.IsChecked } | ForEach-Object { $_.Tag.Choice.Key })
    # Ones not in the list just now (a closed program, or "the program being streamed" while on Monitor) stay as they were
    $shown = @($lbSound.Items | ForEach-Object { $_.Tag.Choice.Stable })
    $keepPicks = @(Read-Lines $script:settings.SoundPicks | Where-Object { $shown -notcontains $_ })
    if ($null -eq $script:settings.SoundPicks -and -not $rbWindow.IsChecked) { $keepPicks = @("own") }
    $keepQuiet = @(Read-Lines $script:settings.SoundQuiet | Where-Object { $shown -notcontains $_ })
    $script:settings.SoundPicks = (@($keepPicks) + @($lbSound.Items | Where-Object { $_.Tag.Box.IsChecked } | ForEach-Object { $_.Tag.Choice.Stable })) -join "`n"
    $script:settings.SoundQuiet = (@($keepQuiet) + @($lbSound.Items | Where-Object { $_.Tag.Mute -and $_.Tag.Mute.IsChecked } | ForEach-Object { $_.Tag.Choice.Stable })) -join "`n"
    Request-SaveSettings
    if ($script:soundFile) { Send-SoundPicks }
}
# Tells the running stream which sources to use (SoundMixer.cs re-reads this file). It's replaced in one step,
# so the stream never reads half of it.
function Send-SoundPicks {
    $keys = @(); $pids = @()
    foreach ($row in $lbSound.Items) {
        if (-not $row.Tag.Box.IsChecked) { continue }
        $choice = $row.Tag.Choice
        $quiet = if ($row.Tag.Mute -and $row.Tag.Mute.IsChecked) { "`tquiet" } else { "" }
        $percent = if ($script:soundVolumes.ContainsKey($choice.Stable)) { $script:soundVolumes[$choice.Stable] } else { 100 }
        if ($percent -ne 100) { $quiet += "`tvol=" + ($percent / 100).ToString([Globalization.CultureInfo]::InvariantCulture) }
        switch ($choice.Kind) {
            "own" { $keys += "app:$($script:soundOwnPid)$quiet"; $pids += $script:soundOwnPid }
            "app" { $keys += "app:$($choice.Id)$quiet"; $pids += $choice.Id }
            "device" { $keys += "dev:$($choice.Name)$quiet" }
        }
    }
    if ([int]$script:settings.SoundDelay -gt 0) { $keys += "delay=$([int]$script:settings.SoundDelay)" }
    $script:soundDirty = $false
    $script:soundPids = @($pids | Select-Object -Unique)
    $part = "$($script:soundFile).part"
    [IO.File]::WriteAllLines($part, [string[]]@($keys | Select-Object -Unique))
    foreach ($try in 1..5) {
        try { Move-Item -LiteralPath $part -Destination $script:soundFile -Force -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 30 }
    }
    $lblStatus.Text = "Couldn't change the sound just now. Tick it again."
}
$btnRefreshSound.Add_Click({ Update-SoundList })
foreach ($c in $rbMonitor, $rbWindow, $rbFile) { $c.Add_Checked({ if ($script:windowReady) { Update-Enabled; Update-SoundList } }) }
$btnRefresh.Add_Click({ Update-WindowList })

# What's picked in the window is remembered for next time (settings.json, written shortly after each change)
function Save-Choices {
    if (-not $script:windowReady) { return }
    $s = $script:settings
    $s.Source = if ($rbWindow.IsChecked) { "window" } elseif ($rbFile.IsChecked) { "file" } else { "monitor" }
    $s.Monitor = "$($cbMonitor.SelectedIndex)"
    if ($cbWindow.SelectedIndex -ge 0 -and $cbWindow.SelectedIndex -lt @($script:windowProcs).Count) {
        $script:pickedProgram = $script:windowProcs[$cbWindow.SelectedIndex].ProcessName
        $s.WindowProgram = $script:pickedProgram
    }
    $s.Quality = $qualities[[Math]::Max(0, $cbQuality.SelectedIndex)].Name
    $s.Encoder = $encoders[[Math]::Max(0, $cbEncoder.SelectedIndex)].Value
    $s.Fps = "$($fpsChoices[[Math]::Max(0, $cbFps.SelectedIndex)])"
    $s.Tunnel = $tunnels[[Math]::Max(0, $cbTunnel.SelectedIndex)].Value
    $s.Public = [bool]$chkPublic.IsChecked
    $s.Loop = [bool]$chkLoop.IsChecked
    $s.Repeat = [bool]$chkRepeat.IsChecked
    Request-SaveSettings
}
foreach ($c in $cbMonitor, $cbWindow, $cbQuality, $cbEncoder, $cbTunnel, $cbFps) { $c.Add_SelectionChanged({ Save-Choices }) }
foreach ($c in $chkPublic, $chkLoop, $chkRepeat) { $c.Add_Click({ Save-Choices }) }
foreach ($c in $rbMonitor, $rbWindow, $rbFile) { $c.Add_Checked({ Save-Choices }) }
$chkLoop.IsChecked = [bool]$script:settings.Loop
$chkRepeat.IsChecked = [bool]$script:settings.Repeat
switch ($script:settings.Source) { "window" { $rbWindow.IsChecked = $true } "file" { $rbFile.IsChecked = $true } }

# Holds all the captured sound back, for when viewers hear things before they see them
function Update-SoundDelayLabel { $lblSoundDelay.Text = "$([int]$script:settings.SoundDelay) ms" }
$sliderSoundDelay.Value = [Math]::Max(0, [Math]::Min(1000, [int]$script:settings.SoundDelay))
Update-SoundDelayLabel
$sliderSoundDelay.Add_ValueChanged({
        $script:settings.SoundDelay = [int]([Math]::Round($sliderSoundDelay.Value / 10) * 10)
        Update-SoundDelayLabel
        $script:soundDirty = $true
        Request-SaveSettings
    })

function Set-File($path) {
    # Subtitles chosen for one video don't belong on another
    if ($path -ne $tbFile.Text -and $script:overlay) { Clear-Subs; $script:currentVideo = $null; $script:subsNotice = "" }
    $tbFile.Text = $path
    $rbFile.IsChecked = $true
}
function Select-MediaFile([switch]$Many) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "Pick a video or music file to stream"
    $dialog.Filter = "Video and music|*.mp4;*.mkv;*.webm;*.mov;*.avi;*.wmv;*.flv;*.ts;*.m4v;*.mp3;*.wav;*.flac;*.ogg;*.m4a;*.aac;*.opus|All files|*.*"
    $dialog.Multiselect = [bool]$Many
    if ($dialog.ShowDialog($window)) { $dialog.FileNames }
}
$btnBrowse.Add_Click({ $picked = Select-MediaFile; if ($picked) { Set-File @($picked)[0]; $script:startItem = $null } })
$btnChange.Add_Click({ $picked = Select-MediaFile; if ($picked) { Switch-File @($picked)[0] } })
$btnSkip.Add_Click({ if ($script:player -and $script:queue.Count) { Start-QueueItem 0 } })
$btnAdd.Add_Click({ $picked = Select-MediaFile -Many; if ($picked) { Add-ToQueue $picked } })
$btnPlayNow.Add_Click({ if ($script:queue.Count) { Start-QueueItem ([Math]::Max(0, $lbQueue.SelectedIndex)) } })
$btnRemove.Add_Click({
        $i = $lbQueue.SelectedIndex
        if ($i -ge 0) { $script:queue.RemoveAt($i); Update-Queue $i }
    })
$btnUp.Add_Click({ Move-QueueItem -1 })
$btnDown.Add_Click({ Move-QueueItem 1 })

# Drops anywhere: on the queue panel they queue up, elsewhere they play or get picked.
# Preview events, since a text box would otherwise take the drop for itself.
$window.Add_PreviewDragOver({ param($s, $e)
        if ($e.Data.GetDataPresent("FileDrop")) { $e.Effects = "Copy"; $e.Handled = $true }
        elseif ($e.Data.GetDataPresent("vvs-move")) { $e.Effects = "Move"; $e.Handled = $true }
    })
$window.Add_PreviewDrop({ param($s, $e)
        if ($e.Data.GetDataPresent("vvs-move")) {
            $e.Handled = $true
            # The row whose middle is below the pointer is where it lands
            $to = $script:queue.Count - 1
            $y = $e.GetPosition($lbQueue).Y
            for ($i = 0; $i -lt $script:queue.Count; $i++) {
                $row = $lbQueue.ItemContainerGenerator.ContainerFromIndex($i)
                if ($row -and $y -lt $row.TranslatePoint((New-Object System.Windows.Point(0, ($row.ActualHeight / 2))), $lbQueue).Y) { $to = $i; break }
            }
            Move-QueueItemTo ([int]$e.Data.GetData("vvs-move")) $to
            return
        }
        if (-not $e.Data.GetDataPresent("FileDrop")) { return }
        $e.Handled = $true
        $files = @($e.Data.GetData("FileDrop"))
        $at = $e.GetPosition($pnlQueue)
        $onQueue = $pnlQueue.IsVisible -and $at.X -ge 0 -and $at.Y -ge 0 -and $at.X -le $pnlQueue.ActualWidth -and $at.Y -le $pnlQueue.ActualHeight
        if ($onQueue -and $pnlQueue.IsEnabled) { Add-ToQueue $files }
        elseif ($script:player) { Switch-File $files[0] }
        elseif ($script:proc) { Show-Notice "You can only swap a file for another file. To stream this one, press Stop first (the video player link will change)." }
        else { Set-File $files[0]; $script:startItem = $null }
    })
$window.Add_ContentRendered({ [void][UI.Win]::SetForegroundWindow((New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle) })
# A message window rather than the status line, which the timer rewrites twice a second while streaming
function Show-Notice($text) { [void](Show-Message $window $text) }

# Viewers were cut off and need the new video player link. The person is often in VR or in another program, so a
# line in the window isn't enough: this also shows a Windows notification, flashes the taskbar button and plays a
# sound. None of it waits for an answer, so the stream carries on.
function Show-NewLinkAlert($why) {
    $copied = if ($script:linkCopied) { " It's copied to the clipboard." } else { " Press Copy next to it in the window." }
    $text = "$why Viewers need the new video player link.$copied"
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        if (-not $script:trayIcon) {
            $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
            $ico = Join-Path $PSScriptRoot "app.ico"
            $script:trayIcon.Icon = if (Test-Path -LiteralPath $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Warning }
            $script:trayIcon.Text = $Title
            # Clicking the notification brings the window back, with the new link in it
            $script:trayIcon.Add_BalloonTipClicked({ $window.WindowState = "Normal"; [void]$window.Activate() })
            $script:trayIcon.Add_MouseClick({ $window.WindowState = "Normal"; [void]$window.Activate() })
        }
        $script:trayIcon.Visible = $true
        $script:trayIcon.ShowBalloonTip(15000, "New video player link", $text, [System.Windows.Forms.ToolTipIcon]::Warning)
    } catch { }
    try { [UI.Win]::Flash((New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle) } catch { }
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
}

# One argument for a Windows program's command line, whatever it holds: backslashes only count as escapes right
# before a quote, so those (and any at the very end, before the closing quote) are doubled
function Quote($s) { '"' + ("$s" -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }

# What's in the file, or nothing (with a message) if ffmpeg can't play it
function Get-MediaInfo($path) {
    $ErrorActionPreference = "Continue"
    $info = & $ffprobeExe -v error -show_chapters -show_entries "stream=index,codec_type,codec_name:stream_disposition=attached_pic:stream_tags=language,title:format=duration" `
        -of json $path | ConvertFrom-Json
    $hasVideo = [bool]($info.streams | Where-Object { $_.codec_type -eq "video" -and $_.disposition.attached_pic -ne 1 })
    $hasAudio = [bool]($info.streams | Where-Object { $_.codec_type -eq "audio" })
    if (-not $hasVideo -and -not $hasAudio) { $lblStatus.Text = "That file has no video or sound ffmpeg can read."; return }
    $duration = 0.0
    [void][double]::TryParse([string]$info.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
    # Subtitle tracks that are text. The others (from discs) are pictures, which can't become an .srt.
    $subtitleNumber = 0
    $tracks = @($info.streams | Where-Object { $_.codec_type -eq "subtitle" } | ForEach-Object {
            @{ Index = $_.index; SubIndex = ($subtitleNumber++); Language = "$($_.tags.language)"; Title = "$($_.tags.title)"
               IsAss = $_.codec_name -in "ass", "ssa"
               IsText = $_.codec_name -in "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text" }
        })
    $sounds = @($info.streams | Where-Object { $_.codec_type -eq "audio" } | ForEach-Object { @{ Language = "$($_.tags.language)"; Title = "$($_.tags.title)" } })
    $chapters = @($info.chapters | Where-Object { $_ } | ForEach-Object {
            $start = 0.0
            [void][double]::TryParse([string]$_.start_time, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$start)
            @{ Start = $start; Title = "$($_.tags.title)" }
        })
    @{ Duration = $duration; HasVideo = $hasVideo; HasAudio = $hasAudio; Tracks = $tracks; Sounds = $sounds; Chapters = $chapters }
}

# Probe the file and start a PipePlayer for it; the stream script then reads from the player's pipes.
# The stream's picture size can't change once it's running, so it's a fixed 16:9 size from the chosen
# quality rather than the first file's size. That way a later file isn't stuck with that file's shape.
function New-FilePlayer($path, $height, $stream, $media) {
    if ($stream) { $file = $stream.File; $audioFile = $stream.AudioFile; $options = $stream.Options; $media = @{ Duration = $stream.Duration; HasVideo = $stream.HasVideo; HasAudio = $stream.HasAudio } }
    else { $file = $path; $audioFile = $null; $options = "" }
    if (-not $media) { return }
    $w = [int][Math]::Round($height * 16 / 9 / 2) * 2
    $tag = "vvs-$PID-$([Environment]::TickCount)"
    $p = New-Object PipePlayer($ffmpegExe, $file, $audioFile, $options, $tag, $w, $height, $script:Fps, $media.Duration, $media.HasVideo, $media.HasAudio)
    $p.Loop = [bool]$chkLoop.IsChecked
    $p.VolumePercent = [int]$sliderVolume.Value
    $p.EvenOutVolume = [bool]$chkEvenOut.IsChecked
    if ($script:assSubs) { $p.SubsFile = $script:assSubs.File; $p.SubsTrack = $script:assSubs.Track; $p.SubsDelay = $script:overlay.Offset }
    $script:cardKey = ""
    $p.Start()
    @{ Player = $p; Tag = $tag; Size = "${w}x$height" }
}

function Show-NowPlaying($name) {
    $lblNow.Text = $name
    $lblNow.ToolTip = $name
}

# Play another file in the running stream. Viewers stay connected and every link stays the same.
function Switch-File($path) {
    if (-not $script:player) { return }   # the stream ended while the file picker was open
    $media = Get-MediaInfo $path
    if (-not $media) { Show-Notice "Can't play that file, so the current one keeps playing:`n$path"; return }
    Start-Media $path $media
}

function Start-Media($path, $media, $subs) {
    $script:ytLoading = $null
    $script:ytNotice = ""
    $script:player.Load($path, $null, "", $media.Duration, $media.HasVideo, $media.HasAudio)
    $tbFile.Text = $path
    $name = [IO.Path]::GetFileName($path)
    Show-NowPlaying $name
    Start-VideoSubs @{ Path = $path; Name = $name; Tracks = $media.Tracks; Sounds = $media.Sounds; Chapters = $media.Chapters } $subs
}

# --- Background work, so finding subtitles never freezes the window. Its results arrive on the timer below. ---
$script:tasks = New-Object System.Collections.ArrayList
$script:taskPool = [runspacefactory]::CreateRunspacePool(1, 6)
$script:taskPool.Open()
$subtitlesScript = Join-Path $PSScriptRoot "Subtitles.ps1"

# $work runs on its own with Subtitles.ps1 available; $done later gets its result and why it failed (if it did)
function Start-SubtitleTask([scriptblock]$work, $arguments, [scriptblock]$done, $tag) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:taskPool
    $setup = '$ErrorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; . $args[0]; $script:OpenSubtitlesApi = $args[1]; $script:AppData = $args[2]; ' +
             '$passed = $args[4]; & ([scriptblock]::Create($args[3])) @passed'
    [void]$ps.AddScript($setup).AddArgument($subtitlesScript).AddArgument($script:OpenSubtitlesApi).AddArgument($script:AppData).AddArgument($work.ToString()).AddArgument(@($arguments))
    [void]$script:tasks.Add(@{ PS = $ps; Async = $ps.BeginInvoke(); Done = $done; Tag = $tag })
}

function Update-SubtitleTasks {
    foreach ($task in @($script:tasks)) {
        if (-not $task.Async.IsCompleted) { continue }
        $script:tasks.Remove($task)
        $result = $null; $why = ""
        try {
            $result = @($task.PS.EndInvoke($task.Async))
            if ($task.PS.Streams.Error.Count) { $why = $task.PS.Streams.Error[0].Exception.Message }
        } catch { $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
        $task.PS.Dispose()
        $value = if ($result.Count -eq 1) { $result[0] } elseif ($result.Count) { $result }
        & $task.Done $value $why $task.Tag
    }
}

# --- Subtitles ---
$subtitleTextFile = Join-Path $env:TEMP "VRVideoStreamer-subs-$PID.txt"
$script:overlay = New-Object SubtitleOverlay($subtitleTextFile)
$script:overlay.Start()
$script:subsName = ""
$script:subsRequest = 0        # goes up with each change, so an answer that arrives too late is ignored
$script:subsNotice = ""
$script:currentVideo = $null   # what's playing, and what's known about its subtitles

function Update-SubsLabel {
    $lblSubs.Text = if ($script:aiJob) {
        $done = Format-Time $script:overlay.LastCueEnd
        $of = if ($script:player -and $script:player.Duration -gt 0) { " of $(Format-Time $script:player.Duration)" } else { "" }
        "Subtitles: AI is listening, $done$of done"
    }
    elseif ($script:subsWaiting) { "Getting subtitles..." } elseif ($script:subsName) { "Subtitles: $($script:subsName)" } else { "Subtitles off" }
    $off = $script:overlay.Offset
    $lblSubsOffset.Text = if ($script:subsName -and $off) { "{0:+0.0;-0.0} s" -f $off } else { "" }
}

# Styled subtitles (.ass) keep their fonts, colours and positions by being drawn as the video is decoded. That needs a
# video being played, so a monitor or program stream shows the same lines as plain text instead.
$script:assSubs = $null
function Test-Libass {
    if ($null -eq $script:hasLibass) {
        $ErrorActionPreference = "Continue"
        $script:hasLibass = [bool](& $ffmpegExe -hide_banner -filters 2>$null | Where-Object { $_ -match '\ssubtitles\s' })
    }
    $script:hasLibass
}
function Update-PlayerAss {
    if (-not $script:player) { return }
    $file = if ($script:assSubs) { $script:assSubs.File }
    $track = if ($script:assSubs) { $script:assSubs.Track } else { -1 }
    if ($script:player.SubsFile -eq $file -and $script:player.SubsTrack -eq $track -and $script:player.SubsDelay -eq $script:overlay.Offset) { return }
    $script:player.SubsFile = $file
    $script:player.SubsTrack = $track
    $script:player.SubsDelay = $script:overlay.Offset
    $script:player.Restart()
}
function Set-AssSubs($file, $track, $name, $streamIndex = 0) {
    $script:subsWaiting = $false
    $script:overlay.Clear()
    $script:assSubs = @{ File = $file; Track = $track }
    $script:subsSource = @{ File = $file; Index = $streamIndex }   # for translating them
    $script:subsName = $name
    Update-PlayerAss
    Update-SubsLabel
}

function Set-Subs($path, $name, [switch]$Quiet) {
    $script:subsWaiting = $false
    if ($path -match '\.(ass|ssa)$') {
        if (($script:player -or $rbFile.IsChecked) -and (Test-Libass)) { Set-AssSubs (Get-Item -LiteralPath $path).FullName -1 $name; return }
        try {
            $f = Get-Item -LiteralPath $path
            $plain = Get-SubtitleCachePath "ass" (($f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks) -join "|")
            if (-not (Test-Path -LiteralPath $plain)) { [void](Save-EmbeddedSubtitle $ffmpegExe $f.FullName 0 $plain) }
            $path = $plain
            $script:subsNotice = "These subtitles show as plain text here. Their fonts and positions need a video file playing."
        } catch { $script:subsNotice = "Can't use those subtitles: $($_.Exception.Message)"; Update-SubsLabel; return }
    }
    if ($script:assSubs) { $script:assSubs = $null; Update-PlayerAss }
    try { $script:overlay.Load($path); $script:subsName = $name; $script:subsSource = @{ Srt = $path } }
    catch {
        $why = "Can't use those subtitles: $($_.Exception.InnerException.Message)"
        if ($Quiet) { $script:subsNotice = $why } else { Update-SubsLabel; Show-Notice $why }
    }
    $btnSubsPause.Content = "Pause"
    Update-SubsLabel
}

function Clear-Subs {
    Stop-AiSubs
    $script:subsRequest++
    $script:subsWaiting = $false
    $script:overlay.Clear()
    $script:subsName = ""
    $script:subsSource = $null
    if ($script:assSubs) { $script:assSubs = $null; Update-PlayerAss }
    Update-SubsLabel
}

# --- AI subtitles: Whisper listens to the sound ahead of what's playing, and lines appear as it writes them ---
$script:aiJob = $null
$script:aiChecked = $false
$aiModels = Join-Path $script:AppData "models"   # outside this folder, so zipping it stays small
# Left behind if the program was closed partway through
Get-ChildItem -LiteralPath (Join-Path $script:AppData "subtitles") -Filter "*.part.srt" -File -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force } catch { } }

# The better model needs a real graphics card to keep up; the smaller one managed 2.2x real time on a CPU alone (16 cores)
function Get-AiModel {
    $card = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA|Radeon RX|Radeon Pro|Arc" }
    if ($card) { "ggml-large-v3-turbo-q5_0.bin" } else { "ggml-small-q5_1.bin" }
}

# The main FFmpeg if it can run Whisper (a full build can), otherwise the one downloaded just for this
function Find-AiTool {
    if ($script:aiChecked) { return $script:aiTool }
    $ErrorActionPreference = "Continue"
    $mainCan = & $ffmpegExe -hide_banner -filters 2>$null | Select-String -Pattern '\bwhisper\b' -Quiet
    $script:aiTool = if ($mainCan) { $ffmpegExe } else {
        $own = Join-Path $toolsFolder "whisper\ffmpeg.exe"
        if (Test-Path -LiteralPath $own) { $own }
    }
    $script:aiChecked = [bool]$script:aiTool
    $script:aiTool
}

function Confirm-AiTools {
    $model = Get-AiModel
    $tool = Find-AiTool
    if ($tool -and (Test-Path -LiteralPath (Join-Path $aiModels $model))) { return $true }
    if (-not (Install-WhisperWithDialog $toolsFolder $window $model $aiModels (-not $tool))) { return $false }
    [bool](Find-AiTool)
}

function Get-AiPath($video, $translate) {
    $id = if (Test-OnlineLink $video.Path) { $video.Path } else {
        $f = Get-Item -LiteralPath $video.Path
        ($f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks) -join "|"
    }
    Get-SubtitleCachePath "ai" "$id|$([bool]$translate)"
}

function Stop-AiSubs {
    $job = $script:aiJob
    if (-not $job) { return }
    $script:aiJob = $null
    try { if (-not $job.Proc.HasExited) { Stop-Process -Id $job.Proc.Id -Force; $job.Proc.WaitForExit(2000) | Out-Null } } catch { }
    foreach ($f in $job.Part, $job.Log) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Start-AiSubs($video, $translate) {
    Stop-AiSubs
    $script:subsNotice = ""
    $script:subsRequest++
    $name = if ($translate) { "AI-made, in English" } else { "AI-made" }
    $final = Get-AiPath $video $translate
    if (Test-Path -LiteralPath $final) { Set-Subs $final $name -Quiet; return }
    # Over the internet, YouTube's sound comes through the same local address the player uses
    $sound = if (Test-OnlineLink $video.Path) { $video.AudioUrl } else { $video.Path }
    if (-not $sound) { $script:subsNotice = "Start the stream first, so the YouTube video's sound is available for AI subtitles."; Update-SubsLabel; return }
    $partName = [IO.Path]::GetFileNameWithoutExtension($final) + ".part.srt"
    $net = if ($sound -match '^http') { "-reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 5 $($video.SoundOptions) " } else { "" }
    # Relative paths from a working folder, because a full path's colon and any apostrophe would break a filter
    # "translate" only when wanted: even translate=0 measured about 20x slower than leaving it out (25x vs about 1x real time)
    $filter = "whisper=model=models/$(Get-AiModel):language=auto:queue=10$(if ($translate) { ':translate=1' }):destination=subtitles/${partName}:format=srt"
    $log = Join-Path $env:TEMP "VRVideoStreamer-ai-$PID.txt"
    New-Item -ItemType Directory -Force (Get-SubtitleCacheFolder) | Out-Null
    $proc = Start-Process (Find-AiTool) -PassThru -WindowStyle Hidden -WorkingDirectory $script:AppData -RedirectStandardError $log -ArgumentList (
        "-hide_banner -loglevel error -nostdin $net-i `"$sound`" -vn -sn -af `"$filter`" -f null -")
    $null = $proc.Handle   # without this, Windows' exit code isn't available later
    # The stream matters more: on a PC without a strong graphics card this could otherwise take the CPU from it
    try { $proc.PriorityClass = "BelowNormal" } catch { }
    $script:overlay.Clear()
    $script:overlay.RestartClock()
    $script:subsWaiting = $false
    $script:subsName = $name
    $script:subsSource = $null   # nothing to translate until the AI has finished
    $script:aiJob = @{ Proc = $proc; Part = (Join-Path (Get-SubtitleCacheFolder) $partName); Final = $final; Log = $log; Name = $name; Size = -1 }
    Update-SubsLabel
}

function Update-AiSubs {
    $job = $script:aiJob
    if (-not $job) { return }
    $size = if (Test-Path -LiteralPath $job.Part) { (Get-Item -LiteralPath $job.Part).Length } else { 0 }
    if ($size -ne $job.Size -and $size -gt 0) {
        $job.Size = $size
        try { $script:overlay.Update($job.Part) } catch { }
    }
    if ($job.Proc.HasExited) {
        $script:aiJob = $null
        $finished = $job.Proc.ExitCode -eq 0 -and $size -gt 0
        if ($finished) {
            Move-Item -LiteralPath $job.Part -Destination $job.Final -Force
            $script:overlay.Update($job.Final)
            $script:subsSource = @{ Srt = $job.Final }
        } elseif ($size -eq 0 -and $job.Proc.ExitCode -eq 0) {
            $script:subsName = ""
            $script:subsNotice = "AI subtitles found no speech in this video."
        } else {
            $why = (Get-Content -LiteralPath $job.Log -ErrorAction SilentlyContinue | Select-Object -Last 1)
            $script:subsNotice = "AI subtitles stopped partway: $why"
            Remove-Item -LiteralPath $job.Part -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $job.Log -Force -ErrorAction SilentlyContinue
    }
    Update-SubsLabel
}

function Test-Language($tag, $code) {
    $short = ($script:SubtitleLanguages | Where-Object { $_.Code -eq $code }).Short
    $tag -match "^($code)([-_.]|$)" -or ($short -and $tag -match "^($short)$")
}

# Everything already available for a video, best first, with no searching needed
function Get-SubChoices($video) {
    if (-not $video) { return }
    $code = $script:settings.SubsLanguage
    $choices = New-Object Collections.ArrayList
    if ($video.Path -and -not (Test-OnlineLink $video.Path) -and (Test-Path -LiteralPath $video.Path -PathType Leaf)) {
        # Subtitle files beside the video, named after it ("movie.srt", "movie.en.ass")
        $stem = [IO.Path]::GetFileNameWithoutExtension($video.Path)
        foreach ($f in Get-ChildItem -LiteralPath (Split-Path $video.Path) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in ".srt", ".ass", ".ssa" }) {
            if ($f.Name.StartsWith("$stem.", [StringComparison]::OrdinalIgnoreCase)) {
                [void]$choices.Add(@{ Kind = "file"; Path = $f.FullName; Label = $f.Name; Note = "beside this file"; Language = ($f.BaseName.Substring($stem.Length).TrimStart('.')) })
            }
        }
        foreach ($t in @($video.Tracks)) {
            if (-not $t -or -not $t.IsText) { continue }
            $known = $script:SubtitleLanguages | Where-Object { Test-Language $t.Language $_.Code } | Select-Object -First 1
            $label = if ($known) { $known.Name } elseif ($t.Language) { $t.Language } else { "Track $($t.Index)" }
            if ($t.Title) { $label = "$label, $($t.Title)" }
            [void]$choices.Add(@{ Kind = "embedded"; Index = $t.Index; SubIndex = $t.SubIndex; IsAss = $t.IsAss; Path = $video.Path; Label = $label; Note = "inside this file"; Language = $t.Language })
        }
    }
    foreach ($c in @($video.Captions)) {
        if (-not $c) { continue }
        [void]$choices.Add(@{ Kind = "caption"; Url = $c.Url; Label = $c.Name; Language = $c.Code; Auto = $c.Auto; Note = $(if ($c.Auto) { "YouTube, automatic" } else { "YouTube" }) })
    }
    # AI-made ones from an earlier time, ready without any wait
    if ($video.Path -and ((Test-OnlineLink $video.Path) -or (Test-Path -LiteralPath $video.Path -PathType Leaf))) {
        foreach ($translated in $false, $true) {
            $made = Get-AiPath $video $translated
            if (Test-Path -LiteralPath $made) {
                [void]$choices.Add(@{ Kind = "file"; Path = $made; Label = $(if ($translated) { "AI-made, in English" } else { "AI-made" }); Note = "from earlier"; Language = "ai" })
            }
        }
    }
    $choices
}

# The one to use by itself: a file you put beside the video, then a track inside it, then YouTube's own over its automatic
function Select-AutoChoice($choices) {
    $code = $script:settings.SubsLanguage
    $files = @($choices | Where-Object { $_.Kind -eq "file" })
    $named = @($files | Where-Object { Test-Language $_.Language $code })
    if ($named) { return $named[0] }
    $plain = @($files | Where-Object { -not $_.Language })
    if ($plain) { return $plain[0] }
    $track = @($choices | Where-Object { $_.Kind -eq "embedded" -and (Test-Language $_.Language $code) })
    if ($track) { return $track[0] }
    $own = @($choices | Where-Object { $_.Kind -eq "caption" -and -not $_.Auto -and (Test-Language $_.Language $code) })
    if ($own) { return $own[0] }
    # "en-orig" is what was actually said; plain "en" on a foreign video is a machine translation
    $auto = @($choices | Where-Object { $_.Kind -eq "caption" -and $_.Auto -and (Test-Language $_.Language $code) } |
            Sort-Object @{ Expression = { $_.Language -notmatch 'orig' } })
    if ($auto) { return $auto[0] }
    $made = @($choices | Where-Object { $_.Language -eq "ai" })
    if ($made) { return $made[0] }
}

function Use-SubChoice($choice, [switch]$Quiet) {
    Stop-AiSubs
    $script:subsNotice = ""
    $script:subsRequest++
    $label = "$($choice.Label) ($($choice.Note))"
    if ($choice.Kind -eq "file") { Set-Subs $choice.Path $label -Quiet:$Quiet; return }
    if ($choice.IsAss -and ($script:player -or $rbFile.IsChecked) -and (Test-Libass)) { Set-AssSubs (Get-Item -LiteralPath $choice.Path).FullName $choice.SubIndex $label $choice.Index; return }
    $path = if ($choice.Kind -eq "caption") {
        Get-SubtitleCachePath "youtube" (($script:currentVideo.Path, $choice.Language, $choice.Auto) -join "|")
    } else {
        $f = Get-Item -LiteralPath $choice.Path
        Get-SubtitleCachePath "track" (($f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks, $choice.Index) -join "|")
    }
    if (Test-Path -LiteralPath $path) { Set-Subs $path $label -Quiet:$Quiet; return }
    # Whatever's showing stays until the new ones are ready, or if they can't be had
    $script:subsWaiting = $true
    Update-SubsLabel
    $tag = @{ Request = $script:subsRequest; Label = $label }
    $finish = {
        param($saved, $why, $tag)
        if ($tag.Request -ne $script:subsRequest) { return }   # moved on since asking
        $script:subsWaiting = $false
        if ($why) { $script:subsNotice = $why; Update-SubsLabel; return }
        Set-Subs "$saved" $tag.Label -Quiet
    }
    if ($choice.Kind -eq "caption") {
        Start-SubtitleTask { param($url, $path, $ytDlp, $videoUrl, $language) Save-YouTubeCaption $url $path $ytDlp $videoUrl $language } @($choice.Url, $path, $script:ytDlpExe, $script:currentVideo.Path, $choice.Language) $finish $tag
    } else {
        Start-SubtitleTask { param($ffmpeg, $file, $index, $path) Save-EmbeddedSubtitle $ffmpeg $file $index $path } @($ffmpegExe, $choice.Path, $choice.Index, $path) $finish $tag
    }
}

# A new video has started. $chosen is what was picked for it in the queue, if anything.
function Start-VideoSubs($video, $chosen) {
    $script:currentVideo = $video
    $script:subsNotice = ""
    Show-If $btnAudio (@($video.Sounds).Count -gt 1)
    Show-If $btnChapters (@($video.Chapters | Where-Object { $_ }).Count -gt 0)
    if ($chosen -and $chosen.Keep) { return }   # chosen just before pressing Start
    Clear-Subs
    if ($chosen -and $chosen.Off) { return }
    if ($chosen -and $chosen.Ai) { Start-AiSubs $video $chosen.Translate; return }
    if ($chosen -and $chosen.Choice) { Use-SubChoice $chosen.Choice -Quiet; return }
    if ($chosen -and $chosen.Path) { Set-Subs $chosen.Path $chosen.Name -Quiet; return }
    if (-not $script:settings.SubsAuto) { return }
    $best = Select-AutoChoice @(Get-SubChoices $video)
    if ($best) { Use-SubChoice $best -Quiet; return }
    # Nothing with the video: OpenSubtitles, only for your own files and only a version made for that exact file
    if ($video.Path -and -not (Test-OnlineLink $video.Path)) {
        $tag = @{ Request = $script:subsRequest }
        Start-SubtitleTask { param($file, $language) Find-ExactOpenSubtitles $file $language } @($video.Path, $script:settings.SubsLanguage) {
            param($found, $why, $tag)
            if ($tag.Request -ne $script:subsRequest -or $why -or -not $found -or -not $found.Path) { return }
            Set-Subs "$($found.Path)" "$($found.Name) (OpenSubtitles)" -Quiet
        } $tag
    }
}

function Select-SrtFile {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "Pick a subtitle file"
    $dialog.Filter = "Subtitles (*.srt, *.ass, *.ssa)|*.srt;*.ass;*.ssa|All files|*.*"
    if ($dialog.ShowDialog($window)) { $dialog.FileName }
}

# The video the menu is about when nothing is playing yet: whatever's in the file box
function Get-MenuVideo {
    if ($script:currentVideo) { return $script:currentVideo }
    if ($rbFile.IsChecked -and $tbFile.Text -and -not (Test-OnlineLink $tbFile.Text) -and (Test-Path -LiteralPath $tbFile.Text -PathType Leaf)) {
        $media = Get-MediaInfo $tbFile.Text
        return @{ Path = $tbFile.Text; Name = [IO.Path]::GetFileName($tbFile.Text); Tracks = $media.Tracks }
    }
}

function New-MenuItem($header, $note, $action, $choice, $checked) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $header
    if ($note) { $item.InputGestureText = $note }
    $item.Tag = @{ Action = $action; Choice = $choice }
    if ($checked) { $item.IsChecked = $true }
    if ($action) { $item.Add_Click({ param($s) Invoke-SubsMenu $s.Tag }) }
    $item
}

# The one subtitles menu: what the video already has, then the ways to get others, then the automatic setting.
# $forItem = a video in the queue, which keeps its choice until its turn comes.
function Show-SubsMenu($button, $forItem) {
    $script:subsMenuItem = $forItem
    $menu = New-Object System.Windows.Controls.ContextMenu
    $code = $script:settings.SubsLanguage
    if ($forItem) {
        $chosen = $forItem.Subs
        [void]$menu.Items.Add((New-MenuItem "Automatic" "" "default" $null (-not $chosen)))
        [void]$menu.Items.Add((New-MenuItem "Off" "" "off" $null ($chosen -and $chosen.Off)))
        $video = if (-not $forItem.IsOnline) { @{ Path = $forItem.Path; Tracks = $forItem.Media.Tracks } }
        $choices = @(Get-SubChoices $video)
        foreach ($c in $choices) { [void]$menu.Items.Add((New-MenuItem $c.Label $c.Note "choice" $c ($chosen -and $chosen.Choice -and $chosen.Choice.Label -eq $c.Label))) }
        if ($forItem.IsOnline) {
            $hint = New-MenuItem "Its own captions show here once it's playing" "" $null $null $false
            $hint.IsEnabled = $false
            [void]$menu.Items.Add($hint)
        }
    } else {
        [void]$menu.Items.Add((New-MenuItem "Off" "" "off" $null (-not $script:subsName -and -not $script:subsWaiting)))
        $video = Get-MenuVideo
        $choices = @(Get-SubChoices $video)
        # Your language at the top; the rest of YouTube's list (often over 100) tucked away
        $others = @()
        foreach ($c in $choices) {
            $isRest = $c.Kind -eq "caption" -and -not (Test-Language $c.Language $code)
            if ($isRest) { $others += $c; continue }
            [void]$menu.Items.Add((New-MenuItem $c.Label $c.Note "choice" $c ($script:subsName -eq "$($c.Label) ($($c.Note))")))
        }
        if ($others) {
            $more = New-MenuItem "Other languages" "$($others.Count) more" $null $null $false
            foreach ($c in ($others | Sort-Object { $_.Label })) { [void]$more.Items.Add((New-MenuItem $c.Label $c.Note "choice" $c ($script:subsName -eq "$($c.Label) ($($c.Note))"))) }
            [void]$menu.Items.Add($more)
        }
        if ($video -and -not $choices) {
            $none = New-MenuItem "This video has no subtitles of its own" "" $null $null $false
            $none.IsEnabled = $false
            [void]$menu.Items.Add($none)
        }
        if ($video -and @($video.Tracks | Where-Object { $_ -and -not $_.IsText }).Count) {
            $pictures = New-MenuItem "Picture-based tracks in this file can't be used" "" $null $null $false
            $pictures.IsEnabled = $false
            [void]$menu.Items.Add($pictures)
        }
    }
    $line = New-Object System.Windows.Controls.Separator
    $line.Style = $window.FindResource("MenuLine")
    [void]$menu.Items.Add($line)
    # A monitor or program has no file to listen to
    if ($forItem -or $video -or ($rbFile.IsChecked -and (Test-OnlineLink $tbFile.Text))) {
        $aiTicked = if ($forItem) { $forItem.Subs -and $forItem.Subs.Ai -and -not $forItem.Subs.Translate } else { [bool]$script:aiJob }
        [void]$menu.Items.Add((New-MenuItem "Generate with AI" "on this PC" "ai" $null $aiTicked))
        [void]$menu.Items.Add((New-MenuItem "Generate with AI, translated to English" "" "ai-english" $null ($forItem -and $forItem.Subs -and $forItem.Subs.Translate)))
    }
    # Whatever's showing, in your language. Not for a queued video: its subtitles aren't chosen until it plays.
    if (-not $forItem) {
        $myLanguage = ($script:SubtitleLanguages | Where-Object { $_.Code -eq $code }).Name
        $translate = New-MenuItem "Translate these to $myLanguage" "online, Google" "translate" $null $false
        $translate.ToolTip = "Sends the subtitles' text to Google Translate. Change the language under My language."
        if (-not $script:subsSource) {
            $translate.IsEnabled = $false
            $translate.Header = if ($script:aiJob) { "Translate to $myLanguage (once the AI has finished)" } else { "Translate to $myLanguage (turn subtitles on first)" }
        }
        [void]$menu.Items.Add($translate)
    }
    [void]$menu.Items.Add((New-MenuItem "Search online" "" "search" $null $false))
    [void]$menu.Items.Add((New-MenuItem "Load a file" "" "load" $null $false))
    $line = New-Object System.Windows.Controls.Separator
    $line.Style = $window.FindResource("MenuLine")
    [void]$menu.Items.Add($line)
    $languageName = ($script:SubtitleLanguages | Where-Object { $_.Code -eq $code }).Name
    [void]$menu.Items.Add((New-MenuItem "Turn on automatically for each video" "" "auto" $null ([bool]$script:settings.SubsAuto)))
    $languages = New-MenuItem "My language" $languageName $null $null $false
    foreach ($l in $script:SubtitleLanguages) { [void]$languages.Items.Add((New-MenuItem $l.Name "" "language" $l.Code ($l.Code -eq $code))) }
    [void]$menu.Items.Add($languages)
    # Drawn into the stream by its encoder, so changes apply from the next Start
    $style = New-MenuItem "Subtitle style" "from next Start" $null $null $false
    foreach ($group in @(
            @{ Header = "Size"; Key = "SubsSize"; Options = @(@("Small", 28), @("Medium", 20), @("Large", 15)) },
            @{ Header = "Position"; Key = "SubsPlace"; Options = @(@("Bottom", "bottom"), @("Top", "top")) },
            @{ Header = "Colour"; Key = "SubsColor"; Options = @(@("White", "white"), @("Yellow", "yellow"), @("Light blue", "cyan")) },
            @{ Header = "Font"; Key = "SubsFont"; Options = @(@("Matches my language", "auto"), @("Standard (Arial)", "arial.ttf"), @("Chinese", "msyh.ttc"), @("Japanese", "YuGothM.ttc"), @("Korean", "malgun.ttf")) })) {
        $part = New-MenuItem $group.Header "" $null $null $false
        foreach ($option in $group.Options) {
            [void]$part.Items.Add((New-MenuItem $option[0] "" "style" @{ Key = $group.Key; Value = $option[1] } ("$($script:settings[$group.Key])" -eq "$($option[1])")))
        }
        [void]$style.Items.Add($part)
    }
    [void]$menu.Items.Add($style)
    $button.ContextMenu = $menu
    $menu.PlacementTarget = $button
    $menu.Placement = "Bottom"
    $menu.IsOpen = $true
}

function Invoke-SubsMenu($tag) {
    switch ($tag.Action) {
        "auto" { $script:settings.SubsAuto = -not $script:settings.SubsAuto; Save-Settings $script:settings; return }
        "language" { $script:settings.SubsLanguage = $tag.Choice; Save-Settings $script:settings; return }
        "style" {
            $script:settings[$tag.Choice.Key] = $tag.Choice.Value
            Save-Settings $script:settings
            if ($script:proc) { $lblStatus.Text = "The new subtitle style applies the next time you press Start." }
            return
        }
    }
    $item = $script:subsMenuItem
    $picked = $null
    if ($tag.Action -eq "translate") { Start-SubsTranslation; return }
    if ($tag.Action -in "ai", "ai-english") {
        if (-not (Confirm-AiTools)) { return }
        $translate = $tag.Action -eq "ai-english"
        if ($item) {
            $item.Subs = @{ Ai = $true; Translate = $translate; Name = "AI" }
            Update-Queue $script:queue.IndexOf($item)
            return
        }
        $video = Get-MenuVideo
        if (-not $video) { $script:subsNotice = "Start the stream first, so the YouTube video's sound is available for AI subtitles."; $lblStatus.Text = $script:subsNotice; return }
        if (-not $script:currentVideo) { $script:currentVideo = $video }
        Start-AiSubs $video $translate
        if ($script:subsNotice) { $lblStatus.Text = $script:subsNotice }
        return
    }
    switch ($tag.Action) {
        "search" {
            $name = if ($item) { $item.Name } elseif ($script:currentVideo) { $script:currentVideo.Name } elseif ($tbFile.Text -and -not (Test-OnlineLink $tbFile.Text)) { $tbFile.Text } else { "" }
            $path = if ($item) { $item.Path } elseif ($script:currentVideo) { $script:currentVideo.Path } else { $tbFile.Text }
            $file = if ($path -and -not (Test-OnlineLink $path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { $path }
            $picked = Show-OpenSubtitlesDialog $window $(if ($name) { Get-SubtitleSearchText $name } else { "" }) $file
            if (-not $picked) { return }
        }
        "load" {
            $srt = Select-SrtFile
            if (-not $srt) { return }
            $picked = @{ Path = $srt; Name = [IO.Path]::GetFileName($srt) }
        }
    }
    if ($item) {
        $item.Subs = switch ($tag.Action) {
            "default" { $null }
            "off" { @{ Off = $true; Name = "off" } }
            "choice" { @{ Choice = $tag.Choice; Name = $tag.Choice.Label } }
            default { $picked }
        }
        Update-Queue $script:queue.IndexOf($item)
        return
    }
    switch ($tag.Action) {
        "off" { Clear-Subs; $script:subsNotice = "" }
        "choice" {
            if (-not $script:currentVideo) { $script:currentVideo = Get-MenuVideo }
            Use-SubChoice $tag.Choice
        }
        default { Stop-AiSubs; $script:subsRequest++; $script:subsNotice = ""; Set-Subs $picked.Path $picked.Name }
    }
}
# The subtitles showing now, translated in the background into your language. Kept, so it's instant next time.
function Start-SubsTranslation {
    $source = $script:subsSource
    if (-not $source) { return }
    $code = $script:settings.SubsLanguage
    $languageName = ($script:SubtitleLanguages | Where-Object { $_.Code -eq $code }).Name
    $key = if ($source.Srt) { $f = Get-Item -LiteralPath $source.Srt; ($f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks) -join "|" }
           else { $f = Get-Item -LiteralPath $source.File; ($f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks, $source.Index) -join "|" }
    $out = Get-SubtitleCachePath "translated" "$key|$code"
    $label = "$(($script:subsName -replace ', in \w+$', '')), in $languageName"
    Stop-AiSubs
    $script:subsNotice = ""
    $script:subsRequest++
    if (Test-Path -LiteralPath $out) { Set-Subs $out $label; return }
    # What's showing stays until the translation is ready
    $script:subsWaiting = $true
    Update-SubsLabel
    $lblStatus.Text = "Translating the subtitles to $languageName. This takes a few seconds to a minute."
    Start-SubtitleTask {
        param($srt, $file, $index, $ffmpeg, $code, $out)
        if (-not $srt) { [void](Save-EmbeddedSubtitle $ffmpeg $file $index "$out.source.srt"); $srt = "$out.source.srt" }
        try { Convert-TranslatedSubtitles $srt $code $out } finally { Remove-Item -LiteralPath "$out.source.srt" -Force -ErrorAction SilentlyContinue }
    } @($source.Srt, $source.File, $source.Index, $ffmpegExe, $code, $out) {
        param($saved, $why, $tag)
        if ($tag.Request -ne $script:subsRequest) { return }   # moved on since asking
        $script:subsWaiting = $false
        if ($why -or -not $saved) { $script:subsNotice = "Couldn't translate the subtitles: $why"; $lblStatus.Text = $script:subsNotice; Update-SubsLabel; return }
        Set-Subs "$saved" $tag.Label -Quiet
        $lblStatus.Text = "Subtitles translated."
    } @{ Request = $script:subsRequest; Label = $label }
}

$btnSubs.Add_Click({ Show-SubsMenu $btnSubs $null })
$btnItemSubs.Add_Click({
        $i = $lbQueue.SelectedIndex
        if ($i -lt 0) { Show-Notice "Select a video in the list first."; return }
        Show-SubsMenu $btnItemSubs $script:queue[$i]
    })
foreach ($step in @(@($btnSubsBack5, -5), @($btnSubsBack, -0.5), @($btnSubsFwd, 0.5), @($btnSubsFwd5, 5))) {
    $step[0].Tag = $step[1]
    $step[0].Add_Click({ param($s) $script:overlay.Offset = [Math]::Round($script:overlay.Offset + [double]$s.Tag, 1); if ($script:assSubs) { Update-PlayerAss }; Update-SubsLabel })
}
$btnSubsPause.Add_Click({
        if ($script:overlay.ClockPaused) { $script:overlay.ResumeClock(); $btnSubsPause.Content = "Pause" }
        else { $script:overlay.PauseClock(); $btnSubsPause.Content = "Resume" }
    })
$btnSubsRestart.Add_Click({ $script:overlay.RestartClock(); $btnSubsPause.Content = "Pause" })

# --- Queue: files wait here already checked to be playable; YouTube is checked when its turn comes ---
$script:queue = New-Object System.Collections.ArrayList

function Update-Queue($select = -1) {
    $lbQueue.Items.Clear()
    foreach ($item in $script:queue) {
        $details = @(Format-Time $item.Media.Duration)
        $details += $(if ($item.IsOnline) { $item.Site } else { "File" })
        if ($item.Subs) { $details += "subtitles: $($item.Subs.Name)" }
        [void]$lbQueue.Items.Add((New-VideoRow $item.Name ($details -join "  -  ") $item.Thumb))
    }
    if ($lbQueue.Items.Count) { $lbQueue.SelectedIndex = [Math]::Min([Math]::Max($select, -1), $lbQueue.Items.Count - 1) }
    $lblQueue.Text = if ($script:queue.Count) { "Up next ($($script:queue.Count))" } else { "Up next" }
    Show-If $lblQueueEmpty (-not $script:queue.Count)
    $btnSkip.IsEnabled = $script:queue.Count -gt 0
}

function Add-ToQueue($paths) {
    $bad = @()
    foreach ($path in $paths) {
        $media = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-MediaInfo $path }
        if ($media) { [void]$script:queue.Add(@{ Path = $path; Name = [IO.Path]::GetFileName($path); Media = $media; Subs = $null }) }
        else { $bad += $path }
    }
    Update-Queue $lbQueue.SelectedIndex
    if ($bad) { Show-Notice "Can't play these, so they weren't added:`n$($bad -join "`n")" }
}

# Take a video out of the queue and play it now (or put it in the file box if nothing is streaming yet)
function Start-QueueItem($index) {
    $item = $script:queue[$index]
    $script:queue.RemoveAt($index)
    if (-not $script:player) { Update-Queue $index; Set-File $item.Path; $script:startItem = $item; return }
    # "Repeat list": what just played goes to the back
    if ($chkRepeat.IsChecked -and $script:nowItem) { [void]$script:queue.Add($script:nowItem) }
    $script:nowItem = $item
    Update-Queue $index
    if ($item.IsOnline) { Start-YouTubeItem $item } else { Start-Media $item.Path $item.Media $item.Subs }
}

function Move-QueueItem($by) {
    $from = $lbQueue.SelectedIndex
    Move-QueueItemTo $from ($from + $by)
}
function Move-QueueItemTo($from, $to) {
    if ($from -lt 0 -or $to -lt 0 -or $from -ge $script:queue.Count -or $to -ge $script:queue.Count -or $from -eq $to) { return }
    $item = $script:queue[$from]
    $script:queue.RemoveAt($from)
    $script:queue.Insert($to, $item)
    Update-Queue $to
}

# Dragging a row to another place in the list
$lbQueue.Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $row = [System.Windows.Controls.ItemsControl]::ContainerFromElement($lbQueue, $e.OriginalSource)
        $script:dragRow = if ($row) { $lbQueue.ItemContainerGenerator.IndexFromContainer($row) } else { -1 }
        $script:dragFrom = $e.GetPosition($lbQueue)
    })
$lbQueue.Add_PreviewMouseMove({ param($s, $e)
        if ($e.LeftButton -ne "Pressed" -or $script:dragRow -lt 0 -or $null -eq $script:dragRow) { return }
        if ([Math]::Abs($e.GetPosition($lbQueue).Y - $script:dragFrom.Y) -lt 6) { return }
        $from = $script:dragRow
        $script:dragRow = -1
        [void][System.Windows.DragDrop]::DoDragDrop($lbQueue, (New-Object System.Windows.DataObject("vvs-move", $from)), "Move")
    })
$btnShuffle.Add_Click({
        if ($script:queue.Count -lt 2) { return }
        $mixed = @(Get-Random -InputObject @($script:queue) -Count $script:queue.Count)
        $script:queue.Clear()
        foreach ($item in $mixed) { [void]$script:queue.Add($item) }
        Update-Queue 0
    })
# Saved lists hold what's needed to find each video again, and files are checked again when loaded
$btnSaveList.Add_Click({
        if (-not $script:queue.Count) { Show-Notice "Up next is empty, so there's nothing to save."; return }
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = "Save this list"
        $dialog.Filter = "VR Video Streamer lists (*.vvslist)|*.vvslist"
        $dialog.DefaultExt = ".vvslist"
        if (-not $dialog.ShowDialog($window)) { return }
        $rows = @($script:queue | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; IsOnline = [bool]$_.IsOnline; Site = $_.Site; Thumb = $_.Thumb; Duration = [double]$_.Media.Duration } })
        ConvertTo-Json -InputObject $rows | Set-Content -LiteralPath $dialog.FileName -Encoding utf8
    })
$btnLoadList.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = "Load a list"
        $dialog.Filter = "VR Video Streamer lists (*.vvslist)|*.vvslist"
        if ($dialog.ShowDialog($window)) { Import-QueueList $dialog.FileName }
    })
function Import-QueueList($file) {
    try { $rows = @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Show-Notice "That file isn't a list this program can read."; return }
    $online = @(); $files = @()
    foreach ($row in @($rows | ForEach-Object { $_ })) {
        if ($row.IsOnline) {
            $online += @{ Path = $row.Path; Name = $row.Name; IsOnline = $true; Site = $row.Site; Thumb = $row.Thumb; Subs = $null
                          Media = @{ Duration = [double]$row.Duration; HasVideo = $true; HasAudio = $true } }
        } else { $files += $row.Path }
    }
    if ($online -and -not (Confirm-YouTubeTools)) { $online = @() }
    if ($files) { Add-ToQueue $files }
    if ($online) { Add-YouTubeItems $online } else { Update-Queue $lbQueue.SelectedIndex }
}

function Format-Time($s) {
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, [double]$s))
    if ($t.TotalHours -ge 1) { "{0}:{1:mm\:ss}" -f [int][Math]::Floor($t.TotalHours), $t } else { "{0:m\:ss}" -f $t }
}

# --- YouTube ---
$script:ytDlpExe = Find-YtDlp $toolsFolder
$script:ytLoading = $null      # the video whose address is being fetched to play next
$script:ytNotice = ""          # why a video was skipped; the status line shows it

function Confirm-YouTubeTools {
    if (-not $script:ytDlpExe) { $script:ytDlpExe = Install-YouTubeWithDialog $toolsFolder $window }
    if ($script:ytDlpExe) { Update-YtDlpOnce }
    [bool]$script:ytDlpExe
}

# Ask for the address of the next video. The current one keeps playing until the answer arrives, or a
# failed one is skipped, because the queue should keep moving when nobody's at the keyboard.
function Start-YouTubeItem($item) {
    if (-not (Confirm-YouTubeTools)) { return }
    $script:ytLoading = $item
    $script:ytNotice = ""
    Get-YouTubeStream $item.Path $qualities[$cbQuality.SelectedIndex].Height {
        param($info, $why, $item)
        if (-not [object]::ReferenceEquals($item, $script:ytLoading)) { return }   # skipped past it before it was ready
        $script:ytLoading = $null
        if (-not $script:player) { return }   # stopped in the meantime
        $stream = if ($info) { Read-YouTubeStream $info }
        if (-not $stream) { $script:ytNotice = "Skipped '$($item.Name)': $why"; $script:nowItem = $null; return }
        $script:player.Load($stream.File, $stream.AudioFile, $stream.Options, $stream.Duration, $stream.HasVideo, $stream.HasAudio)
        $tbFile.Text = $item.Path
        Show-NowPlaying $item.Name
        Start-VideoSubs @{ Path = $item.Path; Name = $item.Name; Captions = $stream.Captions; SoundOptions = $stream.Options; AudioUrl = $(if ($stream.AudioFile) { $stream.AudioFile } else { $stream.File }); Chapters = $stream.Chapters } $item.Subs
    } $item
}

function Add-YouTubeItems($items) {
    foreach ($item in $items) { [void]$script:queue.Add($item) }
    Update-Queue $lbQueue.SelectedIndex
    # Nothing to play yet: the first one becomes what Start streaming will use
    if (-not $script:player -and -not $script:proc -and -not $tbFile.Text -and $script:queue.Count) { Start-QueueItem 0 }
}

function Submit-YouTubeBox {
    $text = $tbYouTube.Text.Trim()
    if (-not $text) { return }
    if (-not (Confirm-YouTubeTools)) { return }
    if (-not (Test-OnlineLink $text)) {
        Show-YouTubeSearch $text
        return
    }
    $tbYouTube.Text = ""
    $btnYouTube.Content = "Reading the link..."
    Get-YouTubeLinkInfo $text {
        param($info, $why, $link)
        $btnYouTube.Content = "Add link or search"
        if (-not $info) { Show-Notice "Couldn't add that link: $why"; return }
        $found = if ($info.entries) { @($info.entries | Where-Object { $_ }) } else { @($info) }
        Add-YouTubeItems @($found | ForEach-Object { New-OnlineItem $_ $link })
    } $text
}
$btnYouTube.Add_Click({ Submit-YouTubeBox })
$tbYouTube.Add_KeyDown({ param($s, $e) if ($e.Key -eq "Return") { $e.Handled = $true; Submit-YouTubeBox } })
$tbYouTube.Add_TextChanged({ Show-If $lblYouTubeHint (-not $tbYouTube.Text) })

# Seek bar: click or drag anywhere to jump there
$script:dragging = $false
$seekBar.Add_PreviewMouseLeftButtonDown({ $script:dragging = $true })
$seekBar.Add_ValueChanged({
        if ($script:dragging -and $script:player -and $script:player.Duration -gt 0) { $lblTimeLeft.Text = Format-Time ($seekBar.Value / $seekBar.Maximum * $script:player.Duration) }
    })
# A live YouTube video has no length, so there's nowhere to jump to
$seekBar.Add_PreviewMouseLeftButtonUp({
        if ($script:dragging -and $script:player -and $script:player.Duration -gt 0) { $script:player.Seek($seekBar.Value / $seekBar.Maximum * $script:player.Duration) }
        $script:dragging = $false
    })
$btnPlay.Add_Click({ if ($script:player) { if ($script:player.Paused) { $script:player.Play() } else { $script:player.Pause() } } })
$btnBack.Add_Click({ if ($script:player -and $script:player.Duration -gt 0) { $script:player.Seek($script:player.Position - 10) } })
$btnFwd.Add_Click({ if ($script:player -and $script:player.Duration -gt 0) { $script:player.Seek($script:player.Position + 10) } })

$script:proc = $null
$script:player = $null
$btnStart.Add_Click({ try {
        $script:Fps = $fpsChoices[[Math]::Max(0, $cbFps.SelectedIndex)]
        $script:streamHwnd = 0
        $script:subsNotice = ""; $script:ytNotice = ""
        $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Quote $StreamScript))
        if ($rbMonitor.IsChecked) {
            $a += @("-Monitor", $cbMonitor.SelectedIndex)
        } elseif ($rbWindow.IsChecked) {
            if ($cbWindow.SelectedIndex -lt 0) { $lblStatus.Text = "Pick a program's window first."; return }
            $script:streamHwnd = [long]$script:windowProcs[$cbWindow.SelectedIndex].MainWindowHandle
            $a += @("-WindowHwnd", $script:streamHwnd)
        } else {
            if (-not $tbFile.Text -and $script:queue.Count) { Start-QueueItem 0 }
            $source = $tbFile.Text.Trim()
            $isYouTube = Test-OnlineLink $source
            if (-not $source -or (-not $isYouTube -and -not (Test-Path -LiteralPath $source))) { $lblStatus.Text = "Pick a file or add a YouTube video first."; return }
            $height = $qualities[$cbQuality.SelectedIndex].Height
            $stream = $null
            $media = $null
            if ($isYouTube) {
                # Its address has to be fetched first, without freezing the window; Start then runs again with it
                if (-not $script:startStream -or $script:startStream.Url -ne $source) {
                    if (-not (Confirm-YouTubeTools)) { return }
                    $script:startingYouTube = $true
                    Update-Enabled
                    $lblStatus.Text = "Getting the video..."
                    $script:startUrl = $source
                    # A restart after a failure (Start-Recovery) has to stay one when the second Start comes, or the
                    # alert about the new link and the remote's address are lost
                    $script:startWasRecovery = [bool]$script:recovering
                    Get-YouTubeStream $source $height {
                        param($info, $why)
                        $script:startingYouTube = $false
                        $found = if ($info) { Read-YouTubeStream $info }
                        if (-not $found) { $lblStatus.Text = "Couldn't get that video: $why"; Update-Enabled; return }
                        $found.Url = $script:startUrl
                        $script:startStream = $found
                        Update-Enabled
                        $script:recovering = $script:startWasRecovery
                        try { $btnStart.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
                        finally { $script:recovering = $false; $script:startWasRecovery = $false }
                    }
                    return
                }
                $stream = $script:startStream
                $script:startStream = $null
            } else {
                $media = Get-MediaInfo $source
            }
            $player = New-FilePlayer $source $height $stream $media
            if (-not $player) { return }
            $a += @("-PipeInput", $player.Tag, "-PipeSize", $player.Size)
            $script:player = $player.Player
            $item = $script:startItem
            $script:startItem = $null
            $name = if ($stream) { $stream.Title } else { [IO.Path]::GetFileName($source) }
            Show-NowPlaying $name
            $script:lastStarved = 0; $script:slowTicks = 0
            $chosen = if ($item -and $item.Path -eq $source -and $item.Subs) { $item.Subs } elseif ($script:subsName -or $script:subsWaiting) { @{ Keep = $true } }
            Start-VideoSubs @{ Path = $source; Name = $name; Tracks = $media.Tracks; Sounds = $media.Sounds; Chapters = $(if ($stream) { $stream.Chapters } else { $media.Chapters }); Captions = $stream.Captions; SoundOptions = $stream.Options; AudioUrl = $(if ($stream) { if ($stream.AudioFile) { $stream.AudioFile } else { $stream.File } }) } $chosen
            $script:overlay.Player = $script:player
            $script:nowItem = if ($item -and $item.Path -eq $source) { $item } else {
                @{ Path = $source; Name = $name; IsOnline = [bool]$stream; Site = "Online"; Subs = $null; Media = $(if ($media) { $media } else { @{ Duration = $stream.Duration; HasVideo = $true; HasAudio = $stream.HasAudio } }) }
            }
            # Picking up where a stream that failed left off
            if ($script:resumeAt -gt 0) { $script:player.Seek($script:resumeAt); $script:resumeAt = 0 }
        }
        $a += @("-SubtitleText", (Quote $subtitleTextFile), "-SubtitleSize", $script:settings.SubsSize, "-SubtitlePlace", $script:settings.SubsPlace,
                "-SubtitleColor", $script:settings.SubsColor, "-SubtitleFont", (Quote (Get-SubtitleFontPath $script:settings)))
        $script:wasLive = $false
        $script:publicFails = 0; $script:linkStalled = $false
        if (-not $script:recovering) { $script:linkBeforeRestart = $null }   # started by hand: viewers expect a new link
        $script:viewerSamples = New-Object Collections.ArrayList
        $lblViewers.Text = ""
        $script:soundPids = @()
        $script:soundFile = $null
        if (-not $rbFile.IsChecked) {
            $script:soundOwnPid = if ($rbWindow.IsChecked) { $script:windowProcs[$cbWindow.SelectedIndex].Id }
            $script:soundFile = Join-Path $env:TEMP "VRVideoStreamer-sound-$PID.txt"
            Send-SoundPicks
            $a += @("-SoundControl", (Quote $script:soundFile), "-SoundMemory", (Quote $script:quietFile))
        }
        $tunnelToken = $null
        if ($chkPublic.IsChecked) {
            $tunnelChoice = $tunnels[$cbTunnel.SelectedIndex].Value
            $a += @("-Public", "-Tunnel", $tunnelChoice)
            # Through the remote control's proxy, so the public link carries the remote page too
            if ($script:remote) {
                $a += @("-TunnelPort", $script:remote.Port)
                if (-not $script:recovering -or -not $script:remote.Secret) { $script:remote.Secret = New-RemoteSecret }
            }
            if ($tunnelChoice -eq "permanent") {
                $tunnelToken = Get-Secret "tunnel.token"
                if (-not $tunnelToken -or -not $script:settings.PermanentHost) {
                    Stop-Stream
                    $lblStatus.Text = "Your permanent link isn't set up yet. Press Permanent link below, or pick another service."
                    Update-Enabled
                    return
                }
                $a += @("-PermanentHost", $script:settings.PermanentHost)
            }
        }
        $q = $qualities[$cbQuality.SelectedIndex]
        $script:streamQuality = $cbQuality.SelectedIndex
        $script:streamFps = $script:Fps
        $script:streamEncoder = $encoders[$cbEncoder.SelectedIndex].Value
        Reset-SlowWarning
        $a += @("-Fps", $script:Fps, "-Height", $q.Height, "-Bitrate", $q.Bitrate, "-AudioBitrate", $audioQualities[$cbAudioQuality.SelectedIndex].Value, "-Encoder", $encoders[$cbEncoder.SelectedIndex].Value)

        foreach ($tb in $linkBoxes.Values) { $tb.Text = "" }
        # A stopped stream's tools can hold on to their logs for a moment, so each start gets new ones
        foreach ($f in $OutLog, $ErrLog) { try { Remove-Item $f -Force -ErrorAction Stop } catch { } }
        $script:logRun = [int]$script:logRun + 1
        $script:OutLog = Join-Path $env:TEMP "VRVideoStreamer-out-$PID-$($script:logRun).txt"
        $script:ErrLog = Join-Path $env:TEMP "VRVideoStreamer-err-$PID-$($script:logRun).txt"
        # Handed over this way so the token never shows in the list of running programs' command lines
        if ($tunnelToken) { $env:TUNNEL_TOKEN = $tunnelToken }
        $script:proc = Start-Process $psExe -ArgumentList ($a -join " ") -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
        Remove-Item Env:TUNNEL_TOKEN -ErrorAction SilentlyContinue
        $script:userStopped = $false
        $script:publicVia = ""
        $lblStat.Text = "Starting..."
        $lblStatus.Text = "Starting..."
        Update-Enabled
    } catch { Stop-Stream; $script:proc = $null; $lblStatus.Text = "Couldn't start: $($_.Exception.Message)"; Update-Enabled } })

function Stop-Preview {
    if ($script:preview) { $script:preview.Stop() }
    $script:preview = $null
    $imgPreview.Source = $null
    Show-If $lblPreview $true
}

function Stop-Stream {
    # The stream script's job object takes ffmpeg, MediaMTX and cloudflared down with it
    if ($script:proc -and -not $script:proc.HasExited) { $script:userStopped = $true; Stop-Process -Id $script:proc.Id -Force }
    if ($script:soundFile) { Remove-Item -LiteralPath $script:soundFile -Force -ErrorAction SilentlyContinue; $script:soundFile = $null }
    $script:overlay.Player = $null
    # A video's subtitles end with it, or the next stream would start with them. A capture's stay: they're not
    # tied to anything. They also stay through a restart after a failure, since it's the same video.
    if ($script:aiJob -or ($script:player -and -not $script:recovering)) { Clear-Subs }
    if ($script:player) { $script:player.Stop(); $script:player = $null }
    $script:currentVideo = $null
    Show-If $btnChapters $false
    $script:ytLoading = $null
    if (-not $script:recovering) {
        $script:nowItem = $null; $script:recoveryTimes = @(); $script:recoverNotice = ""
        # Old remote links stop working with the stream they were for
        if ($script:remote) { $script:remote.Secret = $null; $script:remote.State = "{}" }
        $script:remoteNotice = ""
    }
    $tbRemote.Text = ""
    $script:remoteLinkFor = $null
    $script:publicShown = $null
    $script:linkReconnecting = $false
    Reset-SlowWarning
    $lblViewers.Text = ""
    Stop-Preview
}

# --- Auto-recovery: a stream that fails after going live starts again by itself, from the same place. It gives up
# after three times in ten minutes, since something's really wrong then, and link services dislike constant restarts. ---
function Start-Recovery($why) {
    if (-not $script:wasLive) { return $false }   # never got going, so trying again wouldn't help
    $now = Get-Date
    $script:recoveryTimes = @(@($script:recoveryTimes) | Where-Object { $_ -and ($now - $_).TotalMinutes -lt 10 })
    if ($script:recoveryTimes.Count -ge 3) { return $false }
    $script:recoveryTimes += $now
    $pl = $script:player
    $script:resumeAt = if ($pl -and $pl.Duration -gt 0 -and -not $pl.Ended) { [Math]::Max(0, $pl.Position - 2) } else { 0 }
    $hadPublic = [bool]$linkBoxes.public.Text
    # So the alert can tell, once the link reopens, whether viewers' link changed
    $script:linkBeforeRestart = $linkBoxes.public.Text
    $script:restartWhy = "$why It restarted by itself, and the free link came back at a new address."
    $script:recovering = $true
    try {
        Stop-Stream
        $script:proc = $null
        foreach ($tb in $linkBoxes.Values) { $tb.Text = "" }
        Update-Enabled
        $script:recoverNotice = "$why It restarted by itself$(if ($hadPublic) { ', so viewers need the new video player link, copied to the clipboard once it opens' })."
        $script:recoverNoticeAt = $now
        $btnStart.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    } finally { $script:recovering = $false }
    $true
}

# Asked in the background every 15 s, since the window shouldn't wait on the internet
function Test-PublicLink {
    $link = $linkBoxes.public.Text
    if ($link -notmatch '^https://' -or $script:linkCheckBusy) { return }
    $script:linkCheckBusy = $true
    Start-SubtitleTask {
        param($link)
        try { (Invoke-WebRequest $link -UseBasicParsing -TimeoutSec 10).StatusCode } catch { 0 }
    } @($link) {
        param($status, $why)
        $script:linkCheckBusy = $false
        if (-not $script:proc) { return }
        $script:publicFails = if ($status -eq 200) { 0 } else { [int]$script:publicFails + 1 }
        if ($script:publicFails -eq 0) { $script:linkStalled = $false; return }
        # Cloudflare's own hiccups, or this PC being too busy to answer the check in time, usually pass within a minute
        # or two, and cloudflared reconnects by itself at the same address. Restarting would hand a free link a new
        # address and stop every viewer, so the link is left alone while cloudflared is still running.
        $tunnelRunning = @(Get-Process cloudflared -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path.StartsWith($toolsFolder, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($script:publicFails -ge 4) { $script:linkStalled = $true }
        if ($script:publicVia -eq "Your permanent link" -and $script:publicFails -ge 4 -and $tunnelRunning) {
            # A permanent link keeps its address, so reconnecting just the link program costs viewers nothing.
            # The stream script's watchdog opens it again.
            $script:publicFails = 0
            Get-Process cloudflared -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path.StartsWith($toolsFolder, [StringComparison]::OrdinalIgnoreCase) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
        } elseif ($script:publicFails -ge 20 -or ($script:publicFails -ge 4 -and -not $tunnelRunning)) {
            # Down for about 5 minutes, or the link program has gone: a new link is better than none
            $script:publicFails = 0; $script:linkStalled = $false
            [void](Start-Recovery "The video player link stopped working.")
        }
    }
}

# How much the stream is sending and, from that, about how many are watching. Each viewer's copy goes through MediaMTX,
# and the public services all arrive from one place, so the amount sent is the only count covering everyone. It's
# compared with what the stream is really making just now, since a still picture makes far less than the quality's limit.
function Update-ViewerStats {
    if ($script:statsBusy) { return }
    $script:statsBusy = $true
    Start-SubtitleTask {
        $hls = Invoke-RestMethod "http://127.0.0.1:9997/v3/hlsmuxers/get/desktop" -TimeoutSec 2
        $path = Invoke-RestMethod "http://127.0.0.1:9997/v3/paths/get/desktop" -TimeoutSec 2
        @{ Bytes = [long]$hls.bytesSent; Made = [long]$path.bytesReceived; Rtsp = @($path.readers | Where-Object { $_.type -match "rtsp" }).Count }
    } @() {
        param($stats, $why)
        $script:statsBusy = $false
        if (-not $script:proc -or -not $stats -or $null -eq $stats.Bytes) { return }
        [void]$script:viewerSamples.Add(@{ T = [DateTime]::UtcNow; Bytes = [long]$stats.Bytes; Made = [long]$stats.Made })
        while ($script:viewerSamples.Count -gt 7) { $script:viewerSamples.RemoveAt(0) }
        if ($script:viewerSamples.Count -lt 3) { return }
        $first = $script:viewerSamples[0]; $last = $script:viewerSamples[$script:viewerSamples.Count - 1]
        $seconds = ($last.T - $first.T).TotalSeconds
        $made = $last.Made - $first.Made
        if ($seconds -le 0 -or $made -le 0) { return }
        $mbit = ($last.Bytes - $first.Bytes) * 8 / $seconds / 1000000
        $watching = [Math]::Round(($last.Bytes - $first.Bytes) / $made)
        # One of the RTSP readers is this window's own preview
        if ($script:preview) { $watching += [Math]::Max(0, [int]$stats.Rtsp - 1) } else { $watching += [int]$stats.Rtsp }
        $lblViewers.Text = "{0}  -  sending {1:0.0} Mbit/s" -f $(if ($watching -lt 1) { "No viewers yet" } elseif ($watching -eq 1) { "About 1 watching" } else { "About $watching watching" }), $mbit
    }
}

# --- Remote control: a web page friends can open to pause, skip, seek and add YouTube videos (RemoteProxy.cs) ---
# Its port is fixed so a permanent link can point at it. If something else has it, streams work as before without a remote.
$script:remote = $null
try { $script:remote = New-Object RemoteProxy(8890, 8888, (Join-Path $PSScriptRoot "remote.html")) } catch { }
function New-RemoteSecret {
    $bytes = New-Object byte[] 18
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
    [Convert]::ToBase64String($bytes).Replace("+", "-").Replace("/", "_")
}

# The remote link is the public link's address plus the secret, once the link is up. A permanent link set up before
# the remote existed points past it, so that's checked rather than handing out a link that can't work.
function Update-RemoteLink {
    if (-not $script:remote -or -not $script:remote.Secret -or $tbPublic.Text -notmatch '^(https://[^/]+)/') { $tbRemote.Text = ""; $script:remoteLinkFor = $null; return }
    $link = "$($Matches[1])/remote/$($script:remote.Secret)/"
    if ($script:remoteLinkFor -eq $link) { return }
    $script:remoteLinkFor = $link
    $tbRemote.Text = $link
    Start-SubtitleTask {
        param($link)
        try { (Invoke-WebRequest "${link}state" -UseBasicParsing -TimeoutSec 15).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 } }
    } @($link) {
        param($status, $why, $link)
        if ($tbRemote.Text -ne $link -or $status -eq 200 -or $status -eq -1) { return }   # -1: this PC can't reach it yet, which isn't the link's fault
        $tbRemote.Text = if ($script:publicVia -eq "Your permanent link") { "(Change your permanent link's URL to 127.0.0.1:8890 in Cloudflare to use this)" } else { "(The remote control isn't reachable through this link)" }
    } $link
}

# What the page shows, refreshed with the window's own display
function Update-RemoteState {
    if (-not $script:remote -or -not $script:remote.Secret) { return }
    $pl = $script:player
    $state = @{ mode = $(if (-not $script:proc) { "stopped" } elseif ($pl) { "player" } else { "capture" }); viewers = "$($lblViewers.Text)" }
    if ($pl) {
        $state.title = "$($lblNow.Text)"
        $state.position = [Math]::Round([double]$pl.Position, 1)
        $state.duration = [Math]::Round([double]$pl.Duration, 1)
        $state.paused = [bool]$pl.Paused
        $state.ended = [bool]$pl.Ended
        $state.loading = [bool]$script:ytLoading
        $state.queue = @($script:queue | Select-Object -First 30 | ForEach-Object { @{ name = "$($_.Name)"; length = [Math]::Round([double]$_.Media.Duration) } })
        $state.more = [Math]::Max(0, $script:queue.Count - 30)
        $state.chapters = @($script:currentVideo.Chapters | Where-Object { $_ } | ForEach-Object { @{ start = [double]$_.Start; title = "$($_.Title)" } })
        $state.canAdd = [bool]$script:ytDlpExe -and $script:queue.Count -lt 100
        $state.notice = "$($script:remoteNotice)"
    }
    $script:remote.State = ConvertTo-Json $state -Compress -Depth 4
}

# Commands from the page, carried out here on the window's own thread
function Invoke-RemoteCommands {
    if (-not $script:remote) { return }
    $text = $null
    while ($script:remote.Commands.TryDequeue([ref]$text)) {
        try { $command = $text | ConvertFrom-Json } catch { continue }
        $pl = $script:player
        if (-not $pl -or -not $script:remote.Secret) { continue }
        switch ("$($command.action)") {
            "toggle" { if ($pl.Ended) { $pl.Seek(0); $pl.Play() } elseif ($pl.Paused) { $pl.Play() } else { $pl.Pause() } }
            "back" { if ($pl.Duration -gt 0) { $pl.Seek($pl.Position - 10) } }
            "forward" { if ($pl.Duration -gt 0) { $pl.Seek($pl.Position + 10) } }
            "seek" { $at = 0.0; if ($pl.Duration -gt 0 -and [double]::TryParse("$($command.at)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$at)) { $pl.Seek([Math]::Max(0, [Math]::Min($at, $pl.Duration))) } }
            "skip" { if ($script:queue.Count) { Start-QueueItem 0 } }
            "add" {
                # Only YouTube: other addresses would have this PC fetch whatever a remote user names
                $link = "$($command.link)".Trim()
                if ($link -notmatch '^https?://([a-z0-9-]+\.)*(youtube\.com|youtu\.be)/\S+$' -or -not $script:ytDlpExe) { $script:remoteNotice = "Only YouTube links can be added from the remote."; continue }
                if ([int]$script:remoteAdding -ge 3 -or $script:queue.Count -ge 100) { $script:remoteNotice = "Too many at once. Try again in a moment."; continue }
                $script:remoteAdding = [int]$script:remoteAdding + 1
                $script:remoteNotice = "Adding a video..."
                Get-YouTubeLinkInfo $link {
                    param($info, $why, $link)
                    $script:remoteAdding = [Math]::Max(0, [int]$script:remoteAdding - 1)
                    if (-not $info) { $script:remoteNotice = "Couldn't add that link: $why"; return }
                    $found = @(if ($info.entries) { @($info.entries | Where-Object { $_ } | Select-Object -First 50) } else { $info })
                    Add-YouTubeItems @($found | ForEach-Object { New-OnlineItem $_ $link })
                    $script:remoteNotice = "Added $($found.Count) to Up next."
                    $lblStatus.Text = "Someone added $($found.Count) video$(if ($found.Count -ne 1) { 's' }) from the remote control."
                } $link
            }
        }
    }
}

# --- The screen viewers see while paused and between videos. Redrawn only when its words change. ---
function Update-Card($pl) {
    if (-not $chkCard.IsChecked) { $pl.Card = $null; $script:cardKey = ""; return }
    $next = if ($script:ytLoading) { $script:ytLoading.Name } elseif ($script:queue.Count) { $script:queue[0].Name }
    if ($pl.Ended) {
        $headline = if ($next) { "Up next" } else { "That's all for now" }
        $detail = if ($next) { $next } else { "Thanks for watching" }
    } else {
        $headline = "Paused"
        $detail = "Now playing: $($lblNow.Text)"
    }
    $key = "$headline|$detail"
    if ($key -ne $script:cardKey) {
        $script:cardKey = $key
        $pl.Card = [IntermissionCard]::Make($pl.Width, $pl.Height, $headline, $detail)
    }
}

# --- Everything useful for working out a problem, without names or links ---
function Get-ProblemReport {
    $os = Get-CimInstance Win32_OperatingSystem
    $ErrorActionPreference = "Continue"
    $lines = @(
        "VR Video Streamer problem report, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "Windows: $($os.Caption) $($os.Version)"
        "CPU: $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)"
        "Graphics: $((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', ')"
        "FFmpeg: $((& $ffmpegExe -hide_banner -version 2>$null | Select-Object -First 1)) at $ffmpegExe"
        "yt-dlp: $(if ($script:ytDlpExe) { & $script:ytDlpExe --version 2>$null } else { 'not installed' })"
        "AI tool: $(Find-AiTool)"
        "Program folder: $PSScriptRoot"
        "Source: $(if ($rbMonitor.IsChecked) { 'monitor' } elseif ($rbWindow.IsChecked) { 'program' } else { 'file or online video' })"
        "Quality: $($cbQuality.SelectedItem); $($cbFps.SelectedItem) fps; encoder: $($cbEncoder.SelectedItem); link service: $($cbTunnel.SelectedItem); public: $($chkPublic.IsChecked)"
        "Status: $($lblStat.Text)  /  $($lblStatus.Text)"
        "Subtitles: $($lblSubs.Text)"
        "Player error: $(if ($script:player) { $script:player.LastError })"
        ""
        "--- stream messages"
        (Read-Shared $OutLog 4000)
        ""
        "--- stream errors"
        ((Read-Shared $ErrLog 8000) -split "`r|`n" | Where-Object { $_ -and $_ -notmatch '^frame=' } | Select-Object -Last 30)
    )
    # Names and addresses aren't needed to find a problem, and this may get pasted somewhere public
    # The profile folder's name can differ from the account's, so both go, and any path under Users whatever it's called
    $profileName = Split-Path $env:USERPROFILE -Leaf
    $cleaned = (($lines | ForEach-Object { "$_" }) -join "`r`n") -replace '(?i)\b[a-z]:\\Users\\[^\\\s"'']+', 'C:\Users\<user>' -replace "\b$([regex]::Escape($env:USERNAME))\b", '<user>' -replace "\b$([regex]::Escape($profileName))\b", '<user>' -replace 'https?://[^\s"'']+', '<link>' -replace '(?i)\b[a-z0-9-]+\.trycloudflare\.com\b', '<link>' -replace '\b\d{1,3}(\.\d{1,3}){3}\b', '<address>'
    # Your own domain and the remote control's secret, wherever they turn up without the https:// in front
    if ("$($script:settings.PermanentHost)".Trim()) { $cleaned = $cleaned -replace [regex]::Escape("$($script:settings.PermanentHost)".Trim()), '<your domain>' }
    if ($script:remote -and $script:remote.Secret) { $cleaned = $cleaned.Replace($script:remote.Secret, '<secret>') }
    # Added afterwards, since a version number looks just like an address
    "Program version: $((Get-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'VR Video Streamer.exe') -ErrorAction SilentlyContinue).VersionInfo.FileVersion)`r`n$cleaned"
}
$btnReport.Add_Click({
        $lblStatus.Text = if (Copy-ToClipboard (Get-ProblemReport)) { "Problem report copied. Paste it to whoever's helping you. Your name and links are left out." } else { "Couldn't copy, the clipboard is busy. Try again." }
    })

$btnTestUpload.Add_Click({
        $pick = Show-UploadTest $window $qualities
        if ($null -ne $pick) { $cbQuality.SelectedIndex = $pick }
    })
$btnPermanent.Add_Click({
        if (Show-PermanentLinkDialog $window) { $cbTunnel.SelectedIndex = $tunnels.Count - 1; $chkPublic.IsChecked = $true; $cbTunnel.IsEnabled = $true }
    })

# What viewers hear: the slider acts at once, while the others restart only the decoder, which viewers barely notice
$sliderVolume.Value = $script:settings.Volume
$lblVolume.Text = "$([int]$sliderVolume.Value)%"
$chkEvenOut.IsChecked = [bool]$script:settings.EvenOut
# If this program was ever closed without cleaning up, the programs it silenced come back now
$script:quietFile = Join-Path $script:AppData "quieted-programs.txt"
Restore-QuietPrograms
$chkCard.IsChecked = [bool]$script:settings.Card
Show-If $btnAudio $false
Show-If $btnChapters $false

# Turning the preview off saves the CPU it takes to decode the stream. Viewers aren't affected.
function Update-PreviewLabel { $lblPreview.Text = if ($chkPreview.IsChecked) { "A preview of what viewers see appears here" } else { "Preview off" } }
$chkPreview.IsChecked = [bool]$script:settings.Preview
Update-PreviewLabel
$chkPreview.Add_Click({
        $script:settings.Preview = [bool]$chkPreview.IsChecked
        Save-Settings $script:settings
        Update-PreviewLabel
        $script:previewTried = $null   # back on straight away, not after the wait between retries
        if (-not $chkPreview.IsChecked) { Stop-Preview }
    })

$audioQualities = @(@{ Name = "96 kbps"; Value = "96k" }, @{ Name = "128 kbps"; Value = "128k" }, @{ Name = "192 kbps"; Value = "192k" },
                    @{ Name = "256 kbps"; Value = "256k" }, @{ Name = "320 kbps"; Value = "320k" })
foreach ($q in $audioQualities) { [void]$cbAudioQuality.Items.Add($q.Name) }
$cbAudioQuality.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($audioQualities | ForEach-Object { $_.Value }), $script:settings.AudioBitrate))
$cbAudioQuality.Add_SelectionChanged({
        $script:settings.AudioBitrate = $audioQualities[$cbAudioQuality.SelectedIndex].Value
        Save-Settings $script:settings
    })
$sliderVolume.Add_ValueChanged({
        $percent = [int]$sliderVolume.Value
        $lblVolume.Text = "$percent%"
        $script:settings.Volume = $percent
        if ($script:player) { $script:player.VolumePercent = $percent }
    })
$chkEvenOut.Add_Click({
        $script:settings.EvenOut = [bool]$chkEvenOut.IsChecked
        Save-Settings $script:settings
        if ($script:player) { $script:player.EvenOutVolume = [bool]$chkEvenOut.IsChecked; $script:player.Restart() }
    })
$chkCard.Add_Click({ $script:settings.Card = [bool]$chkCard.IsChecked; Save-Settings $script:settings })
$btnChapters.Add_Click({
        $chapters = @($script:currentVideo.Chapters | Where-Object { $_ })
        if (-not $script:player -or -not $chapters) { return }
        $now = $script:player.Position
        $current = @($chapters | Where-Object { $_.Start -le $now + 0.5 }) | Select-Object -Last 1
        $menu = New-Object System.Windows.Controls.ContextMenu
        $number = 0
        foreach ($chapter in $chapters) {
            $number++
            $row = New-Object System.Windows.Controls.MenuItem
            $title = if ($chapter.Title) { $chapter.Title } else { "Chapter $number" }
            $row.Header = "$(Format-Time $chapter.Start)   " + ($title -replace '_', '__')
            $row.Tag = [double]$chapter.Start
            $row.IsChecked = $chapter -eq $current
            $row.Add_Click({ param($s) if ($script:player) { $script:player.Seek([double]$s.Tag) } })
            [void]$menu.Items.Add($row)
        }
        $btnChapters.ContextMenu = $menu
        $menu.PlacementTarget = $btnChapters
        $menu.Placement = "Bottom"
        $menu.IsOpen = $true
    })
$btnAudio.Add_Click({
        $sounds = @($script:currentVideo.Sounds)
        $menu = New-Object System.Windows.Controls.ContextMenu
        for ($i = 0; $i -lt $sounds.Count; $i++) {
            $known = $script:SubtitleLanguages | Where-Object { Test-Language $sounds[$i].Language $_.Code } | Select-Object -First 1
            $name = if ($known) { $known.Name } elseif ($sounds[$i].Language) { $sounds[$i].Language } else { "Track $($i + 1)" }
            if ($sounds[$i].Title) { $name = "$name, $($sounds[$i].Title)" }
            $row = New-Object System.Windows.Controls.MenuItem
            $row.Header = $name
            $row.Tag = $i
            $row.IsChecked = $script:player -and $script:player.AudioTrack -eq $i
            $row.Add_Click({ param($s) if ($script:player) { $script:player.AudioTrack = [int]$s.Tag; $script:player.Restart() } })
            [void]$menu.Items.Add($row)
        }
        $btnAudio.ContextMenu = $menu
        $menu.PlacementTarget = $btnAudio
        $menu.Placement = "Bottom"
        $menu.IsOpen = $true
    })
$btnStop.Add_Click({ Stop-Stream })
$window.Add_Closing({ Stop-Stream; Restore-QuietPrograms; if ($script:trayIcon) { $script:trayIcon.Dispose() } })

function Read-Shared($path, $tailBytes = 0) {
    if (-not (Test-Path $path)) { return "" }
    $fs = [IO.File]::Open($path, "Open", "Read", "ReadWrite")
    try {
        if ($tailBytes -and $fs.Length -gt $tailBytes) { [void]$fs.Seek(-$tailBytes, "End") }
        (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Dispose() }
}

# The picture viewers get, live (see PreviewFeed.cs). Nobody can see it while the window is minimized, say while
# you're in your headset, so it stops then rather than spend CPU decoding the stream.
function Update-Preview {
    if (-not $chkPreview.IsChecked -or $window.WindowState -eq "Minimized") { if ($script:preview) { Stop-Preview }; return }
    # If it keeps failing (a firewall, say), retry now and then rather than twice a second
    if ((-not $script:preview -or -not $script:preview.Running) -and (-not $script:previewTried -or ((Get-Date) - $script:previewTried).TotalSeconds -ge 5)) {
        $script:previewTried = Get-Date
        if ($script:preview) { $script:preview.Stop() }
        $script:preview = New-Object PreviewFeed($ffmpegExe, "rtsp://127.0.0.1:8554/desktop", $imgPreview)
        $script:preview.Start()
    }
    if ($script:preview -and $script:preview.FramesShown -gt 0) { Show-If $lblPreview $false }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ try {
        if (-not $script:proc) { return }
        $out = Read-Shared $OutLog
        # The newest link: the stream script opens another by itself if the link service drops (a free service's is a new address)
        $newest = [regex]::Matches($out, 'PUBLIC LINK \(via ([^)]+)\)[^\r\n]*\r?\n\s+(https://\S+)') | Select-Object -Last 1
        if ($newest -and $newest.Groups[2].Value -ne $script:publicShown) {
            $changed = [bool]$script:publicShown
            $script:publicShown = $newest.Groups[2].Value
            $script:publicVia = $newest.Groups[1].Value
            $linkBoxes.public.Text = $script:publicShown
            $script:linkCopied = Copy-ToClipboard $linkBoxes.public.Text
            if ($changed) {
                $script:recoverNotice = "The link service dropped and reconnected by itself, so viewers need the new video player link$(if ($script:linkCopied) { ' (copied)' })."
                $script:recoverNoticeAt = Get-Date
                $script:publicFails = 0; $script:linkStalled = $false
                Show-NewLinkAlert "The link service dropped and reconnected at a new address."
            } elseif ($script:linkBeforeRestart -and $script:linkBeforeRestart -ne $script:publicShown) {
                # The stream restarted by itself (Start-Recovery) and a free link came back at a new address.
                # A permanent link comes back the same, so viewers keep watching and there's nothing to say.
                Show-NewLinkAlert $script:restartWhy
            }
            $script:linkBeforeRestart = $null
        }
        $lastDrop = $out.LastIndexOf("The public link service disconnected")
        $script:linkReconnecting = $lastDrop -ge 0 -and (-not $newest -or $lastDrop -gt $newest.Index)
        Update-RemoteLink
        $tunnelStep = ([regex]::Matches($out, 'Opening public link via ([^\r\n]+?)\.\.\.') | Select-Object -Last 1)
        $publicFailed = $chkPublic.IsChecked -and $out -match 'Could not open a public link'
        if ($publicFailed) { $linkBoxes.public.Text = "(failed - press Stop, then Start to try again)" }

        $pl = $script:player
        if ($pl) {
            $pnlPlayer.IsEnabled = $true
            # "Loop" only applies once nothing is waiting, otherwise the queue would never move
            $pl.Loop = $chkLoop.IsChecked -and $script:queue.Count -eq 0 -and -not $chkRepeat.IsChecked
            if ($pl.Ended -and -not $script:ytLoading) {
                if ($script:queue.Count) { Start-QueueItem 0 }
                elseif ($chkRepeat.IsChecked -and $script:nowItem) {
                    # Nothing left: go round again, starting with what just finished
                    [void]$script:queue.Add($script:nowItem)
                    $script:nowItem = $null
                    Start-QueueItem 0
                }
            }
            Update-Card $pl
            $btnSkip.IsEnabled = $script:queue.Count -gt 0
            $lblPlay.Text = if ($pl.Paused) { [string][char]0xE768 } else { [string][char]0xE769 }
            $starved = $pl.StarvedFrames - $script:lastStarved
            $script:lastStarved = $pl.StarvedFrames
            $script:slowTicks = if ($starved -gt 3) { 6 } elseif ($script:slowTicks -gt 0) { $script:slowTicks - 1 } else { 0 }
            if (-not $script:dragging -and $pl.Duration -gt 0) {
                $seekBar.Value = [Math]::Min($seekBar.Maximum, $pl.Position / $pl.Duration * $seekBar.Maximum)
                $lblTimeLeft.Text = Format-Time $pl.Position
                $lblTimeRight.Text = Format-Time $pl.Duration
            }
        }

        $err = Read-Shared $ErrLog 4096
        $stats = ($err -split "`r|`n" | Where-Object { $_ -match '^frame=' } | Select-Object -Last 1)
        if ($script:proc.HasExited -or ($pl -and -not $pl.Running)) {
            $problems = ($err -split "`r|`n" | Where-Object { $_ -and $_ -notmatch '^frame=|^size=|^\s' } | Select-Object -Last 3) -join "  "
            if ($pl -and $pl.LastError -and -not $script:userStopped) { $problems = "$problems  $($pl.LastError)".Trim() }
            if (-not $script:userStopped -and (Start-Recovery "The stream stopped unexpectedly.")) { return }
            $userStopped = $script:userStopped
            Stop-Stream
            $lblStatus.Text = if ($userStopped) { "Stopped." }
                              elseif ($problems) { "Stopped: $problems" } else { "Stopped." }
            $lblStatus.Foreground = $mutedBrush
            $script:proc = $null
            foreach ($tb in $linkBoxes.Values) { $tb.Text = "" }
            Show-NowPlaying "Nothing playing"
            $lblTimeLeft.Text = "--:--"; $lblTimeRight.Text = "--:--"; $seekBar.Value = 0
            $lblPlay.Text = [string][char]0xE769
            Show-If $pillLive $false
            $lblStat.Text = "Ready"
            Update-Enabled
        } elseif ($stats -and $stats -match 'fps=\s*([\d.]+).*time=(\S+)') {
            Show-If $pillLive $true
            $lblStat.Text = "$($Matches[1]) fps  -  running $($Matches[2])"
            Update-SlowWarning $Matches[2]
            $script:wasLive = $true
            Update-Preview
            $script:liveTicks = [int]$script:liveTicks + 1
            if ($script:liveTicks % 4 -eq 0) { Update-ViewerStats }
            if ($script:liveTicks % 30 -eq 0 -and -not $script:linkReconnecting) { Test-PublicLink }
            Update-RemoteState
            $soundGone = @($script:soundPids | Where-Object { -not (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count -gt 0
            $minimized = $script:streamHwnd -and [UI.Win]::IsIconic([IntPtr]$script:streamHwnd)
            $lines = @()
            if ($script:ytLoading) { $lines += "Getting '$($script:ytLoading.Name)'..." }
            elseif ($pl -and $pl.Ended -and $pl.LastError -and $pl.Position -lt 1) { $lines += "Couldn't play that file: $($pl.LastError). Press Change video to pick another. The stream is still running." }
            elseif ($pl -and $pl.Ended) { $lines += "Finished. Add more to Up next, press Change video, press Play to watch again, or click the bar to jump." }
            elseif ($pl -and $pl.Paused) { $lines += $(if ($chkCard.IsChecked) { "Paused: viewers see the Paused screen." } else { "Paused: viewers see the paused picture." }) }
            elseif ($minimized) { $lines += "The program is minimized, so viewers see a frozen picture. Restore it (behind other windows is fine)." }
            if ($script:recoverNotice -and ((Get-Date) - $script:recoverNoticeAt).TotalMinutes -gt 3) { $script:recoverNotice = "" }
            if ($script:recoverNotice) { $lines += $script:recoverNotice }
            if ($script:ytNotice) { $lines += $script:ytNotice }
            if ($script:subsNotice) { $lines += $script:subsNotice }
            if ($pl -and $script:slowTicks -gt 0) { $lines += "The video is arriving more slowly than it plays, so viewers will see stutters." }
            if ($script:linkReconnecting) { $lines += "The video player link dropped. Reconnecting by itself... The stream keeps going, and viewers get the new link." }
            elseif ($script:linkStalled -and $linkBoxes.public.Text) { $lines += "The video player link isn't answering just now. It usually comes back by itself at the same address, so viewers can keep the link they have." }
            elseif ($publicFailed) { $lines += "The video player link failed, so nobody can watch. Press Stop, wait a minute, and Start again." }
            elseif ($linkBoxes.public.Text) { $lines += "Video player link (via $($script:publicVia))$(if ($script:linkCopied) { ' copied to clipboard' } else { ' ready: press Copy next to it' }). Anyone with it can watch until you press Stop." }
            if ($soundGone) { $lines += "A program you picked for sound has closed, so viewers no longer hear it. Press Refresh list and tick another." }
            # Only for a source that's still ticked: a problem with one you've since unticked no longer matters
            $soundProblem = [regex]::Matches($out, "(?m)^Sound problem \[([^\]]+)\]: ([^\r\n]+)") | Where-Object { $script:soundFile -and @(Get-Content -LiteralPath $script:soundFile -ErrorAction SilentlyContinue | ForEach-Object { ($_ -split "`t")[0] }) -contains $_.Groups[1].Value } | Select-Object -Last 1
            if ($soundProblem) { $soundGone = $true; $lines += "Couldn't capture $($soundProblem.Groups[1].Value -replace '^(dev|app):', ''): $($soundProblem.Groups[2].Value)" }
            $muteProblem = [regex]::Matches($out, "(?m)^Sound problem \[mute\]: ([^\r\n]+)") | Select-Object -Last 1
            if ($muteProblem -and @($script:soundQuiet).Count) { $soundGone = $true; $lines += "Couldn't mute a program on this PC: $($muteProblem.Groups[1].Value)" }
            # Why the service that gave the link wasn't the first choice, or why none worked
            $skipped = [regex]::Matches($out, "(?m)^(.+?) didn't work: ([^\r\n]+)") | Where-Object { $_.Groups[1].Value -ne $script:publicVia } | Select-Object -Last 1
            if ($skipped -and ($linkBoxes.public.Text -or $publicFailed)) { $lines += "$($skipped.Groups[1].Value) was skipped: $($skipped.Groups[2].Value)" }
            elseif ($out -match "(?m)^(Note: the link is working[^\r\n]+)") { $lines += $Matches[1] }
            $lblStatus.Text = $lines -join "`n"
            $warn = $soundGone -or $publicFailed -or $minimized -or $script:slowTicks -gt 0 -or $script:linkReconnecting
            $lblStatus.Foreground = if ($warn) { $redBrush } else { $mutedBrush }
        } elseif ($chkPublic.IsChecked -and -not $linkBoxes.public.Text) {
            $lblStatus.Text = "Starting... opening the video player link" +
                $(if ($tunnelStep) { " via $($tunnelStep.Groups[1].Value)" } else { "" }) + " (10-20 s, up to a minute if Cloudflare is slow)"
        }
    } catch { $lblStatus.Text = "Problem updating the window: $($_.Exception.Message)" } })
$timer.Start()

# Answers from yt-dlp and background tasks, and the capture clock for subtitles
$quickTimer = New-Object System.Windows.Threading.DispatcherTimer
$quickTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$quickTimer.Add_Tick({ try {
        Update-YouTubeJobs
        Update-SubtitleTasks
        Update-AiSubs
        Invoke-RemoteCommands
        if ($script:updateState -eq "downloading" -and $script:updateProgress.Total -gt 0) {
            $lblUpdate.Text = "Downloading $([Math]::Min(100, [int](100 * $script:updateProgress.Done / $script:updateProgress.Total)))%"
        }
        # Slider moves are gathered up rather than sent and saved dozens of times a second
        if ($script:soundDirty -and $script:soundFile) { Send-SoundPicks }
        if ($script:settingsDirty -and (-not $script:settingsSavedAt -or ((Get-Date) - $script:settingsSavedAt).TotalSeconds -ge 1)) {
            $script:settingsDirty = $false
            $script:settingsSavedAt = Get-Date
            $script:settings.SoundVolumes = (@($script:soundVolumes.GetEnumerator() | Where-Object { $_.Value -ne 100 } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
            try { Save-Settings $script:settings } catch { }
        }
        $lblSubsTime.Text = if ($script:subsName -and -not $script:player -and -not $rbFile.IsChecked) { Format-Time $script:overlay.ClockPosition } else { "" }
    } catch { $lblStatus.Text = "Problem updating the window: $($_.Exception.Message)" } })
$quickTimer.Start()

# --- Updates. The version shows in the corner. GitHub is asked once per start, in the background, and the button
# beside it asks again. When there's a newer version, the button downloads it, checks it against its published
# checksum, and hands over to Install-Update.ps1, which copies it over this folder once the window has closed. ---
$script:releasesApi = "https://api.github.com/repos/Kubi-Cle/VR-Video-Streamer/releases/latest"
$script:appRoot = Split-Path $PSScriptRoot
$script:updateFolder = Join-Path $script:AppData "update"
$script:updateState = "idle"       # idle, checking, available, downloading
$script:update = $null             # what GitHub has: Version, Page, Zip, Sum, Size
$script:updateProgress = [hashtable]::Synchronized(@{ Done = [long]0; Total = [long]0 })
function Get-ProgramVersion {
    $v = (Get-Item -LiteralPath (Join-Path $script:appRoot 'VR Video Streamer.exe') -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    $parsed = $null
    if ([version]::TryParse("$v", [ref]$parsed)) { New-Object version($parsed.Major, $parsed.Minor, [Math]::Max(0, $parsed.Build)) }
}
$lblVersion.Text = if (Get-ProgramVersion) { "Version $(Get-ProgramVersion)" } else { "" }
function Set-UpdateButton($text, $tip, $glyph = [char]0xE72C) {
    $lblUpdate.Text = $text
    $icoUpdate.Text = $glyph
    $btnUpdate.ToolTip = $tip
}

function Start-UpdateCheck([switch]$Quiet) {
    if ($script:updateState -eq "checking" -or $script:updateState -eq "downloading" -or -not (Get-ProgramVersion)) { return }
    $script:updateState = "checking"
    if (-not $Quiet) { Set-UpdateButton "Checking..." "Asking GitHub for the newest version" }
    Start-SubtitleTask {
        param($api)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod $api -TimeoutSec 15 -Headers @{ "User-Agent" = "VR Video Streamer"; Accept = "application/vnd.github+json" }
        $zip = @($r.assets | Where-Object { $_.name -match '^VR-Video-Streamer-[\d.]+\.zip$' })[0]
        $sum = if ($zip) { @($r.assets | Where-Object { $_.name -eq "$($zip.name).sha256.txt" })[0] }
        @{ Tag = "$($r.tag_name)"; Page = "$($r.html_url)"; Zip = "$($zip.browser_download_url)"; Sum = "$($sum.browser_download_url)"; Size = [long]$zip.size }
    } @($script:releasesApi) {
        param($latest, $why, $quiet)
        $script:updateState = "idle"
        if (-not $latest -or $latest.Tag -notmatch '(\d+)\.(\d+)(?:\.(\d+))?') {
            # Offline, or GitHub busy. A check at start says nothing; it's tried again next time.
            if (-not $quiet) { Set-UpdateButton "Couldn't check" "GitHub didn't answer$(if ($why) { ": $why" }). Click to try again." }
            return
        }
        $theirs = New-Object version([int]$Matches[1], [int]$Matches[2], [int]("0$($Matches[3])"))
        if ($theirs -le (Get-ProgramVersion)) {
            if (-not $quiet) { Set-UpdateButton "Up to date" "You have the newest version. Click to check again." ([char]0xE73E) }
            return
        }
        # Only files from this project's own GitHub releases are downloaded
        $from = '^https://github\.com/Kubi-Cle/[\w.-]+/releases/download/'
        $script:update = @{ Version = $theirs; Page = $latest.Page; Zip = $latest.Zip; Sum = $latest.Sum; Size = $latest.Size }
        $script:updateState = "available"
        if ($latest.Zip -notmatch $from -or $latest.Sum -notmatch $from) { $script:update.Zip = $null }
        Set-UpdateButton "Update to $theirs" "Downloads and installs version $theirs, then restarts the program. Your settings are kept." ([char]0xE896)
    } $Quiet.IsPresent
}

# Can this folder be written to? A copy in Program Files can't be without asking for admin, so it gets the download page.
function Test-AppFolderWritable {
    $probe = Join-Path $script:appRoot "update-check-$PID.tmp"
    try { [IO.File]::WriteAllText($probe, "x"); Remove-Item -LiteralPath $probe -Force; $true } catch { $false }
}

function Open-UpdatePage {
    if ("$($script:update.Page)" -match '^https://github\.com/') { Start-Process "$($script:update.Page)" }
}

function Start-UpdateDownload {
    $u = $script:update
    if ($script:proc -and -not $script:proc.HasExited) { Show-Notice "Stop streaming first, then press Update again."; return }
    if (-not $u.Zip -or -not (Test-AppFolderWritable)) {
        $why = if (-not $u.Zip) { "This version can't be installed automatically." } else { "The program can't change its own folder ($script:appRoot), so it can't install updates itself." }
        if ((Show-Message $window "$why`n`nOpen the download page instead?" @("Open download page", "Cancel")) -eq "Open download page") { Open-UpdatePage }
        return
    }
    $size = if ($u.Size -gt 0) { " ($([Math]::Round($u.Size / 1MB)) MB)" } else { "" }
    $answer = Show-Message $window ("Download version $($u.Version)$size and install it?`n`nThe program closes while the new files are copied in, then opens again by itself. " +
        "Your settings, FFmpeg and other downloads are kept.") @("Update", "Not now", "See what's new")
    if ($answer -eq "See what's new") { Open-UpdatePage; return }
    if ($answer -ne "Update") { return }
    $script:updateState = "downloading"
    $script:updateProgress.Done = 0; $script:updateProgress.Total = $u.Size
    Set-UpdateButton "Downloading..." "Downloading version $($u.Version)" ([char]0xE896)
    Update-Enabled
    Start-SubtitleTask {
        param($zipUrl, $sumUrl, $folder, $progress)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
        New-Item -ItemType Directory -Force $folder | Out-Null
        $sumText = (Invoke-WebRequest $sumUrl -UseBasicParsing -TimeoutSec 30 -UserAgent "VR Video Streamer").Content
        if ($sumText -is [byte[]]) { $sumText = [Text.Encoding]::ASCII.GetString($sumText) }
        $expected = ("$sumText".Trim() -split '\s+')[0]
        if ($expected -notmatch '^[0-9A-Fa-f]{64}$') { throw "The release's checksum file doesn't look right." }
        $zip = Join-Path $folder "update.zip"
        $request = [Net.HttpWebRequest]::Create($zipUrl)
        $request.UserAgent = "VR Video Streamer"
        $request.Timeout = 30000; $request.ReadWriteTimeout = 60000
        $response = $request.GetResponse()
        try {
            if ($response.ContentLength -gt 0) { $progress.Total = $response.ContentLength }
            $in = $response.GetResponseStream()
            $out = [IO.File]::Create($zip)
            try {
                $buffer = New-Object byte[] 262144
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) { $out.Write($buffer, 0, $n); $progress.Done += $n }
            } finally { $out.Dispose(); $in.Dispose() }
        } finally { $response.Close() }
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected.ToUpper()) { throw "The download didn't match its published checksum, so it wasn't installed. Try again later." }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $folder "new"))
        Remove-Item -LiteralPath $zip -Force
        $new = Join-Path $folder "new\VR Video Streamer"
        foreach ($need in "VR Video Streamer.exe", "app\StreamUI.ps1", "app\Install-Update.ps1") {
            if (-not (Test-Path -LiteralPath (Join-Path $new $need))) { throw "The download is missing $need." }
        }
        $new
    } @($u.Zip, $u.Sum, $script:updateFolder, $script:updateProgress) {
        param($new, $why)
        if ($why -or -not $new) {
            $script:updateState = "available"
            Update-Enabled
            Set-UpdateButton "Update to $($script:update.Version)" "Downloads and installs version $($script:update.Version), then restarts the program." ([char]0xE896)
            Show-Notice "The update didn't download: $(if ($why) { $why } else { 'no files arrived' })"
            return
        }
        Install-DownloadedUpdate $new
    }
}

# The window can't replace its own files while it's open, so a separate PowerShell does it after this one closes.
# It's started through WMI so it isn't part of this window's process group, which takes everything started
# from it down when the window closes.
function Install-DownloadedUpdate($new) {
    $installer = Join-Path $script:updateFolder "Install-Update.ps1"
    Copy-Item -LiteralPath (Join-Path $new "app\Install-Update.ps1") -Destination $installer -Force
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $command = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installer`" -WaitFor $PID -From `"$new`" -To `"$script:appRoot`""
    $started = $null
    try { $started = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command; CurrentDirectory = $script:updateFolder } -ErrorAction Stop } catch { }
    if (-not $started -or $started.ReturnValue -ne 0) {
        $script:updateState = "available"
        Update-Enabled
        Set-UpdateButton "Update to $($script:update.Version)" "Downloads and installs version $($script:update.Version), then restarts the program." ([char]0xE896)
        if ((Show-Message $window "The update downloaded, but Windows wouldn't start the installer.`n`nOpen the download page instead?" @("Open download page", "Cancel")) -eq "Open download page") { Open-UpdatePage }
        return
    }
    Set-UpdateButton "Restarting..." "Installing version $($script:update.Version)" ([char]0xE896)
    $window.Close()
}

$btnUpdate.Add_Click({
        switch ($script:updateState) {
            "idle" { Start-UpdateCheck }
            "available" { Start-UpdateDownload }
        }
    })
if ($script:settings.UpdateCheck) { Start-UpdateCheck -Quiet }

$script:windowReady = $true
Update-SoundList
Update-Queue
if ($DroppedFile -and (Test-Path -LiteralPath $DroppedFile)) { Set-File $DroppedFile }
Update-Enabled
Update-SubsLabel
[void]$window.ShowDialog()
$timer.Stop()
$quickTimer.Stop()
Stop-Stream
if ($script:remote) { $script:remote.Stop() }
$script:settings.SoundVolumes = (@($script:soundVolumes.GetEnumerator() | Where-Object { $_.Value -ne 100 } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
try { Save-Settings $script:settings } catch { }
$script:overlay.Stop()
Remove-Item -LiteralPath $subtitleTextFile -Force -ErrorAction SilentlyContinue
# The stream's messages and the link service's logs name the stream's link, so they don't outlive the window.
# The stream script is stopped outright, so its own cleanup doesn't run, and cloudflared holds its log open until
# Windows has taken it down too: wait for that (a few seconds at most), then delete them.
if ($script:proc) { try { [void]$script:proc.WaitForExit(5000) } catch { } }
$until = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $until -and @(Get-Process cloudflared -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($toolsFolder, [StringComparison]::OrdinalIgnoreCase) }).Count) { Start-Sleep -Milliseconds 200 }
$leftovers = @(Get-ChildItem -LiteralPath $toolsFolder -Filter "tunnel-*.log*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) + @($script:OutLog, $script:ErrLog)
foreach ($try in 1..5) {
    $leftovers = @($leftovers | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Where-Object { try { Remove-Item -LiteralPath $_ -Force -ErrorAction Stop; $false } catch { $true } })
    if (-not $leftovers.Count) { break }
    Start-Sleep -Milliseconds 300
}
if ($script:ytWindow) { try { $script:ytWindow.Close() } catch { } }
