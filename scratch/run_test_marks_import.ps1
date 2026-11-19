param([int]$Port = 8088)

$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -ExecutionPolicy Bypass -File "$dir\server.ps1" -Port $p
} -ArgumentList (Get-Location).Path, $Port

Start-Sleep -Seconds 4

try {
    & powershell -ExecutionPolicy Bypass -File "test_marks_import.ps1" -Port $Port
} finally {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
