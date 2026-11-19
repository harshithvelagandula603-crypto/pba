$db = Get-Content 'data/academic_db.json' -Raw | ConvertFrom-Json
Write-Host "Total marks entries: $($db.subjectMarks.Count)"
$db.subjectMarks | Where-Object { $_.subjectId -eq "DBMS" } | ForEach-Object {
    Write-Host "$($_.studentId) DBMS: Int=$($_.internalMarks), Ext=$($_.externalMarks)"
}
