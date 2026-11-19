$s = "Subject,Student ID"
$bomChar = [char]0xFEFF

Write-Host "StartsWith char 0xFEFF:" $s.StartsWith($bomChar)
$firstChar = $s[0]
Write-Host "First char:" $firstChar "code:" ([int]$firstChar)
Write-Host "BOM char code:" ([int]$bomChar)
Write-Host "Chars equal:" ($firstChar -eq $bomChar)
$bomStr = [string]$bomChar
Write-Host "StartsWith string (default):" $s.StartsWith($bomStr)
Write-Host "StartsWith string (Ordinal):" $s.StartsWith($bomStr, [System.StringComparison]::Ordinal)
Write-Host "StartsWith string (OrdinalIgnoreCase):" $s.StartsWith($bomStr, [System.StringComparison]::OrdinalIgnoreCase)
Write-Host "StartsWith string (CurrentCulture):" $s.StartsWith($bomStr, [System.StringComparison]::CurrentCulture)

