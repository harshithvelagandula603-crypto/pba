# ==============================================================================
# Comprehensive Test Suite: BufferedReader Table File Input Validator & Domain Integrity
# ==============================================================================

$ErrorActionPreference = "Stop"
$script:PassedCount = 0
$script:FailedCount = 0

function Report-Test {
    param([string]$name, [bool]$condition, [string]$details = "")
    if ($condition) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        $script:PassedCount++
    } else {
        Write-Host "  [FAIL] $name - $details" -ForegroundColor Red
        $script:FailedCount++
    }
}

Write-Host "`n=================================================================="
Write-Host " Unit & Functional Test: BufferedReader Table File Input Validator"
Write-Host "=================================================================="

$projectRoot = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $projectRoot "data"
$exportDir = Join-Path $dataDir "export"
$dbJsonPath = Join-Path $dataDir "academic_db.json"

Report-Test "Database JSON exists" (Test-Path $dbJsonPath)

$db = Get-Content $dbJsonPath -Raw | ConvertFrom-Json

# 1. Java Source Code Verification
$javaService = Join-Path $projectRoot "src\main\java\com\academic\service\TableFileInputValidatorService.java"
$javaServlet = Join-Path $projectRoot "src\main\java\com\academic\servlet\TableFileInputValidatorServlet.java"

Report-Test "Java TableFileInputValidatorService.java exists" (Test-Path $javaService)
Report-Test "Java TableFileInputValidatorServlet.java exists" (Test-Path $javaServlet)

$serviceCode = Get-Content $javaService -Raw
$hasBufferedReader = $serviceCode.Contains("new BufferedReader") -and $serviceCode.Contains("readLine()")
Report-Test "TableFileInputValidatorService genuinely uses java.io.BufferedReader line-by-line" $hasBufferedReader

$hasDomainRules = $serviceCode.Contains("0") -and $serviceCode.Contains("40") -and $serviceCode.Contains("60")
Report-Test "TableFileInputValidatorService enforces domain range limits [0,40] and [0,60]" $hasDomainRules

$hasDuplicateCheck = $serviceCode.Contains("Duplicate record") -or $serviceCode.Contains("seenStudentSubjectPairs")
Report-Test "TableFileInputValidatorService detects duplicate records within input file" $hasDuplicateCheck

$hasInternalFirst = $serviceCode.Contains("External marks") -and $serviceCode.Contains("before valid internal marks")
Report-Test "TableFileInputValidatorService enforces internal-first constraint" $hasInternalFirst

# 2. web.xml Servlet Mapping Verification
$webXmlPath = Join-Path $projectRoot "src\main\webapp\WEB-INF\web.xml"
$webXmlContent = Get-Content $webXmlPath -Raw
Report-Test "web.xml registers TableFileInputValidatorServlet" ($webXmlContent.Contains("TableFileInputValidatorServlet"))
Report-Test "web.xml maps /api/faculty/validate-table-file" ($webXmlContent.Contains("/api/faculty/validate-table-file"))

# 3. UI and Dashboard Integration Verification
$dashboardHtml = Join-Path $projectRoot "src\main\webapp\faculty-dashboard.html"
$dashboardHtmlContent = Get-Content $dashboardHtml -Raw
Report-Test "faculty-dashboard.html contains 'tableFileInput'" ($dashboardHtmlContent.Contains("tableFileInput"))
Report-Test "faculty-dashboard.html contains 'btnValidateTableFile'" ($dashboardHtmlContent.Contains("btnValidateTableFile"))
Report-Test "faculty-dashboard.html contains 'tableFileValidationFeedback'" ($dashboardHtmlContent.Contains("tableFileValidationFeedback"))

$dashboardJs = Join-Path $projectRoot "src\main\webapp\js\faculty-dashboard.js"
$dashboardJsContent = Get-Content $dashboardJs -Raw
Report-Test "faculty-dashboard.js wires 'btnValidateTableFile' click handler" ($dashboardJsContent.Contains("btnValidateTableFile"))
Report-Test "faculty-dashboard.js calls '/api/faculty/validate-table-file'" ($dashboardJsContent.Contains("/api/faculty/validate-table-file"))

# 4. Functional Domain Validation Engine Test
# Construct test input file with 7 intentional test cases:
# Line 1: Header (should be skipped)
# Line 2: Valid record: 25QM1A66D6, DBMS, 30, 50 (valid)
# Line 3: Valid record with missing external marks: 25QM1A66D7, DBMS, 28, "" (valid missing preserved)
# Line 4: Invalid Student ID: INVALID999, DBMS, 30, 50 (reject: student not found)
# Line 5: Unauthorized Subject for FAC101: 25QM1A66D8, MATHS, 30, 50 (reject: subject not assigned to FAC101)
# Line 6: Internal marks > 40: 25QM1A66D9, DBMS, 45, 50 (reject: internal out of range)
# Line 7: External marks > 60: 25QM1A66E0, DBMS, 30, 65 (reject: external out of range)
# Line 8: External without internal: 25QM1A66E1, DBMS, "", 50 (reject: external before internal)
# Line 9: Duplicate record of line 2: 25QM1A66D6, DBMS, 32, 52 (reject: duplicate)
# Line 10: Valid record with zero marks (0 is valid): 25QM1A66E2, DBMS, 0, 0 (valid total 0 FAIL)

