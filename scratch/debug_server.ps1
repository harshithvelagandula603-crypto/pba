param([int]$Port = 8089)

$ErrorActionPreference = "Continue"

$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -ExecutionPolicy Bypass -File "$dir\server.ps1" -Port $p
} -ArgumentList $PSScriptRoot, $Port

Start-Sleep -Seconds 4
$jobData = Receive-Job -Job $job
Write-Host "Server job output: $jobData"

$baseUrl = "http://localhost:$Port"

try {
    Write-Host "Calling /api/auth/faculty..."
    $facLoginBody = @{ facultyId = "FAC101"; email = "FAC101@edu.in"; password = "Faculty@123" } | ConvertTo-Json
    $loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $facLoginBody -ContentType "application/json"
    Write-Host "Login response: $($loginRes | ConvertTo-Json -Compress)"
} catch {
    Write-Host "Error during login: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        Write-Host "Response body: $($reader.ReadToEnd())"
    }
} finally {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
