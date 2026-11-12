<#
.SYNOPSIS
  Checks a VR Video Streamer release on a real Windows PC before people get it: the zip unpacks properly, every
  script and C# file is accepted by this PC's Windows PowerShell, and each way of streaming really works, measured
  from the stream viewers would get. Nothing goes on the internet: the test streams stay on this PC.

  powershell -ExecutionPolicy Bypass -File build\Test-Release.ps1 -Zip release\VR-Video-Streamer-1.2.5.zip
  powershell -ExecutionPolicy Bypass -File build\Test-Release.ps1 -Latest      (downloads the newest release from GitHub)

  Close VR Video Streamer first. Takes about 5-10 minutes; a test window with a moving pattern opens for a while.
  The result is printed at the end and saved next to the zip as <zip>-test-report.txt.
#>
param(
    [string]$Zip = "",
    [switch]$Latest,
    [int]$Seconds = 10,          # how long each stream is measured
    [switch]$Quick               # 30 and 60 fps on one encoder only
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$results = New-Object System.Collections.ArrayList
function Add-Result($name, $pass, $detail) {
    [void]$results.Add([pscustomobject]@{ Test = $name; Result = $(if ($pass) { "PASS" } else { "FAIL" }); Detail = $detail })
    Write-Host ("  {0}  {1,-46} {2}" -f $(if ($pass) { "PASS" } else { "FAIL" }), $name, $detail) -ForegroundColor $(if ($pass) { "Green" } else { "Red" })
}

if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "VR Video Streamer" }) { throw "Close VR Video Streamer first." }
$work = Join-Path $env:TEMP "vvs-release-test-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# --- The zip ---
if ($Latest) {
    Write-Host "Downloading the newest release from GitHub..." -ForegroundColor Cyan
    $release = Invoke-RestMethod "https://api.github.com/repos/Kubi-Cle/VR-Video-Streamer/releases/latest" -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -match '^VR-Video-Streamer-[\d.]+\.zip$' })[0]
    $sumAsset = @($release.assets | Where-Object { $_.name -eq "$($asset.name).sha256.txt" })[0]
    $Zip = Join-Path $work $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $Zip -UseBasicParsing
    $expected = ((Invoke-WebRequest $sumAsset.browser_download_url -UseBasicParsing).Content -split '\s+')[0]
    if ($expected -is [byte[]]) { $expected = [Text.Encoding]::ASCII.GetString($expected) }
    $actual = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
    Add-Result "Download matches its published checksum" ($actual -eq $expected.Trim().ToUpper()) "$($release.tag_name), $([int]((Get-Item $Zip).Length / 1MB)) MB"
}
if (-not $Zip -or -not (Test-Path -LiteralPath $Zip)) { throw "Give the release zip with -Zip, or use -Latest." }
$Zip = (Resolve-Path -LiteralPath $Zip).Path
Write-Host "Testing $Zip" -ForegroundColor Cyan

