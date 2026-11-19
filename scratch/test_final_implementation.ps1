$baseUrl = "http://localhost:8080"
$exportDir = Join-Path $PSScriptRoot "..\data\export"
$dbFile = Join-Path $PSScriptRoot "..\data\academic_db.json"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Academic Result Input Validator - Comprehensive Final Test Suite" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Test([string]$desc, [bool]$condition, [string]$detail = "") {
    if ($condition) {
        Write-Host "  [PASS] $desc" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $desc $detail" -ForegroundColor Red
        $script:failed++
    }
}

# ----------------------------------------------------------------------
# 1. Faculty Login
# ----------------------------------------------------------------------
Write-Host "`n1. Faculty Authentication..." -ForegroundColor Yellow
$loginBody = @{
    facultyId = "FAC101"
    email = "FAC101@edu.in"
    password = "admin123"
} | ConvertTo-Json

$loginResp = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty" -Method POST -Body $loginBody -ContentType "application/json"
Assert-Test "Faculty FAC101 login succeeded" ($loginResp.success -eq $true -and $null -ne $loginResp.session.sessionId)
$token = $loginResp.session.sessionId
$headers = @{ "X-Session-Id" = $token }

# ----------------------------------------------------------------------
# 2. Test CSV Ingestion with Header detection & domain integrity
# ----------------------------------------------------------------------
Write-Host "`n2. Test CSV Ingestion via BufferedReader Engine..." -ForegroundColor Yellow
$csvData = @"
Subject,Student ID,Internal Marks,External Marks
DBMS,25QM1A66D6,35,52
DBMS,25QM1A66D7,28,45
DBMS,25QM1A66D8,32,48
"@

$csvResp = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Headers $headers -Body $csvData -ContentType "text/plain; charset=UTF-8"
Assert-Test "CSV Import Success status" ($csvResp.success -eq $true)
Assert-Test "CSV Valid records count = 3" ($csvResp.validCount -eq 3)
Assert-Test "Table-file writing status reported as SUCCESS" ($csvResp.tableFileWritingStatus -eq "SUCCESS")
Assert-Test "MySQL synchronization status reported as SYNCHRONIZED" ($csvResp.mysqlSynchronizationStatus -eq "SYNCHRONIZED")
Assert-Test "Table files synchronized flag is true" ($csvResp.tableFilesSynchronized -eq $true)
Assert-Test "AI analysis status is AVAILABLE" ($csvResp.aiAnalysisStatus -eq "AVAILABLE")

# ----------------------------------------------------------------------
# 3. Test Invalid Marks & Student ID Rejection
# ----------------------------------------------------------------------
Write-Host "`n3. Test Domain Integrity Constraint Rejections..." -ForegroundColor Yellow
$invalidCsv = @"
Subject,Sudent ID,Internal Marks,External Marks
DBMS,25QM1A66D9,45,50
DBMS,25QM1A66E0,30,75
DBMS,INVALID_STUDENT_999,25,35
DBMS,25QM1A66D6,,40
DBMS,25QM1A66E1,20,30
DBMS,25QM1A66E1,22,32
"@

$invalidResp = $null
try {
    $invalidResp = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Headers $headers -Body $invalidCsv -ContentType "text/plain; charset=UTF-8"
} catch {
    $invalidResp = $_.ErrorDetails.Message | ConvertFrom-Json
}

Assert-Test "Invalid records import processed partially" ($null -ne $invalidResp)
Assert-Test "Rejections reported (at least 4 invalid rows)" ($invalidResp.rejectedCount -ge 4)

$hasInternalError = $false
$hasExternalError = $false
$hasStudentError = $false
$hasDuplicateError = $false
$hasInternalFirstError = $false

foreach ($err in $invalidResp.errors) {
    if ($err.reason -like "*Internal marks out of domain*") { $hasInternalError = $true }
    if ($err.reason -like "*External marks out of domain*") { $hasExternalError = $true }
    if ($err.reason -like "*does not exist in registered student master records*") { $hasStudentError = $true }
    if ($err.reason -like "*Duplicate record*") { $hasDuplicateError = $true }
    if ($err.reason -like "*cannot be imported before valid internal marks*") { $hasInternalFirstError = $true }
}

