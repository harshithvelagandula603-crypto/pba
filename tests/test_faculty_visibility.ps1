# Test script for faculty-specific subject visibility and authorization
$base = "http://localhost:8080"
$allPassed = $true

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

Write-Host "`n=== 1. TESTING ALL 8 FACULTY ACCOUNTS FOR SUBJECT VISIBILITY ===" -ForegroundColor Cyan

foreach ($facId in ("FAC101", "FAC102", "FAC103", "FAC104", "FAC105", "FAC106", "FAC107", "FAC108")) {
    $email = "$facId@edu.in"
    $expected = $expectedAssignments[$facId]
    
    # Login with facultyId + email
    $loginBody = @{ facultyId = $facId; email = $email } | ConvertTo-Json
    $loginRes = Invoke-RestMethod -Uri "$base/api/auth/faculty-login" -Method POST -Body $loginBody -ContentType "application/json"
    $token = $loginRes.session.sessionId
    
    if (-not $token) {
        Write-Host "FAILED: Login failed for $facId" -ForegroundColor Red
        $allPassed = $false
        continue
    }

    $headers = @{ "X-Session-Id" = $token }

    # 1. Check /api/faculty/subjects
    $subRes = Invoke-RestMethod -Uri "$base/api/faculty/subjects" -Method GET -Headers $headers
    $actualSubjects = @($subRes.subjects | ForEach-Object { $_.subjectId })
    
    $diff1 = Compare-Object $expected $actualSubjects
    if ($diff1) {
        Write-Host "FAILED: $facId /api/faculty/subjects mismatch! Expected: $($expected -join ', ') but Got: $($actualSubjects -join ', ')" -ForegroundColor Red
        $allPassed = $false
    } else {
        Write-Host "PASS: $facId /api/faculty/subjects returned exactly: $($actualSubjects -join ', ')" -ForegroundColor Green
    }

    # 2. Check bypass attempt ?all=true
    $subAllRes = Invoke-RestMethod -Uri "$base/api/faculty/subjects?all=true" -Method GET -Headers $headers
    $actualAllSubjects = @($subAllRes.subjects | ForEach-Object { $_.subjectId })
    $diffAll = Compare-Object $expected $actualAllSubjects
    if ($diffAll) {
        Write-Host "FAILED: $facId /api/faculty/subjects?all=true allowed bypass!" -ForegroundColor Red
        $allPassed = $false
    } else {
        Write-Host "PASS: $facId /api/faculty/subjects?all=true bypass rejected. Returned only assigned subjects." -ForegroundColor Green
    }

    # 3. Check /api/faculty/dashboard-stats
    $dashRes = Invoke-RestMethod -Uri "$base/api/faculty/dashboard-stats" -Method GET -Headers $headers
    $dashSubjects = @($dashRes.subjectsOverview | ForEach-Object { $_.subjectId })
    $dashCount = $dashRes.metrics.totalSubjects
    
    $diffDash = Compare-Object $expected $dashSubjects
    if ($diffDash -or $dashCount -ne $expected.Count) {
        Write-Host "FAILED: $facId dashboard-stats mismatch! Expected count: $($expected.Count), Got: $dashCount; Subjects: $($dashSubjects -join ', ')" -ForegroundColor Red
        $allPassed = $false
    } else {
        Write-Host "PASS: $facId dashboard-stats overview has exactly $($dashCount) assigned subject(s): $($dashSubjects -join ', ')" -ForegroundColor Green
    }

    # 4. Check /api/faculty/student-marks
    $marksRes = Invoke-RestMethod -Uri "$base/api/faculty/student-marks?studentId=25QM1A66D6" -Method GET -Headers $headers
    $marksSubjects = @($marksRes | ForEach-Object { $_.subjectId })
    
    $diffMarks = Compare-Object $expected $marksSubjects
    if ($diffMarks) {
        Write-Host "FAILED: $facId /api/faculty/student-marks contains unassigned subjects! Got: $($marksSubjects -join ', ')" -ForegroundColor Red
        $allPassed = $false
    } else {
        Write-Host "PASS: $facId /api/faculty/student-marks contains exactly assigned subjects: $($marksSubjects -join ', ')" -ForegroundColor Green
    }
}

