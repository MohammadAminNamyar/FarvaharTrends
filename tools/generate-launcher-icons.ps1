$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Bitmap]::FromFile((Join-Path $projectRoot 'assets\branding\logo-transparent.png'))
try {
    # Tight alpha bounds remove transparent image-generation margins; preserve
    # all interior artwork and the antialiased edge of the selected PNG.
    $left = $source.Width; $top = $source.Height; $right = 0; $bottom = 0
    for ($y = 0; $y -lt $source.Height; $y++) {
        for ($x = 0; $x -lt $source.Width; $x++) {
            if ($source.GetPixel($x, $y).A -gt 16) {
                $left = [Math]::Min($left, $x); $right = [Math]::Max($right, $x)
                $top = [Math]::Min($top, $y); $bottom = [Math]::Max($bottom, $y)
            }
        }
    }
    $bounds = [System.Drawing.Rectangle]::FromLTRB($left, $top, $right + 1, $bottom + 1)
    function Write-Icon([string]$RelativePath, [int]$Canvas, [int]$Artwork) {
        $destination = Join-Path $projectRoot $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $bitmap = New-Object System.Drawing.Bitmap($Canvas, $Canvas, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $inset = [int](($Canvas - $Artwork) / 2)
            $target = New-Object System.Drawing.Rectangle($inset, $inset, $Artwork, $Artwork)
            $graphics.DrawImage($source, $target, $bounds, [System.Drawing.GraphicsUnit]::Pixel)
            $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    foreach ($density in @(@('mdpi',48),@('hdpi',72),@('xhdpi',96),@('xxhdpi',144),@('xxxhdpi',192))) {
        Write-Icon ('android\app\src\main\res\mipmap-' + $density[0] + '\ic_launcher.png') $density[1] $density[1]
    }
    # 66dp artwork stays inside Android's guaranteed adaptive-icon safe region.
    Write-Icon 'android\app\src\main\res\drawable-xxxhdpi\ic_launcher_foreground.png' 432 264
} finally { $source.Dispose() }
Write-Output 'Generated transparent legacy icons and the adaptive foreground.'
