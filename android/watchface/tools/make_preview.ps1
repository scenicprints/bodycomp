# Draws src/main/res/drawable-nodpi/preview.png, the picture the watch shows
# for this face in its face picker. Mirrors the layout in gen_watchface.py
# with sample numbers (1,480 eaten, 1,790 burned). Re-run after a redesign:
#   powershell -File android/watchface/tools/make_preview.ps1
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$fontPath = Join-Path $root 'src\main\res\font\inter_regular.ttf'
$outPath = Join-Path $root 'src\main\res\drawable-nodpi\preview.png'

$fonts = New-Object System.Drawing.Text.PrivateFontCollection
$fonts.AddFontFile($fontPath)
$family = $fonts.Families[0]

$bmp = New-Object System.Drawing.Bitmap 450, 450
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAlias'
$g.Clear([System.Drawing.Color]::Transparent)

function Brush([string]$hex) {
    New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
}
function Text([string]$s, [single]$size, [string]$hex, [single]$x, [single]$y) {
    $f = New-Object System.Drawing.Font($family, $size, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString($s, $f, (Brush $hex), $x, $y, [System.Drawing.StringFormat]::GenericTypographic)
}

$g.FillEllipse((Brush '#000000'), 0, 0, 450, 450)
Text 'Mon 23' 27 '#B4B2A9' 94 86

# Battery dots, shown at 80%: four lit, one unlit.
$dots = '#F5566E', '#F28C28', '#F2C500', '#9CCB3B', '#2C2C2A'
foreach ($i in 0..4) {
    $x = 356 - (4 - $i) * 17.5 - 5.75
    $g.FillEllipse((Brush $dots[$i]), $x, 104 - 5.75, 11.5, 11.5)
}
Text '10:08' 106 '#F5566E' 89 114

# Calorie slot origin is (74, 236); the zero line is at slot x = 151.
$ox = 74; $oy = 236; $cx = $ox + 151
$grey = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#888780')), 2
$g.DrawLine($grey, $cx, $oy + 9, $cx, $oy + 71)
foreach ($k in 1..5) {
    $dx = 131 * $k / 5
    $top = if ($k -eq 5) { 16 } else { 24 }
    $g.DrawLine($grey, $cx - $dx, $oy + $top, $cx - $dx, $oy + 32)
    $g.DrawLine($grey, $cx + $dx, $oy + $top, $cx + $dx, $oy + 32)
}
$w = 310 * 131 / 500
$g.FillRectangle((Brush '#F28C28'), $cx - $w, $oy + 40, $w, 21)

$g.FillEllipse((Brush '#F2C500'), $ox + 20, $oy + 91, 16, 16)
Text '1,480' 33 '#F1EFE8' ($ox + 49) ($oy + 80)
Text 'eaten' 22 '#888780' ($ox + 49) ($oy + 120)
$g.FillEllipse((Brush '#F28C28'), $ox + 163, $oy + 91, 16, 16)
Text '1,790' 33 '#F1EFE8' ($ox + 192) ($oy + 80)
Text 'burned' 22 '#888780' ($ox + 192) ($oy + 120)

$g.Dispose()
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $outPath"