Write-Host "`n=== 2. SPECIFIC VERIFICATION FOR FAC102 ===" -ForegroundColor Cyan
$loginRes = Invoke-RestMethod -Uri "$base/api/auth/faculty-login" -Method POST -Body (@{ facultyId = "FAC102"; email = "FAC102@edu.in" } | ConvertTo-Json) -ContentType "application/json"
$fac102Token = $loginRes.session.sessionId
$fac102Headers = @{ "X-Session-Id" = $fac102Token }

# Check that FAC102 specifically cannot see DBMS, OOPs, SE, COA, SE Lab, OOPs Lab, SD Lab, DBMS Lab
$marksRes102 = Invoke-RestMethod -Uri "$base/api/faculty/student-marks?studentId=25QM1A66D6" -Method GET -Headers $fac102Headers
$subjects102 = @($marksRes102 | ForEach-Object { $_.subjectId })
$forbiddenSubjects = @("DBMS", "OOPS", "SE", "COA", "SE_LAB", "OOPS_LAB", "SD_LAB", "DBMS_LAB")

$foundForbidden = @()
foreach ($fs in $forbiddenSubjects) {
    if ($subjects102 -contains $fs) {
        $foundForbidden += $fs
    }
}

if ($foundForbidden.Count -eq 0 -and $subjects102.Count -eq 2 -and ($subjects102 -contains "MATHS") -and ($subjects102 -contains "MATHS_LAB")) {
    Write-Host "PASS: FAC102 sees EXACTLY Maths and Maths Lab. Zero unassigned subjects visible!" -ForegroundColor Green
} else {
    Write-Host "FAILED: FAC102 visibility violation. Found forbidden subjects: $($foundForbidden -join ', ')" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "`n=== 3. BACKEND AUTHORIZATION ENFORCEMENT FOR FAC102 ===" -ForegroundColor Cyan

# Attempt 1: FAC102 requests GET /api/faculty/subject-details for DBMS (unassigned)
try {
    $res = Invoke-RestMethod -Uri "$base/api/faculty/subject-details?subjectId=DBMS" -Method GET -Headers $fac102Headers
    Write-Host "FAILED: GET /api/faculty/subject-details?subjectId=DBMS was NOT rejected!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 403) {
        Write-Host "PASS: GET /api/faculty/subject-details?subjectId=DBMS rejected with 403 Forbidden as expected." -ForegroundColor Green
    } else {
        Write-Host "FAILED: GET /api/faculty/subject-details?subjectId=DBMS returned HTTP $statusCode (expected 403)." -ForegroundColor Red
        $allPassed = $false
    }
}

# Attempt 2: FAC102 requests POST /api/faculty/mark for DBMS (unassigned)
try {
    $postBody = @{
        studentId = "25QM1A66D6"
        subjectId = "DBMS"
        internalMarks = 35
        externalMarks = 50
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
    Write-Host "FAILED: POST /api/faculty/mark with DBMS was NOT rejected!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 403) {
        Write-Host "PASS: POST /api/faculty/mark for unassigned subject DBMS rejected with 403 Forbidden as expected." -ForegroundColor Green
    } else {
        Write-Host "FAILED: POST /api/faculty/mark returned HTTP $statusCode (expected 403)." -ForegroundColor Red
        $allPassed = $false
    }
}

Write-Host "`n=== 4. PRESERVE VALIDATION RULES & MARKS WORKFLOW ===" -ForegroundColor Cyan

