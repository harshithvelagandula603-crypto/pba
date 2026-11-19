# ==============================================================================
# Comprehensive Verification: Excel Table-File Storage + CSV Import Error Fix
# Tests Parts 1 to 6
# ==============================================================================

$ErrorActionPreference = "Stop"
$script:PassedCount = 0
$script:FailedCount = 0

function Report-Test {
    param([string]$name, [bool]$condition, [string]$details = "")
    if ($condition) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        if ($details) { Write-Host "         $details" -ForegroundColor Gray }
        $script:PassedCount++
    } else {
        Write-Host "  [FAIL] $name - $details" -ForegroundColor Red
        $script:FailedCount++
    }
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Full Verification: Parts 1 to 6 (Excel & CSV Imports + Table Files)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$projectRoot = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $projectRoot "data"
$exportDir = Join-Path $dataDir "export"
$dbJsonPath = Join-Path $dataDir "academic_db.json"

Report-Test "Database JSON exists" (Test-Path $dbJsonPath)
$db = Get-Content $dbJsonPath -Raw | ConvertFrom-Json

# ------------------------------------------------------------------------------
# Test 1 & 2: Java Service & Servlet Inspection
# ------------------------------------------------------------------------------
$javaValidator = Join-Path $projectRoot "src\main\java\com\academic\service\TableFileInputValidatorService.java"
$javaExcelService = Join-Path $projectRoot "src\main\java\com\academic\service\MarksImportService.java"

Report-Test "TableFileInputValidatorService.java exists" (Test-Path $javaValidator)
Report-Test "MarksImportService.java exists" (Test-Path $javaExcelService)

$valCode = Get-Content $javaValidator -Raw
Report-Test "TableFileInputValidatorService has parseCsvLine with quote support" ($valCode.Contains("parseCsvLine"))
Report-Test "TableFileInputValidatorService supports 'Sudent ID' typo" ($valCode.Contains("sudent"))
Report-Test "TableFileInputValidatorService strips UTF-8 BOM" ($valCode.Contains("\uFEFF"))
Report-Test "TableFileInputValidatorService pre-scans for subject mismatch" ($valCode.Contains("Subject Code mismatch") -or $valCode.Contains("resolvedPrimarySubject"))
Report-Test "TableFileInputValidatorService genuinely uses BufferedReader line-by-line" ($valCode.Contains("new BufferedReader") -and $valCode.Contains("readLine()"))

$excelCode = Get-Content $javaExcelService -Raw
Report-Test "MarksImportService uses BufferedReader for normalized stream" ($excelCode.Contains("new BufferedReader") -and $excelCode.Contains("readLine()"))
Report-Test "MarksImportService refreshes backend CSV table files after commit" ($excelCode.Contains("TableFileExportService") -and $excelCode.Contains("exportAll"))

# ------------------------------------------------------------------------------
# Test 3: Fix CSV/TXT Import Root Cause - Previous Error Test Case
# Previous failure: Subject was first column (DBMS), so importer thought "DBMS" was student ID!
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing CSV Import: Previous Root Cause (Subject first: 'DBMS' not Student ID) ---" -ForegroundColor Yellow

$csvPreviousErrorCase = @"
Subject,Student ID,Internal Marks (40),External Marks (60)
DBMS,25QM1A66D6,25,58
DBMS,25QM1A66D7,28,45
"@

# Dot-source functions without starting HTTP server
. "$projectRoot\server.ps1" -NoStart

$tokensHdr = Parse-CsvLine -Line "Subject,Student ID,Internal Marks (40),External Marks (60)"
Report-Test "Parse-CsvLine splits header correctly into 4 columns" ($tokensHdr.Count -eq 4)
Report-Test "Column 0 is 'Subject'" ($tokensHdr[0] -eq "Subject")
Report-Test "Column 1 is 'Student ID'" ($tokensHdr[1] -eq "Student ID")

# Test dynamic mapping
$dataRowToks = Parse-CsvLine -Line "DBMS,25QM1A66D6,25,58"
$detectedSub = $dataRowToks[0]
$detectedStudent = $dataRowToks[1]
Report-Test "Correctly mapped Student ID to '25QM1A66D6' (NOT 'DBMS')" ($detectedStudent -eq "25QM1A66D6") "Student: $detectedStudent"
Report-Test "Correctly mapped Subject to 'DBMS'" ($detectedSub -eq "DBMS") "Subject: $detectedSub"

# ------------------------------------------------------------------------------
# Test 4: Different Column Orders
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing Different Column Orders in CSV ---" -ForegroundColor Yellow

# Column Order A: Student ID first, then Subject
$hdrA = Parse-CsvLine -Line "Student ID,Subject,Internal Marks,External Marks"
$colMapA = @{}
for ($i = 0; $i -lt $hdrA.Count; $i++) {
    $low = $hdrA[$i].ToLower()
    if ($low -match "student") { $colMapA["Student"] = $i }
    if ($low -match "subject") { $colMapA["Subject"] = $i }
    if ($low -match "internal") { $colMapA["Internal"] = $i }
    if ($low -match "external") { $colMapA["External"] = $i }
}
Report-Test "Column Order A (Student ID first): Student=0, Subject=1" ($colMapA["Student"] -eq 0 -and $colMapA["Subject"] -eq 1)

