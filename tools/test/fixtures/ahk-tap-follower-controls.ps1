# tools/test/fixtures/ahk-tap-follower-controls.ps1

param([Parameter(Mandatory = $true)][string] $Helper)
$ErrorActionPreference = 'Stop'
. $Helper
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-tap-follower-' + [Guid]::NewGuid().ToString('N'))
$ownedRoot = [IO.Path]::GetFullPath($testRoot)
$null = [IO.Directory]::CreateDirectory($ownedRoot)
$passed = 0

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw 'Unexpected TAP follower output.' }
}
function Assert-Throws([scriptblock] $Action) {
    $refused = $false
    try { & $Action } catch { $refused = $true }
    if (-not $refused) { throw 'Expected TAP read refusal.' }
}
function Assert-Closed([string] $Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
}
function Append-Byte([string] $Path, [byte] $Value) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { $stream.WriteByte($Value) } finally { $stream.Dispose() }
}

try {
    # Every boundary is split, including BOM, multibyte scalars and CRLF.
    $path = Join-Path $ownedRoot 'split.tap'
    $follower = New-AhkTapFollower -Path $path
    Assert-Equal @($follower.Poll()).Count 0
    $text = [string][char]0xFEFF + "ok 1 - caf$([char]0xE9)$([char]::ConvertFromUtf32(0x1F642))`r`n# summary`nunterminated"
    $bytes = $utf8.GetBytes($text)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($value in $bytes) {
        Append-Byte $path $value
        foreach ($line in $follower.Poll()) { $lines.Add($line) }
        Assert-Closed $path
    }
    foreach ($line in $follower.Finish()) { $lines.Add($line) }
    Assert-Equal $lines.Count 3
    Assert-Equal $lines[0] "ok 1 - caf$([char]0xE9)$([char]::ConvertFromUtf32(0x1F642))"
    Assert-Equal $lines[1] '# summary'
    Assert-Equal $lines[2] 'unterminated'
    Assert-Equal @($follower.Finish()).Count 0
    Assert-Equal @($follower.Poll()).Count 0
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) ([Convert]::ToBase64String($bytes))
    $passed++

    $path = Join-Path $ownedRoot 'interior-bom.tap'
    [IO.File]::WriteAllBytes($path, $utf8.GetBytes("one`n$([char]0xFEFF)two`n`n"))
    $follower = New-AhkTapFollower -Path $path
    $lines = @($follower.Finish())
    Assert-Equal $lines.Count 3
    Assert-Equal $lines[1] "$([char]0xFEFF)two"
    Assert-Equal $lines[2] ''
    Assert-Closed $path
    $passed++

    $path = Join-Path $ownedRoot 'partial.tap'
    [IO.File]::WriteAllBytes($path, [byte[]](0xF0, 0x9F))
    $follower = New-AhkTapFollower -Path $path
    Assert-Equal @($follower.Poll()).Count 0
    Assert-Throws { $follower.Finish() }
    Assert-Throws { $follower.Poll() }
    Assert-Closed $path
    $passed++

    $path = Join-Path $ownedRoot 'invalid.tap'
    [IO.File]::WriteAllBytes($path, [byte[]](0xC0, 0xAF))
    $follower = New-AhkTapFollower -Path $path
    Assert-Throws { $follower.Poll() }
    Assert-Closed $path
    $passed++

    $path = Join-Path $ownedRoot 'truncated.tap'
    [IO.File]::WriteAllText($path, "first`n", $utf8)
    $follower = New-AhkTapFollower -Path $path
    Assert-Equal @($follower.Poll())[0] 'first'
    [IO.File]::WriteAllText($path, '', $utf8)
    Assert-Throws { $follower.Finish() }
    Assert-Closed $path
    $passed++

    $path = Join-Path $ownedRoot 'disappeared.tap'
    [IO.File]::WriteAllText($path, "first`n", $utf8)
    $follower = New-AhkTapFollower -Path $path
    $null = $follower.Poll()
    [IO.File]::Delete($path)
    Assert-Throws { $follower.Poll() }
    $passed++

    $path = Join-Path $ownedRoot 'missing.tap'
    $follower = New-AhkTapFollower -Path $path
    Assert-Equal @($follower.Poll()).Count 0
    Assert-Throws { $follower.Finish() }
    $passed++

    $path = Join-Path $ownedRoot 'sharing.tap'
    [IO.File]::WriteAllText($path, "first`n", $utf8)
    $writer = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $follower = New-AhkTapFollower -Path $path
        Assert-Throws { $follower.Poll() }
    } finally { $writer.Dispose() }
    Assert-Closed $path
    Assert-Throws { $follower.Finish() }
    $passed++

    # The production writer may remain open while its shared TAP reader polls.
    $path = Join-Path $ownedRoot 'held-writer.tap'
    $follower = New-AhkTapFollower -Path $path
    $writer = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $text = [string][char]0xFEFF + "ok 1 - held`r`nok 2 - $([char]::ConvertFromUtf32(0x1F642))`n# final"
    $bytes = $utf8.GetBytes($text)
    $lines = [Collections.Generic.List[string]]::new()
    try {
        foreach ($value in $bytes) {
            $writer.WriteByte($value)
            $writer.Flush()
            if (-not $writer.CanWrite) { throw 'The actual writer must remain open during Poll.' }
            foreach ($line in $follower.Poll()) { $lines.Add($line) }
        }
        Assert-Equal $lines.Count 2
        Assert-Equal $lines[0] 'ok 1 - held'
        Assert-Equal $lines[1] "ok 2 - $([char]::ConvertFromUtf32(0x1F642))"
    } finally { $writer.Dispose() }
    foreach ($line in $follower.Finish()) { $lines.Add($line) }
    Assert-Equal $lines.Count 3
    Assert-Equal $lines[2] '# final'
    Assert-Equal @($follower.Finish()).Count 0
    Assert-Closed $path
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) ([Convert]::ToBase64String($bytes))
    $passed++

    if ($passed -ne 9) { throw 'Incomplete TAP follower controls.' }
    Write-Output 'PASS: 9 actual file/UTF-8 controls; no AHK process or native acceptance executed.'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedRoot -cne $ownedRoot -or -not $resolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the owned TAP follower directory.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
