# ==============================================================================
# Academic Result Input Validator - Comprehensive Faculty Flow Verification
# Tests:
# 1. Faculty Excel Import from Faculty_Details_Email_Addresses.xlsx
# 2. Idempotent Import (Zero duplicates on repeated imports)
# 3. Existing Student Records Intact (34 records preserved)
# 4. Password Security & Handling of Unconfigured / Missing Passwords
# 5. Admin Initial Password Configuration
# 6. Faculty Login (Valid vs Invalid Credentials)
# 7. Post-Login Subject Isolation for FAC101 to FAC108
# 8. Server-Side Security & Tamper Rejection (HTTP 403 for Unassigned Subjects)
# 9. Marks Domain Integrity (Internal-First, 0-40, 0-60, NULL as "Not Updated", Computed Total)
# ==============================================================================

param([int]$Port = 8085)

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0
$totalTests = 0

function Report-Test($name, $condition, $details = "") {
    $script:totalTests++
    if ($condition) {
        $script:passed++
        Write-Host "  [PASS] $name" -ForegroundColor Green
        if ($details) { Write-Host "         $details" -ForegroundColor Gray }
    } else {
        $script:failed++
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($details) { Write-Host "         $details" -ForegroundColor Yellow }
    }
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Academic Result Input Validator - Faculty Verification Suite     " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Start test server instance
Write-Host "`n--- Phase 1: Launch Test Server Instance on Port $Port ---" -ForegroundColor Yellow

$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $projectRoot "server.ps1"))) { $projectRoot = $PSScriptRoot }

$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -File "$dir\server.ps1" -Port $p
} -ArgumentList $projectRoot, $Port

Start-Sleep -Seconds 3
$baseUrl = "http://localhost:$Port"