Assert-Test "Rejection Rule: Internal marks > 40 rejected" $hasInternalError
Assert-Test "Rejection Rule: External marks > 60 rejected" $hasExternalError
Assert-Test "Rejection Rule: Unregistered Student ID rejected" $hasStudentError
Assert-Test "Rejection Rule: Duplicate Student ID within file rejected" $hasDuplicateError

# Verify that invalid student ID was NOT written to marks.csv
$marksCsvPath = Join-Path $exportDir "marks.csv"
$marksCsvContent = Get-Content $marksCsvPath
$invalidWritten = $marksCsvContent | Where-Object { $_ -like "*INVALID_STUDENT_999*" }
Assert-Test "Invalid records NOT written to marks.csv" ($null -eq $invalidWritten)

# ----------------------------------------------------------------------
# 4. Test Multiple Subject Support in a Single File
# ----------------------------------------------------------------------
Write-Host "`n4. Test Multiple Subject Support..." -ForegroundColor Yellow

# Case A: Mixed subjects where ALL subjects are assigned to FAC101 (DBMS and SE_LAB)
$multiSubjectAssigned = @"
Subject,Student ID,Internal Marks,External Marks
DBMS,25QM1A66E2,30,45
SE_LAB,25QM1A66E2,35,55
"@

$multiResp = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Headers $headers -Body $multiSubjectAssigned -ContentType "text/plain; charset=UTF-8"
Assert-Test "Multi-subject file with all authorized subjects accepted" ($multiResp.success -eq $true -and $multiResp.validCount -eq 2)

# Case B: Mixed subjects where one subject is NOT assigned to FAC101 (MATHS is assigned to FAC102)
$multiSubjectUnauthorized = @"
Subject,Student ID,Internal Marks,External Marks
DBMS,25QM1A66E3,30,45
MATHS,25QM1A66E3,35,55
"@

$unauthResp = $null
try {
    $unauthResp = Invoke-RestMethod -Uri "$baseUrl/api/faculty/validate-table-file" -Method POST -Headers $headers -Body $multiSubjectUnauthorized -ContentType "text/plain; charset=UTF-8"
} catch {
    $unauthResp = $_.ErrorDetails.Message | ConvertFrom-Json
}
Assert-Test "Unauthorized subject in file rejected entire file" ($unauthResp.success -eq $false -and $unauthResp.rejectedCount -gt 0)
Assert-Test "Rejection message explains unauthorized subject" ($unauthResp.message -like "*Access Denied*" -or $unauthResp.message -like "*not assigned*")

# ----------------------------------------------------------------------
# 5. Verify Table Files & MySQL Consistency
# ----------------------------------------------------------------------
Write-Host "`n5. Verify Backend Table Files and Database Synchronization..." -ForegroundColor Yellow

Assert-Test "marks.csv exists in data/export/" (Test-Path (Join-Path $exportDir "marks.csv"))
Assert-Test "results.csv exists in data/export/" (Test-Path (Join-Path $exportDir "results.csv"))
Assert-Test "students.csv exists in data/export/" (Test-Path (Join-Path $exportDir "students.csv"))
Assert-Test "subjects.csv exists in data/export/" (Test-Path (Join-Path $exportDir "subjects.csv"))
Assert-Test "faculty_assignments.csv exists in data/export/" (Test-Path (Join-Path $exportDir "faculty_assignments.csv"))
Assert-Test "faculty_assignment.csv exists in data/export/" (Test-Path (Join-Path $exportDir "faculty_assignment.csv"))

# Verify that 25QM1A66D6 DBMS marks match in both marks.csv and academic_db.json
$marksCsvRows = Import-Csv (Join-Path $exportDir "marks.csv")
$d6Csv = $marksCsvRows | Where-Object { $_.student_id -eq "25QM1A66D6" -and $_.subject_id -eq "DBMS" } | Select-Object -First 1

$dbData = Get-Content $dbFile -Raw | ConvertFrom-Json
$d6Db = $dbData.subjectMarks | Where-Object { $_.studentId -eq "25QM1A66D6" -and $_.subjectId -eq "DBMS" } | Select-Object -First 1

