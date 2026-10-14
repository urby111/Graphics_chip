param(
    [string]$Frame = (Join-Path $PSScriptRoot '..\screen\first_frame.hex')
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$font = @((Get-Content -Raw (Join-Path $projectRoot 'font_aligned.hex')).Trim() -split '\s+' |
    ForEach-Object { [Convert]::ToByte($_, 16) })
$pixels = [IO.File]::ReadAllLines([IO.Path]::GetFullPath($Frame))
if ($font.Count -ne 38400 -or $pixels.Count -ne 307200) { throw 'Incorrect frame dimensions.' }

# Compare the actual Verilator RGB output to every bit of the framebuffer.
# No one-pixel offset is allowed: file pixel (x,y) must appear at VGA (x,y).
for ($pixel = 0; $pixel -lt $pixels.Count; $pixel++) {
    $byteIndex = $pixel -shr 3
    $mask = 128 -shr ($pixel -band 7)
    $expected = if (($font[$byteIndex] -band $mask) -ne 0) { 'FFF' } else { '000' }
    if ($pixels[$pixel] -cne $expected) {
        $x = $pixel % 640
        $y = [int][Math]::Floor($pixel / 640)
        throw "VGA mismatch at ($x,$y): expected $expected, got $($pixels[$pixel])."
    }
}

# Render only the SIMULATED pixels so the preview also exposes RTL problems.
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object Drawing.Bitmap(640,480)
try {
    for ($y = 0; $y -lt 480; $y++) {
        for ($x = 0; $x -lt 640; $x++) {
            $color = if ($pixels[$y * 640 + $x] -eq 'FFF') { [Drawing.Color]::White } else { [Drawing.Color]::Black }
            $bitmap.SetPixel($x, $y, $color)
        }
    }
    $bitmap.Save((Join-Path $projectRoot 'screen\first_frame.png'), [Drawing.Imaging.ImageFormat]::Png)

    # Enlarge the table 2x for easy inspection, with nearest-neighbor pixels.
    $preview = New-Object Drawing.Bitmap(544,544)
    try {
        for ($y = 0; $y -lt 272; $y++) {
            for ($x = 0; $x -lt 272; $x++) {
                $color = $bitmap.GetPixel($x, $y)
                $preview.SetPixel($x*2, $y*2, $color)
                $preview.SetPixel($x*2+1, $y*2, $color)
                $preview.SetPixel($x*2, $y*2+1, $color)
                $preview.SetPixel($x*2+1, $y*2+1, $color)
            }
        }
        $preview.Save((Join-Path $projectRoot 'screen\font_preview.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $preview.Dispose() }
} finally { $bitmap.Dispose() }
Write-Output 'PASS: all 307200 simulated pixels match font_aligned.hex exactly; saved full frame and enlarged table PNGs.'