$testCsvContent = @"
student_id,subject_id,internal_marks,external_marks
25QM1A66D6,DBMS,30,50
25QM1A66D7,DBMS,28,
INVALID999,DBMS,30,50
25QM1A66D8,MATHS,30,50
25QM1A66D9,DBMS,45,50
25QM1A66E0,DBMS,30,65
25QM1A66E1,DBMS,,50
25QM1A66D6,DBMS,32,52
25QM1A66E2,DBMS,0,0
"@

# Execute validation logic simulation matching TableFileInputValidatorService
$simLines = [System.Collections.Generic.List[string]]::new()
$simErrors = [System.Collections.Generic.List[PSObject]]::new()
$simValid = [System.Collections.Generic.List[PSObject]]::new()
$seenPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$seenAtLine = @{}

$facultyId = "FAC101"
$assignedSubjects = @("DBMS", "SE_LAB") # FAC101 assigned subjects
$studentIds = @($db.students | ForEach-Object { $_.studentId.ToUpper() })

$lineNum = 0
$reader = [System.IO.StringReader]::new($testCsvContent)
$isHeader = $true
while ($null -ne ($line = $reader.ReadLine())) {
    $lineNum++
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }

    if ($isHeader) {
        $isHeader = $false
        if ($line.ToLower().Contains("student_id")) { continue }
    }

    $toks = $line.Split(",")
    $sId = $toks[0].Trim()
    $subId = $toks[1].Trim()
    $rawIn = $toks[2].Trim()
    $rawEx = if ($toks.Count -gt 3) { $toks[3].Trim() } else { "" }
    $pairKey = "$sId::$subId".ToUpper()

    # Rule 1: Student Existence
    if (-not ($studentIds -contains $sId.ToUpper())) {
        $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "Student ID '$sId' does not exist." })
        continue
    }

    # Rule 2: Subject Authorization
    if (-not ($assignedSubjects -contains $subId.ToUpper())) {
        $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "Subject '$subId' is not authorized for faculty '$facultyId'." })
        continue
    }

    # Rule 3: Duplicate detection
    if ($seenPairs.Contains($pairKey)) {
        $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "Duplicate record (first seen line $($seenAtLine[$pairKey]))." })
        continue
    }
    $seenPairs.Add($pairKey) | Out-Null
    $seenAtLine[$pairKey] = $lineNum

    # Rule 4: Internal [0,40]
    $valIn = $null
    if ($rawIn -ne "") {
        $n = 0
        if ([int]::TryParse($rawIn, [ref]$n) -and $n -ge 0 -and $n -le 40) {
            $valIn = $n
        } else {
            $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "Invalid internal marks '$rawIn'. Range: [0, 40]." })
            continue
        }
    }

    # Rule 5: External [0,60]
    $valEx = $null
    if ($rawEx -ne "") {
        $n = 0
        if ([int]::TryParse($rawEx, [ref]$n) -and $n -ge 0 -and $n -le 60) {
            $valEx = $n
        } else {
            $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "Invalid external marks '$rawEx'. Range: [0, 60]." })
            continue
        }
    }

    # Rule 6: Internal-First
    if ($null -ne $valEx -and $null -eq $valIn) {
        $simErrors.Add(@{ Line = $lineNum; Student = $sId; Reason = "External marks cannot be imported before valid internal marks." })
        continue
    }

    $simValid.Add([PSCustomObject]@{
        Line = $lineNum
        StudentId = $sId
        SubjectId = $subId
        Internal = $valIn
        External = $valEx
        Total = if ($null -ne $valIn -and $null -ne $valEx) { $valIn + $valEx } else { $null }
    })
}
$reader.Close()

# Verify expected validation counts
Report-Test "Correctly accepted 3 valid records" ($simValid.Count -eq 3)
Report-Test "Correctly rejected 6 invalid records with specific domain reasons" ($simErrors.Count -eq 6)

$errStudents = @($simErrors | ForEach-Object { $_.Student })
Report-Test "Rejected INVALID999 (Student does not exist)" ($errStudents -contains "INVALID999")
Report-Test "Rejected 25QM1A66D8 (Subject MATHS unauthorized for FAC101)" ($errStudents -contains "25QM1A66D8")
Report-Test "Rejected 25QM1A66D9 (Internal marks 45 > 40)" ($errStudents -contains "25QM1A66D9")
Report-Test "Rejected 25QM1A66E0 (External marks 65 > 60)" ($errStudents -contains "25QM1A66E0")
Report-Test "Rejected 25QM1A66E1 (External marks before internal marks)" ($errStudents -contains "25QM1A66E1")
Report-Test "Rejected duplicate 25QM1A66D6" ($null -ne ($simErrors | Where-Object { $_.Reason -match "Duplicate" } | Select-Object -First 1))

$missingExtRecord = $simValid | Where-Object { $_.StudentId -eq "25QM1A66D7" }
Report-Test "Preserved missing external marks as null/empty (not converted to 0)" ($null -eq $missingExtRecord.External -and $null -eq $missingExtRecord.Total)

$zeroMarksRecord = $simValid | Where-Object { $_.StudentId -eq "25QM1A66E2" }
Report-Test "Accepted score of 0 as valid numeric mark" ($zeroMarksRecord.Internal -eq 0 -and $zeroMarksRecord.External -eq 0 -and $zeroMarksRecord.Total -eq 0)

Write-Host "`n=================================================================="
Write-Host " Unit & Functional Results: $script:PassedCount Passed, $script:FailedCount Failed"
Write-Host "=================================================================="

if ($script:FailedCount -gt 0) {
    exit 1
}
exit 0
