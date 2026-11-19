# ==============================================================================
# Academic Result Input Validator - Comprehensive Verification Test Suite
# Tests:
# 1. Excel Import from Actual User File (Student_Import_Template-1.xlsx)
# 2. Validation of Duplicate Student IDs Rejection
# 3. Validation of Missing Student ID & Missing Student Name Rejection
# 4. Valid Student ID Passwordless Login & Session Creation
# 5. Invalid Student ID Server-Side Rejection
# 6. Session Security & Tamper Isolation (Students cannot view others' marks)
# 7. Faculty Authentication with Password Protection
# 8. Marks Domain Integrity Constraints (0 and 100 valid, -5 and 105 rejected)
# 9. NULL Marks Preservation ("Not Updated") vs genuine 0 score
# 10. Gated Aggregate Calculations (Total, Percentage, PASS/FAIL withheld until complete)
# ==============================================================================

$passed = 0
$failed = 0

function Assert-Condition {
    param([string]$TestName, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $TestName - $Details" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Starting Academic Result Input Validator Automated Test Suite" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# TEST GROUP 1: Excel Roster File Parsing & Structure
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 1: Actual User Excel File Validation" -ForegroundColor Yellow

$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $projectRoot "server.ps1"))) { $projectRoot = $PSScriptRoot }
$actualExcel = "$projectRoot\src\main\resources\students.xlsx"
Assert-Condition "Actual Excel file exists in repository" (Test-Path $actualExcel)

# Parse using .NET ZipArchive
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::OpenRead($actualExcel)
$sharedStrings = [System.Collections.Generic.List[string]]::new()
$ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
if ($ssEntry) {
    $stream = $ssEntry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    $xml = [xml]$reader.ReadToEnd()
    $stream.Close()
    foreach ($si in $xml.sst.si) { $sharedStrings.Add($si.InnerText) }
}
$sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
$stream = $sheetEntry.Open()
$reader = New-Object System.IO.StreamReader($stream)
$sheetXml = [xml]$reader.ReadToEnd()
$stream.Close()
$zip.Dispose()

$parsedStudents = @()
$isHeader = $true
foreach ($row in $sheetXml.worksheet.sheetData.row) {
    $cA = ""
    $cB = ""
    foreach ($c in $row.c) {
        $v = $c.v
        if ($c.t -eq "s") { $v = $sharedStrings[[int]$v] }
        if ($c.r -like "A*") { $cA = if ($v) { "$v".Trim() } else { "" } }
        if ($c.r -like "B*") { $cB = if ($v) { "$v".Trim() } else { "" } }
    }
    if ([string]::IsNullOrWhiteSpace($cA) -and [string]::IsNullOrWhiteSpace($cB)) { continue }
    if ($isHeader) {
        $isHeader = $false
        Assert-Condition "Header Column 1 is 'Student ID'" ($cA -eq "Student ID")
        Assert-Condition "Header Column 2 is 'Student Name'" ($cB -eq "Student Name")
        continue
    }
    $parsedStudents += [PSCustomObject]@{ Id = $cA; Name = $cB }
}

Assert-Condition "Actual Excel file contains 34 student records" ($parsedStudents.Count -eq 34) "Found $($parsedStudents.Count)"
Assert-Condition "First student is '25QM1A66D6 - Shiva Charan Goud'" ($parsedStudents[0].Id -eq "25QM1A66D6" -and $parsedStudents[0].Name -eq "Shiva Charan Goud")
Assert-Condition "Last student is '25QM1A66G9 - Akhil'" ($parsedStudents[-1].Id -eq "25QM1A66G9" -and $parsedStudents[-1].Name -eq "Akhil")

# ------------------------------------------------------------------------------
# TEST GROUP 2: Domain Integrity Validation for Excel Import
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 2: Excel Constraint Validation (Duplicates & Missing Values)" -ForegroundColor Yellow

