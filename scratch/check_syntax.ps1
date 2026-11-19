$content = Get-Content 'server.ps1' -Raw
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    Write-Host "ERRORS FOUND:"
    $errors | ForEach-Object { Write-Host $_.ToString() }
} else {
    Write-Host "SYNTAX_OK"
}

