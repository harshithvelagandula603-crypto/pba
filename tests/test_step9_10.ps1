# test_step9_10.ps1
# Comprehensive Verification Script for Step 9 (Domain Integrity Validation)
# and Step 10 (Automatic Result Calculation)

$baseUrl = "http://localhost:8080"
$ErrorActionPreference = "Stop"

$passed = 0
$failed = 0
$totalTests = 0

function Report-Test($name, $condition, $details = "") {
    $script:totalTests++
    if ($condition) {
        $script:passed++
        Write-Host " [PASS] $name" -ForegroundColor Green
        if ($details) { Write-Host "        $details" -ForegroundColor Gray }
    } else {
        $script:failed++
        Write-Host " [FAIL] $name" -ForegroundColor Red
        if ($details) { Write-Host "        $details" -ForegroundColor Yellow }
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Steps 9 & 10 Comprehensive Verification Suite    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Authenticate Faculty
Write-Host "`n--- Phase 1: Authentication ---" -ForegroundColor Yellow
$loginBody = @{ username = "faculty"; password = "admin123" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $loginBody -ContentType "application/json"
$facSession = $loginRes.session.sessionId
Report-Test "Faculty Login (faculty / admin123)" ($loginRes.success -and $facSession) "Session ID: $facSession"

$headers = @{ "X-Session-Id" = $facSession; "Content-Type" = "application/json" }

# 2. Get Students and Subjects
Write-Host "`n--- Phase 2: Verify Configured 10 Subjects ---" -ForegroundColor Yellow
$subjRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subjects" -Method GET -Headers $headers
$subjects = $subjRes.subjects
Report-Test "10 Curricular Subjects Configured" ($subjects.Count -eq 10) "Configured count: $($subjects.Count)"

$expectedCodes = @("DBMS","Maths","OOPs","SE","COA","SE Lab","Maths Lab","OOPs Lab","SD Lab","DBMS Lab")
$actualCodes = $subjects | ForEach-Object { $_.subjectCode }
$allCodesPresent = $true
foreach ($ec in $expectedCodes) {
    if (-not ($actualCodes -contains $ec)) { $allCodesPresent = $false }
}
Report-Test "All 10 Expected Curricular Codes Present" $allCodesPresent "Codes: $($actualCodes -join ', ')"

$students = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method GET -Headers $headers
Report-Test "Student Roster Loaded" ($students.Count -gt 0) "Total students: $($students.Count)"

$testStudent = $students[0]
$testStudentId = $testStudent.studentId
$testSubjectId = "DBMS" # Database Management Systems
Write-Host "Using Test Student: $testStudentId ($($testStudent.studentName)), Subject: $testSubjectId" -ForegroundColor Cyan

# Reset test record to clean state (NULL, NULL)
$resetPayload = @{
    studentId = $testStudentId
    subjectId = $testSubjectId
    markType = "both"
    internalMarks = $null
    externalMarks = $null
    forceConfirmed = $true
} | ConvertTo-Json
Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $resetPayload -Headers $headers | Out-Null

# 3. Step 9 Stage B & D: Backend Enforcement - Reject External when Internal is NULL
Write-Host "`n--- Phase 3: Internal-First Domain Integrity Enforcement ---" -ForegroundColor Yellow

$rejectedAsExpected = $false
$rejectMsg = ""
try {
    $payloadExtOnly = @{
        studentId = $testStudentId
        subjectId = $testSubjectId
        markType = "external"
        externalMarks = 45
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $payloadExtOnly -Headers $headers
} catch {
    $rejectedAsExpected = $true
    $rejectMsg = $_.Exception.Message
}
Report-Test "Reject external marks when internal marks not saved (Stage D)" $rejectedAsExpected "Response: $rejectMsg"

# 4. Step 9: Internal Marks Boundary Validations [0 - 40]
Write-Host "`n--- Phase 4: Internal Marks Boundaries [0 - 40] ---" -ForegroundColor Yellow

# Boundary: -1 (reject)
$negIntRejected = $false
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "internal"; internalMarks = -1 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch { $negIntRejected = $true }
Report-Test "Reject negative internal marks (-1)" $negIntRejected

# Boundary: 41 (reject)
$overIntRejected = $false
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "internal"; internalMarks = 41 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch { $overIntRejected = $true }
Report-Test "Reject internal marks exceeding 40 (41)" $overIntRejected

# Boundary: 0 (valid)
$res0 = $null
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "internal"; internalMarks = 0 } | ConvertTo-Json
    $res0 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch {}
Report-Test "Accept valid internal marks boundary min (0)" ($res0 -and $res0.success -and $res0.markRecord.internalMarks -eq 0) "internalMarks: $($res0.markRecord.internalMarks)"

# Boundary: 40 (valid)
$res40 = $null
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "internal"; internalMarks = 40 } | ConvertTo-Json
    $res40 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch {}
Report-Test "Accept valid internal marks boundary max (40)" ($res40 -and $res40.success -and $res40.markRecord.internalMarks -eq 40) "internalMarks: $($res40.markRecord.internalMarks)"

# Valid: 32 (standard score)
$body32 = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "internal"; internalMarks = 32 } | ConvertTo-Json
$res32 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body32 -Headers $headers
Report-Test "Save internal marks (32)" ($res32.success -and $res32.markRecord.internalMarks -eq 32)

# 5. Step 9: External Marks Boundaries [0 - 60] (now internal is saved!)
Write-Host "`n--- Phase 5: External Marks Boundaries [0 - 60] ---" -ForegroundColor Yellow

# Boundary: -1 (reject)
$negExtRejected = $false
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "external"; externalMarks = -1 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch { $negExtRejected = $true }
Report-Test "Reject negative external marks (-1)" $negExtRejected

# Boundary: 61 (reject)
$overExtRejected = $false
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "external"; externalMarks = 61 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch { $overExtRejected = $true }
Report-Test "Reject external marks exceeding 60 (61)" $overExtRejected

# Boundary: 0 (valid)
$resExt0 = $null
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "external"; externalMarks = 0 } | ConvertTo-Json
    $resExt0 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch {}
