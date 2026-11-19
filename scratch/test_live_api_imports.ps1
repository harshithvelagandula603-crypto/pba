# ==============================================================================
# Live End-to-End API Test for Excel & CSV Table File Storage
# ==============================================================================

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0

function Report-Test($name, $condition, $details = "") {
    if ($condition) {
        $script:passed++
        Write-Host "  [PASS] $name" -ForegroundColor Green
        if ($details) { Write-Host "         $details" -ForegroundColor Gray }
    } else {
        $script:failed++
        Write-Host "  [FAIL] $name - $details" -ForegroundColor Red
    }
}

$baseUrl = "http://localhost:8080"
$exportDir = "$PSScriptRoot\..\data\export"

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Live API Verification: Excel & CSV Automatic Table-File Storage" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Authenticate as Faculty FAC101 (Assigned: DBMS, SE_LAB)
Write-Host "`n--- 1. Authenticating as Faculty FAC101 ---" -ForegroundColor Yellow
$facLoginBody = @{ facultyId = "FAC101"; email = "FAC101@edu.in"; password = "Faculty@123" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $facLoginBody -ContentType "application/json"
$facToken = $loginRes.session.sessionId
$facHeaders = @{ "X-Session-Id" = $facToken }
Report-Test "Faculty FAC101 logged in successfully" ($loginRes.success -and $facToken)

# 2. Test Excel Import (.xlsx)
Write-Host "`n--- 2. Testing Excel Import with MARKS.xlsx ---" -ForegroundColor Yellow
$marksPath = "$PSScriptRoot\..\MARKS.xlsx"
$fileBytes = [System.IO.File]::ReadAllBytes($marksPath)
$marksBase64 = [Convert]::ToBase64String($fileBytes)

$previewPayload = @{
    subjectId = "DBMS"
    fileName = "MARKS.xlsx"
    fileContentBase64 = $marksBase64
} | ConvertTo-Json

$previewRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-preview" -Method POST -Body $previewPayload -ContentType "application/json" -Headers $facHeaders
Report-Test "Excel Preview succeeds" ($previewRes.success)
Report-Test "Detected subject is DBMS" ($previewRes.subjectCode -eq "DBMS")
Report-Test "Total rows is 34" ($previewRes.totalRows -eq 34)
Report-Test "First row Student ID is '25QM1A66D6' (NOT 'DBMS')" ($previewRes.rows[0].studentId -eq "25QM1A66D6") "Student: $($previewRes.rows[0].studentId)"
Report-Test "30 valid rows, 4 invalid rows" ($previewRes.validRowsCount -eq 30 -and $previewRes.invalidRowsCount -eq 4)

# Commit Excel marks and verify table files are refreshed automatically
$commitRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-commit" -Method POST -Body $previewPayload -ContentType "application/json" -Headers $facHeaders
Report-Test "Excel Commit succeeds" ($commitRes.success)
Report-Test "Table files automatically synchronized on Excel commit" ($commitRes.tableFilesSynchronized -eq $true)
Report-Test "30 valid marks imported to database" ($commitRes.importedCount -eq 30)

# Verify table files on disk
Report-Test "marks.csv exists on disk" (Test-Path "$exportDir\marks.csv")
Report-Test "results.csv exists on disk" (Test-Path "$exportDir\results.csv")
$marksContent = Get-Content "$exportDir\marks.csv" -Raw
Report-Test "marks.csv updated with student 25QM1A66D6" ($marksContent.Contains("25QM1A66D6"))

# 3. Test CSV Import: Fix Previous Error (Subject first: 'DBMS' not Student ID)
Write-Host "`n--- 3. Testing CSV Import: Previous Root Cause Fix ---" -ForegroundColor Yellow

$csvWithSubjectFirst = @"
Subject,Student ID,Internal Marks (40),External Marks (60)
DBMS,25QM1A66D6,35,55
DBMS,25QM1A66D7,30,48
"@

$csvRes1 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvWithSubjectFirst -ContentType "text/plain; charset=UTF-8" -Headers $facHeaders
Report-Test "CSV Import (Subject as Col 0) succeeded" ($csvRes1.success)
Report-Test "Correctly accepted 2 valid records" ($csvRes1.validCount -eq 2)
Report-Test "Zero rejected records" ($csvRes1.rejectedCount -eq 0)
Report-Test "Database synchronized" ($csvRes1.databaseSynchronized -eq $true)
Report-Test "Table files synchronized" ($csvRes1.tableFilesSynchronized -eq $true)

# 4. Test CSV Import with 'Sudent ID' typo header
Write-Host "`n--- 4. Testing CSV Import with 'Sudent ID' Header Typo ---" -ForegroundColor Yellow

$csvWithTypo = @"
Subject,Sudent ID,Internal Marks (40),External Marks (60)
DBMS,25QM1A66D8,32,50
"@

$csvRes2 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvWithTypo -ContentType "text/plain; charset=UTF-8" -Headers $facHeaders
Report-Test "CSV Import with 'Sudent ID' succeeded" ($csvRes2.success)
Report-Test "Record accepted for student 25QM1A66D8" ($csvRes2.validCount -eq 1)

# 5. Test CSV Import with Inverted Column Order
Write-Host "`n--- 5. Testing CSV Import with Inverted Column Order ---" -ForegroundColor Yellow

$csvInverted = @"
Student ID,Subject,Internal Marks (40),External Marks (60)
25QM1A66D9,DBMS,29,51
"@

$csvRes3 = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvInverted -ContentType "text/plain; charset=UTF-8" -Headers $facHeaders
Report-Test "CSV Import with Student ID first succeeded" ($csvRes3.success)
Report-Test "Record accepted for student 25QM1A66D9" ($csvRes3.validCount -eq 1)

# 6. Test Subject Mismatch Rejection (All-or-Nothing)
Write-Host "`n--- 6. Testing Subject Mismatch All-or-Nothing Rejection ---" -ForegroundColor Yellow

$csvMismatch = @"
Subject,Student ID,Internal Marks (40),External Marks (60)
MATHS,25QM1A66E0,30,50
"@

try {
    $mismatchRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvMismatch -ContentType "text/plain; charset=UTF-8" -Headers $facHeaders
    Report-Test "Should have rejected unauthorized subject MATHS" $false
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Test "Rejected unauthorized subject MATHS with HTTP $statusCode (403)" ($statusCode -eq 403)
}

# 7. Test Partial Failure: Valid + Invalid Rows
Write-Host "`n--- 7. Testing Partial Failure: Valid + Invalid Rows ---" -ForegroundColor Yellow

$csvPartial = @"
Subject,Student ID,Internal Marks (40),External Marks (60)
DBMS,25QM1A66E1,30,50
DBMS,NONEXISTENT_STUDENT,30,50
DBMS,25QM1A66E2,45,50
"@

$csvResPartial = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Body $csvPartial -ContentType "text/plain; charset=UTF-8" -Headers $facHeaders
Report-Test "Partial import succeeded overall" ($csvResPartial.success)
Report-Test "Accepted 1 valid record (25QM1A66E1)" ($csvResPartial.validCount -eq 1)
Report-Test "Rejected 2 invalid records" ($csvResPartial.rejectedCount -eq 2)

$errReasons = @($csvResPartial.errors | ForEach-Object { $_.reason })
Report-Test "Reported error for NONEXISTENT_STUDENT" (($errReasons | Where-Object { $_ -like "*does not exist*" }).Count -gt 0)
Report-Test "Reported error for internal marks 45 > 40" (($errReasons | Where-Object { $_ -like "*between 0 and 40*" -or $_ -match "domain \[0-40\]" }).Count -gt 0)

# 8. Verify Student Academic Records Endpoint
Write-Host "`n--- 8. Verifying Student Portal Access ---" -ForegroundColor Yellow
$stLoginBody = @{ studentId = "25QM1A66D6" } | ConvertTo-Json
$stLoginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stLoginBody -ContentType "application/json"
$stToken = $stLoginRes.session.sessionId
$stRecords = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stToken }
Report-Test "Student 25QM1A66D6 can retrieve academic records" ($stRecords.success -and $stRecords.subjects.Count -gt 0)

$dbmsRecord = $stRecords.subjects | Where-Object { $_.subjectId -eq "DBMS" } | Select-Object -First 1
Report-Test "Student 25QM1A66D6 has DBMS total recorded" ($dbmsRecord.totalMarks -gt 0) "DBMS Total: $($dbmsRecord.totalMarks)"

Write-Host "`n=================================================================="
Write-Host " Live API Test Summary: $script:passed Passed, $script:failed Failed"
Write-Host "=================================================================="

if ($script:failed -gt 0) { exit 1 } else { exit 0 }

