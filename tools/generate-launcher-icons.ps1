$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Bitmap]::FromFile((Join-Path $projectRoot 'assets\branding\farvahar-master.png'))
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
    function Write-Icon([string]$RelativePath, [int]$Canvas, [int]$Artwork, [switch]$Opaque) {
        $destination = Join-Path $projectRoot $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $format = if ($Opaque) { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb } else { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb }
        $bitmap = New-Object System.Drawing.Bitmap($Canvas, $Canvas, $format)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $background = if ($Opaque) { [System.Drawing.ColorTranslator]::FromHtml('#102E42') } else { [System.Drawing.Color]::Transparent }
            $graphics.Clear($background)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $ratio = $Artwork / [Math]::Max($bounds.Width, $bounds.Height)
            $width = [int]($bounds.Width * $ratio)
            $height = [int]($bounds.Height * $ratio)
            $target = New-Object System.Drawing.Rectangle([int](($Canvas - $width) / 2), [int](($Canvas - $height) / 2), $width, $height)
            $graphics.DrawImage($source, $target, $bounds, [System.Drawing.GraphicsUnit]::Pixel)
            $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    foreach ($density in @(@('mdpi',48),@('hdpi',72),@('xhdpi',96),@('xxhdpi',144),@('xxxhdpi',192))) {
        Write-Icon ('android\app\src\main\res\mipmap-' + $density[0] + '\ic_launcher.png') $density[1] $density[1]
    }
    # 66dp artwork stays inside Android's guaranteed adaptive-icon safe region.
    Write-Icon 'android\app\src\main\res\drawable-xxxhdpi\ic_launcher_foreground.png' 432 264
    Write-Icon 'assets\brand\farvahar-mark.png' 256 240
    $iosRoot = 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot ($iosRoot + '\Contents.json')) -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.images) {
        $size = [double]($entry.size.Split('x')[0]) * [double]($entry.scale.TrimEnd('x'))
        Write-Icon ($iosRoot + '\' + $entry.filename) ([int]$size) ([int]($size * .88)) -Opaque
    }
    foreach ($scale in 1..3) {
        $suffix = if ($scale -eq 1) { '' } else { '@' + $scale + 'x' }
        Write-Icon ('ios\Runner\Assets.xcassets\LaunchImage.imageset\LaunchImage' + $suffix + '.png') (168 * $scale) (156 * $scale)
    }
} finally { $source.Dispose() }
Write-Output 'Packaged FarvaharTrends artwork for the reader, Android and iOS.'