Report-Test "Accept valid external marks boundary min (0)" ($resExt0 -and $resExt0.success -and $resExt0.markRecord.externalMarks -eq 0)

# Boundary: 60 (valid)
$resExt60 = $null
try {
    $body = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "external"; externalMarks = 60 } | ConvertTo-Json
    $resExt60 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $body -Headers $headers
} catch {}
Report-Test "Accept valid external marks boundary max (60)" ($resExt60 -and $resExt60.success -and $resExt60.markRecord.externalMarks -eq 60)

# Valid: 48 (Total = 32 + 48 = 80)
$bodyExt48 = @{ studentId = $testStudentId; subjectId = $testSubjectId; markType = "external"; externalMarks = 48 } | ConvertTo-Json
$resExt48 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $bodyExt48 -Headers $headers
Report-Test "Save external marks (48) with internal (32)" ($resExt48.success -and $resExt48.markRecord.externalMarks -eq 48)

# 6. Step 10: Automatic Subject Total Calculation
Write-Host "`n--- Phase 6: Step 10 Subject Total Calculation ---" -ForegroundColor Yellow
$recordsRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/student-marks?studentId=$testStudentId" -Method GET -Headers $headers
$subRecord = $recordsRes | Where-Object { $_.subjectId -eq $testSubjectId }
$computedTotal = [int]$subRecord.internalMarks + [int]$subRecord.externalMarks
Report-Test "Subject Total equals Internal (32) + External (48) = 80" ($computedTotal -eq 80) "Total: $computedTotal / 100"

# 7. Step 9 Stage E: Confirmation requirement when clearing internal with existing external
Write-Host "`n--- Phase 7: Stage E Confirmation Flow ---" -ForegroundColor Yellow
$confStatus = 0
$requiresConf = $false
try {
    $bodyClearInt = @{
        studentId = $testStudentId
        subjectId = $testSubjectId
        markType = "internal"
        internalMarks = $null
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $bodyClearInt -Headers $headers
} catch {
    if ($_.Exception.Response) {
        $confStatus = [int]$_.Exception.Response.StatusCode
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $respJson = $_.ErrorDetails.Message | ConvertFrom-Json
            $requiresConf = ($respJson.requiresConfirmation -eq $true)
        }
    }
}
Report-Test "Require confirmation (HTTP 409) when clearing internal while external exists" ($confStatus -eq 409 -and $requiresConf) "Status: $confStatus"

# When confirmed with forceConfirmed: true
$bodyForceConfirm = @{
    studentId = $testStudentId
    subjectId = $testSubjectId
    markType = "internal"
    internalMarks = $null
    forceConfirmed = $true
} | ConvertTo-Json
$resForce = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Body $bodyForceConfirm -Headers $headers
Report-Test "Clearing with forceConfirmed: true succeeds" ($resForce.success -and $resForce.markRecord.internalMarks -eq $null -and $resForce.markRecord.externalMarks -eq $null) "Marks reset to NULL"

# 8. Step 10: Student Result View & Aggregate Rules
Write-Host "`n--- Phase 8: Step 10 Student Result View & Aggregates ---" -ForegroundColor Yellow

# Authenticate as the test student (passwordless Student ID)
$stdLoginBody = @{ studentId = $testStudentId } | ConvertTo-Json
$stdLoginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stdLoginBody -ContentType "application/json"
$stdSession = $stdLoginRes.session.sessionId
Report-Test "Student Login ($testStudentId)" ($stdLoginRes.success -and $stdSession) "Session ID: $stdSession"

$stdHeaders = @{ "X-Session-Id" = $stdSession; "Accept" = "application/json" }
$stdRecords = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers $stdHeaders
Report-Test "Student Records Retrieved via Session Token" ($stdRecords.subjects.Count -eq 10) "Subjects count: $($stdRecords.subjects.Count)"

# Check passfailConfigured flag
Report-Test "Pass/Fail Rules Explicitly Unconfigured" ($stdRecords.passfailConfigured -eq $false) "Note: $($stdRecords.passfailNote)"

# 9. Unauthorized Rejection Security
Write-Host "`n--- Phase 9: Security Rejections ---" -ForegroundColor Yellow
$unauthRejected = $false
try {
    Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET
} catch {
    $unauthRejected = [int]$_.Exception.Response.StatusCode -eq 401
}
Report-Test "Reject unauthenticated request to /api/student/records (HTTP 401)" $unauthRejected

# Final Score
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " TEST RESULTS SUMMARY: $passed Passed, $failed Failed out of $totalTests" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