Assert-Test "25QM1A66D6 Internal marks match (CSV vs DB)" ($d6Csv.internal_marks -eq "$($d6Db.internalMarks)")
Assert-Test "25QM1A66D6 External marks match (CSV vs DB)" ($d6Csv.external_marks -eq "$($d6Db.externalMarks)")
Assert-Test "25QM1A66D6 Total marks match (CSV vs DB)" ($d6Csv.total_marks -eq "$($d6Db.totalMarks)" -and [int]$d6Csv.total_marks -eq ([int]$d6Csv.internal_marks + [int]$d6Csv.external_marks))
Assert-Test "25QM1A66D6 Status = Fully Entered" ($d6Csv.eval_status -eq "Fully Entered")

# ----------------------------------------------------------------------
# 6. Test AI Result Analysis (Faculty Dashboard - Step 6)
# ----------------------------------------------------------------------
Write-Host "`n6. Test AI Result Analysis Endpoint..." -ForegroundColor Yellow
$aiResp = Invoke-RestMethod -Uri "$baseUrl/api/faculty/ai-analysis" -Method GET -Headers $headers
Assert-Test "AI Analysis endpoint responded successfully" ($aiResp.success -eq $true)
Assert-Test "Subject-wise statistics present" ($null -ne $aiResp.analysis.subjectWiseStats -and $aiResp.analysis.subjectWiseStats.Count -gt 0)
Assert-Test "Overall class metrics computed" ($null -ne $aiResp.analysis.overall.avgTotal -and $aiResp.analysis.overall.passPercentage -ge 0)
Assert-Test "Performance insights generated" ($null -ne $aiResp.analysis.performanceInsights -and $aiResp.analysis.performanceInsights.Count -gt 0)
Assert-Test "AI Engine identified" ($null -ne $aiResp.analysis.aiSource)

# ----------------------------------------------------------------------
# 7. Test Student Dashboard & Personalized Improvement Suggestions (Step 7)
# ----------------------------------------------------------------------
Write-Host "`n7. Test Student Dashboard & Improvement Suggestions..." -ForegroundColor Yellow
$stLoginBody = @{
    studentId = "25QM1A66D6"
} | ConvertTo-Json

$stLoginResp = Invoke-RestMethod -Uri "$baseUrl/api/auth/student" -Method POST -Body $stLoginBody -ContentType "application/json"
Assert-Test "Student 25QM1A66D6 login succeeded" ($stLoginResp.success -eq $true)
$stToken = $stLoginResp.session.sessionId
$stHeaders = @{ "X-Session-Id" = $stToken }

$stRecordsResp = Invoke-RestMethod -Uri "$baseUrl/api/student/records" -Method GET -Headers $stHeaders
Assert-Test "Student records endpoint responded" ($stRecordsResp.success -eq $true)
Assert-Test "Enriched with AI Personalized Suggestions" ($null -ne $stRecordsResp.aiSuggestions)
Assert-Test "Strong subjects identified" ($null -ne $stRecordsResp.aiSuggestions.strongSubjects)
Assert-Test "Study recommendations present" ($null -ne $stRecordsResp.aiSuggestions.studyRecommendations -and $stRecordsResp.aiSuggestions.studyRecommendations.Count -gt 0)
Assert-Test "Practical action steps present" ($null -ne $stRecordsResp.aiSuggestions.practicalSuggestions -and $stRecordsResp.aiSuggestions.practicalSuggestions.Count -gt 0)

# Dedicated suggestions endpoint test
$stSugResp = Invoke-RestMethod -Uri "$baseUrl/api/student/ai-suggestions" -Method GET -Headers $stHeaders
Assert-Test "Dedicated AI suggestions endpoint succeeded" ($stSugResp.success -eq $true -and $null -ne $stSugResp.suggestions)

# ----------------------------------------------------------------------
# 8. Web Asset Delivery
# ----------------------------------------------------------------------
Write-Host "`n8. Test Web Dashboard UI Asset Delivery..." -ForegroundColor Yellow
$facPage = Invoke-WebRequest -Uri "$baseUrl/faculty-dashboard.html" -Method GET -UseBasicParsing
Assert-Test "Faculty dashboard HTML delivered" ($facPage.StatusCode -eq 200 -and $facPage.Content.Contains("AI Result Analysis"))

$stPage = Invoke-WebRequest -Uri "$baseUrl/student-dashboard.html" -Method GET -UseBasicParsing
Assert-Test "Student dashboard HTML delivered" ($stPage.StatusCode -eq 200 -and $stPage.Content.Contains("AI Analysis"))

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "Test Suite Complete: $passed Passed, $failed Failed." -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan
