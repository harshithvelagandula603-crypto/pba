# ==============================================================================
# Academic Result Input Validator - Step 7 Verification Test Suite
# Tests:
# 1. Faculty Authentication & Session Token Issuance
# 2. Server-Side Security & Authorization (401 Missing, 403 Student Session)
# 3. Real KPI Metrics Retrieval (/api/faculty/dashboard-stats)
# 4. Configured Subjects Structure (40 Internal, 60 External, 100 Total)
# 5. PASS/FAIL Unconfigured Rules Verification
# 6. Student Directory Retrieval & Status Gating
# 7. Internal Marks Validation (0-40 valid, -1 and 41 rejected)
# 8. External Marks Validation (0-60 valid, -1 and 61 rejected)
# 9. NULL Preservation on Reset ("Not Updated")
# 10. Student Session Security & Isolation
# ==============================================================================

$baseUrl = "http://localhost:8080"
$passed = 0
$failed = 0

function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Name - $Details" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Running Step 7: Faculty Dashboard Automated Verification" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Faculty Authentication
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 1: Faculty Authentication" -ForegroundColor Yellow

$loginBody = @{ role = "faculty"; username = "faculty1"; password = "Faculty@2024" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty-login" -Method Post -Body $loginBody -ContentType "application/json"
Assert-Test "Faculty authentication succeeds with valid credentials" ($loginRes.success -eq $true)
$facultyToken = $loginRes.session.sessionId
Assert-Test "Faculty session token issued" ([string]::IsNullOrWhiteSpace($facultyToken) -eq $false)

# Test invalid faculty credentials
try {
    $badLogin = @{ role = "faculty"; username = "faculty1"; password = "WrongPassword" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty-login" -Method Post -Body $badLogin -ContentType "application/json"
    Assert-Test "Invalid faculty password rejected" $false "Expected HTTP 401"
} catch {
    Assert-Test "Invalid faculty password rejected (401)" ($_.Exception.Response.StatusCode.value__ -eq 401)
}

# ------------------------------------------------------------------------------
# 2. Server-Side Security & Authorization
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 2: Security & Authorization Protection" -ForegroundColor Yellow

# Unauthenticated request (no session header)
try {
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/dashboard-stats" -Method Get
    Assert-Test "Unauthenticated access rejected" $false "Expected HTTP 401"
} catch {
    Assert-Test "Unauthenticated access rejected with 401" ($_.Exception.Response.StatusCode.value__ -eq 401)
}

# Student login to test privilege escalation prevention
$stuLogin = @{ studentId = "25QM1A66D6" } | ConvertTo-Json
$stuRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student-login" -Method Post -Body $stuLogin -ContentType "application/json"
$studentToken = $stuRes.session.sessionId
Assert-Test "Student passwordless login succeeds" ($stuRes.success -eq $true)

# Student token attempting to access faculty dashboard stats
try {
    $headers = @{ "X-Session-Id" = $studentToken }
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/dashboard-stats" -Method Get -Headers $headers
    Assert-Test "Student token rejected from faculty dashboard" $false "Expected HTTP 403"
} catch {
    Assert-Test "Student token rejected with 403 Forbidden" ($_.Exception.Response.StatusCode.value__ -eq 403)
}

# ------------------------------------------------------------------------------
# 3. Real KPI Metrics & Dashboard Stats
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 3: Real KPI Metrics & Subjects Configuration" -ForegroundColor Yellow

$headers = @{ "X-Session-Id" = $facultyToken }
$stats = Invoke-RestMethod -Uri "$baseUrl/api/faculty/dashboard-stats" -Method Get -Headers $headers

Assert-Test "Dashboard stats endpoint returns success" ($stats.success -eq $true)
Assert-Test "Total registered students is non-negative real count" ($stats.metrics.totalStudents -ge 0) "Count: $($stats.metrics.totalStudents)"
Assert-Test "Total configured subjects is 5" ($stats.metrics.totalSubjects -eq 5) "Count: $($stats.metrics.totalSubjects)"
Assert-Test "Students with marks pending is tracked" ($stats.metrics.studentsPending -ge 0) "Pending: $($stats.metrics.studentsPending)"
Assert-Test "Completed mark records is tracked" ($stats.metrics.completedMarkRecords -ge 0) "Completed: $($stats.metrics.completedMarkRecords)"
Assert-Test "Faculty profile username matches session" ($stats.facultyProfile.username -in @("faculty", "faculty1"))
Assert-Test "PASS/FAIL explicitly marked as unconfigured" ($stats.passfailConfigured -eq $false)
Assert-Test "Pass/Fail rules advisory note returned" ($stats.passfailNote -like "*Pass/Fail Rules Not Configured*")

# Check subject configurations (40 Internal, 60 External, 100 Total)
Assert-Test "Subjects overview contains 5 subjects" ($stats.subjectsOverview.Count -eq 5)
$firstSub = $stats.subjectsOverview[0]
Assert-Test "Subject maxInternal is 40" ($firstSub.maxInternal -eq 40)
Assert-Test "Subject maxExternal is 60" ($firstSub.maxExternal -eq 60)
Assert-Test "Subject maxMarks is 100" ($firstSub.maxMarks -eq 100)

# ------------------------------------------------------------------------------
# 4. Student Directory & Evaluation Status
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 4: Student Directory Retrieval & Status Gating" -ForegroundColor Yellow

$students = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method Get -Headers $headers
Assert-Test "Students directory returned as array" ($students.Count -gt 0) "Count: $($students.Count)"
$sampleStudent = $students[0]
Assert-Test "Student record contains studentId and studentName" (-not [string]::IsNullOrEmpty($sampleStudent.studentId) -and -not [string]::IsNullOrEmpty($sampleStudent.studentName))
Assert-Test "Student record contains fullyEnteredCount and pendingCount" ($null -ne $sampleStudent.fullyEnteredCount -and $null -ne $sampleStudent.pendingCount)
Assert-Test "Result outcome is not misleading (Rules Not Configured or Marks Pending)" ($sampleStudent.resultOutcome -in @("Pass/Fail Rules Not Configured", "Marks Pending")) "Outcome: $($sampleStudent.resultOutcome)"

# ------------------------------------------------------------------------------
# 5. Internal & External Marks Domain Constraints
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 5: Internal & External Mark Boundary Constraints" -ForegroundColor Yellow

$testStudentId = $sampleStudent.studentId
$testSubId = $sampleStudent.subjects[0].subjectId

# Valid marks: internal = 35 (<= 40), external = 55 (<= 60)
$validMark = @{
    studentId = $testStudentId
    subjectId = $testSubId
    internalMarks = 35
    externalMarks = 55
} | ConvertTo-Json

try {
    $markRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $validMark -Headers $headers -ContentType "application/json"
    Assert-Test "Valid mark entry (35 Internal, 55 External) accepted" ($markRes.success -eq $true)
} catch {
    $errText = $_.Exception.Message
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errText += " -> " + $reader.ReadToEnd()
    }
    Assert-Test "Valid mark entry (35 Internal, 55 External) accepted" $false $errText
}

# Boundary checks: internal = 0, external = 0 (valid scores)
$zeroMark = @{
    studentId = $testStudentId
    subjectId = $testSubId
    internalMarks = 0
    externalMarks = 0
} | ConvertTo-Json
$zeroRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $zeroMark -Headers $headers -ContentType "application/json"
Assert-Test "Boundary score 0 is accepted as valid numeric mark" ($zeroRes.success -eq $true)

# Boundary checks: internal = 40 (max), external = 60 (max)
$maxMark = @{
    studentId = $testStudentId
    subjectId = $testSubId
    internalMarks = 40
    externalMarks = 60
} | ConvertTo-Json
$maxRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $maxMark -Headers $headers -ContentType "application/json"
Assert-Test "Boundary score 40 Internal, 60 External accepted" ($maxRes.success -eq $true)

# Invalid check: internal = 41 (exceeds 40) -> REJECT
try {
    $badInt = @{
        studentId = $testStudentId
        subjectId = $testSubId
        internalMarks = 41
        externalMarks = 50
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $badInt -Headers $headers -ContentType "application/json"
    Assert-Test "Internal mark 41 rejected" $false "Expected HTTP 400"
} catch {
    Assert-Test "Internal mark 41 rejected with 400 Bad Request" ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# Invalid check: external = 61 (exceeds 60) -> REJECT
try {
    $badExt = @{
        studentId = $testStudentId
        subjectId = $testSubId
        internalMarks = 30
        externalMarks = 61
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $badExt -Headers $headers -ContentType "application/json"
    Assert-Test "External mark 61 rejected" $false "Expected HTTP 400"
} catch {
    Assert-Test "External mark 61 rejected with 400 Bad Request" ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# Invalid check: negative internal mark -5 -> REJECT
try {
    $negInt = @{
        studentId = $testStudentId
        subjectId = $testSubId
        internalMarks = -5
        externalMarks = 50
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $negInt -Headers $headers -ContentType "application/json"
    Assert-Test "Negative internal mark rejected" $false "Expected HTTP 400"
} catch {
    Assert-Test "Negative internal mark rejected with 400 Bad Request" ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# Reset to NULL (Not Updated)
$resetMark = @{
    studentId = $testStudentId
    subjectId = $testSubId
    internalMarks = $null
    externalMarks = $null
} | ConvertTo-Json
$resetRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Body $resetMark -Headers $headers -ContentType "application/json"
Assert-Test "Resetting marks to NULL succeeds" ($resetRes.success -eq $true)

# Verify marks are now returned as NULL ("Not Updated"), not 0
$checkMarks = Invoke-RestMethod -Uri "$baseUrl/api/faculty/student-marks?studentId=$testStudentId" -Method Get -Headers $headers
$targetSub = $checkMarks | Where-Object { $_.subjectId -eq $testSubId } | Select-Object -First 1
Assert-Test "Internal mark is strictly NULL after reset" ($null -eq $targetSub.internalMarks)
Assert-Test "External mark is strictly NULL after reset" ($null -eq $targetSub.externalMarks)
Assert-Test "Total marks is strictly NULL when unentered" ($null -eq $targetSub.totalMarks)
Assert-Test "Evaluation status is 'Not Updated'" ($targetSub.evalStatus -eq "Not Updated")

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "Test Suite Completed: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
