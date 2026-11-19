param([int]$Port = 8089)

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
Write-Host " Testing Excel Marks Import with Actual MARKS.xlsx File " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Start server on test port
Write-Host "`n--- Starting test server on Port $Port ---" -ForegroundColor Yellow
$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -File "$dir\server.ps1" -Port $p
} -ArgumentList $PSScriptRoot, $Port

Start-Sleep -Seconds 3
$baseUrl = "http://localhost:$Port"

try {
    # 2. Authenticate as FAC101 (DBMS faculty)
    Write-Host "`n--- Authenticating as Faculty FAC101 ---" -ForegroundColor Yellow
    $facLoginBody = @{ facultyId = "FAC101"; email = "FAC101@edu.in"; password = "Faculty@123" } | ConvertTo-Json
    $loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $facLoginBody -ContentType "application/json"
    $facToken = $loginRes.session.sessionId
    $facHeaders = @{ "X-Session-Id" = $facToken }
    Report-Test "Faculty FAC101 logged in successfully" ($loginRes.success -and $facToken)

    # 3. Read actual MARKS.xlsx and convert to base64
    $marksPath = "$PSScriptRoot\MARKS.xlsx"
    Report-Test "MARKS.xlsx file exists" (Test-Path $marksPath)
    $fileBytes = [System.IO.File]::ReadAllBytes($marksPath)
    $marksBase64 = [Convert]::ToBase64String($fileBytes)

    # 4. Preview MARKS.xlsx
    Write-Host "`n--- Previewing actual MARKS.xlsx ---" -ForegroundColor Yellow
    $previewPayload = @{
        subjectId = "DBMS"
        fileName = "MARKS.xlsx"
        fileContentBase64 = $marksBase64
    } | ConvertTo-Json

    $previewRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-preview" -Method POST -Body $previewPayload -ContentType "application/json" -Headers $facHeaders

    Report-Test "Preview request succeeds" ($previewRes.success)
    Report-Test "Detected subject is DBMS" ($previewRes.subjectCode -eq "DBMS") "Subject: $($previewRes.subjectCode)"
    Report-Test "Total rows is 34" ($previewRes.totalRows -eq 34) "Total: $($previewRes.totalRows)"
    Report-Test "Student ID is correctly mapped (NOT 'DBMS')" ($previewRes.rows[0].studentId -eq "25QM1A66D6") "First row Student ID: $($previewRes.rows[0].studentId)"
    Report-Test "Subject Code is correctly mapped ('DBMS')" ($previewRes.rows[0].subjectCode -eq "DBMS") "First row Subject Code: $($previewRes.rows[0].subjectCode)"
    Report-Test "Student Name is resolved ('Shiva Charan Goud')" ($previewRes.rows[0].studentName -eq "Shiva Charan Goud") "Student Name: $($previewRes.rows[0].studentName)"
    Report-Test "First row has valid internal=25, external=58" ($previewRes.rows[0].internalMarks -eq 25 -and $previewRes.rows[0].externalMarks -eq 58) "Int: $($previewRes.rows[0].internalMarks), Ext: $($previewRes.rows[0].externalMarks)"
    Report-Test "First row status is VALID" ($previewRes.rows[0].status -eq "VALID")
    Report-Test "Exactly 30 valid rows and 4 invalid rows" ($previewRes.validRowsCount -eq 30 -and $previewRes.invalidRowsCount -eq 4) "Valid: $($previewRes.validRowsCount), Invalid: $($previewRes.invalidRowsCount)"

    # Verify specific invalid rows:
    # Row 8: 25QM1A66E1 (Internal -2.0)
    $r8 = $previewRes.rows | Where-Object { $_.studentId -eq "25QM1A66E1" } | Select-Object -First 1
    Report-Test "Row for 25QM1A66E1 rejected (negative internal -2)" ($r8.status -eq "INVALID" -and $r8.errorMessage -match "domain \[0-40\]") "Error: $($r8.errorMessage)"

    # Row 11: 25QM1A66E4 (Internal -14.0)
    $r11 = $previewRes.rows | Where-Object { $_.studentId -eq "25QM1A66E4" } | Select-Object -First 1
    Report-Test "Row for 25QM1A66E4 rejected (negative internal -14)" ($r11.status -eq "INVALID" -and $r11.errorMessage -match "domain \[0-40\]") "Error: $($r11.errorMessage)"

    # Row 12: 25QM1A66E5 (External 63.0)
    $r12 = $previewRes.rows | Where-Object { $_.studentId -eq "25QM1A66E5" } | Select-Object -First 1
    Report-Test "Row for 25QM1A66E5 rejected (out-of-range external 63)" ($r12.status -eq "INVALID" -and $r12.errorMessage -match "domain \[0-60\]") "Error: $($r12.errorMessage)"

    # Row 29: 25QM1A66G2 (Internal -5.0)
    $r29 = $previewRes.rows | Where-Object { $_.studentId -eq "25QM1A66G2" } | Select-Object -First 1
    Report-Test "Row for 25QM1A66G2 rejected (negative internal -5)" ($r29.status -eq "INVALID" -and $r29.errorMessage -match "domain \[0-40\]") "Error: $($r29.errorMessage)"

    # 5. Commit Valid Marks
    Write-Host "`n--- Committing Valid Marks from MARKS.xlsx ---" -ForegroundColor Yellow
    $commitRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-commit" -Method POST -Body $previewPayload -ContentType "application/json" -Headers $facHeaders

    Report-Test "Commit succeeds" ($commitRes.success)
    Report-Test "Exactly 30 valid rows imported" ($commitRes.importedCount -eq 30) "Imported count: $($commitRes.importedCount)"
    Report-Test "Exactly 4 invalid rows rejected" ($commitRes.rejectedCount -eq 4) "Rejected count: $($commitRes.rejectedCount)"
    Report-Test "Reported processed count is 34" ($commitRes.processedCount -eq 34) "Processed count: $($commitRes.processedCount)"
    Report-Test "Reported validCount is 30" ($commitRes.validCount -eq 30) "Valid count: $($commitRes.validCount)"
    Report-Test "Reported invalidCount is 4" ($commitRes.invalidCount -eq 4) "Invalid count: $($commitRes.invalidCount)"
    Report-Test "All 4 rejected students listed with reasons" ($commitRes.rejectedRows.Count -eq 4) "Count: $($commitRes.rejectedRows.Count)"

    # 6. Verify Database Persistence for Valid & Invalid rows
    Write-Host "`n--- Verifying Database Records via Faculty API ---" -ForegroundColor Yellow
    $subDetails = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers $facHeaders
    
    # Valid student 25QM1A66D6: Internal 25, External 58, Total 83
    $stD6 = $subDetails.students | Where-Object { $_.studentId -eq "25QM1A66D6" } | Select-Object -First 1
    Report-Test "Student 25QM1A66D6 saved with internal=25" ($stD6.internalMarks -eq 25) "Internal: $($stD6.internalMarks)"
    Report-Test "Student 25QM1A66D6 saved with external=58" ($stD6.externalMarks -eq 58) "External: $($stD6.externalMarks)"
    Report-Test "Student 25QM1A66D6 total is 83" ($stD6.totalMarks -eq 83) "Total: $($stD6.totalMarks)"

    # Invalid student 25QM1A66E5 (had external=63): Internal & External must remain NULL
    $stE5 = $subDetails.students | Where-Object { $_.studentId -eq "25QM1A66E5" } | Select-Object -First 1
    Report-Test "Rejected student 25QM1A66E5 marks remain NULL in DB" ($null -eq $stE5.internalMarks -and $null -eq $stE5.externalMarks) "Int: $($stE5.internalMarks), Ext: $($stE5.externalMarks)"

    # 7. Verify Student Academic Records via Student API
    Write-Host "`n--- Verifying Student Academic Records ---" -ForegroundColor Yellow
    $stLoginBody = @{ studentId = "25QM1A66D6" } | ConvertTo-Json
    $stLoginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stLoginBody -ContentType "application/json"
    $stToken = $stLoginRes.session.sessionId

    $stRecords = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stToken }
    $dbmsMark = $stRecords.subjects | Where-Object { $_.subjectId -eq "DBMS" } | Select-Object -First 1
    Report-Test "Student 25QM1A66D6 records show DBMS Internal=25" ($dbmsMark.internalMarks -eq 25)
    Report-Test "Student 25QM1A66D6 records show DBMS External=58" ($dbmsMark.externalMarks -eq 58)
    Report-Test "Student 25QM1A66D6 records show DBMS Total=83" ($dbmsMark.totalMarks -eq 83)
    Report-Test "Student 25QM1A66D6 records show DBMS Status=PASS" ($dbmsMark.resultStatus -eq "PASS")

    # Check student with rejected marks
    $stE5LoginBody = @{ studentId = "25QM1A66E5" } | ConvertTo-Json
    $stE5LoginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stE5LoginBody -ContentType "application/json"
    $stE5Records = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stE5LoginRes.session.sessionId }
    $dbmsE5 = $stE5Records.subjects | Where-Object { $_.subjectId -eq "DBMS" } | Select-Object -First 1
    Report-Test "Rejected student 25QM1A66E5 shows NULL internal marks ('Not Updated')" ($null -eq $dbmsE5.internalMarks)
    Report-Test "Rejected student 25QM1A66E5 shows NULL external marks ('Not Updated')" ($null -eq $dbmsE5.externalMarks)
    Report-Test "Rejected student 25QM1A66E5 status is 'Result Pending'" ($dbmsE5.resultStatus -eq "Result Pending")

} finally {
    Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " MARKS.xlsx Verification Suite: $passed Passed, $failed Failed out of $totalTests Tests" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
