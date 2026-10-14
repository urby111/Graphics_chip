param(
    [string]$Source = (Join-Path $PSScriptRoot '..\font_glyphs.hex'),
    [string]$Output = (Join-Path $PSScriptRoot '..\font_aligned.hex')
)

$ErrorActionPreference = 'Stop'
# This source starts with symbol 2: space is glyph 30 and A is glyph 63.
# Its 254 eight-byte glyphs end at offset 2032; the remaining data includes
# file metadata rather than glyphs. Keep the original file intact.
$glyphCount = 254
$tokens = (Get-Content -Raw -LiteralPath $Source).Trim() -split '\s+'
$bytes = @($tokens | ForEach-Object {
    if ($_ -notmatch '^(?:0x)?([0-9a-fA-F]{2})$') {
        throw "Invalid byte: $_"
    }
    [Convert]::ToByte($Matches[1], 16)
})
if ($bytes.Count -lt ($glyphCount * 8)) { throw 'Source is missing glyph bytes.' }

# Check two recognizable glyphs before assuming the eight-byte framing.
if ((($bytes[504..511] | ForEach-Object { $_.ToString('X2') }) -join ' ') -ne
    '38 6C C6 C6 FE C6 C6 00') { throw 'Expected the 8x8 A at source offset 504.' }
if (($bytes[240..247] | Measure-Object -Sum).Sum -ne 0) {
    throw 'Expected the blank space glyph at source offset 240.'
}

# Preserve each glyph at exactly 8x8 pixels. Arrange codes 00..FF in a
# 16x16 table, with 8 blank pixels between glyphs and a 16-pixel margin.
# The source omits codes 00 and 01, so those two cells remain blank.
# Framebuffer stride is always 80 bytes, regardless of table width.
$frame = New-Object byte[] (80 * 480)
for ($glyph = 0; $glyph -lt $glyphCount; $glyph++) {
    $code = $glyph + 2
    $column = 2 + ($code % 16) * 2
    $topRow = 16 + [int][Math]::Floor($code / 16) * 16
    for ($row = 0; $row -lt 8; $row++) {
        $frame[($topRow + $row) * 80 + $column] = $bytes[$glyph * 8 + $row]
    }
}

# Plain two-digit hex is portable $readmemh input; one line per screen row.
$lines = for ($y = 0; $y -lt 480; $y++) {
    ($frame[($y * 80)..($y * 80 + 79)] | ForEach-Object { $_.ToString('X2') }) -join ' '
}
Set-Content -LiteralPath $Output -Value $lines -Encoding ascii

# Read the saved file back and check every character row and the black padding.
$saved = @((Get-Content -Raw -LiteralPath $Output).Trim() -split '\s+' |
    ForEach-Object { [Convert]::ToByte($_, 16) })
if ($saved.Count -ne 38400) { throw 'Wrong framebuffer size.' }
for ($y = 0; $y -lt 480; $y++) {
    for ($x = 0; $x -lt 80; $x++) {
        $expected = 0
        if ($y -ge 16 -and $y -lt 272 -and $x -ge 2 -and $x -lt 34) {
            $localX = $x - 2
            $localY = $y - 16
            $code = [int][Math]::Floor($localY / 16) * 16 + [int][Math]::Floor($localX / 2)
            if (($localX % 2) -eq 0 -and ($localY % 16) -lt 8 -and $code -ge 2) {
                $expected = $bytes[($code - 2) * 8 + ($localY % 16)]
            }
        }
        if ($saved[$y * 80 + $x] -ne $expected) { throw "Mismatch at byte ($x, $y)." }
    }
}
# Keep the familiar font.hex filename in sync for users who load it manually.
$fontPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\font.hex'))
if ([IO.Path]::GetFullPath($Output) -ne $fontPath) {
    Copy-Item -LiteralPath $Output -Destination $fontPath -Force
}
Write-Output "Aligned and verified $glyphCount native 8x8 glyphs in a spaced 16x16 table: $Output"
