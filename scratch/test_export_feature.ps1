param([string]$BaseUrl = "http://localhost:8080")

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Testing Common Export Functionality (Excel & CSV) End-to-End    " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Report-Test($name, $condition, $details = "") {
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

try {
    # 1. Login as Faculty FAC101
    Write-Host "`n--- 1. Authentication ---" -ForegroundColor Yellow
    $loginResp = Invoke-RestMethod -Uri "$BaseUrl/api/auth/faculty-login" -Method POST `
        -Body (@{ facultyId = "FAC101"; email = "FAC101@edu.in" } | ConvertTo-Json) `
        -ContentType "application/json"

    $token = $loginResp.session.sessionId
    Report-Test "Faculty FAC101 logged in" ($null -ne $token)
    $headers = @{ "X-Session-Id" = $token }

    # 2. Test Security: Unauthenticated access blocked
    Write-Host "`n--- 2. Security & Authorization ---" -ForegroundColor Yellow
    $unauthBlocked = $false
    try {
        Invoke-RestMethod -Uri "$BaseUrl/api/faculty/export-academic-records?format=csv" -Method GET
    } catch {
        $unauthBlocked = ($_.Exception.Response.StatusCode.value__ -eq 403)
    }
    Report-Test "Unauthenticated export request rejected with 403 Forbidden" $unauthBlocked

    # 3. Test Scenario 1: Import valid records through Excel and export them
    Write-Host "`n--- 3. Scenario 1 & 3: Excel Import and Excel Export ---" -ForegroundColor Yellow
    
    # Download template for DBMS
    $templateBytes = Invoke-WebRequest -Uri "$BaseUrl/api/faculty/marks-template?subjectId=DBMS" -Headers $headers -Method GET -UseBasicParsing
    Report-Test "Downloaded DBMS Excel template" ($templateBytes.StatusCode -eq 200 -and $templateBytes.Content.Length -gt 1000)

    # Let's import marks for 25QM1A66D6 in DBMS via Excel commit
    # Create an Excel payload or use marks-import-commit
    $excelBase64 = [Convert]::ToBase64String($templateBytes.Content)
    
    # We can commit valid marks directly via /api/faculty/marks-import-commit
    # Let's first test the preview and commit
    $previewResp = Invoke-RestMethod -Uri "$BaseUrl/api/faculty/marks-import-preview" -Method POST `
        -Headers $headers `
        -Body (@{ fileContentBase64 = $excelBase64; subjectId = "DBMS" } | ConvertTo-Json) `
        -ContentType "application/json"
    Report-Test "Excel marks preview succeeded" ($previewResp.success -eq $true)

    # Now let's commit marks via CSV to DBMS with specific values:
    # 25QM1A66D6: Internal 35, External 50 (Total 85, PASS)
    # Also include an INVALID record: INVALID_STU_999, Internal 55 (exceeds 40)
    Write-Host "`n--- 4. Scenario 2 & 4: CSV Import with Valid and Invalid Records ---" -ForegroundColor Yellow
    $csvPayload = @"
Subject,Student ID,Internal Marks,External Marks
DBMS,25QM1A66D6,35,50
DBMS,25QM1A66D7,30,42
DBMS,INVALID_STU_999,55,70
"@

    $csvResp = Invoke-RestMethod -Uri "$BaseUrl/api/faculty/validate-table-file" -Method POST `
        -Headers $headers `
        -Body $csvPayload `
        -ContentType "text/plain; charset=UTF-8"

    Report-Test "CSV Import responded successfully" ($csvResp.success -eq $true)
    Report-Test "Valid records written (2 valid)" ($csvResp.validCount -eq 2)
    Report-Test "Invalid records rejected (1 rejected)" ($csvResp.rejectedCount -ge 1)

    # 5. Scenario 4: Export as CSV and verify contents
    Write-Host "`n--- 5. Verify CSV Export ---" -ForegroundColor Yellow
    $csvExportResp = Invoke-WebRequest -Uri "$BaseUrl/api/faculty/export-academic-records?format=csv&subjectId=DBMS" `
        -Headers $headers -Method GET -UseBasicParsing

    Report-Test "CSV Export returned HTTP 200" ($csvExportResp.StatusCode -eq 200)
    Report-Test "Content-Type is text/csv" ($csvExportResp.Headers["Content-Type"] -like "*text/csv*")
    Report-Test "Content-Disposition has attachment" ($csvExportResp.Headers["Content-Disposition"] -like "*attachment*")

    $csvContent = "$($csvExportResp.Content)"
    Report-Test "Exported CSV contains student 25QM1A66D6" ($csvContent -match "25QM1A66D6")
    Report-Test "Exported CSV contains internal marks 35" ($csvContent -match ",35,")
    Report-Test "Exported CSV contains external marks 50" ($csvContent -match ",50,")
    Report-Test "Exported CSV contains total marks 85" ($csvContent -match ",85,")
    Report-Test "Exported CSV contains PASS status" ($csvContent -match "PASS")

    # Scenario 5: Confirm invalid records NOT included
    Report-Test "Invalid record INVALID_STU_999 is NOT in exported CSV" (-not ($csvContent -match "INVALID_STU_999"))

    # Parse CSV with Import-Csv
    $tempCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) ("test_export_" + [Guid]::NewGuid().ToString() + ".csv")
    [System.IO.File]::WriteAllText($tempCsvPath, $csvContent, [System.Text.Encoding]::UTF8)
    $parsedCsv = Import-Csv $tempCsvPath
    Remove-Item $tempCsvPath -Force -ErrorAction SilentlyContinue

    $d6Row = $parsedCsv | Where-Object { $_.student_id -eq "25QM1A66D6" -and $_.subject_id -eq "DBMS" }
    Report-Test "25QM1A66D6 row parsed cleanly" ($null -ne $d6Row)
    Report-Test "25QM1A66D6 internal_marks is 35" ($d6Row.internal_marks -eq "35")
    Report-Test "25QM1A66D6 external_marks is 50" ($d6Row.external_marks -eq "50")
    Report-Test "25QM1A66D6 total_marks is 85" ($d6Row.total_marks -eq "85")
    Report-Test "25QM1A66D6 result_status is PASS" ($d6Row.result_status -eq "PASS")

    # Scenario 6: Confirm no duplicates for 25QM1A66D6 in DBMS
    $d6Count = @($parsedCsv | Where-Object { $_.student_id -eq "25QM1A66D6" -and $_.subject_id -eq "DBMS" }).Count
    Report-Test "No duplicate records created during export (exactly 1 record)" ($d6Count -eq 1)

    # 6. Scenario 3: Export as Excel and verify contents
    Write-Host "`n--- 6. Verify Excel (.xlsx) Export ---" -ForegroundColor Yellow
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("X-Session-Id", $token)
    $excelBytes = $wc.DownloadData("$BaseUrl/api/faculty/export-academic-records?format=xlsx&subjectId=DBMS")
    $contentDisp = $wc.ResponseHeaders["Content-Disposition"]
    $contentType = $wc.ResponseHeaders["Content-Type"]

    Report-Test "Excel Export returned valid bytes" ($excelBytes.Length -gt 1000)
    Report-Test "Content-Type is OpenXML spreadsheet" ($contentType -like "*spreadsheetml*")
    Report-Test "Content-Disposition has attachment with .xlsx filename" ($contentDisp -like "*academic_records_DBMS.xlsx*")

    # Inspect the zip structure of the exported .xlsx
    $tempXlsxPath = Join-Path ([System.IO.Path]::GetTempPath()) ("test_export_" + [Guid]::NewGuid().ToString() + ".xlsx")
    [System.IO.File]::WriteAllBytes($tempXlsxPath, $excelBytes)

    $zip = [System.IO.Compression.ZipFile]::OpenRead($tempXlsxPath)
    $hasWorkbook = ($null -ne $zip.GetEntry("xl/workbook.xml"))
    $hasSheet = ($null -ne $zip.GetEntry("xl/worksheets/sheet1.xml"))
    Report-Test "Exported .xlsx has valid OpenXML workbook" $hasWorkbook
    Report-Test "Exported .xlsx has sheet1.xml" $hasSheet

    # Read sheet1.xml
    $sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
    $sheetStream = $sheetEntry.Open()
    $sheetReader = New-Object System.IO.StreamReader($sheetStream)
    $sheetXml = $sheetReader.ReadToEnd()
    $sheetStream.Close()
    $zip.Dispose()
    Remove-Item $tempXlsxPath -Force -ErrorAction SilentlyContinue

    Report-Test "Excel sheet contains Student ID 25QM1A66D6" ($sheetXml -match "25QM1A66D6")
    Report-Test "Excel sheet contains internal mark 35" ($sheetXml -match "<v>35</v>")
    Report-Test "Excel sheet contains external mark 50" ($sheetXml -match "<v>50</v>")
    Report-Test "Excel sheet contains total mark 85" ($sheetXml -match "<v>85</v>")
    Report-Test "Excel sheet contains result status PASS" ($sheetXml -match "PASS")
    Report-Test "Excel sheet does NOT contain INVALID_STU_999" (-not ($sheetXml -match "INVALID_STU_999"))

    # 7. Scenario 7: Confirm all existing application features still work
    Write-Host "`n--- 7. Existing Application Features Verification ---" -ForegroundColor Yellow
    # Faculty dashboard stats
    $stats = Invoke-RestMethod -Uri "$BaseUrl/api/faculty/dashboard-stats" -Headers $headers -Method GET
    Report-Test "Faculty dashboard stats endpoint works" ($stats.success -eq $true)
    Report-Test "Dashboard reports registered students count" ($stats.metrics.totalStudents -gt 0)

    # Assigned subjects endpoint
    $assigned = Invoke-RestMethod -Uri "$BaseUrl/api/faculty/assigned-subjects" -Headers $headers -Method GET
    Report-Test "Faculty assigned subjects endpoint works" ($assigned.success -eq $true -and $assigned.subjects.Count -gt 0)

    # AI Analysis endpoint
    $ai = Invoke-RestMethod -Uri "$BaseUrl/api/faculty/ai-analysis" -Headers $headers -Method GET
    Report-Test "AI Analysis endpoint works" ($ai.success -eq $true)

    # Table files on disk
    $marksCsvPath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\export\marks.csv"
    if (Test-Path $marksCsvPath) {
        $diskMarks = Get-Content $marksCsvPath
        Report-Test "data/export/marks.csv is preserved on disk" ($diskMarks.Count -gt 1)
        Report-Test "data/export/marks.csv contains 25QM1A66D6" ($diskMarks -match "25QM1A66D6")
    }

    # Student login works
    $stuLogin = Invoke-RestMethod -Uri "$BaseUrl/api/auth/student-login" -Method POST `
        -Body (@{ studentId = "25QM1A66D6" } | ConvertTo-Json) `
        -ContentType "application/json"
    Report-Test "Student login works" ($stuLogin.success -eq $true)

} catch {
    Write-Host "Unexpected exception during test: $_" -ForegroundColor Red
    $script:failed++
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Test Summary: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 } else { exit 0 }
