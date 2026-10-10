# video/scripts/real/Capture.ps1
#
# Screen capture loop run in its own process by record-screen.ps1: grabs a
# region of the primary screen into numbered JPEG frames until a stop file
# appears. Each frame's real duration goes into an ffmpeg concat list, so the
# encoded clip keeps wall-clock timing even when a frame takes longer to grab;
# capture.json records when the first frame was taken, for cutting the clip.

param(
	[Parameter(Mandatory)] [string]$OutDir,
	[Parameter(Mandatory)] [string]$StopFile,
	# "x,y,width,height" in physical pixels; the working area when omitted.
	[string]$Region = '',
	[int]$Fps = 24
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class DpiAware { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
# Physical pixels, not the scaled logical size.
[DpiAware]::SetProcessDPIAware() | Out-Null

# The working area excludes the taskbar, so the user's pinned apps stay private.
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($Region -ne '') {
	$v = $Region.Split(',') | ForEach-Object { [int]$_ }
	if ($v.Count -ne 4) { throw "Region must be x,y,width,height: $Region" }
	$area = New-Object System.Drawing.Rectangle $v[0], $v[1], $v[2], $v[3]
}
$bmp = New-Object System.Drawing.Bitmap $area.Width, $area.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
$params = New-Object System.Drawing.Imaging.EncoderParameters 1
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 92L

New-Item -ItemType Directory -Force $OutDir | Out-Null
$frameMs = 1000 / $Fps
$startedAt = [DateTime]::Now
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$stamps = New-Object System.Collections.Generic.List[double]
$n = 0
while (-not (Test-Path $StopFile)) {
	$stamps.Add($clock.Elapsed.TotalSeconds)
	$g.CopyFromScreen($area.Location, [System.Drawing.Point]::Empty, $area.Size)
	$bmp.Save((Join-Path $OutDir ('{0:D5}.jpg' -f $n)), $codec, $params)
	$n++
	$wait = [int]($n * $frameMs - $clock.ElapsedMilliseconds)
	if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
}
$seconds = $clock.Elapsed.TotalSeconds
if ($n -eq 0) { throw 'No frame was captured' }

$inv = [Globalization.CultureInfo]::InvariantCulture
$list = New-Object System.Text.StringBuilder
[void]$list.Append("ffconcat version 1.0`n")
for ($i = 0; $i -lt $n; $i++) {
	$end = if ($i + 1 -lt $n) { $stamps[$i + 1] } else { $seconds }
	[void]$list.Append(("file '{0:D5}.jpg'`nduration {1}`n" -f $i, ($end - $stamps[$i]).ToString('0.######', $inv)))
}
# The concat demuxer ignores the last duration unless the file is repeated.
[void]$list.Append(("file '{0:D5}.jpg'`n" -f ($n - 1)))
[IO.File]::WriteAllText((Join-Path $OutDir 'frames.ffconcat'), $list.ToString())

@{
	frames = $n; seconds = $seconds; fps = $n / $seconds; width = $area.Width; height = $area.Height
	startedAt = $startedAt.ToString('o')
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $OutDir 'capture.json')
