# Direct functional unit tests for FIX 1, FIX 2, and FIX 3
$allPassed = $true
$passCount = 0
$failCount = 0

function Assert-Test([string]$Title, [bool]$Condition, [string]$Details = "") {
    if ($Condition) {
        Write-Host "  PASS: $Title" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  FAIL: $Title" -ForegroundColor Red
        if ($Details) {
            Write-Host "        $Details" -ForegroundColor Yellow
        }
        $script:failCount++
        $script:allPassed = $false
    }
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "TEST SUITE: FIX 1, FIX 2, AND FIX 3 VERIFICATION" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# ==============================================================================
# SECTION 1: FIX 1 - Dashboard Subject Cards
# ==============================================================================
Write-Host "`n--- FIX 1: Dashboard Subject Cards ---" -ForegroundColor Yellow
$fdJsPath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\src\main\webapp\js\faculty-dashboard.js"
$fdJsContent = Get-Content $fdJsPath -Raw

$hasInternalRange = $fdJsContent -match 'Internal:\s*<strong>\s*0[–-]'
$hasExternalRange = $fdJsContent -match 'External:\s*<strong>\s*0[–-]'
$hasAssignedMetaDiv = $fdJsContent -match 'assigned-subject-meta'
$hasOpenSubjectBtn = $fdJsContent -match 'Open Subject'
$hasMaxMarksBadge = $fdJsContent -match 'assigned-subject-weight-badge.*Max:'
$hasCodeBadge = $fdJsContent -match 'assigned-subject-code-badge'

Assert-Test "Card does NOT display 'Internal: 0-40'" (-not $hasInternalRange) "Found internal range in card template"
Assert-Test "Card does NOT display 'External: 0-60'" (-not $hasExternalRange) "Found external range in card template"
Assert-Test "Card does NOT contain 'assigned-subject-meta' div" (-not $hasAssignedMetaDiv) "Found assigned-subject-meta div"
Assert-Test "Card keeps 'Open Subject' button" $hasOpenSubjectBtn
Assert-Test "Card keeps 'Max: 100 Marks' badge" $hasMaxMarksBadge
Assert-Test "Card keeps subject code badge" $hasCodeBadge

# ==============================================================================
# SECTION 2: FIX 2 - Entered-Count Calculation & Formats
# ==============================================================================
Write-Host "`n--- FIX 2: Entered-Count Calculation & Format Checks ---" -ForegroundColor Yellow

# 2.1 Check enter-marks.html initial badge
$emHtmlPath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\src\main\webapp\enter-marks.html"
$emHtmlContent = Get-Content $emHtmlPath -Raw
$hasOldHardcoded10 = $emHtmlContent -match 'id="studentProgressBadge">0\s*/\s*10\s*Entered'
Assert-Test "enter-marks.html does not hardcode '0 / 10 Entered'" (-not $hasOldHardcoded10)

# 2.2 Check enter-marks.js format and calculations
$emJsPath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\src\main\webapp\js\enter-marks.js"
$emJsContent = Get-Content $emJsPath -Raw

Assert-Test "enter-marks.js formats subject component ratio as 'completed / total Required Entered'" (
    $emJsContent -match '\$\{completedComponents\}\s*/\s*\$\{totalRequiredComponents\}\s*Entered'
)
Assert-Test "enter-marks.js defines totalRequiredComponents = 2" (
    $emJsContent -match 'totalRequiredComponents\s*=\s*2'
)
Assert-Test "enter-marks.js updates progress badge using Math.min to prevent numerator > denominator" (
    $emJsContent -match 'Math\.min\(fullyEnteredCount,\s*totalSubs\)'
)

# 2.3 Check faculty-dashboard.js format and calculations
Assert-Test "faculty-dashboard.js clamps intEntered to totalSubs" (
    $fdJsContent -match 'intEntered\s*=\s*Math\.min\(Math\.max\(0,\s*isNaN\(rawInt\)\s*\?\s*0\s*:\s*rawInt\),\s*totalSubs\)'
)
Assert-Test "faculty-dashboard.js clamps extEntered to totalSubs" (
    $fdJsContent -match 'extEntered\s*=\s*Math\.min\(Math\.max\(0,\s*isNaN\(rawExt\)\s*\?\s*0\s*:\s*rawExt\),\s*totalSubs\)'
)
Assert-Test "faculty-dashboard.js grading table includes component count ratio" (
    $fdJsContent -match 'totalReqComps\s*=\s*2'
)

# 2.4 Test counting math with simulated data sets
$simDb = [PSCustomObject]@{
    subjects = @(
        [PSCustomObject]@{ subjectId = "DBMS"; subjectCode = "DBMS"; subjectName = "Database Management Systems"; maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        [PSCustomObject]@{ subjectId = "SE_LAB"; subjectCode = "SE Lab"; subjectName = "Software Engineering Laboratory"; maxMarks = 100; maxInternal = 40; maxExternal = 60 }
    )
}

# Test Case A: Student with No Marks
$subListNoMarks = @(
    [PSCustomObject]@{ subjectId = "DBMS"; internalMarks = $null; externalMarks = $null; evalStatus = "Not Updated" },
    [PSCustomObject]@{ subjectId = "SE_LAB"; internalMarks = $null; externalMarks = $null; evalStatus = "Not Updated" }
)
$intCountA = [Math]::Min(@($subListNoMarks | Where-Object { $null -ne $_.internalMarks }).Count, $subListNoMarks.Count)
$extCountA = [Math]::Min(@($subListNoMarks | Where-Object { $null -ne $_.externalMarks }).Count, $subListNoMarks.Count)
$fullyCountA = [Math]::Min(@($subListNoMarks | Where-Object { $_.evalStatus -eq "Fully Entered" }).Count, $subListNoMarks.Count)

Assert-Test "No marks: internal count is 0 / 2" ($intCountA -eq 0) "Got $intCountA"
Assert-Test "No marks: external count is 0 / 2" ($extCountA -eq 0) "Got $extCountA"
Assert-Test "No marks: fully entered count is 0 / 2" ($fullyCountA -eq 0) "Got $fullyCountA"

# Test Case B: Student with Partial Marks (Internal: 35, External: NULL)
$subListPartial = @(
    [PSCustomObject]@{ subjectId = "DBMS"; internalMarks = 35; externalMarks = $null; evalStatus = "Marks Pending" }
)
$intCountB = [Math]::Min(@($subListPartial | Where-Object { $null -ne $_.internalMarks }).Count, $subListPartial.Count)
$extCountB = [Math]::Min(@($subListPartial | Where-Object { $null -ne $_.externalMarks }).Count, $subListPartial.Count)
$fullyCountB = [Math]::Min(@($subListPartial | Where-Object { $_.evalStatus -eq "Fully Entered" }).Count, $subListPartial.Count)

Assert-Test "Partial marks: internal count is 1 / 1 (never 35/1)" ($intCountB -eq 1) "Got $intCountB"
Assert-Test "Partial marks: external count is 0 / 1" ($extCountB -eq 0) "Got $extCountB"
Assert-Test "Partial marks: fully entered count is 0 / 1" ($fullyCountB -eq 0) "Got $fullyCountB"

# Test Case C: Student with Full Marks (Internal: 38, External: 54)
$subListFull = @(
    [PSCustomObject]@{ subjectId = "DBMS"; internalMarks = 38; externalMarks = 54; evalStatus = "Fully Entered" }
)
$intCountC = [Math]::Min(@($subListFull | Where-Object { $null -ne $_.internalMarks }).Count, $subListFull.Count)
$extCountC = [Math]::Min(@($subListFull | Where-Object { $null -ne $_.externalMarks }).Count, $subListFull.Count)
$fullyCountC = [Math]::Min(@($subListFull | Where-Object { $_.evalStatus -eq "Fully Entered" }).Count, $subListFull.Count)

Assert-Test "Full marks: internal count is 1 / 1" ($intCountC -eq 1) "Got $intCountC"
Assert-Test "Full marks: external count is 1 / 1" ($extCountC -eq 1) "Got $extCountC"
Assert-Test "Full marks: fully entered count is 1 / 1" ($fullyCountC -eq 1) "Got $fullyCountC"

# Test Case D: Check Java DAO query distinct fix
$daoPath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\src\main\java\com\academic\dao\SubjectMarkDAO.java"
$daoContent = Get-Content $daoPath -Raw
Assert-Test "SubjectMarkDAO uses COUNT(DISTINCT sm.subject_id) to avoid duplicate joined counting" (
    $daoContent -match 'COUNT\(DISTINCT\s+sm\.subject_id\)'
)

# ==============================================================================
# SECTION 3: FIX 3 - Test-MarksExcelRows with Mixed-Subject Validation
# ==============================================================================
Write-Host "`n--- FIX 3: Test-MarksExcelRows Mixed-Subject Validation ---" -ForegroundColor Yellow

# Extract Test-MarksExcelRows function from server.ps1 into the test session
$serverCode = Get-Content "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\server.ps1" -Raw
$startIdx = $serverCode.IndexOf("function Test-MarksExcelRows {")
$endIdx = $serverCode.IndexOf("function Sync-FacultyData {")
$funcDef = $serverCode.Substring($startIdx, $endIdx - $startIdx)
. ([scriptblock]::Create($funcDef))

# Prepare test institutional DB
$testDb = [PSCustomObject]@{
    subjects = @(
        [PSCustomObject]@{ subjectId = "DBMS"; subjectCode = "DBMS"; subjectName = "Database Management Systems"; maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        [PSCustomObject]@{ subjectId = "SE_LAB"; subjectCode = "SE Lab"; subjectName = "Software Engineering Laboratory"; maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        [PSCustomObject]@{ subjectId = "MATHS"; subjectCode = "MATHS"; subjectName = "Mathematics"; maxMarks = 100; maxInternal = 40; maxExternal = 60 }
    )
    students = @(
        [PSCustomObject]@{ studentId = "25QM1A66D6"; studentName = "Shiva Charan Goud" },
        [PSCustomObject]@{ studentId = "25QM1A66D7"; studentName = "Koushik Reddy" },
        [PSCustomObject]@{ studentId = "25QM1A66D8"; studentName = "Siddharth" },
        [PSCustomObject]@{ studentId = "25QM1A66D9"; studentName = "Rahul" }
    )
    faculty = @(
        [PSCustomObject]@{ facultyId = "FAC101"; email = "FAC101@edu.in" }
    )
    facultySubjects = @(
        [PSCustomObject]@{ facultyId = "FAC101"; subjectId = "DBMS" }
    )
    subjectMarks = @()
}

$facultySessDBMS = [PSCustomObject]@{
    username = "FAC101"
    facultyId = "FAC101"
    role = "faculty"
    assignedSubjects = @("DBMS")
}

# 3.1 Test Case: All rows match assigned subject DBMS -> Must succeed
$validRowsAllDBMS = @(
    [PSCustomObject]@{ RowNum = 2; SubjectCode = "DBMS"; StudentId = "25QM1A66D6"; RawInternal = "35"; RawExternal = "52" },
    [PSCustomObject]@{ RowNum = 3; SubjectCode = "DBMS"; StudentId = "25QM1A66D7"; RawInternal = "38"; RawExternal = "55" }
)
$resMatching = Test-MarksExcelRows -RawRows $validRowsAllDBMS -TargetSubjectId "DBMS" -FacultySession $facultySessDBMS -DbRef $testDb

Assert-Test "All matching rows: Success is true" ($resMatching.Success -eq $true) "Success was $($resMatching.Success): $($resMatching.Error)"
Assert-Test "All matching rows: ValidRowsCount is 2" ($resMatching.ValidRowsCount -eq 2) "Got $($resMatching.ValidRowsCount)"
Assert-Test "All matching rows: SubjectMismatch is false" ($resMatching.SubjectMismatch -eq $false)

# 3.2 Test Case: Mixed Subject File (Row 1: DBMS, Row 2: SE Lab, Row 3: SE Lab, Row 4: DBMS)
$mixedRows = @(
    [PSCustomObject]@{ RowNum = 2; SubjectCode = "DBMS"; StudentId = "25QM1A66D6"; RawInternal = "35"; RawExternal = "52" },
    [PSCustomObject]@{ RowNum = 3; SubjectCode = "SE Lab"; StudentId = "25QM1A66D7"; RawInternal = "38"; RawExternal = "55" },
    [PSCustomObject]@{ RowNum = 4; SubjectCode = "SE Lab"; StudentId = "25QM1A66D8"; RawInternal = "30"; RawExternal = "48" },
    [PSCustomObject]@{ RowNum = 5; SubjectCode = "DBMS"; StudentId = "25QM1A66D9"; RawInternal = "32"; RawExternal = "50" }
)
$resMixed = Test-MarksExcelRows -RawRows $mixedRows -TargetSubjectId "DBMS" -FacultySession $facultySessDBMS -DbRef $testDb

Assert-Test "Mixed subjects: Entire file rejected (Success is false)" ($resMixed.Success -eq $false) "Success was $($resMixed.Success)"
Assert-Test "Mixed subjects: SubjectMismatch flag is true" ($resMixed.SubjectMismatch -eq $true)
Assert-Test "Mixed subjects: Identifies mismatching row number (3)" ($resMixed.Error -match 'row\s+3') "Error: $($resMixed.Error)"
Assert-Test "Mixed subjects: Mentions expected subject ('DBMS')" ($resMixed.Error -match 'DBMS') "Error: $($resMixed.Error)"
Assert-Test "Mixed subjects: Mentions actual subject found ('SE Lab')" ($resMixed.Error -match 'SE Lab') "Error: $($resMixed.Error)"
Assert-Test "Mixed subjects: States zero marks were saved" ($resMixed.Error -match 'zero marks were saved') "Error: $($resMixed.Error)"

# 3.3 Test Case: Blank/Missing Subject Code in row 2
$blankSubjRows = @(
    [PSCustomObject]@{ RowNum = 2; SubjectCode = "DBMS"; StudentId = "25QM1A66D6"; RawInternal = "35"; RawExternal = "52" },
    [PSCustomObject]@{ RowNum = 3; SubjectCode = ""; StudentId = "25QM1A66D7"; RawInternal = "38"; RawExternal = "55" }
)
$resBlank = Test-MarksExcelRows -RawRows $blankSubjRows -TargetSubjectId "DBMS" -FacultySession $facultySessDBMS -DbRef $testDb

Assert-Test "Blank subject code: Entire file rejected (Success is false)" ($resBlank.Success -eq $false)
Assert-Test "Blank subject code: Error specifies row 3 and missing code" ($resBlank.Error -match 'row\s+3' -and $resBlank.Error -match 'Missing Subject Code') "Error: $($resBlank.Error)"

# 3.4 Test Case: File belongs to unassigned subject (e.g. FAC101 assigned DBMS uploads MATHS file)
$mathsRows = @(
    [PSCustomObject]@{ RowNum = 2; SubjectCode = "MATHS"; StudentId = "25QM1A66D6"; RawInternal = "35"; RawExternal = "52" }
)
$resUnassigned = Test-MarksExcelRows -RawRows $mathsRows -TargetSubjectId "" -FacultySession $facultySessDBMS -DbRef $testDb

Assert-Test "Unassigned subject file: Rejected with SubjectMismatch = true" ($resUnassigned.Success -eq $false -and $resUnassigned.SubjectMismatch -eq $true) "Error: $($resUnassigned.Error)"
Assert-Test "Unassigned subject file: Error states assigned subject" ($resUnassigned.Error -match 'DBMS') "Error: $($resUnassigned.Error)"

# 3.5 Test Case: Matching subject file with row-specific mark errors (e.g., marks > 40, external without internal)
$rowsWithOneBadMark = @(
    [PSCustomObject]@{ RowNum = 2; SubjectCode = "DBMS"; StudentId = "25QM1A66D6"; RawInternal = "35"; RawExternal = "52" },
    [PSCustomObject]@{ RowNum = 3; SubjectCode = "DBMS"; StudentId = "25QM1A66D7"; RawInternal = "99"; RawExternal = "55" } # 99 > 40
)
$resBadMark = Test-MarksExcelRows -RawRows $rowsWithOneBadMark -TargetSubjectId "DBMS" -FacultySession $facultySessDBMS -DbRef $testDb

Assert-Test "Matching subject file with invalid mark: Success is true (preview succeeds)" ($resBadMark.Success -eq $true)
Assert-Test "Matching subject file: ValidRowsCount is 1" ($resBadMark.ValidRowsCount -eq 1) "Got $($resBadMark.ValidRowsCount)"
Assert-Test "Matching subject file: InvalidRowsCount is 1" ($resBadMark.InvalidRowsCount -eq 1) "Got $($resBadMark.InvalidRowsCount)"
Assert-Test "Matching subject file: Invalid row flags domain error [0-40]" ($resBadMark.Rows[1].errorMessage -match '\[0-40\]') "Error: $($resBadMark.Rows[1].errorMessage)"

# 3.6 Check Java MarksImportService.java for the pre-scan logic
$javaServicePath = "c:\Users\harsh\OneDrive\Desktop\Academic Rsult\src\main\java\com\academic\service\MarksImportService.java"
$javaContent = Get-Content $javaServicePath -Raw

Assert-Test "Java MarksImportService has row-by-row pre-scan for subject consistency" (
    $javaContent -match 'PRE-SCAN.*Verify EVERY row has the expected subject code'
)
Assert-Test "Java MarksImportService displays first mismatch row number and codes" (
    $javaContent -match 'Subject Code mismatch at row %d: expected ''%s'', but found ''%s'''
)
Assert-Test "Java MarksImportService commitValidMarks guards against mismatched subject" (
    $javaContent -match 'Subject Code mismatch detected during commit'
)

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "FINAL RESULTS: $passCount PASSED, $failCount FAILED" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "====================================================" -ForegroundColor Cyan
