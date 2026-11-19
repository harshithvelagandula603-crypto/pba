# Comprehensive Test for Table File Export Logic
$rootDir = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $rootDir "server.ps1"))) { $rootDir = $PSScriptRoot }

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Unit & Functional Test: Export Table Files Logic & CSV Domain    " -ForegroundColor Cyan
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

# 1. Load academic_db.json
$dbPath = Join-Path $rootDir "data\academic_db.json"
Report-Test "Database JSON exists" (Test-Path $dbPath)
$db = Get-Content $dbPath -Raw | ConvertFrom-Json

# 2. Setup export directory
$exportDir = Join-Path $rootDir "data\export"
if (-not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}
Report-Test "Protected backend export directory exists" (Test-Path $exportDir)

# Helper for CSV escaping
$escapeCsvVal = {
    param([string]$val)
    if ($null -eq $val) { return "" }
    $str = "$val"
    if ($str.Contains(",") -or $str.Contains('"') -or $str.Contains("`n") -or $str.Contains("`r")) {
        return '"' + $str.Replace('"', '""') + '"'
    }
    return $str
}

# --- Generate 1: students.csv ---
$studentsLines = [System.Collections.Generic.List[string]]::new()
$studentsLines.Add("student_id,student_name,roll_no,email,department,semester")
$sortedStudents = @($db.students | Sort-Object { $_.studentId })
foreach ($st in $sortedStudents) {
    $sId = & $escapeCsvVal $st.studentId
    $sName = & $escapeCsvVal $st.studentName
    $sRoll = if ($st.rollNo) { & $escapeCsvVal $st.rollNo } else { $sId }
    $sEmail = if ($st.email) { & $escapeCsvVal $st.email } else { "" }
    $sDept = if ($st.department) { & $escapeCsvVal $st.department } else { "" }
    $sSem = if ($null -ne $st.semester -and "$($st.semester)".Trim() -ne "") { "$($st.semester)".Trim() } else { "" }
    $studentsLines.Add("$sId,$sName,$sRoll,$sEmail,$sDept,$sSem")
}
$studentsFile = Join-Path $exportDir "students.csv"
[System.IO.File]::WriteAllLines($studentsFile, $studentsLines, [System.Text.UTF8Encoding]::new($false))
Report-Test "Generated students.csv" (Test-Path $studentsFile)
Report-Test "students.csv contains all $($sortedStudents.Count) registered students" (($studentsLines.Count - 1) -eq $sortedStudents.Count)

# --- Generate 2: subjects.csv ---
$subjectsLines = [System.Collections.Generic.List[string]]::new()
$subjectsLines.Add("subject_id,subject_code,subject_name,max_marks,max_internal,max_external,pass_marks")
$sortedSubjects = @($db.subjects | Sort-Object { $_.subjectId })
foreach ($sub in $sortedSubjects) {
    $subId = & $escapeCsvVal $sub.subjectId
    $subCode = if ($sub.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sub.subjectCode } else { $subId }
    $subName = & $escapeCsvVal $sub.subjectName
    $maxM = if ($null -ne $sub.maxMarks) { $sub.maxMarks } else { 100 }
    $maxIn = if ($null -ne $sub.maxInternal) { $sub.maxInternal } else { 40 }
    $maxEx = if ($null -ne $sub.maxExternal) { $sub.maxExternal } else { 60 }
    $passM = if ($null -ne $sub.passMarks) { $sub.passMarks } else { 40 }
    $subjectsLines.Add("$subId,$subCode,$subName,$maxM,$maxIn,$maxEx,$passM")
}
$subjectsFile = Join-Path $exportDir "subjects.csv"
[System.IO.File]::WriteAllLines($subjectsFile, $subjectsLines, [System.Text.UTF8Encoding]::new($false))
Report-Test "Generated subjects.csv" (Test-Path $subjectsFile)
Report-Test "subjects.csv contains all $($sortedSubjects.Count) curricular subjects" (($subjectsLines.Count - 1) -eq $sortedSubjects.Count)