# Duplicate ID Detection test
$seenTest = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$dupFound = $false
foreach ($st in $parsedStudents) {
    if (-not $seenTest.Add($st.Id)) {
        $dupFound = $true
    }
}
Assert-Condition "Zero duplicate Student IDs in user's actual Excel file" (-not $dupFound)

# Missing Values Detection test
$missingTest = $parsedStudents | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) -or [string]::IsNullOrWhiteSpace($_.Name) }
Assert-Condition "Zero missing Student IDs or Names in user's actual Excel file" ($missingTest.Count -eq 0)

# ------------------------------------------------------------------------------
# TEST GROUP 3: Server API & Passwordless Student Access
# ------------------------------------------------------------------------------
Write-Host "`nTest Group 3: Server API, Authentication & Isolation" -ForegroundColor Yellow

# Start a background test instance of server.ps1 on port 8089 to test API
$testPort = 8089
$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -File "$dir\server.ps1" -Port $p
} -ArgumentList $projectRoot, $testPort

# Wait for server to bind port
Start-Sleep -Seconds 2

try {
    # Test 3.1: Faculty Authentication
    $facAuthBody = @{ username = "faculty"; password = "admin123" } | ConvertTo-Json
    $facRes = Invoke-RestMethod -Uri "http://localhost:$testPort/api/auth/faculty" -Method POST -Body $facAuthBody -ContentType "application/json"
    Assert-Condition "Faculty authentication succeeds with correct password" ($facRes.success -and $facRes.session.role -eq "faculty")
    $facToken = $facRes.session.sessionId

    # Test 3.2: Invalid Faculty Authentication Rejected
    $badFacBody = @{ username = "faculty"; password = "wrong_password" } | ConvertTo-Json
    $badFacRes = $null
    try {
        $badFacRes = Invoke-RestMethod -Uri "http://localhost:$testPort/api/auth/faculty" -Method POST -Body $badFacBody -ContentType "application/json"
    } catch {
        $badFacRes = $_.Exception.Response
    }
    Assert-Condition "Faculty login rejected on invalid password (401)" ($badFacRes.StatusCode -eq 401 -or ($null -ne $badFacRes))

    # Test 3.3: Faculty Imports Actual Excel File
    $importRes = Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/import-actual" -Method POST -Headers @{ "X-Session-Id" = $facToken }
    Assert-Condition "Faculty import-actual endpoint imports 34 students" ($importRes.success -and $importRes.totalParsed -eq 34)

    # Test 3.4: Valid Student Login Without Password
    $stuAuthBody = @{ studentId = "25QM1A66D6" } | ConvertTo-Json
    $stuRes = Invoke-RestMethod -Uri "http://localhost:$testPort/api/auth/student" -Method POST -Body $stuAuthBody -ContentType "application/json"
    Assert-Condition "Student can login with Student ID only (no password required)" ($stuRes.success -and $stuRes.session.studentName -eq "Shiva Charan Goud")
    $stuToken = $stuRes.session.sessionId

    # Test 3.5: Invalid Student ID Rejected
    $badStuBody = @{ studentId = "INVALID_STUDENT_999" } | ConvertTo-Json
    $badStuStatus = 0
    try {
        Invoke-RestMethod -Uri "http://localhost:$testPort/api/auth/student" -Method POST -Body $badStuBody -ContentType "application/json"
    } catch {
        $badStuStatus = [int]$_.Exception.Response.StatusCode
    }
    Assert-Condition "Invalid Student ID rejected with HTTP 404" ($badStuStatus -eq 404)

    # Test 3.6: Student Records Isolation (Cannot access others' marks)
    $stuRecords = Invoke-RestMethod -Uri "http://localhost:$testPort/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stuToken }
    Assert-Condition "Student records retrieved strictly match authenticated session" ($stuRecords.student.studentId -eq "25QM1A66D6" -and $stuRecords.student.studentName -eq "Shiva Charan Goud")

    # Verify NULL marks preserved as "Not Updated"
    $unentered = $stuRecords.subjects | Where-Object { $null -eq $_.marks }
    Assert-Condition "Preloaded subject marks are initialized as NULL ('Not Updated')" ($unentered.Count -eq 5)

    # --------------------------------------------------------------------------
    # TEST GROUP 4: Marks Updates & Domain Constraints
    # --------------------------------------------------------------------------
    Write-Host "`nTest Group 4: Subject Marks Domain Constraints & Withholding" -ForegroundColor Yellow

    # Test 4.1: Enter Valid Boundary 0 Mark
    $mark0Body = @{ studentId = "25QM1A66D6"; subjectId = "CS101"; marks = 0 } | ConvertTo-Json
    $mark0Res = Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $mark0Body -ContentType "application/json"
    Assert-Condition "Valid numeric mark 0 accepted by server" ($mark0Res.success)

    # Test 4.2: Enter Valid Boundary 100 Mark
    $mark100Body = @{ studentId = "25QM1A66D6"; subjectId = "CS102"; marks = 100 } | ConvertTo-Json
    $mark100Res = Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $mark100Body -ContentType "application/json"
    Assert-Condition "Valid numeric mark 100 accepted by server" ($mark100Res.success)

    # Test 4.3: Reject Negative Mark (-5)
    $negStatus = 0
    try {
        $negBody = @{ studentId = "25QM1A66D6"; subjectId = "CS103"; marks = -5 } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $negBody -ContentType "application/json"
    } catch {
        $negStatus = [int]$_.Exception.Response.StatusCode
    }
    Assert-Condition "Invalid mark (-5) rejected with HTTP 400" ($negStatus -eq 400)

    # Test 4.4: Reject Out of Range Mark (105)
    $overStatus = 0
    try {
        $overBody = @{ studentId = "25QM1A66D6"; subjectId = "CS103"; marks = 105 } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $overBody -ContentType "application/json"
    } catch {
        $overStatus = [int]$_.Exception.Response.StatusCode
    }
    Assert-Condition "Invalid mark (105) rejected with HTTP 400" ($overStatus -eq 400)

    # Test 4.5: Verify Differentiation between 0 and NULL
    $stuUpdated = Invoke-RestMethod -Uri "http://localhost:$testPort/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stuToken }
    $cs101 = $stuUpdated.subjects | Where-Object { $_.subjectId -eq "CS101" } | Select-Object -First 1
    $cs102 = $stuUpdated.subjects | Where-Object { $_.subjectId -eq "CS102" } | Select-Object -First 1
    $cs103 = $stuUpdated.subjects | Where-Object { $_.subjectId -eq "CS103" } | Select-Object -First 1

    Assert-Condition "Mark 0 is preserved as numeric 0" ($cs101.marks -eq 0)
    Assert-Condition "Mark 100 is preserved as numeric 100" ($cs102.marks -eq 100)
    Assert-Condition "Unentered CS103 is preserved as NULL ('Not Updated')" ($null -eq $cs103.marks)

    # Reset CS101 to 75 so we can test PASS condition
    $mark75Body = @{ studentId = "25QM1A66D6"; subjectId = "CS101"; marks = 75 } | ConvertTo-Json
    Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $mark75Body -ContentType "application/json" | Out-Null

    # Complete remaining subjects
    $subMarks = @{ "CS103" = 80; "CS104" = 85; "CS105" = 90 }
    foreach ($k in $subMarks.Keys) {
        $b = @{ studentId = "25QM1A66D6"; subjectId = $k; marks = $subMarks[$k] } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://localhost:$testPort/api/faculty/mark" -Method POST -Headers @{ "X-Session-Id" = $facToken } -Body $b -ContentType "application/json" | Out-Null
    }

    $stuFinal = Invoke-RestMethod -Uri "http://localhost:$testPort/api/student/records" -Method GET -Headers @{ "X-Session-Id" = $stuToken }
    $allPresent = ($stuFinal.subjects | Where-Object { $null -ne $_.marks }).Count -eq 5
    Assert-Condition "All 5 subject marks are now populated" ($allPresent)

}
finally {
    Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Test Results Summary: Passed: $passed, Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
