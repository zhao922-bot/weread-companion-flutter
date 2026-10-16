param([switch]$Install)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Bitmap]::FromFile((Join-Path $PSScriptRoot 'readamber-master.png'))
try {
    $sizes = @(16, 24, 32, 48, 64, 72, 96, 128, 144, 192, 256, 512, 1024)
    $images = @{}
    foreach ($size in $sizes) {
        $target = New-Object System.Drawing.Bitmap($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($target)
        try {
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $attributes = New-Object System.Drawing.Imaging.ImageAttributes
            try {
                $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
                $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
                $graphics.DrawImage($source, $rect, 0, 0, $source.Width, $source.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
            } finally { $attributes.Dispose() }
            $stream = New-Object System.IO.MemoryStream
            try {
                $target.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $images[$size] = $stream.ToArray()
                [System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot "readamber-icon-$size.png"), $images[$size])
            } finally { $stream.Dispose() }
        } finally { $graphics.Dispose(); $target.Dispose() }
    }
    # PNG-compressed ICO frames preserve the generated artwork without redrawing it.
    $icoSizes = @(16, 24, 32, 48, 64, 128, 256)
    $file = [System.IO.File]::Create((Join-Path $PSScriptRoot 'readamber.ico'))
    $writer = New-Object System.IO.BinaryWriter($file)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$icoSizes.Length)
        $offset = 6 + 16 * $icoSizes.Length
        foreach ($size in $icoSizes) {
            $dimension = if ($size -eq 256) { 0 } else { $size }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$size].Length)
            $writer.Write([uint32]$offset)
            $offset += $images[$size].Length
        }
        foreach ($size in $icoSizes) { $writer.Write([byte[]]$images[$size]) }
    } finally { $writer.Dispose(); $file.Dispose() }
} finally { $source.Dispose() }
if ($Install) {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $densities = @{mdpi=48; hdpi=72; xhdpi=96; xxhdpi=144; xxxhdpi=192}
    foreach ($density in $densities.Keys) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "readamber-icon-$($densities[$density]).png") -Destination (Join-Path $repoRoot "android/app/src/main/res/mipmap-$density/ic_launcher.png")
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'readamber.ico') -Destination (Join-Path $repoRoot 'windows/runner/resources/app_icon.ico')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'readamber-icon-32.png') -Destination (Join-Path $repoRoot 'web/favicon.png')
    foreach ($size in @(192,512)) {
        foreach ($name in @("Icon-$size.png", "Icon-maskable-$size.png")) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "readamber-icon-$size.png") -Destination (Join-Path $repoRoot "web/icons/$name")
        }
    }
}
Write-Output 'Exported 13 PNG sizes and a 7-frame Windows ICO.'
