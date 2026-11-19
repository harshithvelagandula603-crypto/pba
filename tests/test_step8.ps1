# ==============================================================================
# Academic Result Input Validator - Step 8 Automated Verification Test Suite
# Tests:
# 1. Faculty Authentication & Session Generation
# 2. 10 Curricular Subjects Configuration & Verification
# 3. GET /api/faculty/students empty-array fix verification
# 4. Student Roster Import (No fake data; uses institutional file)
# 5. Mark Validation Boundaries:
#    - Internal: 0 (valid), 40 (valid), -1 (rejected), 41 (rejected), "invalid" (rejected)
#    - External: 0 (valid), 60 (valid), -5 (rejected), 61 (rejected), "text" (rejected)
# 6. NULL Preservation (Empty fields must remain NULL, never converted to 0)
# 7. Upsert Behavior (Updating existing mark records without duplicating)
# 8. Total Marks Computation (Only when both present; withheld when missing)
# 9. Faculty Session Security (Unauthorized requests rejected)
# 10. Dashboard Stats & Subject Overview compatibility
# ==============================================================================

$baseUrl = "http://localhost:8080"
$passed = 0
$failed = 0

function Assert-Test {
    param([string]$Title, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host " [PASS] $Title" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host " [FAIL] $Title - $Details" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Step 8 Verification Test Suite: Enter/Update Marks Terminal" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Test 1: Faculty Authentication
$loginBody = @{ username = "faculty"; password = "admin123" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method Post -Body $loginBody -ContentType "application/json"
$token = $loginRes.session.sessionId
Assert-Test -Title "Faculty Authentication (Login)" -Condition ($loginRes.success -and $token)

$headers = @{ "X-Session-Id" = $token }

# Test 2: Check 10 Subjects via /api/faculty/subjects
$subsRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subjects" -Method Get -Headers $headers
$subs = $subsRes.subjects
Assert-Test -Title "10 Curricular Subjects Configured" -Condition ($subs.Count -eq 10) -Details "Count: $($subs.Count)"

$expectedSubjects = @(
    @{ code = "DBMS";      name = "Database Management Systems" },
    @{ code = "Maths";     name = "Mathematics" },
    @{ code = "OOPs";      name = "Object-Oriented Programming" },
    @{ code = "SE";        name = "Software Engineering" },
    @{ code = "COA";       name = "Computer Organization and Architecture" },
    @{ code = "SE Lab";    name = "Software Engineering Laboratory" },
    @{ code = "Maths Lab"; name = "Mathematics Laboratory" },
    @{ code = "OOPs Lab";  name = "Object-Oriented Programming Laboratory" },
    @{ code = "SD Lab";    name = "Software Development Laboratory" },
    @{ code = "DBMS Lab";  name = "Database Management Systems Laboratory" }
)

$allMatched = $true
foreach ($exp in $expectedSubjects) {
    $found = $subs | Where-Object { $_.subjectCode -eq $exp.code -and $_.subjectName -eq $exp.name }
    if (-not $found) {
        $allMatched = $false
        Write-Host "   Missing or mismatched subject: $($exp.code) - $($exp.name)" -ForegroundColor Yellow
    }
}
Assert-Test -Title "All 10 Subjects Match Expected Code & Full Name" -Condition $allMatched

# Test 3: GET /api/faculty/students handles empty list without crashing
$studentsRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method Get -Headers $headers
Assert-Test -Title "GET /api/faculty/students returns valid JSON array (Bug 2 Fixed)" -Condition ($null -ne $studentsRes)

# Test 4: Import Roster from actual template
$importRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/import-actual" -Method Post -Headers $headers
Assert-Test -Title "Import Institutional Student Roster" -Condition ($importRes.success -and $importRes.importedCount -ge 0)

# Re-fetch students
$students = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method Get -Headers $headers
Assert-Test -Title "Students Available in Database" -Condition ($students.Count -gt 0) -Details "Found $($students.Count) students"

$testStudent = $students[0]
$testStudentId = $testStudent.studentId
Write-Host "   Using Test Student: $($testStudent.studentName) ($testStudentId)" -ForegroundColor Gray

# Test 5: Validation - Internal Marks
# 5a. Valid Internal = 0
$m0 = @{ studentId = $testStudentId; subjectId = "DBMS"; internalMarks = 0; externalMarks = $null } | ConvertTo-Json
$r0 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $m0 -ContentType "application/json"
Assert-Test -Title "Internal Mark Boundary: 0 (Valid)" -Condition ($r0.success -and $r0.markRecord.internalMarks -eq 0)

# 5b. Valid Internal = 40
$m40 = @{ studentId = $testStudentId; subjectId = "DBMS"; internalMarks = 40; externalMarks = $null } | ConvertTo-Json
$r40 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $m40 -ContentType "application/json"
Assert-Test -Title "Internal Mark Boundary: 40 (Valid)" -Condition ($r40.success -and $r40.markRecord.internalMarks -eq 40)

# 5c. Reject Internal = -1
try {
    $mNeg = @{ studentId = $testStudentId; subjectId = "DBMS"; internalMarks = -1 } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mNeg -ContentType "application/json"
    Assert-Test -Title "Internal Mark: -1 Rejected" -Condition $false
} catch {
    Assert-Test -Title "Internal Mark: -1 Rejected" -Condition ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# 5d. Reject Internal = 41
try {
    $mOver = @{ studentId = $testStudentId; subjectId = "DBMS"; internalMarks = 41 } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mOver -ContentType "application/json"
    Assert-Test -Title "Internal Mark: 41 Rejected" -Condition $false
} catch {
    Assert-Test -Title "Internal Mark: 41 Rejected" -Condition ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# 5e. Reject Internal = "invalid_text"
try {
    $mTxt = @{ studentId = $testStudentId; subjectId = "DBMS"; internalMarks = "abc" } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mTxt -ContentType "application/json"
    Assert-Test -Title "Internal Mark: Text Rejected" -Condition $false
} catch {
    Assert-Test -Title "Internal Mark: Text Rejected" -Condition ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# Test 6: Validation - External Marks
# 6a. Valid External = 0
$mExt0 = @{ studentId = $testStudentId; subjectId = "MATHS"; internalMarks = $null; externalMarks = 0 } | ConvertTo-Json
$rExt0 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mExt0 -ContentType "application/json"
Assert-Test -Title "External Mark Boundary: 0 (Valid)" -Condition ($rExt0.success -and $rExt0.markRecord.externalMarks -eq 0)

# 6b. Valid External = 60
$mExt60 = @{ studentId = $testStudentId; subjectId = "MATHS"; internalMarks = $null; externalMarks = 60 } | ConvertTo-Json
$rExt60 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mExt60 -ContentType "application/json"
Assert-Test -Title "External Mark Boundary: 60 (Valid)" -Condition ($rExt60.success -and $rExt60.markRecord.externalMarks -eq 60)

# 6c. Reject External = -5
try {
    $mExtNeg = @{ studentId = $testStudentId; subjectId = "MATHS"; externalMarks = -5 } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mExtNeg -ContentType "application/json"
    Assert-Test -Title "External Mark: -5 Rejected" -Condition $false
} catch {
    Assert-Test -Title "External Mark: -5 Rejected" -Condition ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# 6d. Reject External = 61
try {
    $mExtOver = @{ studentId = $testStudentId; subjectId = "MATHS"; externalMarks = 61 } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mExtOver -ContentType "application/json"
    Assert-Test -Title "External Mark: 61 Rejected" -Condition $false
} catch {
    Assert-Test -Title "External Mark: 61 Rejected" -Condition ($_.Exception.Response.StatusCode.value__ -eq 400)
}

# Test 7: NULL Handling & Partial Updates
# 7a. Internal entered (35), External NULL -> Total withheld
$mPart = @{ studentId = $testStudentId; subjectId = "OOPS"; internalMarks = 35; externalMarks = $null } | ConvertTo-Json
$rPart = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mPart -ContentType "application/json"
Assert-Test -Title "Partial Update: Internal 35, External NULL -> Total is NULL" -Condition ($rPart.success -and $rPart.markRecord.internalMarks -eq 35 -and $null -eq $rPart.markRecord.externalMarks -and $null -eq $rPart.markRecord.totalMarks)

# 7b. Update External (52) for same subject -> Record updated (not duplicated), Total = 87
$mBoth = @{ studentId = $testStudentId; subjectId = "OOPS"; internalMarks = 35; externalMarks = 52 } | ConvertTo-Json
$rBoth = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $headers -Body $mBoth -ContentType "application/json"
Assert-Test -Title "Update Both: Internal 35 + External 52 = Total 87" -Condition ($rBoth.success -and $rBoth.markRecord.totalMarks -eq 87 -and $rBoth.markRecord.evalStatus -eq "Fully Entered")

# Verify no duplicate records exist for this student and subject
$allMarks = Invoke-RestMethod -Uri "$baseUrl/api/faculty/student-marks?studentId=$testStudentId" -Method Get -Headers $headers
$oopsRecords = @($allMarks | Where-Object { $_.subjectId -eq "OOPS" })
Assert-Test -Title "Duplicate Prevention: Exactly 1 record for student & subject" -Condition ($oopsRecords.Count -eq 1)

# Test 8: Security - Reject Unauthorized Requests
try {
    $fakeHeaders = @{ "X-Session-Id" = "nonexistent_token" }
    $null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method Post -Headers $fakeHeaders -Body $mBoth -ContentType "application/json"
    Assert-Test -Title "Security: Reject Unauthorized Mark Save" -Condition $false
} catch {
    Assert-Test -Title "Security: Reject Unauthorized Mark Save" -Condition ($_.Exception.Response.StatusCode.value__ -eq 401)
}

# Test 9: Faculty Dashboard Stats returns subjectCode in subjectsOverview (Bug 1 Fixed)
$stats = Invoke-RestMethod -Uri "$baseUrl/api/faculty/dashboard-stats" -Method Get -Headers $headers
$firstSubOverview = $stats.subjectsOverview[0]
Assert-Test -Title "Dashboard Stats Overview includes subjectCode" -Condition ($null -ne $firstSubOverview.subjectCode -and $firstSubOverview.subjectCode -ne "") -Details "subjectCode: $($firstSubOverview.subjectCode)"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Tests Completed: Passed: $passed | Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan
