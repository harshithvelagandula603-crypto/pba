param([int]$Port = 8092)

$rootDir = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $rootDir "server.ps1"))) { $rootDir = $PSScriptRoot }

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Testing Export Table Files Feature End-to-End                   " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Syntax check of server.ps1
$tokens = $null
$errors = $null
$serverFile = Join-Path $rootDir "server.ps1"
$null = [System.Management.Automation.Language.Parser]::ParseFile($serverFile, [ref]$tokens, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    Write-Host "Syntax Error in server.ps1:" -ForegroundColor Red
    foreach ($e in $errors) {
        Write-Host "  Line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "[PASS] server.ps1 syntax is completely clean." -ForegroundColor Green
}

# 2. Start server in background job
Write-Host "`n--- Starting test server on Port $Port ---" -ForegroundColor Yellow
$job = Start-Job -ScriptBlock {
    param($dir, $p)
    Set-Location $dir
    & powershell -ExecutionPolicy Bypass -File "$dir\server.ps1" -Port $p
} -ArgumentList $rootDir, $Port

Start-Sleep -Seconds 6
$baseUrl = "http://localhost:$Port"

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
    # Test server health
    $health = Invoke-RestMethod -Uri "$baseUrl/api/health" -Method GET
    Report-Test "Server is responding" ($health.status -eq "ok")

    # Test 1: Unauthorized access to export endpoint is rejected
    Write-Host "`n--- Test Group 1: Security & Authorization ---" -ForegroundColor Yellow
    $unauthBlocked = $false
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/faculty/export-table-files" -Method POST
    } catch {
        $unauthBlocked = ($_.Exception.Response.StatusCode.value__ -eq 403)
    }
    Report-Test "Unauthenticated access rejected with 403 Forbidden" $unauthBlocked

    # Login as student and attempt export (should be rejected)
    $stuLogin = Invoke-RestMethod -Uri "$baseUrl/api/auth/student-login" -Method POST `
        -Body (@{ studentId = "25QM1A66D6" } | ConvertTo-Json) -ContentType "application/json"
    $stuToken = $stuLogin.session.sessionId
    $studentBlocked = $false
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/faculty/export-table-files" -Method POST `
            -Headers @{ "X-Session-Id" = $stuToken }
    } catch {
        $studentBlocked = ($_.Exception.Response.StatusCode.value__ -eq 403)
    }
    Report-Test "Student session access rejected with 403 Forbidden" $studentBlocked

    # Login as authorized faculty
    $facLogin = Invoke-RestMethod -Uri "$baseUrl/api/auth/faculty-login" -Method POST `
        -Body (@{ facultyId = "FAC101"; email = "FAC101@edu.in" } | ConvertTo-Json) -ContentType "application/json"
    $facToken = $facLogin.session.sessionId
    Report-Test "Faculty FAC101 logged in successfully" ($null -ne $facToken)

    # Test 2: Trigger Export Table Files
    Write-Host "`n--- Test Group 2: Table Files Export Execution ---" -ForegroundColor Yellow
    $exportRes = Invoke-RestMethod -Uri "$baseUrl/api/faculty/export-table-files" -Method POST `
        -Headers @{ "X-Session-Id" = $facToken }

    Report-Test "Export API returns success" ($exportRes.success -eq $true)
    Report-Test "Export API returns 5 generated files" ($exportRes.files.Count -eq 5)
    Report-Test "Export directory is returned" (-not [string]::IsNullOrWhiteSpace($exportRes.directory))

    # Test 3: Check exported files on disk
    Write-Host "`n--- Test Group 3: File Inspection in Protected Backend Directory ---" -ForegroundColor Yellow
    $exportDir = Join-Path $rootDir "data\export"
    Report-Test "Protected export directory exists" (Test-Path $exportDir)

    $expectedFiles = @("students.csv", "subjects.csv", "faculty_assignments.csv", "marks.csv", "results.csv")
    foreach ($f in $expectedFiles) {
        $fPath = Join-Path $exportDir $f
        Report-Test "File '$f' exists on disk" (Test-Path $fPath)
        if (Test-Path $fPath) {
            $lines = Get-Content $fPath
            Report-Test "File '$f' has header and content (lines: $($lines.Count))" ($lines.Count -gt 1)
        }
    }

    # Test 4: Verify domain integrity inside CSV files
    Write-Host "`n--- Test Group 4: CSV Content & Domain Integrity Verification ---" -ForegroundColor Yellow

    # Check marks.csv:
    $marksPath = Join-Path $exportDir "marks.csv"
    $marksLines = Get-Content $marksPath
    $marksHeader = $marksLines[0]
    Report-Test "marks.csv header is correct" ($marksHeader -eq "student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status")

    # Check unentered marks are preserved as empty string (missing), NOT converted to 0
    # Let's inspect rows with unentered components
    $hasUnenteredPreservedAsEmpty = $false
    $hasNeverConvertedToZero = $true
    for ($i = 1; $i -lt $marksLines.Count; $i++) {
        $cols = $marksLines[$i].Split(",")
        # internal is cols[4], external is cols[5], total is cols[6], status is cols[7]
        $st = $cols[7]
        if ($st -eq "Not Updated") {
            # Both internal and external must be empty
            if ($cols[4] -eq "" -and $cols[5] -eq "" -and $cols[6] -eq "") {
                $hasUnenteredPreservedAsEmpty = $true
            } else {
                $hasNeverConvertedToZero = $false
            }
        }
    }
    Report-Test "Missing marks preserved as empty string (NULL) in marks.csv" $hasUnenteredPreservedAsEmpty
    Report-Test "Unentered marks are NEVER converted to zero" $hasNeverConvertedToZero

    # Check faculty_assignments.csv: No passwords or secret hashes exposed
    $faPath = Join-Path $exportDir "faculty_assignments.csv"
    $faContent = Get-Content $faPath -Raw
    $hasNoPasswordExposed = (-not ($faContent -match "password" -or $faContent -match "admin123" -or $faContent -match "SHA256"))
    Report-Test "faculty_assignments.csv does NOT expose passwords or password hashes" $hasNoPasswordExposed

    # Check results.csv:
    $resPath = Join-Path $exportDir "results.csv"
    $resLines = Get-Content $resPath
    $resHeader = $resLines[0]
    Report-Test "results.csv header is correct" ($resHeader -eq "student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects")

    # Check that incomplete results show RESULT WITHHELD
    $hasWithheld = $false
    for ($i = 1; $i -lt $resLines.Count; $i++) {
        $cols = $resLines[$i].Split(",")
        if ($cols[5] -eq "RESULT WITHHELD") {
            $hasWithheld = $true
            # total and percentage must be empty when withheld
            if ($cols[3] -ne "" -or $cols[4] -ne "") {
                Report-Test "Withheld results must not expose premature total/percentage" $false
            }
        }
    }
    Report-Test "Incomplete student evaluations are strictly RESULT WITHHELD" $hasWithheld

    # Test 5: Verify protected backend directory is not directly accessible via public web URL
    Write-Host "`n--- Test Group 5: Web Protection Verification ---" -ForegroundColor Yellow
    $webAccessBlocked = $false
    try {
        Invoke-RestMethod -Uri "$baseUrl/data/export/marks.csv" -Method GET
    } catch {
        $webAccessBlocked = ($_.Exception.Response.StatusCode.value__ -eq 404 -or $_.Exception.Response.StatusCode.value__ -eq 403)
    }
    Report-Test "Direct web access to /data/export/marks.csv is blocked (404/403)" $webAccessBlocked

} finally {
    Write-Host "`n--- Stopping test server ---" -ForegroundColor Yellow
    Stop-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Test Results: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==================================================================" -ForegroundColor Cyan