# 4a: Internal mark out of 40 (>40 rejected)
try {
    $postBody = @{
        studentId = "25QM1A66D6"
        subjectId = "MATHS"
        internalMarks = 45
        markType = "internal"
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
    Write-Host "FAILED: Internal marks 45 was NOT rejected!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 400) {
        Write-Host "PASS: Internal mark > 40 rejected with 400 Bad Request." -ForegroundColor Green
    } else {
        Write-Host "FAILED: Internal mark > 40 returned HTTP $statusCode (expected 400)." -ForegroundColor Red
        $allPassed = $false
    }
}

# 4b: External marks remain unavailable until valid internal marks are saved (test on MATHS_LAB)
try {
    $postBody = @{
        studentId = "25QM1A66D6"
        subjectId = "MATHS_LAB"
        externalMarks = 48
        markType = "external"
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
    Write-Host "FAILED: External marks without prior internal marks was NOT rejected!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 400) {
        Write-Host "PASS: External marks rejected with 400 because internal marks not yet saved." -ForegroundColor Green
    } else {
        Write-Host "FAILED: External marks check returned HTTP $statusCode (expected 400)." -ForegroundColor Red
        $allPassed = $false
    }
}

# 4c: Save valid internal mark (38/40) for MATHS
$postBody = @{
    studentId = "25QM1A66D6"
    subjectId = "MATHS"
    internalMarks = 38
    markType = "internal"
} | ConvertTo-Json
$resInternal = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
if ($resInternal.success) {
    Write-Host "PASS: Valid internal mark (38/40) successfully saved for MATHS." -ForegroundColor Green
} else {
    Write-Host "FAILED to save valid internal mark." -ForegroundColor Red
    $allPassed = $false
}

# 4d: External mark out of 60 (>60 rejected)
try {
    $postBody = @{
        studentId = "25QM1A66D6"
        subjectId = "MATHS"
        externalMarks = 65
        markType = "external"
    } | ConvertTo-Json
    $res = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
    Write-Host "FAILED: External marks 65 was NOT rejected!" -ForegroundColor Red
    $allPassed = $false
} catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 400) {
        Write-Host "PASS: External mark > 60 rejected with 400 Bad Request." -ForegroundColor Green
    } else {
        Write-Host "FAILED: External mark > 60 returned HTTP $statusCode (expected 400)." -ForegroundColor Red
        $allPassed = $false
    }
}

# 4e: Save valid external mark (55/60) for MATHS
$postBody = @{
    studentId = "25QM1A66D6"
    subjectId = "MATHS"
    externalMarks = 55
    markType = "external"
} | ConvertTo-Json
$resExternal = Invoke-RestMethod -Uri "$base/api/faculty/mark" -Method POST -Headers $fac102Headers -Body $postBody -ContentType "application/json"
if ($resExternal.success) {
    Write-Host "PASS: Valid external mark (55/60) successfully saved for MATHS." -ForegroundColor Green
} else {
    Write-Host "FAILED to save valid external mark." -ForegroundColor Red
    $allPassed = $false
}

# 4f: Verify student marks retrieval: Internal = 38, External = 55, Total = 93
$marksCheck = Invoke-RestMethod -Uri "$base/api/faculty/student-marks?studentId=25QM1A66D6" -Method GET -Headers $fac102Headers
$mathsRec = $marksCheck | Where-Object { $_.subjectId -eq "MATHS" } | Select-Object -First 1

if ($mathsRec.internalMarks -eq 38 -and $mathsRec.externalMarks -eq 55 -and $mathsRec.totalMarks -eq 93 -and $mathsRec.evalStatus -eq "Fully Entered") {
    Write-Host "PASS: Subject marks retrieved correctly: Internal=38, External=55, Total=93, Status=Fully Entered." -ForegroundColor Green
} else {
    Write-Host "FAILED: Subject marks calculation mismatch! Got: $($mathsRec | ConvertTo-Json)" -ForegroundColor Red
    $allPassed = $false
}

Write-Host "`n=======================================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "ALL TESTS PASSED SUCCESSFULLY!" -ForegroundColor Green
} else {
    Write-Host "SOME TESTS FAILED." -ForegroundColor Red
}
Write-Host "=======================================================`n" -ForegroundColor Cyan