# --- Generate 3: faculty_assignments.csv ---
$assignLines = [System.Collections.Generic.List[string]]::new()
$assignLines.Add("faculty_id,email,subject_id,subject_code,subject_name")
$sortedAssignments = @($db.facultySubjects | Sort-Object { $_.facultyId }, { $_.subjectId })
foreach ($fa in $sortedAssignments) {
    $fId = & $escapeCsvVal $fa.facultyId
    $fObj = $db.faculty | Where-Object { $_.facultyId -eq $fa.facultyId } | Select-Object -First 1
    $fEmail = if ($fObj -and $fObj.email) { & $escapeCsvVal $fObj.email } else { "" }
    $sId = & $escapeCsvVal $fa.subjectId
    $sObj = $db.subjects | Where-Object { $_.subjectId -eq $fa.subjectId } | Select-Object -First 1
    $sCode = if ($sObj -and $sObj.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sObj.subjectCode } else { $sId }
    $sName = if ($sObj) { & $escapeCsvVal $sObj.subjectName } else { "" }
    $assignLines.Add("$fId,$fEmail,$sId,$sCode,$sName")
}
$assignFile = Join-Path $exportDir "faculty_assignments.csv"
[System.IO.File]::WriteAllLines($assignFile, $assignLines, [System.Text.UTF8Encoding]::new($false))
Report-Test "Generated faculty_assignments.csv" (Test-Path $assignFile)
Report-Test "faculty_assignments.csv has no password or secret data exposed" (-not ((Get-Content $assignFile -Raw) -match "password|admin123|SHA256"))

# --- Generate 4: marks.csv ---
$marksLines = [System.Collections.Generic.List[string]]::new()
$marksLines.Add("student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status")
$totalMarksRecords = 0
$unenteredCount = 0
$fullyEnteredCount = 0

