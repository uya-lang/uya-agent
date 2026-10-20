Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 40,30
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Red)
$g.FillRectangle([System.Drawing.Brushes]::Blue, 10, 10, 20, 10)
$g.Dispose()
[System.Windows.Forms.Clipboard]::SetImage($bmp)
$bmp.Save("C:\uya-verify\ref.png", [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output "IMGSET"