Write-Host "--- Unpacking" -ForegroundColor Cyan
# Explorer's own extractor (what people use with right-click > Extract All)
$explorerOut = Join-Path $work "explorer"
New-Item -ItemType Directory -Force $explorerOut | Out-Null
$shell = New-Object -ComObject Shell.Application
$items = $shell.NameSpace($Zip).Items()
$shell.NameSpace($explorerOut).CopyHere($items, 4 + 16 + 1024)
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline -and @(Get-ChildItem $explorerOut -Recurse -File -ErrorAction SilentlyContinue).Count -lt 41) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 2
$app = Join-Path $explorerOut "VR Video Streamer"
$flat = @(Get-ChildItem $explorerOut -File | Where-Object { $_.Name -like "VR Video Streamer*\*" -or $_.Name -match [char]0xF05C })
Add-Result "Explorer unpacks it into folders" ((Test-Path (Join-Path $app "VR Video Streamer.exe")) -and (Test-Path (Join-Path $app "app\StreamUI.ps1")) -and $flat.Count -eq 0) "$(@(Get-ChildItem $explorerOut -Recurse -File).Count) files"
# The in-app updater's way
$dotnetOut = Join-Path $work "dotnet"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($Zip, $dotnetOut)
Add-Result "The updater's unpacking works" (Test-Path (Join-Path $dotnetOut "VR Video Streamer\app\Install-Update.ps1")) ""
if (-not (Test-Path (Join-Path $app "app\StreamUI.ps1"))) { $app = Join-Path $dotnetOut "VR Video Streamer" }
$bad = @()
foreach ($line in Get-Content -LiteralPath (Join-Path $app "CHECKSUMS.txt")) {
    if ($line -notmatch '^([0-9A-F]{64})\s+(.+)$') { continue }
    $file = Join-Path $app $Matches[2]
    if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Matches[1]) { $bad += $Matches[2] }
}
Add-Result "Every file matches CHECKSUMS.txt" ($bad.Count -eq 0) $(if ($bad) { "different: $($bad -join ', ')" } else { "" })
$exeVersion = (Get-Item (Join-Path $app "VR Video Streamer.exe")).VersionInfo.FileVersion
$readme = (Get-Content -LiteralPath (Join-Path $app "README.txt") -TotalCount 1)
Add-Result "Launcher version matches the README" ($readme -match "Version $([regex]::Escape(($exeVersion -replace '\.0$', '')))\b") "exe $exeVersion; README: $readme"

Write-Host "--- Scripts and C# (this PC's Windows PowerShell)" -ForegroundColor Cyan
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$parseErrors = @()
foreach ($f in Get-ChildItem (Join-Path $app "app") -Filter *.ps1) {
    $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs) { $parseErrors += "$($f.Name):$($errs[0].Extent.StartLineNumber) $($errs[0].Message)" }
}
Add-Result "Every script parses" ($parseErrors.Count -eq 0) ($parseErrors -join "; ")
# Compiled the way the program does (Add-Type), each group in its own PowerShell like the program's processes
$groups = @(
    @{ Files = "KillOnClose.cs"; Refs = "" },
    @{ Files = "FrameRelay.cs"; Refs = "System.Core" },
    @{ Files = "ProcessAudio.cs,DeviceAudio.cs,SoundMixer.cs,SessionQuiet.cs"; Refs = "System.Core" },
    @{ Files = "PipePlayer.cs,SubtitleOverlay.cs,SegmentProxy.cs,SessionQuiet.cs,RemoteProxy.cs"; Refs = "System.Core" },
    @{ Files = "PreviewFeed.cs,IntermissionCard.cs,QrCode.cs"; Refs = "PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Drawing,System.Core" }
)
foreach ($g in $groups) {
    $paths = ($g.Files -split ",") | Where-Object { Test-Path (Join-Path $app "app\$_") } | ForEach-Object { "'" + (Join-Path $app "app\$_") + "'" }
    $refs = if ($g.Refs) { " -ReferencedAssemblies " + (($g.Refs -split ",") -join ",") } else { "" }
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -Command "try { Add-Type -Path $($paths -join ',')$refs; 'OK' } catch { `$_.Exception.Message }" 2>&1 | Out-String
    Add-Result "C# compiles: $($g.Files)" ($out.Trim() -eq "OK") $(if ($out.Trim() -ne "OK") { $out.Trim().Substring(0, [Math]::Min(200, $out.Trim().Length)) } else { "" })
}

# --- Streams ---
. (Join-Path $app "app\FFmpegSetup.ps1")
$ffmpeg = Find-FFmpeg (Join-Path $app "app\tools")
if (-not $ffmpeg) { throw "FFmpeg wasn't found. Open VR Video Streamer once so it can download it, then run this again." }
$ffprobe = Join-Path (Split-Path $ffmpeg) "ffprobe.exe"
Write-Host "--- Streams (FFmpeg: $ffmpeg)" -ForegroundColor Cyan
function Test-Encoder($codec) {
    $ErrorActionPreference = "Continue"
    & $ffmpeg -hide_banner -loglevel quiet -nostdin -f lavfi -i "color=black:s=1280x720:r=30" -frames:v 5 -c:v $codec -f null - 2>$null
    $LASTEXITCODE -eq 0
}
$encoders = @("cpu")
foreach ($e in @(@{ V = "nvenc"; C = "h264_nvenc" }, @{ V = "amf"; C = "h264_amf" }, @{ V = "qsv"; C = "h264_qsv" })) { if (Test-Encoder $e.C) { $encoders += $e.V; break } }
if ($Quick) { $encoders = @($encoders[-1]) }