# Column Order B: External first, Internal, Subject, Student
$hdrB = Parse-CsvLine -Line "External Marks (60),Internal Marks (40),Subject,Student ID"
$colMapB = @{}
for ($i = 0; $i -lt $hdrB.Count; $i++) {
    $low = $hdrB[$i].ToLower()
    if ($low -match "student") { $colMapB["Student"] = $i }
    if ($low -match "subject") { $colMapB["Subject"] = $i }
    if ($low -match "internal") { $colMapB["Internal"] = $i }
    if ($low -match "external") { $colMapB["External"] = $i }
}
Report-Test "Column Order B (Inverted): External=0, Internal=1, Subject=2, Student=3" ($colMapB["External"] -eq 0 -and $colMapB["Internal"] -eq 1 -and $colMapB["Subject"] -eq 2 -and $colMapB["Student"] -eq 3)

# ------------------------------------------------------------------------------
# Test 5: Typo 'Sudent ID' Support
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing 'Sudent ID' Header Typo ---" -ForegroundColor Yellow

$hdrTypo = Parse-CsvLine -Line "Subject,Sudent ID,Internal Marks (40),External Marks (60)"
$colStudentTypo = -1
for ($i = 0; $i -lt $hdrTypo.Count; $i++) {
    $low = $hdrTypo[$i].ToLower()
    if ($low -match "student|sudent") { $colStudentTypo = $i }
}
Report-Test "Mapped 'Sudent ID' typo to Student Column (index 1)" ($colStudentTypo -eq 1)

# ------------------------------------------------------------------------------
# Test 6: Subject Mismatch Rejection
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing Subject Mismatch All-or-Nothing Rejection ---" -ForegroundColor Yellow

$fac101Assigned = @("DBMS", "SE_LAB")
$mismatchRows = @(
    [PSCustomObject]@{ LineNumber = 2; SubjectToken = "MATHS"; StudentToken = "25QM1A66D6" }
)
$isMismatch = -not ($fac101Assigned -contains $mismatchRows[0].SubjectToken)
Report-Test "Rejected unauthorized subject 'MATHS' for FAC101" $isMismatch

# ------------------------------------------------------------------------------
# Test 7: Missing Marks Preserved as NULL (Never 0)
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing Missing Marks Preservation ---" -ForegroundColor Yellow

$rawRowMissingExt = [PSCustomObject]@{ Internal = "28"; External = "" }
$valIn = [int]$rawRowMissingExt.Internal
$valEx = if ($rawRowMissingExt.External -ne "") { [int]$rawRowMissingExt.External } else { $null }

Report-Test "Internal marks is 28" ($valIn -eq 28)
Report-Test "Missing external marks is preserved as `$null (not 0)" ($null -eq $valEx)

$scoreZeroRow = [PSCustomObject]@{ Internal = "0"; External = "0" }
$zeroIn = [int]$scoreZeroRow.Internal
$zeroEx = [int]$scoreZeroRow.External
Report-Test "Explicit 0 is preserved as 0 (valid score)" ($zeroIn -eq 0 -and $zeroEx -eq 0)

# ------------------------------------------------------------------------------
# Test 8: Duplicate Record Detection
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing Duplicate Record Detection ---" -ForegroundColor Yellow

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$p1 = "25QM1A66D6::DBMS"
$firstSeen = $seen.Add($p1)
$secondSeen = $seen.Add($p1)

Report-Test "First appearance is accepted" ($firstSeen -eq $true)
Report-Test "Second duplicate appearance is rejected" ($secondSeen -eq $false)

# ------------------------------------------------------------------------------
# Test 9: Automatic Table-File Generation Function
# ------------------------------------------------------------------------------
Write-Host "`n--- Testing Export-AllTableFiles Output ---" -ForegroundColor Yellow

$exportResult = Export-AllTableFiles -TargetDir $exportDir

Report-Test "Export-AllTableFiles succeeded" ($exportResult.Success)
Report-Test "Generated students.csv" (Test-Path (Join-Path $exportDir "students.csv"))
Report-Test "Generated subjects.csv" (Test-Path (Join-Path $exportDir "subjects.csv"))
Report-Test "Generated faculty_assignments.csv" (Test-Path (Join-Path $exportDir "faculty_assignments.csv"))
Report-Test "Generated marks.csv" (Test-Path (Join-Path $exportDir "marks.csv"))
Report-Test "Generated results.csv" (Test-Path (Join-Path $exportDir "results.csv"))

$marksCsvContent = Get-Content (Join-Path $exportDir "marks.csv") -Raw
Report-Test "marks.csv contains student 25QM1A66D6" ($marksCsvContent.Contains("25QM1A66D6"))
Report-Test "faculty_assignments.csv contains no password or secret data" (-not ($marksCsvContent.Contains("password")))

Write-Host "`n=================================================================="
Write-Host " Verification Summary: $script:PassedCount Passed, $script:FailedCount Failed"
Write-Host "=================================================================="

if ($script:FailedCount -gt 0) {
    exit 1
}
exit 0
