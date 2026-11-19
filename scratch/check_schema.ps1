$db = Get-Content "data/academic_db.json" | ConvertFrom-Json
$records = $db.subjectMarks | Select-Object -First 3
foreach ($m in $records) {
    Write-Host "---"
    $m.PSObject.Properties | ForEach-Object { Write-Host ("  " + $_.Name + " = " + $_.Value) }
}

