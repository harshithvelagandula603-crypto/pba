## PowerShell script to verify CSV export sync with DB
$exportDir = "C:\Users\harsh\OneDrive\Desktop\Academic Rsult\data\export"
$dbFile    = "C:\Users\harsh\OneDrive\Desktop\Academic Rsult\data\academic_db.json"

# Load JSON DB
$db = Get-Content -Raw -Path $dbFile | ConvertFrom-Json

function Get-FullyEnteredRows($path) {
    Import-Csv -Path $path | Where-Object { $_.eval_status -eq 'Fully Entered' }
}

$files = @(
    "students.csv",
    "subjects.csv",
    "faculty_assignments.csv",
    "marks.csv",
    "results.csv"
)

foreach ($f in $files) {
    $fullPath = Join-Path $exportDir $f
    $total = (Import-Csv -Path $fullPath).Count
    $fully = (Get-FullyEnteredRows $fullPath).Count
    Write-Host "\n--- $f ---"
    Write-Host "Path: $fullPath"
    Write-Host "Total rows (incl. header): $total"
    Write-Host "Fully Entered rows: $fully"
}

# Sync check for marks
$csvMarks = Get-FullyEnteredRows (Join-Path $exportDir "marks.csv")
$missing = @()
foreach ($row in $csvMarks) {
    $match = $db.marks | Where-Object { $_.studentId -eq $row.student_id -and $_.subjectId -eq $row.subject_id -and $_.internalMarks -eq ($row.internal_marks -as [int]) -and $_.externalMarks -eq ($row.external_marks -as [int]) }
    if (-not $match) { $missing += $row }
}
if ($missing.Count -eq 0) {
    Write-Host "\nAll Fully Entered marks rows are present in the DB."
} else {
    Write-Host "\nMissing in DB: $($missing.Count) rows."
    $missing | Format-Table student_id,subject_id,internal_marks,external_marks
}