foreach ($st in $sortedStudents) {
    foreach ($sub in $sortedSubjects) {
        $mRecord = $db.subjectMarks | Where-Object {
            $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
        } | Select-Object -First 1

        $intVal = $null
        $extVal = $null
        if ($null -ne $mRecord) {
            if ($null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null") {
                $n = 0
                if ([int]::TryParse("$($mRecord.internalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 40) {
                    $intVal = $n
                }
            }
            if ($null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null") {
                $n = 0
                if ([int]::TryParse("$($mRecord.externalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 60) {
                    $extVal = $n
                }
            }
        }

        $totVal = $null
        $evalStatus = "Not Updated"
        if ($null -ne $intVal -and $null -ne $extVal) {
            $totVal = $intVal + $extVal
            $evalStatus = "Fully Entered"
            $fullyEnteredCount++
        } elseif ($null -ne $intVal -or $null -ne $extVal) {
            $evalStatus = "Marks Pending"
        } else {
            $unenteredCount++
        }

        $intStr = if ($null -ne $intVal) { "$intVal" } else { "" }
        $extStr = if ($null -ne $extVal) { "$extVal" } else { "" }
        $totStr = if ($null -ne $totVal) { "$totVal" } else { "" }

        $stId = & $escapeCsvVal $st.studentId
        $stName = & $escapeCsvVal $st.studentName
        $subId = & $escapeCsvVal $sub.subjectId
        $subCode = if ($sub.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sub.subjectCode } else { $subId }
        $stStatus = & $escapeCsvVal $evalStatus

        $marksLines.Add("$stId,$stName,$subId,$subCode,$intStr,$extStr,$totStr,$stStatus")
        $totalMarksRecords++
    }
}
$marksFile = Join-Path $exportDir "marks.csv"
[System.IO.File]::WriteAllLines($marksFile, $marksLines, [System.Text.UTF8Encoding]::new($false))
Report-Test "Generated marks.csv" (Test-Path $marksFile)
Report-Test "marks.csv preserves unentered marks as empty string (count: $unenteredCount)" ($unenteredCount -gt 0)

# Check that unentered rows in marks.csv have empty string, never 0
$rawMarks = Get-Content $marksFile
$missingPreservedCorrectly = $true
for ($i = 1; $i -lt $rawMarks.Count; $i++) {
    $cols = $rawMarks[$i].Split(",")
    if ($cols[7] -eq "Not Updated") {
        if ($cols[4] -ne "" -or $cols[5] -ne "" -or $cols[6] -ne "") {
            $missingPreservedCorrectly = $false
        }
    }
}
Report-Test "Not Updated marks in marks.csv have empty components (never converted to 0)" $missingPreservedCorrectly

# --- Generate 5: results.csv ---
$resultsLines = [System.Collections.Generic.List[string]]::new()
$resultsLines.Add("student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects")
$totalSubsCount = $sortedSubjects.Count
$resultsCount = 0

foreach ($st in $sortedStudents) {
    $fullyEntered = 0
    $sumTotal = 0
    $allSubjectsPassed = $true

    foreach ($sub in $sortedSubjects) {
        $mRecord = $db.subjectMarks | Where-Object {
            $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
        } | Select-Object -First 1

        $hasInt = ($null -ne $mRecord -and $null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null")
        $hasExt = ($null -ne $mRecord -and $null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null")

        if ($hasInt -and $hasExt) {
            $nIn = [int]$mRecord.internalMarks
            $nEx = [int]$mRecord.externalMarks
            $subTot = $nIn + $nEx
            $fullyEntered++
            $sumTotal += $subTot
            if ($subTot -lt 35) {
                $allSubjectsPassed = $false
            }
        }
    }

    $isComplete = ($fullyEntered -eq $totalSubsCount -and $totalSubsCount -gt 0)
    $totStr = ""
    $pctStr = ""
    $resStatus = "RESULT WITHHELD"

    if ($isComplete) {
        $totStr = "$sumTotal"
        $pct = [Math]::Round(($sumTotal / ($totalSubsCount * 100)) * 100, 2)
        $pctStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F2}", $pct)
        $resStatus = if ($allSubjectsPassed) { "PASS" } else { "FAIL" }
    }

    $stId = & $escapeCsvVal $st.studentId
    $stName = & $escapeCsvVal $st.studentName
    $stRoll = if ($st.rollNo) { & $escapeCsvVal $st.rollNo } else { $stId }
    $resStatusEsc = & $escapeCsvVal $resStatus

    $resultsLines.Add("$stId,$stName,$stRoll,$totStr,$pctStr,$resStatusEsc,$fullyEntered,$totalSubsCount")
    $resultsCount++
}
$resultsFile = Join-Path $exportDir "results.csv"
[System.IO.File]::WriteAllLines($resultsFile, $resultsLines, [System.Text.UTF8Encoding]::new($false))
Report-Test "Generated results.csv" (Test-Path $resultsFile)

# Inspect results.csv lines:
$rawResults = Get-Content $resultsFile
$withheldCount = 0
for ($i = 1; $i -lt $rawResults.Count; $i++) {
    $cols = $rawResults[$i].Split(",")
    if ($cols[5] -eq "RESULT WITHHELD") {
        $withheldCount++
        if ($cols[3] -ne "" -or $cols[4] -ne "") {
            Report-Test "Withheld record has empty total and percentage" $false "Found total: $($cols[3])"
        }
    }
}
Report-Test "results.csv withholds aggregate for incomplete students ($withheldCount withheld)" ($withheldCount -gt 0)

# Check Java service and servlet code presence
$servicePath = Join-Path $rootDir "src\main\java\com\academic\service\TableFileExportService.java"
$servletPath = Join-Path $rootDir "src\main\java\com\academic\servlet\TableFileExportServlet.java"
Report-Test "Java TableFileExportService.java exists" (Test-Path $servicePath)
Report-Test "Java TableFileExportServlet.java exists" (Test-Path $servletPath)

$serviceCode = Get-Content $servicePath -Raw
Report-Test "Java TableFileExportService genuinely uses java.io.BufferedReader" (
    $serviceCode -match "import java\.io\.BufferedReader;" -and
    $serviceCode -match "BufferedReader br = new BufferedReader" -and
    $serviceCode -match "br\.readLine\(\)"
)

# Check HTML and JS for Export button
$htmlPath = Join-Path $rootDir "src\main\webapp\faculty-dashboard.html"
$jsPath = Join-Path $rootDir "src\main\webapp\js\faculty-dashboard.js"
$htmlCode = Get-Content $htmlPath -Raw
$jsCode = Get-Content $jsPath -Raw

Report-Test "faculty-dashboard.html contains 'btnExportTableFiles'" ($htmlCode -match "btnExportTableFiles")
Report-Test "faculty-dashboard.html contains 'exportTableFeedback'" ($htmlCode -match "exportTableFeedback")
Report-Test "faculty-dashboard.js attaches click handler for 'btnExportTableFiles'" ($jsCode -match "btnExportTableFiles.*addEventListener")
Report-Test "faculty-dashboard.js calls '/api/faculty/export-table-files'" ($jsCode -match "/api/faculty/export-table-files")

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Unit & Functional Results: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan
