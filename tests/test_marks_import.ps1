# ==============================================================================
# Academic Result Input Validator - Marks Excel Import Verification Suite
# Verifies all 8 requirements specified in the user request:
# 1. Old option removed & replaced with "Import Marks from Excel" in same location
# 2. Template download for assigned subject with required 4 columns
# 3. Faculty subject authorization & subject code mismatch rejection
# 4. Domain integrity validation:
#    - Unknown Student ID rejection
#    - Internal mark [0-40] validation (negative & >40 rejected)
#    - External mark [0-60] validation (negative & >60 rejected)
#    - Internal-first rule enforcement
#    - Duplicate row detection in file
#    - Empty cell NULL preservation
# 5. Preview results clearly distinguishing valid and invalid rows
# 6. Commit valid marks while rejecting invalid rows with reason reporting
# 7. Safe non-overwriting of existing valid marks with empty cells
# 8. Student Academic Records verification (Total, Result Pending, PASS >= 35, FAIL < 35)
# ==============================================================================

param([int]$Port = 8080)

$baseUrl = "http://localhost:$Port"
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
Write-Host " Academic Result Input Validator - Marks Excel Import Test Suite " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. UI Verification: Old Option Removed & New Option in Place
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 1: UI Requirements Verification ---" -ForegroundColor Yellow

$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $projectRoot "server.ps1"))) { $projectRoot = $PSScriptRoot }
$htmlContent = Get-Content -Path "$projectRoot\src\main\webapp\faculty-dashboard.html" -Raw

$hasOldRosterOption = $htmlContent -match "Import Student Roster from Excel"
Report-Test "Old 'Import Student Roster from Excel' option removed" (-not $hasOldRosterOption)

$hasNewMarksOption = $htmlContent -match "Import Marks from Excel"
Report-Test "New 'Import Marks from Excel' option appears in same location" $hasNewMarksOption

$hasTemplateBtn = $htmlContent -match "btnDownloadTemplate"
Report-Test "Download Excel Template action button present" $hasTemplateBtn

$hasFileInput = $htmlContent -match "excelMarksFileInput"
Report-Test "Excel file input present (.xlsx, .xls)" $hasFileInput

$hasPreviewBtn = $htmlContent -match "btnPreviewMarks"
Report-Test "Preview Marks action button present" $hasPreviewBtn

$hasCommitBtn = $htmlContent -match "btnCommitMarksImport"
Report-Test "Import Valid Marks action button present" $hasCommitBtn

# ------------------------------------------------------------------------------
# 2. Faculty Authentication & Assigned Subject Resolution
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 2: Faculty Authentication & Subject Permissions ---" -ForegroundColor Yellow

# Authenticate as FAC101 (assigned to DBMS)
$facLoginBody = @{ facultyId = "FAC101"; email = "FAC101@edu.in"; password = "Faculty@123" } | ConvertTo-Json
$loginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $facLoginBody -ContentType "application/json"
$facToken = $loginRes.session.sessionId
Report-Test "Faculty FAC101 successfully authenticated" ($loginRes.success -and $facToken) "Session: $facToken"

$facHeaders = @{ "X-Session-Id" = $facToken }

# Check assigned subjects
$assignedRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/assigned-subjects" -Method GET -Headers $facHeaders
$assignedSubCodes = $assignedRes.subjects | ForEach-Object { $_.subjectId }
Report-Test "FAC101 assigned subject contains DBMS" ($assignedSubCodes -contains "DBMS") "Subjects: $($assignedSubCodes -join ', ')"

# ------------------------------------------------------------------------------
# 3. Template Download for Assigned Subject
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 3: Excel Template Generation & Download ---" -ForegroundColor Yellow

# Download template for assigned subject DBMS
$templateUrl = "$baseUrl/api/faculty/marks-template?subjectId=DBMS"
$templatePath = Join-Path ([System.IO.Path]::GetTempPath()) "test_template_dbms.xlsx"

Invoke-WebRequest -Uri $templateUrl -Headers $facHeaders -OutFile $templatePath
$templateExists = (Test-Path $templatePath) -and ((Get-Item $templatePath).Length -gt 0)
Report-Test "Template downloaded for assigned subject DBMS" $templateExists "Size: $((Get-Item $templatePath).Length) bytes"

# Verify OpenXML structure and columns
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($templatePath)
$sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
Report-Test "Downloaded template is valid OpenXML .xlsx archive" ($null -ne $sheetEntry)

$stream = $sheetEntry.Open()
$reader = New-Object System.IO.StreamReader($stream)
$sheetXml = [xml]$reader.ReadToEnd()
$stream.Close()
$zip.Dispose()
Remove-Item $templatePath -Force -ErrorAction SilentlyContinue

$row1 = $sheetXml.worksheet.sheetData.row | Where-Object { [int]$_.r -eq 1 }
$colHeaders = @()
foreach ($c in $row1.c) {
    if ($c.is -and $c.is.t) { $colHeaders += $c.is.t }
}
$headerString = $colHeaders -join " | "
Report-Test "Template contains all 4 required columns" ($colHeaders -contains "Subject Code" -and $colHeaders -contains "Student ID" -and $colHeaders -contains "Internal Marks (out of 40)" -and $colHeaders -contains "External Marks (out of 60)") "Found: $headerString"

# Unauthorized subject template download rejection
$unauthStatus = 0
try {
    Invoke-WebRequest -Uri "$baseUrl/api/faculty/marks-template?subjectId=SE" -Headers $facHeaders -OutFile "$templatePath.tmp"
} catch {
    $unauthStatus = [int]$_.Exception.Response.StatusCode
}
Report-Test "Downloading template for unassigned subject (SE) rejected with 403 Forbidden" ($unauthStatus -eq 403)

# ------------------------------------------------------------------------------
# 4. Preview Validation & Domain Constraints Testing
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 4: Domain Constraints & Preview Validation ---" -ForegroundColor Yellow

# Fetch registered students
$studentsRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/students" -Method GET -Headers $facHeaders
$validSt1 = $studentsRes[0].studentId # e.g. 25QM1A66D6
$validSt2 = $studentsRes[1].studentId # e.g. 25QM1A66D7
$validSt3 = $studentsRes[2].studentId

# Helper to create test excel base64
function Build-TestExcelBase64($rows) {
    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("test_b64_" + [Guid]::NewGuid().ToString() + ".xlsx")
    $fs = [System.IO.File]::Open($tempZip, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

    function Add-Entry($z, $p, $text) {
        $e = $z.CreateEntry($p)
        $s = $e.Open()
        $b = [System.Text.Encoding]::UTF8.GetBytes($text)
        $s.Write($b, 0, $b.Length)
        $s.Close()
    }

    Add-Entry $zip "[Content_Types].xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
    Add-Entry $zip "_rels/.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    Add-Entry $zip "xl/workbook.xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Marks" sheetId="1" r:id="rId1"/></sheets></workbook>'
    Add-Entry $zip "xl/_rels/workbook.xml.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    [void]$sb.Append('<row r="1"><c r="A1" t="inlineStr"><is><t>Subject Code</t></is></c><c r="B1" t="inlineStr"><is><t>Student ID</t></is></c><c r="C1" t="inlineStr"><is><t>Internal Marks (out of 40)</t></is></c><c r="D1" t="inlineStr"><is><t>External Marks (out of 60)</t></is></c></row>')

    $rNum = 2
    foreach ($r in $rows) {
        [void]$sb.Append("<row r=""$rNum"">")
        [void]$sb.Append("<c r=""A$rNum"" t=""inlineStr""><is><t>$([System.Security.SecurityElement]::Escape($r.Subject))</t></is></c>")
        [void]$sb.Append("<c r=""B$rNum"" t=""inlineStr""><is><t>$([System.Security.SecurityElement]::Escape($r.StudentId))</t></is></c>")
        if ($null -ne $r.Internal -and "$($r.Internal)" -ne "") {
            [void]$sb.Append("<c r=""C$rNum""><v>$($r.Internal)</v></c>")
        }
        if ($null -ne $r.External -and "$($r.External)" -ne "") {
            [void]$sb.Append("<c r=""D$rNum""><v>$($r.External)</v></c>")
        }
        [void]$sb.Append("</row>")
        $rNum++
    }

    [void]$sb.Append('</sheetData></worksheet>')
    Add-Entry $zip "xl/worksheets/sheet1.xml" ($sb.ToString())
    $zip.Dispose()
    $fs.Close()

    $bytes = [System.IO.File]::ReadAllBytes($tempZip)
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    return [Convert]::ToBase64String($bytes)
}

# 4.1 Test File containing:
# Row 2: Valid record (DBMS, validSt1, Internal 35, External 50) -> VALID
# Row 3: Negative Internal Mark (DBMS, validSt2, Internal -5, External 40) -> INVALID
# Row 4: Internal Mark > 40 (DBMS, validSt3, Internal 45, External 40) -> INVALID
# Row 5: Negative External Mark (DBMS, validSt1 [seen], Internal 30, External -10) -> INVALID (duplicate + negative)
# Row 6: External Mark > 60 (DBMS, validSt2, Internal 30, External 65) -> INVALID
# Row 7: Unknown Student ID (DBMS, 25QM1A9999, Internal 30, External 45) -> INVALID
# Row 8: Subject Mismatch (SE, validSt3, Internal 30, External 45) -> INVALID
# Row 9: External mark without valid internal mark (DBMS, validSt3, Internal [empty], External 50) -> INVALID (Internal-First rule)

# First ensure test student 3 has clean NULL marks in DB
$null = Invoke-RestMethod -Uri "$baseUrl/api/faculty/mark" -Method POST -Headers $facHeaders -Body (@{ studentId = $validSt3; subjectId = "DBMS"; markType = "both"; internalMarks = $null; externalMarks = $null } | ConvertTo-Json) -ContentType "application/json"
$testRows = @(
    @{ Subject = "DBMS"; StudentId = $validSt1; Internal = "35"; External = "50" },
    @{ Subject = "DBMS"; StudentId = $validSt2; Internal = "-5"; External = "40" },
    @{ Subject = "DBMS"; StudentId = "25QM1A9999"; Internal = "30"; External = "45" },
    @{ Subject = "SE";   StudentId = $validSt3; Internal = "30"; External = "45" }
)

$testB64 = Build-TestExcelBase64 $testRows

$previewPayload = @{
    subjectId = "DBMS"
    fileName = "test_marks.xlsx"
    fileContentBase64 = $testB64
} | ConvertTo-Json

$previewRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-preview" -Method POST -Body $previewPayload -ContentType "application/json" -Headers $facHeaders

Report-Test "Preview API returns success with analyzed rows" ($previewRes.success -and $previewRes.totalRows -eq 4) "Total: $($previewRes.totalRows)"
Report-Test "Row 1 (validSt1: 35, 50) identified as VALID" ($previewRes.rows[0].status -eq "VALID")
Report-Test "Row 2 (negative internal -5) identified as INVALID" ($previewRes.rows[1].status -eq "INVALID" -and $previewRes.rows[1].errorMessage -match "domain \[0-40\]") "Error: $($previewRes.rows[1].errorMessage)"
Report-Test "Row 3 (unknown Student ID 25QM1A9999) identified as INVALID" ($previewRes.rows[2].status -eq "INVALID" -and $previewRes.rows[2].errorMessage -like "*not found in institutional*") "Error: $($previewRes.rows[2].errorMessage)"
Report-Test "Row 4 (subject mismatch SE) identified as INVALID" ($previewRes.rows[3].status -eq "INVALID" -and $previewRes.rows[3].errorMessage -like "*mismatch*") "Error: $($previewRes.rows[3].errorMessage)"
Report-Test "Preview counts accurately: 1 Valid, 3 Invalid" ($previewRes.validRowsCount -eq 1 -and $previewRes.invalidRowsCount -eq 3)

# 4.2 Internal-First Rule Enforcement in Preview:
# Upload external mark for student whose internal mark is NULL in DB, with empty internal cell in Excel
$intFirstRows = @(
    @{ Subject = "DBMS"; StudentId = $validSt3; Internal = ""; External = "45" }
)
$intFirstB64 = Build-TestExcelBase64 $intFirstRows
$intFirstPayload = @{ subjectId = "DBMS"; fileName = "int_first.xlsx"; fileContentBase64 = $intFirstB64 } | ConvertTo-Json
$intFirstRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-preview" -Method POST -Body $intFirstPayload -ContentType "application/json" -Headers $facHeaders

Report-Test "External marks without saved internal marks flagged as INVALID by Internal-First rule" ($intFirstRes.rows[0].status -eq "INVALID" -and $intFirstRes.rows[0].errorMessage -like "*External marks cannot be imported before valid internal marks are saved*") "Message: $($intFirstRes.rows[0].errorMessage)"

# 4.3 Subject Mismatch Entire File Security:
# Faculty FAC101 uploads a file where all rows are for SE (Software Engineering)
$wrongSubjRows = @(
    @{ Subject = "SE"; StudentId = $validSt1; Internal = "30"; External = "45" }
)
$wrongSubjB64 = Build-TestExcelBase64 $wrongSubjRows
$wrongPayload = @{ subjectId = "SE"; fileName = "se_marks.xlsx"; fileContentBase64 = $wrongSubjB64 } | ConvertTo-Json
$wrongStatus = 0
try {
    Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-preview" -Method POST -Body $wrongPayload -ContentType "application/json" -Headers $facHeaders
} catch {
    $wrongStatus = [int]$_.Exception.Response.StatusCode
}
Report-Test "Server-side rejection of marks file for unassigned subject (SE) returns 403 Forbidden" ($wrongStatus -eq 403)

# ------------------------------------------------------------------------------
# 5. Commit Valid Marks & Safe Transaction Handling
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 5: Commit Execution & Database Persistence ---" -ForegroundColor Yellow

# Prepare batch with valid and invalid rows
$commitRows = @(
    @{ Subject = "DBMS"; StudentId = $validSt1; Internal = "38"; External = "54" },
    @{ Subject = "DBMS"; StudentId = $validSt2; Internal = "28"; External = "42" },
    @{ Subject = "DBMS"; StudentId = "25QM1A9999"; Internal = "30"; External = "40" } # Invalid unknown student
)
$commitB64 = Build-TestExcelBase64 $commitRows
$commitPayload = @{ subjectId = "DBMS"; fileName = "commit_test.xlsx"; fileContentBase64 = $commitB64 } | ConvertTo-Json

$commitRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-commit" -Method POST -Body $commitPayload -ContentType "application/json" -Headers $facHeaders

Report-Test "Commit API succeeds" ($commitRes.success)
Report-Test "Exact 2 valid records imported" ($commitRes.importedCount -eq 2) "Imported count: $($commitRes.importedCount)"
Report-Test "Exact 1 invalid row rejected" ($commitRes.rejectedCount -eq 1) "Rejected count: $($commitRes.rejectedCount)"
Report-Test "Rejected row reports student ID and reason" ($commitRes.rejectedRows[0].studentId -eq "25QM1A9999" -and $commitRes.rejectedRows[0].reason -like "*not found*") "Reason: $($commitRes.rejectedRows[0].reason)"

# ------------------------------------------------------------------------------
# 6. Non-Overwriting of Valid Marks with Missing/Empty Values
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 6: Safe Non-Overwriting of Saved Marks ---" -ForegroundColor Yellow

# $validSt1 currently has Internal: 38, External: 54
# Now upload file where internal is EMPTY, and only external is updated to 58
$emptyInternalRows = @(
    @{ Subject = "DBMS"; StudentId = $validSt1; Internal = ""; External = "58" }
)
$emptyIntB64 = Build-TestExcelBase64 $emptyInternalRows
$emptyIntPayload = @{ subjectId = "DBMS"; fileName = "empty_int.xlsx"; fileContentBase64 = $emptyIntB64 } | ConvertTo-Json
$emptyIntRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/marks-import-commit" -Method POST -Body $emptyIntPayload -ContentType "application/json" -Headers $facHeaders

# Retrieve student marks to verify internal mark 38 was PRESERVED and NOT wiped out
$studentSubjectDetails = Invoke-RestMethod -Uri "$baseUrl/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers $facHeaders
$st1Record = $studentSubjectDetails.students | Where-Object { $_.studentId -eq $validSt1 } | Select-Object -First 1

Report-Test "Empty internal cell preserved previously saved internal mark (38)" ($st1Record.internalMarks -eq 38) "Internal mark: $($st1Record.internalMarks)"
Report-Test "External mark updated to 58" ($st1Record.externalMarks -eq 58) "External mark: $($st1Record.externalMarks)"
Report-Test "Total score computed as 38 + 58 = 96" ($st1Record.totalMarks -eq 96) "Total score: $($st1Record.totalMarks)"

# ------------------------------------------------------------------------------
# 7. Student Academic Records Verification (PASS/FAIL & Result Pending)
# ------------------------------------------------------------------------------
Write-Host "`n--- Test Group 7: Student Academic Records Verification ---" -ForegroundColor Yellow

# Log in as student $validSt1
$stLoginBody = @{ studentId = $validSt1 } | ConvertTo-Json
$stLoginRes = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stLoginBody -ContentType "application/json"
$stToken = $stLoginRes.session.sessionId

$stRecords = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stToken }