try {
    # --------------------------------------------------------------------------
    # 2. Verify Excel File & Faculty Data Synchronization
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 2: Faculty Data Import & Idempotency ---" -ForegroundColor Yellow

    # Call import endpoint to test idempotency
    $importRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/import-faculty-excel" -Method POST
    Report-Test "Faculty Excel Import API succeeds" ($importRes.success) "Faculty: $($importRes.facultyCount), Assignments: $($importRes.assignmentsCount)"
    Report-Test "Exact 8 faculty accounts registered" ($importRes.facultyCount -eq 8) "Count: $($importRes.facultyCount)"
    Report-Test "Exact 10 subject assignments registered" ($importRes.assignmentsCount -eq 10) "Count: $($importRes.assignmentsCount)"

    # Repeat import to verify idempotency (zero duplicates)
    $repeatRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/import-faculty-excel" -Method POST
    Report-Test "Repeated import maintains exactly 8 faculty accounts" ($repeatRes.facultyCount -eq 8)
    Report-Test "Repeated import maintains exactly 10 assignments" ($repeatRes.assignmentsCount -eq 10)

    # --------------------------------------------------------------------------
    # 3. Verify Existing Student Records Remain Intact
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 3: Existing Student Records Integrity ---" -ForegroundColor Yellow

    $adminLogin = @{ username = "faculty"; password = "admin123" } | ConvertTo-Json
    $adminRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $adminLogin -ContentType "application/json"
    $adminToken = $adminRes.session.sessionId

    $students = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method GET -Headers @{ "X-Session-Id" = $adminToken }
    Report-Test "Existing student records intact" ($students.Count -eq 34) "Found $($students.Count) student records"
    Report-Test "First student intact: '25QM1A66D6 - Shiva Charan Goud'" ($students[0].studentId -eq "25QM1A66D6")

    # --------------------------------------------------------------------------
    # 4. Authentication Tests (Valid, Invalid, Unconfigured)
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 4: Faculty Authentication & Password Handling ---" -ForegroundColor Yellow

    # 4.1 Valid login for FAC101
    $fac101Login = @{ facultyId = "FAC101"; password = "Faculty@123" } | ConvertTo-Json
    $fac101Res = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $fac101Login -ContentType "application/json"
    Report-Test "FAC101 login succeeds with valid configured credentials" ($fac101Res.success -and $fac101Res.session.facultyId -eq "FAC101")
    $fac101Token = $fac101Res.session.sessionId

    # 4.2 Invalid password rejected
    $badPassBody = @{ facultyId = "FAC101"; password = "wrong_password_999" } | ConvertTo-Json
    $badPassStatus = 0
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $badPassBody -ContentType "application/json"
    } catch {
        $badPassStatus = [int]$_.Exception.Response.StatusCode
    }
    Report-Test "FAC101 login rejected on wrong password (401)" ($badPassStatus -eq 401)

    # 4.3 Non-existent Faculty ID rejected
    $badIdBody = @{ facultyId = "FAC999"; password = "Faculty@123" } | ConvertTo-Json
    $badIdStatus = 0
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $badIdBody -ContentType "application/json"
    } catch {
        $badIdStatus = [int]$_.Exception.Response.StatusCode
    }
    Report-Test "Non-existent Faculty ID 'FAC999' rejected (401)" ($badIdStatus -eq 401)

    # 4.4 Unconfigured Password Safety Test
    # Clear password for a test account to verify safe handling of unconfigured accounts
    $clearPassBody = @{ facultyId = "FAC103"; newPassword = "" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/admin/set-faculty-password" -Method POST -Body $clearPassBody -ContentType "application/json" | Out-Null

    $unconfBody = @{ facultyId = "FAC103"; password = "Faculty@123" } | ConvertTo-Json
    $unconfStatus = 0
    $unconfErr = ""
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $unconfBody -ContentType "application/json"
    } catch {
        $unconfStatus = [int]$_.Exception.Response.StatusCode
        $unconfErr = $_.ErrorDetails.Message
    }
    Report-Test "Unconfigured faculty password handled safely (403)" ($unconfStatus -eq 403) "Response: $unconfErr"

    # 4.5 Admin sets initial password
    $setPassBody = @{ facultyId = "FAC103"; newPassword = "Faculty@123" } | ConvertTo-Json
    $setRes = Invoke-RestMethod -Uri "$baseUrl/api/admin/set-faculty-password" -Method POST -Body $setPassBody -ContentType "application/json"
    Report-Test "Authorized admin sets initial password for FAC103" ($setRes.success)

    # Login now succeeds
    $fac103Res = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $unconfBody -ContentType "application/json"
    Report-Test "FAC103 login succeeds after initial password configured" ($fac103Res.success -and $fac103Res.session.facultyId -eq "FAC103")
    $fac103Token = $fac103Res.session.sessionId

    # --------------------------------------------------------------------------
    # 5. Verify Respective Subjects After Login
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 5: Post-Login Respective Subject Display ---" -ForegroundColor Yellow

    # Mapping expectation from prompt:
    # FAC101 — DBMS, SE Lab
    # FAC102 — Maths, Maths Lab
    # FAC103 — OOPs
    # FAC104 — COA
    # FAC105 — SE
    # FAC106 — SD Lab
    # FAC107 — OOPs Lab
    # FAC108 — DBMS Lab

    $expectedAssignments = @{
        "FAC101" = @("DBMS", "SE_LAB")
        "FAC102" = @("MATHS", "MATHS_LAB")
        "FAC103" = @("OOPS")
        "FAC104" = @("COA")
        "FAC105" = @("SE")
        "FAC106" = @("SD_LAB")
        "FAC107" = @("OOPS_LAB")
        "FAC108" = @("DBMS_LAB")
    }

    foreach ($facId in $expectedAssignments.Keys) {
        $loginBody = @{ facultyId = $facId; password = "Faculty@123" } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $loginBody -ContentType "application/json"
        $tok = $res.session.sessionId

        $assignedRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/assigned-subjects" -Method GET -Headers @{ "X-Session-Id" = $tok }
        $actualIds = @($assignedRes.subjects | ForEach-Object { $_.subjectId })
        $expected = $expectedAssignments[$facId]

        $matches = $true
        if ($actualIds.Count -ne $expected.Count) {
            $matches = $false
        } else {
            foreach ($exp in $expected) {
                if (-not ($actualIds -contains $exp)) { $matches = $false }
            }
        }

        Report-Test "$facId sees only assigned subjects: $($expected -join ', ')" $matches "Actual: $($actualIds -join ', ')"
    }

    # --------------------------------------------------------------------------
    # 6. Backend Authorization & Tamper Security (HTTP 403 Rejection)
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 6: Server-Side Authorization Enforcement ---" -ForegroundColor Yellow

    # 6.1 FAC101 attempts to view unassigned subject 'MATHS' (assigned to FAC102)
    $tamperStatus = 0
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=MATHS" -Method GET -Headers @{ "X-Session-Id" = $fac101Token }
    } catch {
        $tamperStatus = [int]$_.Exception.Response.StatusCode
    }
    Report-Test "FAC101 rejected from opening unassigned subject 'MATHS' (HTTP 403 Forbidden)" ($tamperStatus -eq 403)

    # 6.2 FAC101 attempts to enter marks for unassigned subject 'MATHS'
    $tamperMarkStatus = 0
    try {
        $markPayload = @{
            studentId = "25QM1A66D6"
            subjectId = "MATHS"
            markType = "internal"
            internalMarks = 35
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $fac101Token } -Body $markPayload -ContentType "application/json"
    } catch {
        $tamperMarkStatus = [int]$_.Exception.Response.StatusCode
    }
    Report-Test "FAC101 rejected from modifying marks for unassigned subject 'MATHS' (HTTP 403 Forbidden)" ($tamperMarkStatus -eq 403)

    # 6.3 FAC101 can open assigned subject 'DBMS'
    $validSubRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers @{ "X-Session-Id" = $fac101Token }
    Report-Test "FAC101 authorized to access assigned subject 'DBMS' (HTTP 200)" ($validSubRes.success -and $validSubRes.students.Count -gt 0)

    # --------------------------------------------------------------------------
    # 7. Internal-First, External-Second Marks Entry
    # --------------------------------------------------------------------------
    Write-Host "`n--- Phase 7: Subject Marks Domain Integrity ---" -ForegroundColor Yellow

    $testStudentId = "25QM1A66D6"

    # Reset DBMS marks for test student
    $resetBody = @{
        studentId = $testStudentId
        subjectId = "DBMS"
        markType = "both"
        internalMarks = $null
        externalMarks = $null
        forceConfirmed = $true
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $fac101Token } -Body $resetBody -ContentType "application/json" | Out-Null

    # 7.1 Try to enter external marks first (must be rejected)
    $extFirstStatus = 0
    try {
        $extBody = @{
            studentId = $testStudentId
            subjectId = "DBMS"
            markType = "external"
            externalMarks = 50
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $fac101Token } -Body $extBody -ContentType "application/json"
    } catch {
        $extFirstStatus = [int]$_.Exception.Response.StatusCode
    }
    Report-Test "External marks REJECTED when internal marks are missing (HTTP 400)" ($extFirstStatus -eq 400)

    # 7.2 Save valid internal marks (35 / 40)
    $intBody = @{
        studentId = $testStudentId
        subjectId = "DBMS"
        markType = "internal"
        internalMarks = 35
    } | ConvertTo-Json
    $intRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $fac101Token } -Body $intBody -ContentType "application/json"
    Report-Test "Valid internal marks (35/40) saved successfully" ($intRes.success -and $intRes.markRecord.internalMarks -eq 35)

    # Verify external marks is still NULL / Not Updated, total is NULL
    $subjDetails = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers @{ "X-Session-Id" = $fac101Token }
    $stRecord = $subjDetails.students | Where-Object { $_.studentId -eq $testStudentId } | Select-Object -First 1
    Report-Test "Missing external marks displayed as NULL / 'Marks Pending'" ($null -eq $stRecord.externalMarks -and $null -eq $stRecord.totalMarks)

    # 7.3 Now save external marks (52 / 60)
    $extBody2 = @{
        studentId = $testStudentId
        subjectId = "DBMS"
        markType = "external"
        externalMarks = 52
    } | ConvertTo-Json
    $extRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $fac101Token } -Body $extBody2 -ContentType "application/json"
    Report-Test "External marks saved after internal marks confirmed" ($extRes.success -and $extRes.markRecord.externalMarks -eq 52)

    # 7.4 Total automatically calculated (35 + 52 = 87)
    $subjDetailsAfter = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers @{ "X-Session-Id" = $fac101Token }
    $stRecordAfter = $subjDetailsAfter.students | Where-Object { $_.studentId -eq $testStudentId } | Select-Object -First 1
    Report-Test "Subject total computed when both components present (35 + 52 = 87)" ($stRecordAfter.totalMarks -eq 87 -and $stRecordAfter.evalStatus -eq "Fully Entered")

}
finally {
    Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Verification Summary: Total: $totalTests | Passed: $passed | Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
