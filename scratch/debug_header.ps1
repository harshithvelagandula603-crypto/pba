. .\server.ps1 -NoStart

$line = "Subject,Student ID,Internal Marks (40),External Marks (60)"
$tokens = Parse-CsvLine -Line $line
Write-Host "Tokens Count: $($tokens.Count)"

$colSubject = -1
$colStudent = -1
$colInternal = -1
$colExternal = -1

for ($i = 0; $i -lt $tokens.Count; $i++) {
    $low = $tokens[$i].ToLower() -replace '[^a-z0-9_()]', ' '
    Write-Host "Token $($i) '$($tokens[$i])' -> '$low'"
    if (($low -match "subject|course" -or $low.Trim().StartsWith("sub")) -and -not ($low -match "mark")) {
        $colSubject = $i
    } elseif ($low -match "student|sudent|roll" -or $low.Trim() -eq "id" -or $low.Trim() -eq "sid") {
        $colStudent = $i
    } elseif ($low -match "internal" -or $low.Trim().StartsWith("int")) {
        $colInternal = $i
    } elseif ($low -match "external" -or $low.Trim().StartsWith("ext")) {
        $colExternal = $i
    }
}

Write-Host "colSubject: $colSubject"
Write-Host "colStudent: $colStudent"
Write-Host "colInternal: $colInternal"
Write-Host "colExternal: $colExternal"

$dataLine = "DBMS,25QM1A66D6,35,55"
$dtoks = Parse-CsvLine -Line $dataLine
Write-Host "Data Line Toks Count: $($dtoks.Count)"
for ($i = 0; $i -lt $dtoks.Count; $i++) {
    Write-Host "Data $($i) '$($dtoks[$i])'"
}
$subVal = if ($colSubject -ge 0 -and $colSubject -lt $dtoks.Count) { $dtoks[$colSubject].Trim() } else { "" }
$stVal  = if ($colStudent -ge 0 -and $colStudent -lt $dtoks.Count) { $dtoks[$colStudent].Trim() } else { "" }
Write-Host "subVal: '$subVal'"
Write-Host "stVal: '$stVal'"
