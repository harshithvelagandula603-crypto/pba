$marksPath = 'C:\Users\harsh\OneDrive\Desktop\Academic Rsult\data\export\marks.csv'
$marksRows = Import-Csv -Path $marksPath
$fullMarks = $marksRows | Where-Object { $_.eval_status -eq 'Fully Entered' }
Write-Host "Marks CSV FullyEntered count:" $fullMarks.Count

$dbPath = 'C:\Users\harsh\OneDrive\Desktop\Academic Rsult\data\academic_db.json'
$db = Get-Content -Raw -Path $dbPath | ConvertFrom-Json
$fullDb = $db.subjectMarks | Where-Object { $_.evalStatus -eq 'Fully Entered' }
Write-Host "DB FullyEntered count:" $fullDb.Count

# Verify that each FullyEntered DB record exists in CSV (match studentId,subjectId,internalMarks,externalMarks,totalMarks)
$missing = @()
foreach ($rec in $fullDb) {
    $match = $fullMarks | Where-Object {
        $_.student_id -eq $rec.studentId -and
        $_.subject_id -eq $rec.subjectId -and
        $_.internal_marks -eq $rec.internalMarks -and
        $_.external_marks -eq $rec.externalMarks -and
        $_.total_marks -eq $rec.totalMarks
    }
    if (-not $match) { $missing += $rec }
}
if ($missing.Count -eq 0) {
    Write-Host "All FullyEntered DB records are present in marks.csv"
} else {
    Write-Host "Missing ${($missing.Count)} records in marks.csv"
    foreach ($m in $missing) { Write-Host "  $($m.studentId) $($m.subjectId)" }
}