# Test video: one white frame and a short beep at exactly the same moment every 2 s, so sync can be measured
$syncFile = Join-Path $work "sync.mp4"
$ErrorActionPreference = "Continue"
& $ffmpeg -v error -y -f lavfi -i "color=black:s=1920x1080:r=60:d=180,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,2)\,1/60)',drawbox=x='mod(t*400\,iw-100)':y=500:w=100:h=100:color=red:t=fill" `
    -f lavfi -i "sine=f=1000:r=48000:d=180,volume='if(lt(mod(t\,2)\,0.05)\,1\,0)':eval=frame" -c:v libx264 -preset veryfast -g 60 -c:a aac -b:a 192k $syncFile 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

function Measure-Stream([switch]$Sync) {
    $rec = Join-Path $work "rec-$([guid]::NewGuid().ToString('n')).ts"
    $ErrorActionPreference = "Continue"
    & $ffmpeg -v error -y -i "http://127.0.0.1:8888/desktop/index.m3u8" -t $Seconds -map 0 -c copy $rec 2>&1 | Out-Null
    if (-not (Test-Path $rec) -or (Get-Item $rec).Length -eq 0) { return @{ Ok = $false } }
    $r = @{ Ok = $true }
    $fm = & $ffmpeg -v error -i $rec -map 0:v:0 -f framemd5 - 2>$null
    $tb = ($fm | Where-Object { $_ -match '^#tb 0: (\d+)/(\d+)' } | Select-Object -First 1); [void]($tb -match '(\d+)/(\d+)'); $tbv = [double]$Matches[1] / [double]$Matches[2]
    $rows = @($fm | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object { , ($_ -split ',') })
    if ($rows.Count -gt 1) {
        $span = ([double]$rows[-1][2] - [double]$rows[0][2]) * $tbv
        $changes = 0; for ($i = 1; $i -lt $rows.Count; $i++) { if ($rows[$i][5].Trim() -ne $rows[$i - 1][5].Trim()) { $changes++ } }
        $r.Fps = [Math]::Round($rows.Count / $span, 1); $r.Distinct = [Math]::Round($changes / $span, 1)
    }
    $r.Audio = [bool](& $ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $rec)
    if ($Sync) {
        $flashes = @(); $t = $null
        foreach ($line in (& $ffmpeg -v error -i $rec -map 0:v:0 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" -f null - 2>$null)) {
            if ($line -match 'pts_time:([\d.]+)') { $t = [double]$Matches[1] }
            if ($line -match 'YAVG=([\d.]+)' -and $null -ne $t -and [double]$Matches[1] -gt 128 -and ($flashes.Count -eq 0 -or $t - $flashes[-1] -gt 1)) { $flashes += $t }
        }
        $beeps = @((& $ffmpeg -v info -nostats -i $rec -map 0:a:0 -af "silencedetect=n=-30dB:d=0.3" -f null - 2>&1) | ForEach-Object { if ("$_" -match 'silence_end: ([\d.]+)') { [double]$Matches[1] } })
        $r.Sync = @(foreach ($f in $flashes) { $near = $beeps | Sort-Object { [Math]::Abs($_ - $f) } | Select-Object -First 1; if ($null -ne $near -and [Math]::Abs($near - $f) -lt 0.9) { [int](($near - $f) * 1000) } })
    }
    $ErrorActionPreference = "Stop"
    Remove-Item $rec -Force -ErrorAction SilentlyContinue
    $r
}

function Wait-Live {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest "http://127.0.0.1:8888/desktop/index.m3u8" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { return $true } } catch { }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Test-Stream($name, $streamArgs, $fps, [switch]$Sync, [scriptblock]$Before, [scriptblock]$After) {
    $state = $null
    if ($Before) { $state = & $Before }
    $script = Join-Path $app "app\Start-DesktopStream.ps1"
    $log = Join-Path $work "stream-$([guid]::NewGuid().ToString('n')).txt"
    $p = Start-Process $psExe -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"") + $streamArgs + @("-Fps", $fps) -join " ") -PassThru -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    $live = Wait-Live
    $m = @{ Ok = $false }
    if ($live) { Start-Sleep -Seconds 6; $m = Measure-Stream -Sync:$Sync }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    if ($After) { & $After $state }
    Start-Sleep -Seconds 3
    $left = @(Get-Process mediamtx, cloudflared -ErrorAction SilentlyContinue)
    $why = @()
    if (-not $live) { $why += "never went live: " + ((Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^frame=' } | Select-Object -Last 3) -join " ") }
    elseif (-not $m.Ok) { $why += "couldn't record the stream" }
    else {
        if ($m.Fps -lt $fps * 0.97) { $why += "only $($m.Fps) fps" }
        if ($m.Distinct -lt $fps * 0.9 -and $name -notmatch "monitor") { $why += "only $($m.Distinct) distinct frames/s" }
        if (-not $m.Audio -and $name -notmatch "monitor|window") { $why += "no sound" }
        if ($Sync) { if (-not $m.Sync -or $m.Sync.Count -lt 2) { $why += "couldn't measure sync" } elseif (($m.Sync | Measure-Object -Maximum).Maximum -gt 100 -or ($m.Sync | Measure-Object -Minimum).Minimum -lt -100) { $why += "out of sync: $($m.Sync -join ',') ms" } }
    }
    if ($left) { $why += "left running: $(($left | ForEach-Object Name) -join ',')"; $left | Stop-Process -Force -ErrorAction SilentlyContinue }
    $detail = "$($m.Fps) fps, $($m.Distinct) distinct/s" + $(if ($Sync -and $m.Sync) { ", sync $(($m.Sync | Measure-Object -Minimum).Minimum)..$(($m.Sync | Measure-Object -Maximum).Maximum) ms" } else { "" }) + $(if ($why) { " - " + ($why -join "; ") } else { "" })
    Add-Result $name ($why.Count -eq 0) $detail
}

# Video file through the window's player (PipePlayer + subtitles), the way the window streams files and YouTube
Add-Type -Path (Join-Path $app "app\PipePlayer.cs"), (Join-Path $app "app\SubtitleOverlay.cs") -ReferencedAssemblies System.Core
$subsFile = Join-Path $work "VRVideoStreamer-subs-test.txt"
$overlay = New-Object SubtitleOverlay($subsFile); $overlay.Start()
$srt = Join-Path $work "test.srt"; Set-Content $srt "1`r`n00:00:01,000 --> 00:59:00,000`r`nSubtitle test`r`n" -Encoding ascii; $overlay.Load($srt)
$font = Join-Path $env:WINDIR "Fonts\arial.ttf"
foreach ($enc in $encoders) {
    foreach ($fps in 30, 60) {
        $tag = "vvs-test-$PID-$enc-$fps"
        # A closure rather than code in a string, so a user name with an apostrophe in these paths can't break it
        $before = { $pl = New-Object PipePlayer($ffmpeg, $syncFile, "", "", $tag, 1920, 1080, $fps, 180, $true, $true); $pl.Start(); $pl }.GetNewClosure()
        Test-Stream "Video file via the player, $fps fps, $enc" @("-PipeInput", $tag, "-PipeSize", "1920x1080", "-Height", "1080", "-Bitrate", "4M", "-AudioBitrate", "128k", "-Encoder", $enc,
            "-SubtitleText", "`"$subsFile`"", "-SubtitleSize", "20", "-SubtitlePlace", "bottom", "-SubtitleColor", "white", "-SubtitleFont", "`"$font`"") $fps -Sync -Before $before -After { param($pl) if ($pl) { $pl.Stop() } }
    }
}
# The subtitle file missing at Start (what used to stop every stream): the stream should recreate it
$overlay.Stop(); Remove-Item $subsFile -Force -ErrorAction SilentlyContinue
$tag = "vvs-test-$PID-nosubs"
$before = { $pl = New-Object PipePlayer($ffmpeg, $syncFile, "", "", $tag, 1920, 1080, 30, 180, $true, $true); $pl.Start(); $pl }.GetNewClosure()
Test-Stream "Video file with the subtitle file missing" @("-PipeInput", $tag, "-PipeSize", "1920x1080", "-Height", "1080", "-Bitrate", "4M", "-AudioBitrate", "128k", "-Encoder", $encoders[-1],
    "-SubtitleText", "`"$subsFile`"", "-SubtitleSize", "20", "-SubtitlePlace", "bottom", "-SubtitleColor", "white", "-SubtitleFont", "`"$font`"") 30 -Before $before -After { param($pl) if ($pl) { $pl.Stop() } }

# A program's window: a test window with a moving pattern
$ffplay = Join-Path (Split-Path $ffmpeg) "ffplay.exe"
if (Test-Path $ffplay) {
    foreach ($fps in 30, 60) {
        $player = Start-Process $ffplay -ArgumentList "-loglevel error -an -loop 0 -window_title `"VVS window test`" -x 960 -y 540 `"$syncFile`"" -PassThru
        $deadline = (Get-Date).AddSeconds(15); do { Start-Sleep -Milliseconds 300; $player.Refresh() } while ($player.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)
        Test-Stream "Program window, $fps fps, $($encoders[-1])" @("-WindowHwnd", [long]$player.MainWindowHandle, "-Height", "1080", "-Bitrate", "4M", "-Encoder", $encoders[-1]) $fps
        Stop-Process -Id $player.Id -Force -ErrorAction SilentlyContinue
    }
} else { Add-Result "Program window" $false "ffplay.exe wasn't found next to ffmpeg, so a test window couldn't be opened" }

# A whole monitor (a still desktop repeats frames, so only the frame rate is checked)
foreach ($fps in 30, 60) { Test-Stream "Monitor, $fps fps, $($encoders[-1])" @("-Monitor", "0", "-Height", "1080", "-Bitrate", "4M", "-Encoder", $encoders[-1]) $fps }

# --- Opening the program twice must not delete a running copy's files ---
$fake = Join-Path $env:TEMP "VRVideoStreamer-subs-$PID.txt"; Set-Content $fake "x"
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $app "app\StreamUI.ps1"), [ref]$null, [ref]$null)
$cleanup = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -like 'Get-ChildItem $env:TEMP -Filter "VRVideoStreamer-*"*' } | Select-Object -First 1
$mutex = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -like '$singleInstance = New-Object*' } | Select-Object -First 1
$order = $cleanup -and $mutex -and $cleanup.Extent.StartOffset -gt $mutex.Extent.StartOffset
$job = Start-Job -ScriptBlock { param($code) Invoke-Expression $code } -ArgumentList $cleanup.Extent.Text
Wait-Job $job -Timeout 60 | Out-Null; Remove-Job $job -Force
Add-Result "Opening it twice keeps a running copy's files" ($order -and (Test-Path $fake)) $(if (-not $order) { "the clean-up runs before the 'already open' check" } elseif (-not (Test-Path $fake)) { "a running copy's subtitle file was deleted" } else { "" })
Remove-Item $fake -Force -ErrorAction SilentlyContinue

# --- Report ---
$failed = @($results | Where-Object Result -eq "FAIL").Count
$report = "$Zip-test-report.txt"
@("VR Video Streamer release test, $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Zip: $Zip", "Windows: $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)",
  "FFmpeg: $ffmpeg", "Encoders tested: $($encoders -join ', ')", "") + ($results | Format-Table -AutoSize -Wrap | Out-String -Width 220) | Set-Content $report -Encoding utf8
Write-Host ""
if ($failed) { Write-Host "$failed of $($results.Count) checks FAILED. Don't publish this release yet. Report: $report" -ForegroundColor Red }
else { Write-Host "All $($results.Count) checks passed. Report: $report" -ForegroundColor Green }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