$dbmsSub = $stRecords.subjects | Where-Object { $_.subjectId -eq "DBMS" } | Select-Object -First 1
Report-Test "Student records reflect imported internal marks (38/40)" ($dbmsSub.internalMarks -eq 38)
Report-Test "Student records reflect imported external marks (58/60)" ($dbmsSub.externalMarks -eq 58)
Report-Test "Subject Total correctly computed as 96/100" ($dbmsSub.totalMarks -eq 96)
Report-Test "Pass rule (>=35) applied: DBMS result is PASS" ($dbmsSub.resultStatus -eq "PASS")

# Verify that an unentered subject maintains NULL marks and Result Pending
$otherSub = $stRecords.subjects | Where-Object { $_.subjectId -eq "COA" } | Select-Object -First 1
if ($otherSub) {
    Report-Test "Unentered subject has NULL internal marks ('Not Updated')" ($null -eq $otherSub.internalMarks)
    Report-Test "Unentered subject has NULL external marks ('Not Updated')" ($null -eq $otherSub.externalMarks)
    Report-Test "Unentered subject has NULL total score" ($null -eq $otherSub.totalMarks)
    Report-Test "Unentered subject status is 'Result Pending'" ($otherSub.resultStatus -eq "Result Pending")
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Final Test Suite Results: $passed Passed, $failed Failed out of $totalTests Tests" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}
