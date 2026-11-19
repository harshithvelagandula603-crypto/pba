$baseUrl = "http://localhost:8080"

# Login as faculty
$loginBody = @{ facultyId = "FAC101"; email = "FAC101@edu.in"; password = "Faculty@123" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $loginBody -ContentType "application/json"
$token = $loginRes.session.sessionId
Write-Host "Token: $token"
$headers = @{ "X-Session-Id" = $token }

# Test 3: CSV with Subject first
$csvBody = "Subject,Student ID,Internal Marks (40),External Marks (60)`nDBMS,25QM1A66D6,35,55`nDBMS,25QM1A66D7,30,48"

Write-Host "`n=== Test 3: CSV Subject First ==="
try {
    $res = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvBody -ContentType "text/plain; charset=UTF-8" -Headers $headers
    Write-Host "Success: $($res.success)  valid: $($res.validCount)  rejected: $($res.rejectedCount)"
    if ($res.errors) {
        foreach ($e in $res.errors) {
            Write-Host "  Error line $($e.lineNumber): $($e.reason)"
        }
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Host "HTTP $statusCode"
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $errBody = $reader.ReadToEnd()
    $reader.Dispose()
    Write-Host $errBody
}

# Test 4: CSV with Sudent ID
$csvBody2 = "Subject,Sudent ID,Internal Marks (40),External Marks (60)`nDBMS,25QM1A66D8,32,50"

Write-Host "`n=== Test 4: CSV Sudent ID ==="
try {
    $res2 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvBody2 -ContentType "text/plain; charset=UTF-8" -Headers $headers
    Write-Host "Success: $($res2.success)  valid: $($res2.validCount)  rejected: $($res2.rejectedCount)"
    if ($res2.errors) {
        foreach ($e in $res2.errors) {
            Write-Host "  Error line $($e.lineNumber): $($e.reason)"
        }
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Host "HTTP $statusCode"
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $errBody = $reader.ReadToEnd()
    $reader.Dispose()
    Write-Host $errBody
}
