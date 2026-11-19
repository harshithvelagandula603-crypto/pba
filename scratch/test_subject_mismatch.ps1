# Comprehensive verification script for Subject Mismatch Detection
$base = "http://localhost:8080"
$allPassed = $true

function Get-HttpErrorData($errRecord) {
    $raw = ""
    if ($errRecord.ErrorDetails -and $errRecord.ErrorDetails.Message) {
        $raw = $errRecord.ErrorDetails.Message
    } elseif ($errRecord.Exception.Response) {
        try {
            $stream = $errRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $raw = $reader.ReadToEnd()
            }
        } catch {}
    }
    $obj = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $obj = $raw | ConvertFrom-Json } catch {}
    }
    return @{
        Raw = $raw
        Obj = $obj
        StatusCode = if ($errRecord.Exception.Response) { [int]$errRecord.Exception.Response.StatusCode } else { 0 }
    }
}

Write-Host "=== TEST: SUBJECT MISMATCH DETECTION & BLOCKING ===" -ForegroundColor Cyan

# 1. Prepare base64 file content of MARKS.xlsx
$filePath = Join-Path $PSScriptRoot "MARKS.xlsx"
if (-not (Test-Path $filePath)) {
    $filePath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\MARKS.xlsx"
}
$bytes = [System.IO.File]::ReadAllBytes($filePath)
$base64Content = [Convert]::ToBase64String($bytes)
Write-Host "Read MARKS.xlsx ($($bytes.Length) bytes, $($base64Content.Length) base64 chars)" -ForegroundColor Gray

# 2. Test with Faculty FAC103 (assigned to OOPS, MARKS.xlsx is DBMS)
Write-Host "`n--- Test 1: FAC103 (assigned OOPS) previews DBMS file ---" -ForegroundColor Yellow
$loginRes = Invoke-RestMethod -Uri "$base/api/auth/faculty-login" -Method POST -Body (@{ facultyId = "FAC103"; email = "FAC103@edu.in" } | ConvertTo-Json) -ContentType "application/json"
$fac103Token = $loginRes.session.sessionId
$fac103Headers = @{ "X-Session-Id" = $fac103Token }

try {
    $previewBody = @{
        subjectId = "OOPS"
        fileContentBase64 = $base64Content
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/marks-import-preview" -Method POST -Headers $fac103Headers -Body $previewBody -ContentType "application/json"
    Write-Host "FAILED: Preview was NOT rejected for FAC103!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $errInfo = Get-HttpErrorData $_
    $statusCode = $errInfo.StatusCode
    $errObj = $errInfo.Obj

    if ($statusCode -eq 403 -and $errObj -and $errObj.subjectMismatch -eq $true) {
        Write-Host "PASS: HTTP 403 Forbidden received with subjectMismatch=true" -ForegroundColor Green
        Write-Host "  Detected: $($errObj.detectedSubject)" -ForegroundColor Gray
        Write-Host "  Assigned: $($errObj.assignedSubjects -join ', ')" -ForegroundColor Gray
        Write-Host "  Message:  $($errObj.error)" -ForegroundColor Gray
    } else {
        Write-Host "FAILED: Expected HTTP 403 with subjectMismatch=true. Got HTTP $statusCode - $($errInfo.Raw)" -ForegroundColor Red
        $allPassed = $false
    }
}

# 3. Test Commit Block: FAC103 attempts to commit DBMS marks
Write-Host "`n--- Test 2: FAC103 commit attempt is blocked ---" -ForegroundColor Yellow
try {
    $commitBody = @{
        subjectId = "OOPS"
        fileContentBase64 = $base64Content
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/marks-import-commit" -Method POST -Headers $fac103Headers -Body $commitBody -ContentType "application/json"
    Write-Host "FAILED: Commit was NOT rejected for FAC103!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $errInfo = Get-HttpErrorData $_
    $statusCode = $errInfo.StatusCode
    $errObj = $errInfo.Obj

    if ($statusCode -eq 403 -and $errObj -and $errObj.subjectMismatch -eq $true) {
        Write-Host "PASS: Commit blocked with HTTP 403 and subjectMismatch=true" -ForegroundColor Green
        Write-Host "  Message: $($errObj.error)" -ForegroundColor Gray
    } else {
        Write-Host "FAILED: Expected HTTP 403 on commit block. Got HTTP $statusCode - $($errInfo.Raw)" -ForegroundColor Red
        $allPassed = $false
    }
}

# 4. Test with Authorized Faculty FAC101 (assigned DBMS)
Write-Host "`n--- Test 3: FAC101 (assigned DBMS) previews DBMS file ---" -ForegroundColor Yellow
$loginRes101 = Invoke-RestMethod -Uri "$base/api/auth/faculty-login" -Method POST -Body (@{ facultyId = "FAC101"; email = "FAC101@edu.in" } | ConvertTo-Json) -ContentType "application/json"
$fac101Token = $loginRes101.session.sessionId
$fac101Headers = @{ "X-Session-Id" = $fac101Token }

try {
    $previewBody101 = @{
        subjectId = "DBMS"
        fileContentBase64 = $base64Content
    } | ConvertTo-Json
    $res101 = Invoke-RestMethod -Uri "$base/api/faculty/marks-import-preview" -Method POST -Headers $fac101Headers -Body $previewBody101 -ContentType "application/json"
    
    if ($res101.success -and $res101.subjectId -eq "DBMS") {
        Write-Host "PASS: FAC101 preview succeeded for assigned DBMS subject." -ForegroundColor Green
        Write-Host "  Total rows: $($res101.totalRows), Valid rows: $($res101.validRowsCount), Invalid: $($res101.invalidRowsCount)" -ForegroundColor Gray
    } else {
        Write-Host "FAILED: FAC101 preview did not succeed: $($res101 | ConvertTo-Json)" -ForegroundColor Red
        $allPassed = $false
    }
} catch {
    Write-Host "FAILED: FAC101 preview threw error: $_" -ForegroundColor Red
    $allPassed = $false
}

# 5. Test with FAC104 (assigned COA)
Write-Host "`n--- Test 4: FAC104 (assigned COA) previews DBMS file ---" -ForegroundColor Yellow
$loginRes104 = Invoke-RestMethod -Uri "$base/api/auth/faculty-login" -Method POST -Body (@{ facultyId = "FAC104"; email = "FAC104@edu.in" } | ConvertTo-Json) -ContentType "application/json"
$fac104Token = $loginRes104.session.sessionId
$fac104Headers = @{ "X-Session-Id" = $fac104Token }

try {
    $previewBody104 = @{
        subjectId = "COA"
        fileContentBase64 = $base64Content
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/marks-import-preview" -Method POST -Headers $fac104Headers -Body $previewBody104 -ContentType "application/json"
    Write-Host "FAILED: Preview was NOT rejected for FAC104!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $errInfo = Get-HttpErrorData $_
    $statusCode = $errInfo.StatusCode
    $errObj = $errInfo.Obj

    if ($statusCode -eq 403 -and $errObj -and $errObj.subjectMismatch -eq $true) {
        Write-Host "PASS: FAC104 correctly blocked with HTTP 403 and subjectMismatch=true" -ForegroundColor Green
        Write-Host "  Detected: $($errObj.detectedSubject)" -ForegroundColor Gray
        Write-Host "  Assigned: $($errObj.assignedSubjects -join ', ')" -ForegroundColor Gray
    } else {
        Write-Host "FAILED: FAC104 block failed. HTTP $statusCode - $($errInfo.Raw)" -ForegroundColor Red
        $allPassed = $false
    }
}

# 6. Test with FAC101 (assigned DBMS & SE_LAB) when dropdown is SE_LAB but file is DBMS
Write-Host "`n--- Test 5: FAC101 selects SE_LAB but uploads DBMS file ---" -ForegroundColor Yellow
try {
    $previewBodyMismatch = @{
        subjectId = "SE_LAB"
        fileContentBase64 = $base64Content
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/marks-import-preview" -Method POST -Headers $fac101Headers -Body $previewBodyMismatch -ContentType "application/json"
    Write-Host "FAILED: Preview was NOT rejected when file subject differed from selected subject!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $errInfo = Get-HttpErrorData $_
    $statusCode = $errInfo.StatusCode
    $errObj = $errInfo.Obj

    if ($statusCode -eq 403 -and $errObj -and $errObj.subjectMismatch -eq $true) {
        Write-Host "PASS: Blocked with HTTP 403 and subjectMismatch=true on selected vs file mismatch." -ForegroundColor Green
        Write-Host "  Message: $($errObj.error)" -ForegroundColor Gray
    } else {
        Write-Host "FAILED: Expected HTTP 403 mismatch. Got HTTP $statusCode - $($errInfo.Raw)" -ForegroundColor Red
        $allPassed = $false
    }
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "ALL SUBJECT MISMATCH TESTS PASSED!" -ForegroundColor Green
} else {
    Write-Host "SOME TESTS FAILED." -ForegroundColor Red
}
Write-Host "=======================================================`n" -ForegroundColor Cyan
