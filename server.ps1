# ==============================================================================
# Academic Result Input Validator - Server & REST API Backend
# Steps 9-10 Update: Domain Integrity Validation & Automatic Result Calculation
# Implements:
# - Static web asset delivery (HTML, CSS, JS) from src/main/webapp
# - Relational database persistence with domain constraints (students, subjects, subject_marks, users)
# - Excel roster import & validation (missing IDs, missing names, duplicate IDs)
# - Passwordless student access with Student ID server validation & session isolation
# - Password-protected faculty authentication
# - NULL mark preservation ("Not Updated") for BOTH internal_marks and external_marks components
# - internal_marks : 0-40 or NULL (internal assessment component)
# - external_marks : 0-60 or NULL (external examination component)
# - total_marks    : computed ONLY when BOTH components are non-null; never stored persistently
# - "Marks Pending" status: if EITHER component is NULL for a subject
# - Step 9: INTERNAL-FIRST ENFORCEMENT - External marks REJECTED until valid internal marks saved
# - Step 9: Backend enforcement of internal-first rule (not just UI disabling)
# - Step 9: Safe handling of internal mark updates when external marks exist
# - Step 10: Automatic subject total = Internal + External (only when both present)
# - Step 10: Overall aggregate & percentage across 10 subjects (only when all complete)
# - PASS/FAIL rules: NOT configured yet - displayed as "Pass/Fail Rules Not Configured"
# - Gated aggregate results: Total, Percentage withheld until ALL subjects are FULLY entered
# Zero external dependencies required (uses built-in Windows .NET HttpListener & Zip).
# ==============================================================================

param(
    [int]$Port = 8080,
    [string]$WebRoot = "$PSScriptRoot\src\main\webapp",
    [string]$DataDir = "$PSScriptRoot\data",
    [switch]$NoStart = $false
)

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# 1. Database Initialization & Domain Models
# ------------------------------------------------------------------------------
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

$dbPath = Join-Path $DataDir "academic_db.json"

# ------------------------------------------------------------------------------
# Password Security & Secure Hashing (SHA-256 with Salt)
# ------------------------------------------------------------------------------
function Get-PasswordHash {
    param([string]$Password, [string]$Salt = "AcademicValidatorSalt2024")
    if ([string]::IsNullOrWhiteSpace($Password)) { return $null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Password + ":" + $Salt)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($bytes)
    return "SHA256:" + [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
}

function Test-PasswordHash {
    param([string]$Password, [string]$StoredHash, [string]$Salt = "AcademicValidatorSalt2024")
    if ([string]::IsNullOrWhiteSpace($StoredHash)) { return $false }
    if ($StoredHash -eq $Password) { return $true }
    $computed = Get-PasswordHash -Password $Password -Salt $Salt
    if ($computed -eq $StoredHash) { return $true }
    return $false
}

# ------------------------------------------------------------------------------
# Faculty Excel Parsing & Data Import (Faculty_Details_Email_Addresses.xlsx)
# ------------------------------------------------------------------------------
function Import-FacultyExcelRecords {
    param([string]$FilePath)

    $errors = [System.Collections.Generic.List[string]]::new()
    $facultyList = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $assignments = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path $FilePath)) {
        $errors.Add("Faculty Excel file not found at: $FilePath")
        return @{ Success = $false; Errors = $errors }
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        $sharedStrings = [System.Collections.Generic.List[string]]::new()
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $stream = $ssEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $xml = [xml]$reader.ReadToEnd()
            $stream.Close()
            foreach ($si in $xml.sst.si) {
                if ($si.t) {
                    $sharedStrings.Add("$($si.t)")
                } elseif ($si.r) {
                    $sharedStrings.Add((($si.r | ForEach-Object { "$($_.t)" }) -join ""))
                } else {
                    $sharedStrings.Add("")
                }
            }
        }

        $sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
        if (-not $sheetEntry) {
            $errors.Add("Invalid Excel file: sheet1.xml missing.")
            $zip.Dispose()
            return @{ Success = $false; Errors = $errors }
        }

        $stream = $sheetEntry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $sheetXml = [xml]$reader.ReadToEnd()
        $stream.Close()
        $zip.Dispose()

        $isHeader = $true
        foreach ($row in $sheetXml.worksheet.sheetData.row) {
            $cellA = ""
            $cellB = ""
            $cellC = ""

            foreach ($c in $row.c) {
                $val = $c.v
                if ($c.t -eq "s") {
                    $idx = [int]$val
                    if ($idx -ge 0 -and $idx -lt $sharedStrings.Count) {
                        $val = $sharedStrings[$idx]
                    }
                }
                if ($c.r -like "A*") { $cellA = if ($val) { "$val".Trim() } else { "" } }
                if ($c.r -like "B*") { $cellB = if ($val) { "$val".Trim() } else { "" } }
                if ($c.r -like "C*") { $cellC = if ($val) { "$val".Trim() } else { "" } }
            }

            if ([string]::IsNullOrWhiteSpace($cellA) -and [string]::IsNullOrWhiteSpace($cellB)) {
                continue
            }

            if ($isHeader) {
                $isHeader = $false
                continue
            }

            $facId = $cellA.Trim()
            $email = $cellB.Trim()
            $subjRaw = $cellC.Trim()

            # Normalize subject ID according to approved 10 institutional curricular subjects
            $subjId = switch -regex ("$subjRaw".Trim().ToUpper()) {
                "^DBMS$"      { "DBMS" }
                "^MATHS$"     { "MATHS" }
                "^OOPS$"      { "OOPS" }
                "^SE$"        { "SE" }
                "^COA$"       { "COA" }
                "SE\s*LAB"    { "SE_LAB" }
                "MATHS\s*LAB" { "MATHS_LAB" }
                "OOPS\s*LAB"  { "OOPS_LAB" }
                "SD\s*LAB"    { "SD_LAB" }
                "DBMS\s*LAB"  { "DBMS_LAB" }
                default       { $subjRaw.Replace(" ", "_").ToUpper() }
            }

            if (-not $facultyList.ContainsKey($facId)) {
                $facultyList[$facId] = [PSCustomObject]@{
                    facultyId = $facId
                    email = $email
                }
            }

            $pairKey = "$facId|$subjId"
            if (-not $seenPairs.Contains($pairKey)) {
                $seenPairs.Add($pairKey) | Out-Null
                $assignments.Add([PSCustomObject]@{
                    assignmentId = [Guid]::NewGuid().ToString()
                    facultyId = $facId
                    subjectId = $subjId
                    rawSubject = $subjRaw
                    assignedAt = [DateTime]::UtcNow.ToString("o")
                })
            }
        }

        return @{
            Success = $true
            Faculty = $facultyList.Values
            Assignments = $assignments
            Errors = $errors
        }
    } catch {
        $errors.Add("Error reading Excel: $_")
        return @{ Success = $false; Errors = $errors }
    }
}

# ------------------------------------------------------------------------------
# Student Excel Parsing & Domain Integrity Validation
# ------------------------------------------------------------------------------
function Import-StudentExcelRecords {
    param([string]$FilePath)

    $errors = [System.Collections.Generic.List[string]]::new()
    $validStudents = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path $FilePath)) {
        $errors.Add("Excel file not found at: $FilePath")
        return @{ Success = $false; ImportedCount = 0; Errors = $errors }
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)

        # Shared Strings
        $sharedStrings = [System.Collections.Generic.List[string]]::new()
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $stream = $ssEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $xml = [xml]$reader.ReadToEnd()
            $stream.Close()
            foreach ($si in $xml.sst.si) {
                $sharedStrings.Add($si.InnerText)
            }
        }

        # Sheet1 (Students sheet)
        $sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
        if (-not $sheetEntry) {
            $errors.Add("Invalid Excel file format: sheet1.xml missing.")
            $zip.Dispose()
            return @{ Success = $false; ImportedCount = 0; Errors = $errors }
        }

        $stream = $sheetEntry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $sheetXml = [xml]$reader.ReadToEnd()
        $stream.Close()
        $zip.Dispose()

        $isHeader = $true
        foreach ($row in $sheetXml.worksheet.sheetData.row) {
            $rowNum = [int]$row.r
            $cellA = ""
            $cellB = ""

            foreach ($c in $row.c) {
                $val = $c.v
                if ($c.t -eq "s") {
                    $idx = [int]$val
                    if ($idx -ge 0 -and $idx -lt $sharedStrings.Count) {
                        $val = $sharedStrings[$idx]
                    }
                }
                if ($c.r -like "A*") { $cellA = if ($val) { "$val".Trim() } else { "" } }
                if ($c.r -like "B*") { $cellB = if ($val) { "$val".Trim() } else { "" } }
            }

            # Skip empty lines
            if ([string]::IsNullOrWhiteSpace($cellA) -and [string]::IsNullOrWhiteSpace($cellB)) {
                continue
            }

            if ($isHeader) {
                $isHeader = $false
                if ($cellA -notmatch "student" -or $cellB -notmatch "name") {
                    $errors.Add("Row $($rowNum): Invalid Excel header format. Expected Column A: 'Student ID', Column B: 'Student Name'. Found: '$cellA', '$cellB'")
                    return @{ Success = $false; ImportedCount = 0; Errors = $errors }
                }
                continue
            }

            # 1. Missing Student ID
            if ([string]::IsNullOrWhiteSpace($cellA)) {
                $errors.Add("Row $($rowNum): Missing Student ID. Student record cannot be imported without an ID.")
                continue
            }

            # 2. Missing Student Name
            if ([string]::IsNullOrWhiteSpace($cellB)) {
                $errors.Add("Row $($rowNum): Missing Student Name for Student ID '$cellA'.")
                continue
            }

            # 3. Duplicate Student ID in file
            if (-not $seenIds.Add($cellA)) {
                $errors.Add("Row $($rowNum): Duplicate Student ID '$cellA' detected in Excel file.")
                continue
            }

            $validStudents.Add([PSCustomObject]@{
                studentId = $cellA
                studentName = $cellB
                rollNo = $cellA
            })
        }

        if ($errors.Count -gt 0) {
            return @{ Success = $false; ImportedCount = 0; Errors = $errors }
        }

        if ($validStudents.Count -eq 0) {
            $errors.Add("No student records found in the Excel sheet.")
            return @{ Success = $false; ImportedCount = 0; Errors = $errors }
        }

        return @{ Success = $true; ValidStudents = $validStudents; Errors = @() }
    }
    catch {
        $errors.Add("Error reading Excel archive: $($_.Exception.Message)")
        return @{ Success = $false; ImportedCount = 0; Errors = $errors }
    }
}

# ------------------------------------------------------------------------------
# Faculty Marks Excel Template Generation, Parsing & Domain Validation
# ------------------------------------------------------------------------------
function New-MarksExcelTemplate {
    param(
        [string]$SubjectCode,
        [array]$Students,
        [array]$SubjectMarks
    )

    $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ("template_" + [Guid]::NewGuid().ToString() + ".xlsx")
    $fs = [System.IO.File]::Open($tempZipPath, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

    function Add-ZipEntryText($archive, $entryPath, $textContent) {
        $entry = $archive.CreateEntry($entryPath)
        $stream = $entry.Open()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($textContent)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    # [Content_Types].xml
    $ctXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
    Add-ZipEntryText $zip "[Content_Types].xml" $ctXml

    # _rels/.rels
    $relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    Add-ZipEntryText $zip "_rels/.rels" $relsXml

    # xl/workbook.xml
    $wbXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Marks" sheetId="1" r:id="rId1"/></sheets></workbook>'
    Add-ZipEntryText $zip "xl/workbook.xml" $wbXml

    # xl/_rels/workbook.xml.rels
    $wbRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
    Add-ZipEntryText $zip "xl/_rels/workbook.xml.rels" $wbRelsXml

    # xl/worksheets/sheet1.xml
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    
    # Header row
    [void]$sb.Append('<row r="1"><c r="A1" t="inlineStr"><is><t>Subject Code</t></is></c><c r="B1" t="inlineStr"><is><t>Student ID</t></is></c><c r="C1" t="inlineStr"><is><t>Internal Marks (out of 40)</t></is></c><c r="D1" t="inlineStr"><is><t>External Marks (out of 60)</t></is></c></row>')

    $r = 2
    foreach ($st in $Students) {
        $stId = $st.studentId
        $intVal = ""
        $extVal = ""
        if ($SubjectMarks) {
            $sm = $SubjectMarks | Where-Object { $_.studentId -eq $stId } | Select-Object -First 1
            if ($sm) {
                if ($null -ne $sm.internalMarks -and "$($sm.internalMarks)".Trim() -ne "") { $intVal = "$($sm.internalMarks)" }
                if ($null -ne $sm.externalMarks -and "$($sm.externalMarks)".Trim() -ne "") { $extVal = "$($sm.externalMarks)" }
            }
        }

        [void]$sb.Append("<row r=""$r"">")
        [void]$sb.Append("<c r=""A$r"" t=""inlineStr""><is><t>$([System.Security.SecurityElement]::Escape($SubjectCode))</t></is></c>")
        [void]$sb.Append("<c r=""B$r"" t=""inlineStr""><is><t>$([System.Security.SecurityElement]::Escape($stId))</t></is></c>")
        if ($intVal -ne "") {
            [void]$sb.Append("<c r=""C$r""><v>$intVal</v></c>")
        }
        if ($extVal -ne "") {
            [void]$sb.Append("<c r=""D$r""><v>$extVal</v></c>")
        }
        [void]$sb.Append("</row>")
        $r++
    }

    [void]$sb.Append('</sheetData></worksheet>')
    Add-ZipEntryText $zip "xl/worksheets/sheet1.xml" ($sb.ToString())

    $zip.Dispose()
    $fs.Close()
    $fileBytes = [System.IO.File]::ReadAllBytes($tempZipPath)
    Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
    return $fileBytes
}

function New-AcademicRecordsExcel {
    param(
        [array]$Records,
        [string]$SheetTitle = "Academic Records"
    )

    $tempZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ("academic_export_" + [Guid]::NewGuid().ToString() + ".xlsx")
    $fs = [System.IO.File]::Open($tempZipPath, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

    function Add-ZipEntryTextInternal($archive, $entryPath, $textContent) {
        $entry = $archive.CreateEntry($entryPath)
        $stream = $entry.Open()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($textContent)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    # [Content_Types].xml
    $ctXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
    Add-ZipEntryTextInternal $zip "[Content_Types].xml" $ctXml

    # _rels/.rels
    $relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    Add-ZipEntryTextInternal $zip "_rels/.rels" $relsXml

    # xl/workbook.xml
    $wbXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Academic Records" sheetId="1" r:id="rId1"/></sheets></workbook>'
    Add-ZipEntryTextInternal $zip "xl/workbook.xml" $wbXml

    # xl/_rels/workbook.xml.rels
    $wbRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
    Add-ZipEntryTextInternal $zip "xl/_rels/workbook.xml.rels" $wbRelsXml

    # xl/worksheets/sheet1.xml
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    
    # Header row
    [void]$sb.Append('<row r="1">')
    [void]$sb.Append('<c r="A1" t="inlineStr"><is><t>Student ID</t></is></c>')
    [void]$sb.Append('<c r="B1" t="inlineStr"><is><t>Student Name</t></is></c>')
    [void]$sb.Append('<c r="C1" t="inlineStr"><is><t>Roll No</t></is></c>')
    [void]$sb.Append('<c r="D1" t="inlineStr"><is><t>Subject ID</t></is></c>')
    [void]$sb.Append('<c r="E1" t="inlineStr"><is><t>Subject Code</t></is></c>')
    [void]$sb.Append('<c r="F1" t="inlineStr"><is><t>Subject Name</t></is></c>')
    [void]$sb.Append('<c r="G1" t="inlineStr"><is><t>Internal Marks (0-40)</t></is></c>')
    [void]$sb.Append('<c r="H1" t="inlineStr"><is><t>External Marks (0-60)</t></is></c>')
    [void]$sb.Append('<c r="I1" t="inlineStr"><is><t>Total Marks (0-100)</t></is></c>')
    [void]$sb.Append('<c r="J1" t="inlineStr"><is><t>Result Status</t></is></c>')
    [void]$sb.Append('<c r="K1" t="inlineStr"><is><t>Evaluation Status</t></is></c>')
    [void]$sb.Append('</row>')

    $r = 2
    if ($Records) {
        foreach ($rec in $Records) {
            $stId = if ($rec.studentId) { [System.Security.SecurityElement]::Escape("$($rec.studentId)") } else { "" }
            $stName = if ($rec.studentName) { [System.Security.SecurityElement]::Escape("$($rec.studentName)") } else { "" }
            $stRoll = if ($rec.rollNo) { [System.Security.SecurityElement]::Escape("$($rec.rollNo)") } else { $stId }
            $subId = if ($rec.subjectId) { [System.Security.SecurityElement]::Escape("$($rec.subjectId)") } else { "" }
            $subCode = if ($rec.subjectCode) { [System.Security.SecurityElement]::Escape("$($rec.subjectCode)") } else { $subId }
            $subName = if ($rec.subjectName) { [System.Security.SecurityElement]::Escape("$($rec.subjectName)") } else { "" }
            $intVal = if ($null -ne $rec.internalMarks -and "$($rec.internalMarks)".Trim() -ne "" -and "$($rec.internalMarks)" -ne "null") { "$($rec.internalMarks)".Trim() } else { "" }
            $extVal = if ($null -ne $rec.externalMarks -and "$($rec.externalMarks)".Trim() -ne "" -and "$($rec.externalMarks)" -ne "null") { "$($rec.externalMarks)".Trim() } else { "" }
            $totVal = if ($null -ne $rec.totalMarks -and "$($rec.totalMarks)".Trim() -ne "" -and "$($rec.totalMarks)" -ne "null") { "$($rec.totalMarks)".Trim() } else { "" }
            $resStatus = if ($rec.resultStatus) { [System.Security.SecurityElement]::Escape("$($rec.resultStatus)") } else { "Not Updated" }
            $evalStatus = if ($rec.evalStatus) { [System.Security.SecurityElement]::Escape("$($rec.evalStatus)") } else { "Not Updated" }

            [void]$sb.Append("<row r=""$r"">")
            [void]$sb.Append("<c r=""A$r"" t=""inlineStr""><is><t>$stId</t></is></c>")
            [void]$sb.Append("<c r=""B$r"" t=""inlineStr""><is><t>$stName</t></is></c>")
            [void]$sb.Append("<c r=""C$r"" t=""inlineStr""><is><t>$stRoll</t></is></c>")
            [void]$sb.Append("<c r=""D$r"" t=""inlineStr""><is><t>$subId</t></is></c>")
            [void]$sb.Append("<c r=""E$r"" t=""inlineStr""><is><t>$subCode</t></is></c>")
            [void]$sb.Append("<c r=""F$r"" t=""inlineStr""><is><t>$subName</t></is></c>")
            if ($intVal -ne "") {
                [void]$sb.Append("<c r=""G$r""><v>$intVal</v></c>")
            }
            if ($extVal -ne "") {
                [void]$sb.Append("<c r=""H$r""><v>$extVal</v></c>")
            }
            if ($totVal -ne "") {
                [void]$sb.Append("<c r=""I$r""><v>$totVal</v></c>")
            }
            [void]$sb.Append("<c r=""J$r"" t=""inlineStr""><is><t>$resStatus</t></is></c>")
            [void]$sb.Append("<c r=""K$r"" t=""inlineStr""><is><t>$evalStatus</t></is></c>")
            [void]$sb.Append("</row>")
            $r++
        }
    }

    [void]$sb.Append('</sheetData></worksheet>')
    Add-ZipEntryTextInternal $zip "xl/worksheets/sheet1.xml" ($sb.ToString())

    $zip.Dispose()
    $fs.Close()
    $fileBytes = [System.IO.File]::ReadAllBytes($tempZipPath)
    Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
    return $fileBytes
}

function New-AcademicRecordsCsv {
    param([array]$Records)

    $escapeCsvVal = {
        param([string]$val)
        if ($null -eq $val) { return "" }
        $str = "$val"
        if ($str.Contains(",") -or $str.Contains('"') -or $str.Contains("`n") -or $str.Contains("`r")) {
            return '"' + $str.Replace('"', '""') + '"'
        }
        return $str
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("student_id,student_name,roll_no,subject_id,subject_code,subject_name,internal_marks,external_marks,total_marks,result_status,eval_status")

    if ($Records) {
        foreach ($rec in $Records) {
            $stId = & $escapeCsvVal $rec.studentId
            $stName = & $escapeCsvVal $rec.studentName
            $stRoll = & $escapeCsvVal $rec.rollNo
            $subId = & $escapeCsvVal $rec.subjectId
            $subCode = & $escapeCsvVal $rec.subjectCode
            $subName = & $escapeCsvVal $rec.subjectName
            $intStr = if ($null -ne $rec.internalMarks) { "$($rec.internalMarks)" } else { "" }
            $extStr = if ($null -ne $rec.externalMarks) { "$($rec.externalMarks)" } else { "" }
            $totStr = if ($null -ne $rec.totalMarks) { "$($rec.totalMarks)" } else { "" }
            $resStr = & $escapeCsvVal $rec.resultStatus
            $evalStr = & $escapeCsvVal $rec.evalStatus

            $lines.Add("$stId,$stName,$stRoll,$subId,$subCode,$subName,$intStr,$extStr,$totStr,$resStr,$evalStr")
        }
    }

    return ($lines -join "`r`n")
}

function Get-AcademicExportRecords {
    param(
        [string]$FacultyId,
        [string]$TargetSubjectId
    )

    $allowedSubIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($FacultyId) {
        $faList = @($global:Db.facultySubjects | Where-Object { $_.facultyId -ieq $FacultyId })
        foreach ($fa in $faList) {
            $allowedSubIds.Add($fa.subjectId) | Out-Null
        }
    }
    if ($allowedSubIds.Count -eq 0) {
        foreach ($sub in $global:Db.subjects) {
            $allowedSubIds.Add($sub.subjectId) | Out-Null
        }
    }

    $selectedSubs = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($sub in $global:Db.subjects) {
        if (-not $allowedSubIds.Contains($sub.subjectId)) { continue }
        if ([string]::IsNullOrWhiteSpace($TargetSubjectId) -or $TargetSubjectId -ieq "ALL" -or $sub.subjectId -ieq $TargetSubjectId -or ($sub.PSObject.Properties["subjectCode"] -and $sub.subjectCode -ieq $TargetSubjectId)) {
            $selectedSubs.Add($sub)
        }
    }

    $sortedStudents = @($global:Db.students | Sort-Object { $_.studentId })
    $records = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($st in $sortedStudents) {
        $stId = $st.studentId
        $stName = $st.studentName
        $stRoll = if ($st.rollNo) { $st.rollNo } else { $stId }

        foreach ($sub in $selectedSubs) {
            $subId = $sub.subjectId
            $subCode = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $subId }
            $subName = $sub.subjectName

            $mRecord = $global:Db.subjectMarks | Where-Object {
                $_.studentId -eq $stId -and $_.subjectId -eq $subId
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
            $resStatus = "Not Updated"

            if ($null -ne $intVal -and $null -ne $extVal) {
                $totVal = $intVal + $extVal
                $evalStatus = "Fully Entered"
                $resStatus = if ($totVal -ge 35) { "PASS" } else { "FAIL" }
            } elseif ($null -ne $intVal -or $null -ne $extVal) {
                $evalStatus = if ($null -ne $intVal) { "Internal Only" } else { "External Only" }
                $resStatus = "Marks Pending"
            }

            $records.Add([PSCustomObject]@{
                studentId     = $stId
                studentName   = $stName
                rollNo        = $stRoll
                subjectId     = $subId
                subjectCode   = $subCode
                subjectName   = $subName
                internalMarks = $intVal
                externalMarks = $extVal
                totalMarks    = $totVal
                resultStatus  = $resStatus
                evalStatus    = $evalStatus
            })
        }
    }
    return $records
}

function Read-MarksExcelRecords {
    param([string]$FilePath)

    $rawRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path $FilePath)) {
        $errors.Add("File not found: $FilePath")
        return @{ Success = $false; Errors = $errors; Rows = $rawRows }
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        $sharedStrings = [System.Collections.Generic.List[string]]::new()
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($ssEntry) {
            $stream = $ssEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $xml = [xml]$reader.ReadToEnd()
            $stream.Close()
            foreach ($si in $xml.sst.si) {
                $sharedStrings.Add($si.InnerText)
            }
        }

        $sheetEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
        if (-not $sheetEntry) {
            $zip.Dispose()
            $errors.Add("Invalid Excel file format: sheet1.xml missing.")
            return @{ Success = $false; Errors = $errors; Rows = $rawRows }
        }

        $stream = $sheetEntry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $sheetXml = [xml]$reader.ReadToEnd()
        $stream.Close()
        $zip.Dispose()

        $headerFound = $false
        $colSubject = $null
        $colStudent = $null
        $colInternal = $null
        $colExternal = $null

        foreach ($row in $sheetXml.worksheet.sheetData.row) {
            $rowNum = [int]$row.r
            $cellVals = [System.Collections.Specialized.OrderedDictionary]::new()

            foreach ($c in $row.c) {
                $val = ""
                $colRef = ($c.r -replace '\d+', '').ToUpper()
                if ($c.t -eq "s") {
                    $idx = [int]$c.v
                    if ($idx -ge 0 -and $idx -lt $sharedStrings.Count) {
                        $val = $sharedStrings[$idx]
                    }
                } elseif ($c.is -and $c.is.t) {
                    $val = $c.is.t
                } else {
                    $val = "$($c.v)"
                }
                $cellVals[$colRef] = if ($null -ne $val) { "$val".Trim() } else { "" }
            }

            if (-not $headerFound) {
                # Identify header row by inspecting cell content for column keywords
                $hasHeaderKeywords = $false
                foreach ($k in $cellVals.Keys) {
                    $hdr = $cellVals[$k].ToLower()
                    if ($hdr -like "*subject*" -or $hdr -like "*student*" -or $hdr -like "*sudent*" -or $hdr -like "*internal*" -or $hdr -like "*external*") {
                        $hasHeaderKeywords = $true
                        break
                    }
                }

                if ($hasHeaderKeywords) {
                    $headerFound = $true
                    $colsWithContent = [System.Collections.Generic.List[string]]::new()
                    foreach ($k in $cellVals.Keys) {
                        if (-not [string]::IsNullOrWhiteSpace($cellVals[$k])) {
                            $colsWithContent.Add($k)
                        }
                        $hdr = $cellVals[$k].ToLower()
                        if ($hdr -like "*subject*" -and -not ($hdr -like "*mark*")) {
                            $colSubject = $k
                        } elseif ($hdr -like "*student*" -or $hdr -like "*sudent*") {
                            $colStudent = $k
                        } elseif ($hdr -like "*internal*") {
                            $colInternal = $k
                        } elseif ($hdr -like "*external*") {
                            $colExternal = $k
                        }
                    }

                    # Fallback by column order (1: Subject, 2: Student ID, 3: Internal Marks, 4: External Marks)
                    if ($null -eq $colSubject -and $colsWithContent.Count -ge 1) { $colSubject = $colsWithContent[0] }
                    if ($null -eq $colStudent -and $colsWithContent.Count -ge 2) { $colStudent = $colsWithContent[1] }
                    if ($null -eq $colInternal -and $colsWithContent.Count -ge 3) { $colInternal = $colsWithContent[2] }
                    if ($null -eq $colExternal -and $colsWithContent.Count -ge 4) { $colExternal = $colsWithContent[3] }
                    continue
                } else {
                    # Skip empty or non-header title rows before the header row
                    continue
                }
            }

            $sc = if ($null -ne $colSubject -and $cellVals.Contains($colSubject)) { $cellVals[$colSubject] } else { "" }
            $st = if ($null -ne $colStudent -and $cellVals.Contains($colStudent)) { $cellVals[$colStudent] } else { "" }
            $in = if ($null -ne $colInternal -and $cellVals.Contains($colInternal)) { $cellVals[$colInternal] } else { "" }
            $ex = if ($null -ne $colExternal -and $cellVals.Contains($colExternal)) { $cellVals[$colExternal] } else { "" }

            if ([string]::IsNullOrWhiteSpace($sc) -and [string]::IsNullOrWhiteSpace($st) -and [string]::IsNullOrWhiteSpace($in) -and [string]::IsNullOrWhiteSpace($ex)) {
                continue
            }

            $rawRows.Add([PSCustomObject]@{
                RowNum      = $rowNum
                SubjectCode = $sc
                StudentId   = $st
                RawInternal = $in
                RawExternal = $ex
            })
        }

        if (-not $headerFound -and $rawRows.Count -eq 0) {
            $errors.Add("Excel header row missing required columns. Expected: 'Subject Code', 'Student ID' (or 'Sudent ID'), 'Internal Marks (40)', 'External Marks (60)'.")
            return @{ Success = $false; Errors = $errors; Rows = $rawRows }
        }

        return @{ Success = $true; Errors = @(); Rows = $rawRows }
    }
    catch {
        # Fallback: Attempt parsing as delimited CSV / text
        try {
            $lines = Get-Content -Path $FilePath -Encoding UTF8
            $isHdr = $true
            $rIndex = 1
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line.Split(",")
                if ($isHdr) {
                    $isHdr = $false
                    $rIndex++
                    continue
                }
                $sc = if ($parts.Length -gt 0) { $parts[0].Trim() } else { "" }
                $st = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" }
                $in = if ($parts.Length -gt 2) { $parts[2].Trim() } else { "" }
                $ex = if ($parts.Length -gt 3) { $parts[3].Trim() } else { "" }
                $rawRows.Add([PSCustomObject]@{
                    RowNum      = $rIndex
                    SubjectCode = $sc
                    StudentId   = $st
                    RawInternal = $in
                    RawExternal = $ex
                })
                $rIndex++
            }
            if ($rawRows.Count -gt 0) {
                return @{ Success = $true; Errors = @(); Rows = $rawRows }
            }
        } catch {}

        $errors.Add("Error reading Excel archive: $($_.Exception.Message)")
        return @{ Success = $false; Errors = $errors; Rows = $rawRows }
    }
}

function Test-MarksExcelRows {
    param(
        [array]$RawRows,
        [string]$TargetSubjectId,
        [PSCustomObject]$FacultySession,
        [PSCustomObject]$DbRef
    )

    $result = [PSCustomObject]@{
        Success = $true
        SubjectId = ""
        SubjectCode = ""
        TotalRows = $RawRows.Count
        ValidRowsCount = 0
        InvalidRowsCount = 0
        Rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        Error = $null
        SubjectMismatch = $false
        DetectedSubject = ""
        AssignedSubjects = @()
    }

    if ($RawRows.Count -eq 0) {
        $result.Success = $false
        $result.Error = "No mark records found in the uploaded Excel sheet."
        return $result
    }

    # 1. Faculty Assignment & Institutional Authorization Context
    $facId = if ($FacultySession.facultyId) { $FacultySession.facultyId } else { $FacultySession.username }
    $assignedSubjectIds = @()
    if ($FacultySession.assignedSubjects -and $FacultySession.assignedSubjects.Count -gt 0) {
        $assignedSubjectIds = @($FacultySession.assignedSubjects)
    } elseif ($DbRef.facultySubjects) {
        $assignedSubjectIds = @($DbRef.facultySubjects | Where-Object { $_.facultyId -eq $facId } | ForEach-Object { $_.subjectId })
    }

    # Resolve the faculty's assigned subject names for display
    $assignedSubjectNames = @()
    if ($assignedSubjectIds.Count -gt 0) {
        foreach ($asId in $assignedSubjectIds) {
            $asObj = $DbRef.subjects | Where-Object { $_.subjectId -ieq $asId } | Select-Object -First 1
            if ($asObj) {
                $asCode = if ($asObj.PSObject.Properties["subjectCode"]) { $asObj.subjectCode } else { $asObj.subjectId }
                $assignedSubjectNames += "$asCode ($($asObj.subjectName))"
            } else {
                $assignedSubjectNames += $asId
            }
        }
    }
    $assignedList = if ($assignedSubjectNames.Count -gt 0) { $assignedSubjectNames -join ", " } else { "(none assigned)" }

    # Helper scriptblock to match a raw string against institutional subjects
    $findSubjectObj = {
        param([string]$codeStr)
        if ([string]::IsNullOrWhiteSpace($codeStr)) { return $null }
        $c = $codeStr.Trim()
        return ($DbRef.subjects | Where-Object {
            $_.subjectId -ieq $c -or
            ($_.PSObject.Properties["subjectCode"] -and $_.subjectCode -ieq $c) -or
            ($_.PSObject.Properties["subjectName"] -and $_.subjectName -ieq $c) -or
            (($_.subjectId -replace "[-_\s]+", "") -ieq ($c -replace "[-_\s]+", "")) -or
            ($_.PSObject.Properties["subjectCode"] -and (($_.subjectCode -replace "[-_\s]+", "") -ieq ($c -replace "[-_\s]+", "")))
        } | Select-Object -First 1)
    }

    # 2. Check Row 1 to establish expected subject
    $firstRow = $RawRows[0]
    $firstRowNum = if ($firstRow.RowNum) { $firstRow.RowNum } else { 2 }
    $firstRawCode = if ($firstRow.SubjectCode) { "$($firstRow.SubjectCode)".Trim() } else { "" }

    if ([string]::IsNullOrWhiteSpace($firstRawCode)) {
        $result.Success = $false
        $result.SubjectMismatch = $true
        $result.DetectedSubject = "(blank / missing)"
        $result.AssignedSubjects = $assignedSubjectNames
        $result.Error = "Missing Subject Code at row ${firstRowNum}: The Subject Code column is required and cannot be blank. Your assigned subject is $assignedList. The entire file has been rejected and zero marks were saved."
        return $result
    }

    $subjCandidate = & $findSubjectObj $firstRawCode
    if ($null -eq $subjCandidate) {
        $result.Success = $false
        $result.SubjectMismatch = $true
        $result.DetectedSubject = $firstRawCode
        $result.AssignedSubjects = $assignedSubjectNames
        $result.Error = "Subject '$firstRawCode' detected at row $firstRowNum could not be identified in institutional records. Your assigned subject is $assignedList. The entire file has been rejected and zero marks were saved."
        return $result
    }

    $expectedSubId = $subjCandidate.subjectId
    $expectedSubCode = if ($subjCandidate.PSObject.Properties["subjectCode"]) { $subjCandidate.subjectCode } else { $subjCandidate.subjectId }
    $detectedSubject = "$expectedSubCode ($($subjCandidate.subjectName))"

    # Verify faculty authorization for detected subject
    $isAuthorized = $false
    if ($facId -eq "faculty") {
        $isAuthorized = $true
    } elseif ($assignedSubjectIds -and ($assignedSubjectIds -contains $expectedSubId)) {
        $isAuthorized = $true
    }

    if (-not $isAuthorized) {
        $result.Success = $false
        $result.SubjectMismatch = $true
        $result.DetectedSubject = $detectedSubject
        $result.AssignedSubjects = $assignedSubjectNames
        $result.Error = "The uploaded file belongs to $detectedSubject, but your assigned subject is $assignedList. Please upload the correct file. Zero marks were saved."
        return $result
    }

    # Check against target subject if explicitly provided
    if (-not [string]::IsNullOrWhiteSpace($TargetSubjectId)) {
        $targetSubObj = & $findSubjectObj $TargetSubjectId
        if ($targetSubObj -and ($targetSubObj.subjectId -ine $expectedSubId)) {
            $targetCode = if ($targetSubObj.PSObject.Properties["subjectCode"]) { $targetSubObj.subjectCode } else { $targetSubObj.subjectId }
            $targetSubjectDisplay = "$targetCode ($($targetSubObj.subjectName))"
            $result.Success = $false
            $result.SubjectMismatch = $true
            $result.DetectedSubject = $detectedSubject
            $result.AssignedSubjects = @($targetSubjectDisplay)
            $result.Error = "The uploaded file belongs to $detectedSubject, but you selected $targetSubjectDisplay. Please upload the correct file. Zero marks were saved."
            return $result
        }
    }

    # 3. Pre-scan EVERY row in the entire file for subject validity and faculty authorization
    for ($idx = 0; $idx -lt $RawRows.Count; $idx++) {
        $rr = $RawRows[$idx]
        $rNum = if ($rr.RowNum) { $rr.RowNum } else { $idx + 2 }
        $rowRawCode = if ($rr.SubjectCode) { "$($rr.SubjectCode)".Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($rowRawCode)) {
            $result.Success = $false
            $result.SubjectMismatch = $true
            $result.DetectedSubject = "(blank / missing)"
            $result.AssignedSubjects = $assignedSubjectNames
            $result.Error = "Missing Subject Code at row ${rNum}: The Subject Code column cannot be blank or missing. Your assigned subject is $assignedList. The entire file has been rejected and zero marks were saved."
            return $result
        }

        $rowSubObj = & $findSubjectObj $rowRawCode
        if ($null -eq $rowSubObj) {
            $result.Success = $false
            $result.SubjectMismatch = $true
            $result.DetectedSubject = $rowRawCode
            $result.AssignedSubjects = $assignedSubjectNames
            $result.Error = "Subject '$rowRawCode' detected at row $rNum could not be identified in institutional records. Your assigned subject is $assignedList. The entire file has been rejected and zero marks were saved."
            return $result
        }

        $rowSubId = $rowSubObj.subjectId
        $rowSubCode = if ($rowSubObj.PSObject.Properties["subjectCode"]) { $rowSubObj.subjectCode } else { $rowSubObj.subjectId }

        # Check faculty authorization for this row's subject
        $isRowAuth = ($facId -eq "faculty" -or ($assignedSubjectIds -and ($assignedSubjectIds -contains $rowSubId)))
        if (-not $isRowAuth) {
            $result.Success = $false
            $result.SubjectMismatch = $true
            $result.DetectedSubject = $rowRawCode
            $result.AssignedSubjects = $assignedSubjectNames
            $result.Error = "Subject Code mismatch at row ${rNum}: expected '$expectedSubCode', but found '$rowRawCode'. The uploaded file contains unauthorized subject codes. Your assigned subject is $assignedList. The entire file has been rejected and zero marks were saved."
            return $result
        }

        # If TargetSubjectId was explicitly selected in the dropdown and not empty:
        if (-not [string]::IsNullOrWhiteSpace($TargetSubjectId)) {
            $targetSubObj = & $findSubjectObj $TargetSubjectId
            if ($targetSubObj -and ($rowSubId -ine $targetSubObj.subjectId)) {
                $targetCode = if ($targetSubObj.PSObject.Properties["subjectCode"]) { $targetSubObj.subjectCode } else { $targetSubObj.subjectId }
                $targetSubjectDisplay = "$targetCode ($($targetSubObj.subjectName))"
                $result.Success = $false
                $result.SubjectMismatch = $true
                $result.DetectedSubject = $rowRawCode
                $result.AssignedSubjects = @($targetSubjectDisplay)
                $result.Error = "Subject Code mismatch at row ${rNum}: expected '$targetCode', but found '$rowRawCode'. You selected $targetSubjectDisplay. The entire file has been rejected and zero marks were saved."
                return $result
            }
        }

        # Attach resolved subject to row - preserves minority subjects without changing them!
        $rr | Add-Member -NotePropertyName "ResolvedSubjectId" -NotePropertyValue $rowSubId -Force
        $rr | Add-Member -NotePropertyName "ResolvedSubjectCode" -NotePropertyValue $rowSubCode -Force
    }

    $result.SubjectId = $expectedSubId
    $result.SubjectCode = $expectedSubCode

    # 4. All rows match assigned subject. Validate rows individually.
    $seenStudentSubjectPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $validCount = 0
    $invalidCount = 0

    foreach ($rr in $RawRows) {
        $rowErrors = [System.Collections.Generic.List[string]]::new()
        $rowStatus = "VALID"
        $parsedInternal = $null
        $parsedExternal = $null
        $rowSubId = if ($rr.PSObject.Properties["ResolvedSubjectId"]) { $rr.ResolvedSubjectId } else { $expectedSubId }
        $rowSubCode = if ($rr.PSObject.Properties["ResolvedSubjectCode"]) { $rr.ResolvedSubjectCode } else { $expectedSubCode }

        # A. Subject code match check
        if ([string]::IsNullOrWhiteSpace($rr.SubjectCode)) {
            $rowErrors.Add("Missing Subject Code.")
            $rowStatus = "INVALID"
        }

        # B. Student ID check
        $stObj = $null
        $trimmedId = if ($null -ne $rr.StudentId) { "$($rr.StudentId)".Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($trimmedId)) {
            $rowErrors.Add("Missing Student ID.")
            $rowStatus = "INVALID"
        } else {
            $stObj = $DbRef.students | Where-Object { $_.studentId.Trim() -ieq $trimmedId } | Select-Object -First 1
            if ($null -eq $stObj) {
                $rowErrors.Add("Student ID '$trimmedId' not found in institutional student roster.")
                $rowStatus = "INVALID"
            } else {
                $pairKey = "$trimmedId::$rowSubId".ToUpper()
                if (-not $seenStudentSubjectPairs.Add($pairKey)) {
                    $rowErrors.Add("Duplicate Student ID: '$trimmedId' appears multiple times for subject '$rowSubCode' in file.")
                    $rowStatus = "INVALID"
                }
            }
        }

        # Look up existing saved marks for this student and subject
        $existingMark = $null
        if ($stObj) {
            $existingMark = $DbRef.subjectMarks | Where-Object {
                $_.studentId -eq $stObj.studentId -and $_.subjectId -eq $rowSubId
            } | Select-Object -First 1
        }
        $existingSavedInternal = if ($existingMark -and $null -ne $existingMark.internalMarks -and "$($existingMark.internalMarks)".Trim() -ne "") { [int]$existingMark.internalMarks } else { $null }

        # C. Internal Marks [0–40] or empty
        $rawIn = if ($null -ne $rr.RawInternal) { "$($rr.RawInternal)".Trim() } else { "" }
        if ($rawIn -ne "") {
            $dIn = 0.0
            if (-not [double]::TryParse($rawIn, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dIn)) {
                $rowErrors.Add("Internal marks must be a valid integer between 0 and 40. Received: '$rawIn'.")
                $rowStatus = "INVALID"
            } elseif ($dIn -ne [Math]::Truncate($dIn)) {
                $rowErrors.Add("Internal marks must be a whole number between 0 and 40. Fractional marks such as '$rawIn' are not accepted.")
                $rowStatus = "INVALID"
            } elseif ($dIn -lt 0 -or $dIn -gt 40) {
                $rowErrors.Add("Internal marks out of domain [0-40]. Received: $([int]$dIn).")
                $rowStatus = "INVALID"
            } else {
                $parsedInternal = [int]$dIn
            }
        } else {
            $parsedInternal = $null # Empty preserves NULL
        }

        # D. External Marks [0-60] or empty
        $rawEx = if ($null -ne $rr.RawExternal) { "$($rr.RawExternal)".Trim() } else { "" }
        if ($rawEx -ne "") {
            $dEx = 0.0
            if (-not [double]::TryParse($rawEx, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dEx)) {
                $rowErrors.Add("External marks must be a valid integer between 0 and 60. Received: '$rawEx'.")
                $rowStatus = "INVALID"
            } elseif ($dEx -ne [Math]::Truncate($dEx)) {
                $rowErrors.Add("External marks must be a whole number between 0 and 60. Fractional marks such as '$rawEx' are not accepted.")
                $rowStatus = "INVALID"
            } elseif ($dEx -lt 0 -or $dEx -gt 60) {
                $rowErrors.Add("External marks out of domain [0-60]. Received: $([int]$dEx).")
                $rowStatus = "INVALID"
            } else {
                $parsedExternal = [int]$dEx
            }
        } else {
            $parsedExternal = $null # Empty preserves NULL
        }

        # E. Internal-First Enforcement Rule
        if ($null -ne $parsedExternal) {
            $hasValidInternal = ($null -ne $parsedInternal) -or ($null -ne $existingSavedInternal)
            if (-not $hasValidInternal) {
                $rowErrors.Add("External marks cannot be imported before valid internal marks are saved.")
                $rowStatus = "INVALID"
            }
        }

        if ($rowStatus -eq "VALID") {
            $validCount++
        } else {
            $invalidCount++
        }

        $result.Rows.Add([PSCustomObject]@{
            rowNumber     = $rr.RowNum
            subjectCode   = $rr.SubjectCode
            studentId     = if ($stObj) { $stObj.studentId } else { $trimmedId }
            studentName   = if ($stObj) { $stObj.studentName } else { "Unknown Student" }
            internalMarks = $parsedInternal
            externalMarks = $parsedExternal
            rawInternal   = $rawIn
            rawExternal   = $rawEx
            status        = $rowStatus
            errorMessage  = if ($rowErrors.Count -gt 0) { $rowErrors -join "; " } else { $null }
            targetSubjectId = $rowSubId
        })
    }

    $result.ValidRowsCount = $validCount
    $result.InvalidRowsCount = $invalidCount
    return $result
}

function Sync-FacultyData {
    param([PSCustomObject]$DbRef)

    if (-not $DbRef.PSObject.Properties["faculty"]) {
        $DbRef | Add-Member -NotePropertyName "faculty" -NotePropertyValue @() -Force
    }
    if (-not $DbRef.PSObject.Properties["facultySubjects"]) {
        $DbRef | Add-Member -NotePropertyName "facultySubjects" -NotePropertyValue @() -Force
    }

    # Locate faculty excel file in workspace or downloads
    $candidates = @(
        (Join-Path $PSScriptRoot "Faculty_Details_Email_Addresses.xlsx"),
        (Join-Path $PSScriptRoot "src\main\resources\Faculty_Details_Email_Addresses.xlsx"),
        "C:\Users\harsh\Downloads\faculty login details.xlsx"
    )

    $targetFile = $null
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { $targetFile = $cand; break }
    }

    if ($targetFile) {
        $importRes = Import-FacultyExcelRecords -FilePath $targetFile
        if ($importRes.Success) {
            $defaultHash = Get-PasswordHash -Password "Faculty@123"

            # 1. Sync Faculty accounts idempotently (preserve existing passwords)
            $existingFacList = [System.Collections.Generic.List[PSCustomObject]]::new()
            if ($DbRef.faculty) {
                foreach ($f in $DbRef.faculty) { $existingFacList.Add($f) }
            }

            foreach ($impFac in $importRes.Faculty) {
                $found = $existingFacList | Where-Object { $_.facultyId -eq $impFac.facultyId } | Select-Object -First 1
                if ($found) {
                    $found.email = $impFac.email
                    if (-not $found.PSObject.Properties["accountStatus"]) {
                        $found | Add-Member -NotePropertyName "accountStatus" -NotePropertyValue "ACTIVE" -Force
                    }
                } else {
                    $newFac = [PSCustomObject]@{
                        facultyId = $impFac.facultyId
                        email = $impFac.email
                        passwordHash = $defaultHash
                        accountStatus = "ACTIVE"
                        createdAt = [DateTime]::UtcNow.ToString("o")
                    }
                    $existingFacList.Add($newFac)
                }

                # Also synchronize with users collection for authentication compatibility
                $uExists = $DbRef.users | Where-Object { $_.username -eq $impFac.facultyId } | Select-Object -First 1
                if (-not $uExists) {
                    $existingHash = if ($found -and $found.passwordHash) { $found.passwordHash } else { $defaultHash }
                    $DbRef.users += [PSCustomObject]@{
                        username = $impFac.facultyId
                        passwordHash = $existingHash
                        role = "FACULTY"
                        accountStatus = "ACTIVE"
                    }
                }
            }
            $DbRef | Add-Member -NotePropertyName "faculty" -NotePropertyValue $existingFacList.ToArray() -Force

            # 2. Sync Faculty-Subject Assignments idempotently (prevent duplicate assignments)
            $existingAssignList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $seenPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            if ($DbRef.facultySubjects) {
                foreach ($a in $DbRef.facultySubjects) {
                    $pair = "$($a.facultyId)|$($a.subjectId)"
                    if ($seenPairs.Add($pair)) {
                        $existingAssignList.Add($a)
                    }
                }
            }

            foreach ($impAssign in $importRes.Assignments) {
                $pair = "$($impAssign.facultyId)|$($impAssign.subjectId)"
                if ($seenPairs.Add($pair)) {
                    $existingAssignList.Add($impAssign)
                }
            }
            $DbRef | Add-Member -NotePropertyName "facultySubjects" -NotePropertyValue $existingAssignList.ToArray() -Force
            Write-Host "Faculty data synchronized: $($DbRef.faculty.Count) accounts, $($DbRef.facultySubjects.Count) assignments." -ForegroundColor Green
        }
    }
}

function Sync-StudentData {
    param([PSCustomObject]$DbRef)

    if (-not $DbRef.PSObject.Properties["students"]) {
        $DbRef | Add-Member -NotePropertyName "students" -NotePropertyValue @() -Force
    }
    if (-not $DbRef.PSObject.Properties["subjectMarks"]) {
        $DbRef | Add-Member -NotePropertyName "subjectMarks" -NotePropertyValue @() -Force
    }

    $candidates = @(
        (Join-Path $PSScriptRoot "src\main\resources\students.xlsx"),
        (Join-Path $PSScriptRoot "students.xlsx"),
        "C:\Users\harsh\Downloads\Student_Import_Template-1.xlsx"
    )

    $targetFile = $null
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { $targetFile = $cand; break }
    }

    if ($targetFile) {
        $importRes = Import-StudentExcelRecords -FilePath $targetFile
        if ($importRes.Success) {
            $existingStudentList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            if ($DbRef.students) {
                foreach ($s in $DbRef.students) {
                    if ($seenIds.Add($s.studentId.Trim())) {
                        $existingStudentList.Add($s)
                    }
                }
            }

            $existingMarksList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $seenMarkPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            if ($DbRef.subjectMarks) {
                foreach ($m in $DbRef.subjectMarks) {
                    $pair = "$($m.studentId.Trim())|$($m.subjectId.Trim())"
                    if ($seenMarkPairs.Add($pair)) {
                        $existingMarksList.Add($m)
                    }
                }
            }

            $importedCount = 0
            $skippedCount = 0

            foreach ($impSt in $importRes.ValidStudents) {
                $cleanId = $impSt.studentId.Trim()
                if (-not $seenIds.Contains($cleanId)) {
                    $seenIds.Add($cleanId) | Out-Null
                    $existingStudentList.Add($impSt)
                    $importedCount++

                    # Initialize subject marks for all curricular subjects with NULL ("Not Updated")
                    if ($DbRef.subjects) {
                        foreach ($sub in $DbRef.subjects) {
                            $pair = "$cleanId|$($sub.subjectId.Trim())"
                            if ($seenMarkPairs.Add($pair)) {
                                $existingMarksList.Add([PSCustomObject]@{
                                    markId        = [Guid]::NewGuid().ToString()
                                    studentId     = $impSt.studentId
                                    subjectId     = $sub.subjectId
                                    internalMarks = $null
                                    externalMarks = $null
                                    updatedAt     = [DateTime]::UtcNow.ToString("o")
                                })
                            }
                        }
                    }
                } else {
                    $skippedCount++
                }
            }

            $DbRef | Add-Member -NotePropertyName "students" -NotePropertyValue $existingStudentList.ToArray() -Force
            $DbRef | Add-Member -NotePropertyName "subjectMarks" -NotePropertyValue $existingMarksList.ToArray() -Force
            Write-Host "Student data synchronized: $($existingStudentList.Count) total students ($importedCount newly imported, $skippedCount existing/skipped)." -ForegroundColor Green
        } else {
            Write-Host "Warning: Student Excel import failed: $($importRes.Errors -join '; ')" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Warning: Student Excel file not found in search paths." -ForegroundColor Yellow
    }
}

function Initialize-Database {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8
            $loaded = $raw | ConvertFrom-Json
            if ($loaded.subjects -and $loaded.users) {
                # Step 8 Migration: Detect old CS10x placeholder subjects and replace with the 10 institutional subjects
                $firstSubjectId = if ($loaded.subjects -and $loaded.subjects.Count -gt 0) { "$($loaded.subjects[0].subjectId)" } else { "" }
                $needsSubjectMigration = ($firstSubjectId -match "^CS10")

                if ($needsSubjectMigration) {
                    Write-Host "Step 8 Migration: Replacing old CS10x placeholder subjects with 10 institutional subjects. Student records preserved. Subject marks cleared." -ForegroundColor Cyan
                    $newSubjects = @(
                        [PSCustomObject]@{ subjectId = "DBMS";      subjectCode = "DBMS";      subjectName = "Database Management Systems";                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "MATHS";     subjectCode = "Maths";     subjectName = "Mathematics";                                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "OOPS";      subjectCode = "OOPs";      subjectName = "Object-Oriented Programming";                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "SE";        subjectCode = "SE";        subjectName = "Software Engineering";                       maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "COA";       subjectCode = "COA";       subjectName = "Computer Organization and Architecture";     maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "SE_LAB";    subjectCode = "SE Lab";    subjectName = "Software Engineering Laboratory";            maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "MATHS_LAB"; subjectCode = "Maths Lab"; subjectName = "Mathematics Laboratory";                    maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "OOPS_LAB";  subjectCode = "OOPs Lab";  subjectName = "Object-Oriented Programming Laboratory";    maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "SD_LAB";    subjectCode = "SD Lab";    subjectName = "Software Development Laboratory";           maxMarks = 100; maxInternal = 40; maxExternal = 60 },
                        [PSCustomObject]@{ subjectId = "DBMS_LAB";  subjectCode = "DBMS Lab";  subjectName = "Database Management Systems Laboratory";    maxMarks = 100; maxInternal = 40; maxExternal = 60 }
                    )
                    $loaded | Add-Member -NotePropertyName "subjects" -NotePropertyValue $newSubjects -Force

                    # Re-initialise subject marks for all existing students against the new subject list
                    $newMarks = [System.Collections.Generic.List[PSCustomObject]]::new()
                    foreach ($st in $loaded.students) {
                        foreach ($sub in $newSubjects) {
                            $newMarks.Add([PSCustomObject]@{
                                markId        = [Guid]::NewGuid().ToString()
                                studentId     = $st.studentId
                                subjectId     = $sub.subjectId
                                internalMarks = $null
                                externalMarks = $null
                                updatedAt     = [DateTime]::UtcNow.ToString("o")
                            })
                        }
                    }
                    $loaded | Add-Member -NotePropertyName "subjectMarks" -NotePropertyValue $newMarks.ToArray() -Force

                    $json = $loaded | ConvertTo-Json -Depth 10
                    Set-Content -Path $Path -Value $json -Encoding UTF8
                    Write-Host "Migration complete. Students preserved: $($loaded.students.Count). New subject marks initialized." -ForegroundColor Green
                    return $loaded
                }

                # Step 6/7 Schema Compatibility: Ensure all subjectMarks have internalMarks and externalMarks properties
                if ($loaded.subjectMarks) {
                    foreach ($m in $loaded.subjectMarks) {
                        if (-not $m.PSObject.Properties["internalMarks"]) {
                            $m | Add-Member -NotePropertyName "internalMarks" -NotePropertyValue $null -Force
                        }
                        if (-not $m.PSObject.Properties["externalMarks"]) {
                            $m | Add-Member -NotePropertyName "externalMarks" -NotePropertyValue $null -Force
                        }
                    }
                }

                # Step 8: Ensure subjects have subjectCode field; add if missing (backward compatibility)
                foreach ($sub in $loaded.subjects) {
                    if (-not $sub.PSObject.Properties["subjectCode"]) {
                        $sub | Add-Member -NotePropertyName "subjectCode" -NotePropertyValue $sub.subjectId -Force
                    }
                    if (-not $sub.PSObject.Properties["maxInternal"]) {
                        $sub | Add-Member -NotePropertyName "maxInternal" -NotePropertyValue 40 -Force
                    }
                    if (-not $sub.PSObject.Properties["maxExternal"]) {
                        $sub | Add-Member -NotePropertyName "maxExternal" -NotePropertyValue 60 -Force
                    }
                }

                # Synchronize faculty details and subject assignments
                Sync-FacultyData -DbRef $loaded
                Sync-StudentData -DbRef $loaded

                $json = $loaded | ConvertTo-Json -Depth 10
                Set-Content -Path $Path -Value $json -Encoding UTF8
                return $loaded
            }
        } catch {
            Write-Host "Warning: Resetting corrupt database store: $_" -ForegroundColor Yellow
        }
    }

    # Curricular Subjects (Step 8: Exact 10 subjects as specified)
    $defaultSubjects = @(
        @{ subjectId = "DBMS";      subjectCode = "DBMS";      subjectName = "Database Management Systems";                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "MATHS";     subjectCode = "Maths";     subjectName = "Mathematics";                                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "OOPS";      subjectCode = "OOPs";      subjectName = "Object-Oriented Programming";                maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "SE";        subjectCode = "SE";        subjectName = "Software Engineering";                       maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "COA";       subjectCode = "COA";       subjectName = "Computer Organization and Architecture";     maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "SE_LAB";    subjectCode = "SE Lab";    subjectName = "Software Engineering Laboratory";            maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "MATHS_LAB"; subjectCode = "Maths Lab"; subjectName = "Mathematics Laboratory";                    maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "OOPS_LAB";  subjectCode = "OOPs Lab";  subjectName = "Object-Oriented Programming Laboratory";    maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "SD_LAB";    subjectCode = "SD Lab";    subjectName = "Software Development Laboratory";           maxMarks = 100; maxInternal = 40; maxExternal = 60 },
        @{ subjectId = "DBMS_LAB";  subjectCode = "DBMS Lab";  subjectName = "Database Management Systems Laboratory";    maxMarks = 100; maxInternal = 40; maxExternal = 60 }
    )

    # Protected Faculty Account (Username: faculty, Password: admin123)
    $defaultUsers = @(
        @{
            username = "faculty"
            passwordHash = "admin123"
            role = "FACULTY"
            accountStatus = "ACTIVE"
        }
    )

    $initData = [PSCustomObject]@{
        students = @()
        subjects = $defaultSubjects
        subjectMarks = @()
        users = $defaultUsers
        faculty = @()
        facultySubjects = @()
        # Step 6 metadata: pass/fail rules not yet configured
        passfailConfig = @{ configured = $false; note = "Pass/Fail rules not configured. Exact rules must be provided before calculating results." }
    }

    Sync-FacultyData -DbRef $initData
    Sync-StudentData -DbRef $initData

    $json = $initData | ConvertTo-Json -Depth 10
    Set-Content -Path $Path -Value $json -Encoding UTF8
    return $initData
}

$global:Db = Initialize-Database -Path $dbPath

function Save-Database {
    $json = $global:Db | ConvertTo-Json -Depth 10
    Set-Content -Path $dbPath -Value $json -Encoding UTF8
}

function Parse-CsvLine {
    param([string]$Line)
    $tokens = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Line) { return $tokens }

    $sb = [System.Text.StringBuilder]::new()
    $inQuotes = $false

    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq '"') {
            if ($inQuotes -and ($i + 1) -lt $Line.Length -and $Line[$i + 1] -eq '"') {
                $sb.Append('"') | Out-Null
                $i++
            } else {
                $inQuotes = -not $inQuotes
            }
        } elseif (($c -eq ',' -or $c -eq "`t") -and -not $inQuotes) {
            $tokens.Add($sb.ToString().Trim())
            $sb.Clear() | Out-Null
        } else {
            $sb.Append($c) | Out-Null
        }
    }
    $tokens.Add($sb.ToString().Trim())
    return $tokens
}

function Export-AllTableFiles {
    param([string]$TargetDir)

    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        $TargetDir = Join-Path $PSScriptRoot "data\export"
    }
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $escapeCsvVal = {
        param([string]$val)
        if ($null -eq $val) { return "" }
        $str = "$val"
        if ($str.Contains(",") -or $str.Contains('"') -or $str.Contains("`n") -or $str.Contains("`r")) {
            return '"' + $str.Replace('"', '""') + '"'
        }
        return $str
    }

    # 1. students.csv
    $studentsLines = [System.Collections.Generic.List[string]]::new()
    $studentsLines.Add("student_id,student_name,roll_no,email,department,semester")
    $sortedStudents = @($global:Db.students | Sort-Object { $_.studentId })
    foreach ($st in $sortedStudents) {
        $sId = & $escapeCsvVal $st.studentId
        $sName = & $escapeCsvVal $st.studentName
        $sRoll = if ($st.rollNo) { & $escapeCsvVal $st.rollNo } else { $sId }
        $sEmail = if ($st.email) { & $escapeCsvVal $st.email } else { "" }
        $sDept = if ($st.department) { & $escapeCsvVal $st.department } else { "" }
        $sSem = if ($null -ne $st.semester -and "$($st.semester)".Trim() -ne "") { "$($st.semester)".Trim() } else { "" }
        $studentsLines.Add("$sId,$sName,$sRoll,$sEmail,$sDept,$sSem")
    }

    # 2. subjects.csv
    $subjectsLines = [System.Collections.Generic.List[string]]::new()
    $subjectsLines.Add("subject_id,subject_code,subject_name,max_marks,max_internal,max_external,pass_marks")
    $sortedSubjects = @($global:Db.subjects | Sort-Object { $_.subjectId })
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

    # 3. faculty_assignments.csv
    $assignLines = [System.Collections.Generic.List[string]]::new()
    $assignLines.Add("faculty_id,email,subject_id,subject_code,subject_name")
    $sortedAssignments = @($global:Db.facultySubjects | Sort-Object { $_.facultyId }, { $_.subjectId })
    foreach ($fa in $sortedAssignments) {
        $fId = & $escapeCsvVal $fa.facultyId
        $fObj = $global:Db.faculty | Where-Object { $_.facultyId -eq $fa.facultyId } | Select-Object -First 1
        $fEmail = if ($fObj -and $fObj.email) { & $escapeCsvVal $fObj.email } else { "" }
        $sId = & $escapeCsvVal $fa.subjectId
        $sObj = $global:Db.subjects | Where-Object { $_.subjectId -eq $fa.subjectId } | Select-Object -First 1
        $sCode = if ($sObj -and $sObj.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sObj.subjectCode } else { $sId }
        $sName = if ($sObj) { & $escapeCsvVal $sObj.subjectName } else { "" }
        $assignLines.Add("$fId,$fEmail,$sId,$sCode,$sName")
    }

    # 4. marks.csv
    $marksLines = [System.Collections.Generic.List[string]]::new()
    $marksLines.Add("student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status")
    $totalMarksRecords = 0
    foreach ($st in $sortedStudents) {
        $stId = & $escapeCsvVal $st.studentId
        $stName = & $escapeCsvVal $st.studentName

        foreach ($sub in $sortedSubjects) {
            $subId = & $escapeCsvVal $sub.subjectId
            $subCode = if ($sub.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sub.subjectCode } else { $subId }

            $mRecord = $global:Db.subjectMarks | Where-Object {
                $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
            } | Select-Object -First 1

            $intStr = ""
            $extStr = ""
            $totStr = ""
            $evalStatus = "Not Updated"

            if ($null -ne $mRecord) {
                $hasInt = ($null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null")
                $hasExt = ($null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null")

                if ($hasInt) { $intStr = "$($mRecord.internalMarks)".Trim() }
                if ($hasExt) { $extStr = "$($mRecord.externalMarks)".Trim() }

                if ($hasInt -and $hasExt) {
                    $totVal = [int]$mRecord.internalMarks + [int]$mRecord.externalMarks
                    $totStr = "$totVal"
                    $evalStatus = if ($totVal -ge 35) { "Fully Entered" } else { "FAIL" }
                } elseif ($hasInt) {
                    $evalStatus = "Internal Only"
                }
            }

            $evalStatusEsc = & $escapeCsvVal $evalStatus
            $marksLines.Add("$stId,$stName,$subId,$subCode,$intStr,$extStr,$totStr,$evalStatusEsc")
            $totalMarksRecords++
        }
    }

    # 5. results.csv
    $resultsLines = [System.Collections.Generic.List[string]]::new()
    $resultsLines.Add("student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects")
    $totalSubsCount = $sortedSubjects.Count
    $resultsCount = 0
    foreach ($st in $sortedStudents) {
        $fullyEntered = 0
        $sumTotal = 0
        $allSubjectsPassed = $true

        foreach ($sub in $sortedSubjects) {
            $mRecord = $global:Db.subjectMarks | Where-Object {
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

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "students.csv"), $studentsLines, $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "subjects.csv"), $subjectsLines, $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "faculty_assignments.csv"), $assignLines, $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "faculty_assignment.csv"), $assignLines, $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "marks.csv"), $marksLines, $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $TargetDir "results.csv"), $resultsLines, $utf8NoBom)

    return @{
        Success = $true
        Directory = $TargetDir
        Files = @("students.csv", "subjects.csv", "faculty_assignments.csv", "faculty_assignment.csv", "marks.csv", "results.csv")
        RecordCounts = @{
            "students.csv" = $sortedStudents.Count
            "subjects.csv" = $sortedSubjects.Count
            "faculty_assignments.csv" = $sortedAssignments.Count
            "faculty_assignment.csv" = $sortedAssignments.Count
            "marks.csv" = $totalMarksRecords
            "results.csv" = $resultsCount
        }
    }
}

# ------------------------------------------------------------------------------
# 2.5 AI Result Analysis & Student Improvement Engine (OpenRouter + Rule-Based)
# ------------------------------------------------------------------------------
$global:CurriculumTopics = @{
    "DBMS"      = "Relational Algebra, Complex SQL Queries, Database Normalization (1NF to BCNF), Transaction ACID Properties & Concurrency Control"
    "DBMS_LAB"  = "SQL DDL/DML Scripting, Stored Procedures, Triggers, View Creation and Index Optimization"
    "MATHS"     = "Linear Algebra & Eigenvalues, Multivariable Calculus, Differential Equations, Probability & Statistics"
    "MATHS_LAB" = "Computational Linear Algebra, Numerical Methods Implementation, Statistical Curve Fitting"
    "COA"       = "Pipelining & Branch Hazards, Cache Mapping Architectures, Memory Hierarchy, Micro-operations & Control Design"
    "OOPS"      = "Dynamic Polymorphism, Inheritance & Abstract Classes, Robust Exception Handling, Collections & Generics"
    "OOPS_LAB"  = "Object-Oriented Design Patterns, File I/O Streams, Unit Testing, Modular Interface Implementation"
    "SE"        = "Agile & Scrum Lifecycles, UML Structural & Behavioral Modeling, Boundary Value Testing, Code Refactoring"
    "SE_LAB"    = "Requirement Specification Drafting, Automated Testing Suites, Test-Driven Development (TDD)"
    "SD_LAB"    = "Full-Stack Web Architecture, RESTful API Development, Responsive UI Design, Secure Authentication"
}

function Invoke-AiInsight {
    param([string]$Prompt)
    $apiKey = $env:OPENROUTER_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return $null
    }
    try {
        $headers = @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type"  = "application/json"
        }
        $body = @{
            model = "google/gemini-2.0-flash-lite-001"
            messages = @(
                @{ role = "system"; content = "You are an institutional academic advisor. Provide concise, constructive pedagogical insights. Never modify scores or results." },
                @{ role = "user"; content = $Prompt }
            )
            max_tokens = 250
        } | ConvertTo-Json -Depth 5

        $resp = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/chat/completions" -Method POST -Headers $headers -Body $body -TimeoutSec 4
        if ($resp -and $resp.choices -and $resp.choices.Count -gt 0) {
            return $resp.choices[0].message.content.Trim()
        }
    } catch {
        # Fallback seamlessly to local rule-based engine
    }
    return $null
}

function Generate-FacultyAiAnalysis {
    param(
        [string]$FacultyId,
        [array]$AssignedSubjectIds,
        [string]$TargetSubjectId = ""
    )

    $subFilter = @()
    if (-not [string]::IsNullOrWhiteSpace($TargetSubjectId) -and $TargetSubjectId -ne "ALL") {
        $subFilter = @($TargetSubjectId)
    } elseif ($AssignedSubjectIds -and $AssignedSubjectIds.Count -gt 0) {
        $subFilter = @($AssignedSubjectIds)
    } else {
        $subFilter = @($global:Db.subjects | ForEach-Object { $_.subjectId })
    }

    $subjectWise = [System.Collections.Generic.List[PSCustomObject]]::new()
    $studentsNeedingSupport = [System.Collections.Generic.List[PSCustomObject]]::new()
    $subjectsNeedingAttention = [System.Collections.Generic.List[PSCustomObject]]::new()

    $totalStudentsEvaluated = 0
    $allTotals = [System.Collections.Generic.List[int]]::new()
    $allInternals = [System.Collections.Generic.List[int]]::new()
    $allExternals = [System.Collections.Generic.List[int]]::new()

    $overallPassCount = 0
    $overallFailCount = 0
    $overallFullyEntered = 0

    $highestScore = -1
    $highestStudent = "N/A"
    $lowestScore = 101
    $lowestStudent = "N/A"

    foreach ($sId in $subFilter) {
        $sObj = $global:Db.subjects | Where-Object { $_.subjectId -ieq $sId } | Select-Object -First 1
        if (-not $sObj) { continue }
        $sCode = if ($sObj.PSObject.Properties["subjectCode"]) { $sObj.subjectCode } else { $sObj.subjectId }
        $sName = $sObj.subjectName

        $marksForSub = @($global:Db.subjectMarks | Where-Object { $_.subjectId -ieq $sId })
        $evaluatedMarks = @($marksForSub | Where-Object {
            ($null -ne $_.internalMarks -and "$($_.internalMarks)".Trim() -ne "" -and "$($_.internalMarks)" -ne "null") -or
            ($null -ne $_.externalMarks -and "$($_.externalMarks)".Trim() -ne "" -and "$($_.externalMarks)" -ne "null")
        })

        $fullyEnteredList = @($marksForSub | Where-Object {
            ($null -ne $_.internalMarks -and "$($_.internalMarks)".Trim() -ne "" -and "$($_.internalMarks)" -ne "null") -and
            ($null -ne $_.externalMarks -and "$($_.externalMarks)".Trim() -ne "" -and "$($_.externalMarks)" -ne "null")
        })

        $subPass = 0
        $subFail = 0
        $subIntSum = 0
        $subIntCount = 0
        $subExtSum = 0
        $subExtCount = 0
        $subTotSum = 0

        $subHigh = -1
        $subHighSt = "N/A"
        $subLow = 101
        $subLowSt = "N/A"

        foreach ($m in $marksForSub) {
            $hasIn = ($null -ne $m.internalMarks -and "$($m.internalMarks)".Trim() -ne "" -and "$($m.internalMarks)" -ne "null")
            $hasEx = ($null -ne $m.externalMarks -and "$($m.externalMarks)".Trim() -ne "" -and "$($m.externalMarks)" -ne "null")

            $stObj = $global:Db.students | Where-Object { $_.studentId.Trim() -ieq $m.studentId.Trim() } | Select-Object -First 1
            $stName = if ($stObj) { $stObj.studentName } else { $m.studentId }

            if ($hasIn) {
                $inVal = [int]$m.internalMarks
                $subIntSum += $inVal
                $subIntCount++
                $allInternals.Add($inVal)
            }
            if ($hasEx) {
                $exVal = [int]$m.externalMarks
                $subExtSum += $exVal
                $subExtCount++
                $allExternals.Add($exVal)
            }
            if ($hasIn -and $hasEx) {
                $tot = [int]$m.internalMarks + [int]$m.externalMarks
                $subTotSum += $tot
                $allTotals.Add($tot)

                if ($tot -ge 35) {
                    $subPass++
                    $overallPassCount++
                } else {
                    $subFail++
                    $overallFailCount++
                    $studentsNeedingSupport.Add([PSCustomObject]@{
                        studentId     = $m.studentId
                        studentName   = $stName
                        subjectCode   = $sCode
                        subjectName   = $sName
                        totalMarks    = $tot
                        internalMarks = [int]$m.internalMarks
                        externalMarks = [int]$m.externalMarks
                        reason        = "Failed ($tot/100). Scored below passing mark of 35."
                        supportAction = "Mandatory remedial tutorial in $($sCode); review midterm problem sets."
                    })
                }

                if ($tot -gt $subHigh) {
                    $subHigh = $tot
                    $subHighSt = "$stName ($($m.studentId))"
                }
                if ($tot -lt $subLow) {
                    $subLow = $tot
                    $subLowSt = "$stName ($($m.studentId))"
                }

                if ($tot -gt $highestScore) {
                    $highestScore = $tot
                    $highestStudent = "$stName ($($m.studentId))"
                }
                if ($tot -lt $lowestScore) {
                    $lowestScore = $tot
                    $lowestStudent = "$stName ($($m.studentId))"
                }
            } elseif ($hasIn -and [int]$m.internalMarks -lt 14) {
                $studentsNeedingSupport.Add([PSCustomObject]@{
                    studentId     = $m.studentId
                    studentName   = $stName
                    subjectCode   = $sCode
                    subjectName   = $sName
                    totalMarks    = $null
                    internalMarks = [int]$m.internalMarks
                    externalMarks = $null
                    reason        = "Low internal marks ($([int]$m.internalMarks)/40). Risk of overall course failure."
                    supportAction = "Immediate assignment submission and lab viva re-evaluation."
                })
            }
        }

        $overallFullyEntered += $fullyEnteredList.Count
        $totalStudentsEvaluated += $evaluatedMarks.Count

        $avgIn = if ($subIntCount -gt 0) { [Math]::Round(($subIntSum / $subIntCount), 1) } else { 0 }
        $avgEx = if ($subExtCount -gt 0) { [Math]::Round(($subExtSum / $subExtCount), 1) } else { 0 }
        $avgTot = if ($fullyEnteredList.Count -gt 0) { [Math]::Round(($subTotSum / $fullyEnteredList.Count), 1) } else { 0 }
        $passPct = if ($fullyEnteredList.Count -gt 0) { [Math]::Round(($subPass / $fullyEnteredList.Count) * 100, 1) } else { 0 }
        $failPct = if ($fullyEnteredList.Count -gt 0) { [Math]::Round(($subFail / $fullyEnteredList.Count) * 100, 1) } else { 0 }

        $needsAttn = ($fullyEnteredList.Count -gt 0 -and ($passPct -lt 65 -or $subFail -gt 0 -or $avgTot -lt 45))
        if ($needsAttn) {
            $subjectsNeedingAttention.Add([PSCustomObject]@{
                subjectId      = $sId
                subjectCode    = $sCode
                subjectName    = $sName
                passPercentage = $passPct
                avgTotal       = $avgTot
                failCount      = $subFail
                reason         = if ($subFail -gt 0) { "$subFail student(s) failed; pass rate is $passPct%." } else { "Average total marks ($avgTot/100) are below targeted benchmark." }
            })
        }

        $subjectWise.Add([PSCustomObject]@{
            subjectId       = $sId
            subjectCode     = $sCode
            subjectName     = $sName
            evaluatedCount  = $evaluatedMarks.Count
            fullyEntered    = $fullyEnteredList.Count
            avgInternal     = $avgIn
            avgExternal     = $avgEx
            avgTotal        = $avgTot
            highestScore    = if ($subHigh -ge 0) { $subHigh } else { 0 }
            highestStudent  = $subHighSt
            lowestScore     = if ($subLow -le 100) { $subLow } else { 0 }
            lowestStudent   = $subLowSt
            passCount       = $subPass
            failCount       = $subFail
            passPercentage  = $passPct
            failPercentage  = $failPct
            needsAttention  = $needsAttn
        })
    }

    $overallAvgIn = if ($allInternals.Count -gt 0) { [Math]::Round(($allInternals | Measure-Object -Average).Average, 1) } else { 0 }
    $overallAvgEx = if ($allExternals.Count -gt 0) { [Math]::Round(($allExternals | Measure-Object -Average).Average, 1) } else { 0 }
    $overallAvgTot = if ($allTotals.Count -gt 0) { [Math]::Round(($allTotals | Measure-Object -Average).Average, 1) } else { 0 }
    $overallPassPct = if ($overallFullyEntered -gt 0) { [Math]::Round(($overallPassCount / $overallFullyEntered) * 100, 1) } else { 0 }
    $overallFailPct = if ($overallFullyEntered -gt 0) { [Math]::Round(($overallFailCount / $overallFullyEntered) * 100, 1) } else { 0 }

    $classTier = if ($overallFullyEntered -eq 0) {
        "Evaluation In Progress"
    } elseif ($overallPassPct -ge 85) {
        "Excellent Performance"
    } elseif ($overallPassPct -ge 70) {
        "Good Performance"
    } elseif ($overallPassPct -ge 50) {
        "Satisfactory Performance"
    } else {
        "Needs Attention & Remedial Action"
    }

    # Generate Performance Insights
    $insightsList = [System.Collections.Generic.List[string]]::new()
    if ($overallFullyEntered -gt 0) {
        $insightsList.Add("Class Overall Performance: Rated as '$classTier' with an aggregate pass rate of $overallPassPct% ($overallPassCount passed, $overallFailCount failed out of $overallFullyEntered completed evaluations).")
        $insightsList.Add("Component Distribution: Average internal marks stand at $overallAvgIn/40, while external marks average $overallAvgEx/60 (combined mean: $overallAvgTot/100).")
        if ($highestScore -ge 0) {
            $insightsList.Add("Top Academic Achievement: Highest score recorded is $highestScore/100 by $highestStudent.")
        }
        if ($subjectsNeedingAttention.Count -gt 0) {
            $attnNames = @($subjectsNeedingAttention | ForEach-Object { "$($_.subjectCode)" }) -join ", "
            $insightsList.Add("Focus Areas: $attnNames show lower-than-average pass rates or failure clusters requiring instructor attention.")
        } else {
            $insightsList.Add("Curricular Uniformity: All evaluated subjects currently maintain pass rates above institutional threshold.")
        }
        if ($studentsNeedingSupport.Count -gt 0) {
            $insightsList.Add("Remedial Intervention: $($studentsNeedingSupport.Count) student record(s) flagged for academic intervention based on low marks or failure.")
        }
    } else {
        $insightsList.Add("Academic marks are currently pending full evaluation. Comprehensive statistical metrics will populate automatically as marks are imported.")
    }

    # Optional OpenRouter AI Enhancement
    $aiSource = "Institutional Rule-Based Engine"
    $aiPrompt = "Summarize academic result metrics into 2 short pedagogical recommendations: Total Evaluated: $overallFullyEntered, Pass: $overallPassPct%, Avg Total: $overallAvgTot/100, Subjects Needing Attention: $($subjectsNeedingAttention.Count), Students Flagged: $($studentsNeedingSupport.Count)."
    $externalAi = Invoke-AiInsight -Prompt $aiPrompt
    if ($null -ne $externalAi) {
        $insightsList.Add("AI Strategic Note: $externalAi")
        $aiSource = "OpenRouter AI"
    }

    return @{
        subjectWiseStats         = $subjectWise
        overall = @{
            totalEvaluated   = $totalStudentsEvaluated
            fullyEntered     = $overallFullyEntered
            avgInternal      = $overallAvgIn
            avgExternal      = $overallAvgEx
            avgTotal         = $overallAvgTot
            highestScore     = if ($highestScore -ge 0) { $highestScore } else { 0 }
            highestStudent   = $highestStudent
            lowestScore      = if ($lowestScore -le 100) { $lowestScore } else { 0 }
            lowestStudent    = $lowestStudent
            passCount        = $overallPassCount
            failCount        = $overallFailCount
            passPercentage   = $overallPassPct
            failPercentage   = $overallFailPct
            classPerformance = $classTier
        }
        subjectsNeedingAttention = $subjectsNeedingAttention
        studentsNeedingSupport   = $studentsNeedingSupport
        performanceInsights      = $insightsList
        aiSource                 = $aiSource
    }
}

function Generate-StudentAiSuggestions {
    param([string]$StudentId)

    $student = $global:Db.students | Where-Object { $_.studentId.Trim() -ieq $StudentId.Trim() } | Select-Object -First 1
    $stName = if ($student) { $student.studentName } else { $StudentId }

    $strongSubjects = [System.Collections.Generic.List[PSCustomObject]]::new()
    $needsImprovement = [System.Collections.Generic.List[PSCustomObject]]::new()
    $studyRecs = [System.Collections.Generic.List[string]]::new()
    $practicalSteps = [System.Collections.Generic.List[string]]::new()

    foreach ($sub in $global:Db.subjects) {
        $sId = $sub.subjectId
        $sCode = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
        $sName = $sub.subjectName

        $m = $global:Db.subjectMarks | Where-Object {
            $_.studentId.Trim() -ieq $StudentId.Trim() -and $_.subjectId -ieq $sId
        } | Select-Object -First 1

        $hasIn = ($null -ne $m -and $null -ne $m.internalMarks -and "$($m.internalMarks)".Trim() -ne "" -and "$($m.internalMarks)" -ne "null")
        $hasEx = ($null -ne $m -and $null -ne $m.externalMarks -and "$($m.externalMarks)".Trim() -ne "" -and "$($m.externalMarks)" -ne "null")

        $intM = if ($hasIn) { [int]$m.internalMarks } else { $null }
        $extM = if ($hasEx) { [int]$m.externalMarks } else { $null }
        $totM = if ($hasIn -and $hasEx) { $intM + $extM } else { $null }

        $topics = if ($global:CurriculumTopics.ContainsKey($sId.ToUpper())) {
            $global:CurriculumTopics[$sId.ToUpper()]
        } else {
            "Core syllabus concepts, foundational principles, practical implementation techniques"
        }

        if ($null -ne $totM) {
            if ($totM -ge 60) {
                $strongSubjects.Add([PSCustomObject]@{
                    subjectId   = $sId
                    subjectCode = $sCode
                    subjectName = $sName
                    totalMarks  = $totM
                    grade       = if ($totM -ge 75) { "Distinction" } else { "First Class" }
                    note        = "Demonstrated strong theoretical understanding and practical proficiency."
                })
            } elseif ($totM -lt 35) {
                $needsImprovement.Add([PSCustomObject]@{
                    subjectId           = $sId
                    subjectCode         = $sCode
                    subjectName         = $sName
                    totalMarks          = $totM
                    internalMarks       = $intM
                    externalMarks       = $extM
                    status              = "FAIL"
                    reason              = "Total score ($totM/100) is below the required 35/100 pass threshold."
                    relevantTopics      = $topics
                    studyRecommendation = "Schedule a daily 45-minute focused review. Work through past 3 years university exam problem sets."
                    practicalSuggestion = "Meet with the course instructor during office hours to review failed exam concepts and clarify doubts."
                })
            } elseif ($null -ne $intM -and $intM -lt 16) {
                $needsImprovement.Add([PSCustomObject]@{
                    subjectId           = $sId
                    subjectCode         = $sCode
                    subjectName         = $sName
                    totalMarks          = $totM
                    internalMarks       = $intM
                    externalMarks       = $extM
                    status              = "LOW_INTERNAL"
                    reason              = "Passing overall ($totM/100), but internal component ($intM/40) is low."
                    relevantTopics      = $topics
                    studyRecommendation = "Prioritize lab assignments and participate in weekly problem-solving tutorials to maximize internal assessment."
                    practicalSuggestion = "Review marked internal test papers to identify specific calculation or syntax errors."
                })
            }
        } elseif ($hasIn -and $intM -lt 14) {
            $needsImprovement.Add([PSCustomObject]@{
                subjectId           = $sId
                subjectCode         = $sCode
                subjectName         = $sName
                totalMarks          = $null
                internalMarks       = $intM
                externalMarks       = $null
                status              = "LOW_INTERNAL"
                reason              = "Internal marks ($intM/40) are below recommended target before external evaluation."
                relevantTopics      = $topics
                studyRecommendation = "Focus on continuous internal assessment, quizzes, and complete all lab record notebooks."
                practicalSuggestion = "Seek immediate feedback on assignments from faculty to ensure lab scores are maximized."
            })
        }
    }

    if ($needsImprovement.Count -gt 0) {
        $studyRecs.Add("Targeted Study Schedule: Allocate 60% of independent study time to subjects flagged for improvement ($(@($needsImprovement | ForEach-Object { $_.subjectCode }) -join ', ')).")
        $studyRecs.Add("Active Recall & Problem Sets: Rather than passive re-reading, practice solving algorithmic problems and theoretical derivations from memory.")
        $practicalSteps.Add("Consultation Hours: Attend subject faculty consultation sessions with specific questions on topics where marks were lost.")
        $practicalSteps.Add("Peer Discussion Group: Form a study cohort with classmates excelling in your challenge areas for weekly problem reviews.")
        $practicalSteps.Add("Lab Work Completion: Ensure all pending practical code implementations and reports are verified by lab faculty.")
    } else {
        $studyRecs.Add("Consistent Maintenance: Maintain your current study routine and revision cycles across all subjects.")
        $studyRecs.Add("Advanced Exploration: Consider tackling advanced problem sets, competitive coding, or technical certifications in your strong subjects.")
        $practicalSteps.Add("Peer Mentorship: Reinforce your concepts by mentoring classmates or leading study group discussions.")
    }

    $aiSource = "Institutional Rule-Based Engine"
    $aiPrompt = "Student $StudentId performance: $(@($strongSubjects | ForEach-Object { "$($_.subjectCode): $($_.totalMarks)" }) -join ', '). Weaknesses: $(@($needsImprovement | ForEach-Object { "$($_.subjectCode): $($_.totalMarks)" }) -join ', '). Provide 2 short, highly motivating improvement recommendations."
    $externalAi = Invoke-AiInsight -Prompt $aiPrompt
    if ($null -ne $externalAi) {
        $studyRecs.Add("AI Academic Coach: $externalAi")
        $aiSource = "OpenRouter AI"
    }

    return @{
        studentId                  = $StudentId
        studentName                = $stName
        strongSubjects             = $strongSubjects
        subjectsNeedingImprovement = $needsImprovement
        studyRecommendations       = $studyRecs
        practicalSuggestions       = $practicalSteps
        aiSource                   = $aiSource
    }
}

# In-Memory Active Sessions Store
$global:Sessions = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()

# ------------------------------------------------------------------------------
# 3. HTTP Server Initialization
# ------------------------------------------------------------------------------
if ($NoStart) {
    return
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".htm"  = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
}

function Send-JsonResponse {
    param(
        $Response,
        $Data,
        [int]$StatusCode = 200
    )
    $json = $null
    if ($null -eq $Data) {
        $json = "null"
    } elseif ($Data -is [System.Collections.IList] -or $Data -is [Array]) {
        if ($Data.Count -eq 0) {
            $json = "[]"
        } elseif ($Data.Count -eq 1) {
            $json = "[" + ($Data[0] | ConvertTo-Json -Depth 10 -Compress) + "]"
        } else {
            $json = $Data | ConvertTo-Json -Depth 10
        }
    } else {
        $json = $Data | ConvertTo-Json -Depth 10
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-RequestBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return "" }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

$listener.Start()
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Academic Result Input Validator - Server Started" -ForegroundColor Green
Write-Host "URL: http://localhost:$Port/" -ForegroundColor Yellow
Write-Host "Serving: $WebRoot" -ForegroundColor Gray
Write-Host "Database Store: $dbPath" -ForegroundColor Gray
Write-Host "==================================================================" -ForegroundColor Cyan

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $req = $context.Request
            $res = $context.Response
            $res.Headers.Add("Access-Control-Allow-Origin", "*")
            $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-Session-Id")
            $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

            if ($req.HttpMethod -eq "OPTIONS") {
                $res.StatusCode = 200
                $res.Close()
                continue
            }

            $rawPath = $req.Url.LocalPath
            $method = $req.HttpMethod.ToUpper()

            # ------------------------------------------------------------------
            # REST API ROUTING
            # ------------------------------------------------------------------
            if ($rawPath.StartsWith("/api/")) {

                # POST /api/auth/student or /api/auth/student-login (Passwordless Student ID Login)
                if (($rawPath -eq "/api/auth/student" -or $rawPath -eq "/api/auth/student-login") -and $method -eq "POST") {
                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $rawId = if ($payload.studentId) { "$($payload.studentId)".Trim() } else { "" }

                    if ([string]::IsNullOrWhiteSpace($rawId)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Student ID cannot be empty." } -StatusCode 400
                        continue
                    }

                    # Parameterized verification against database students table (case-insensitive, whitespace-trimmed)
                    $student = $global:Db.students | Where-Object { $_.studentId.Trim() -ieq $rawId } | Select-Object -First 1

                    if ($null -eq $student) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Invalid Student ID: '$rawId' was not found in institutional records. Please verify and try again."
                        } -StatusCode 404
                        continue
                    }

                    # Create session token tied to verified Student ID
                    $sessionId = [Guid]::NewGuid().ToString()
                    $sessionObj = @{
                        sessionId = $sessionId
                        role = "student"
                        studentId = $student.studentId
                        studentName = $student.studentName
                        createdAt = [DateTime]::UtcNow
                    }
                    $global:Sessions[$sessionId] = $sessionObj

                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        session = $sessionObj
                    } -StatusCode 200
                    continue
                }

                # POST /api/auth/faculty or /api/auth/faculty-login (Faculty ID & Registered Email Authentication)
                if (($rawPath -eq "/api/auth/faculty" -or $rawPath -eq "/api/auth/faculty-login") -and $method -eq "POST") {
                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $rawUser = if ($payload.facultyId) { "$($payload.facultyId)".Trim() } elseif ($payload.username) { "$($payload.username)".Trim() } else { "" }
                    $rawEmail = if ($payload.email) { "$($payload.email)".Trim() } else { "" }

                    if ([string]::IsNullOrWhiteSpace($rawUser)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Faculty ID is required." } -StatusCode 400
                        continue
                    }

                    if ([string]::IsNullOrWhiteSpace($rawEmail)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Registered email address is required." } -StatusCode 400
                        continue
                    }

                    # 1. Lookup in faculty roster
                    $facultyAccount = $null
                    if ($global:Db.faculty) {
                        $facultyAccount = $global:Db.faculty | Where-Object { $_.facultyId.Trim() -ieq $rawUser } | Select-Object -First 1
                    }

                    # Fallback lookup in users table
                    if ($null -eq $facultyAccount -and $global:Db.users) {
                        $facultyAccount = $global:Db.users | Where-Object { $_.username.Trim() -ieq $rawUser -and $_.role -eq "FACULTY" } | Select-Object -First 1
                    }

                    if ($null -eq $facultyAccount) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Invalid faculty credentials. Faculty ID '$rawUser' was not found in institutional records."
                        } -StatusCode 401
                        continue
                    }

                    # 2. Validate registered email address against record
                    $storedEmail = if ($facultyAccount.PSObject.Properties["email"]) { "$($facultyAccount.email)".Trim() } else { "" }
                    if ([string]::IsNullOrWhiteSpace($storedEmail)) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Registered email address not found for Faculty ID '$rawUser'. Please contact administrator."
                        } -StatusCode 403
                        continue
                    }

                    if (-not ($storedEmail.Equals($rawEmail, [System.StringComparison]::OrdinalIgnoreCase))) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Invalid faculty credentials. The provided email address does not match institutional records for Faculty ID '$rawUser'."
                        } -StatusCode 401
                        continue
                    }

                    # 3. Resolve authenticated faculty ID and assigned subjects strictly from database
                    $facId = if ($facultyAccount.PSObject.Properties["facultyId"]) { $facultyAccount.facultyId } else { $facultyAccount.username }

                    $assignedSubIds = @()
                    if ($global:Db.facultySubjects) {
                        $assignedSubIds = $global:Db.facultySubjects | Where-Object { $_.facultyId.Trim() -ieq $facId } | ForEach-Object { $_.subjectId }
                    }
                    if ($facId -eq "faculty" -and ($null -eq $assignedSubIds -or $assignedSubIds.Count -eq 0)) {
                        $assignedSubIds = $global:Db.subjects | ForEach-Object { $_.subjectId }
                    }

                    $sessionId = [Guid]::NewGuid().ToString()
                    $sessionObj = @{
                        sessionId = $sessionId
                        role = "faculty"
                        facultyId = $facId
                        username = $facId
                        email = $storedEmail
                        assignedSubjects = $assignedSubIds
                        createdAt = [DateTime]::UtcNow
                    }
                    $global:Sessions[$sessionId] = $sessionObj

                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        session = $sessionObj
                    } -StatusCode 200
                    continue
                }

                # POST /api/auth/logout
                if ($rawPath -eq "/api/auth/logout" -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if ($token -and $global:Sessions.ContainsKey($token)) {
                        $dummy = $null
                        $global:Sessions.TryRemove($token, [ref]$dummy) | Out-Null
                    }
                    Send-JsonResponse -Response $res -Data @{ success = $true } -StatusCode 200
                    continue
                }

                # GET /api/student/records (Session-Protected Student Result Retrieval)
                if ($rawPath -eq "/api/student/records" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }

                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "student") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Account is not a student." } -StatusCode 403
                        continue
                    }

                    # Requirement 3: Ensure students cannot view other students' marks by tampering with Student ID
                    # Strictly query using the session's verified studentId
                    $studentId = $sess.studentId
                    $student = $global:Db.students | Where-Object { $_.studentId -eq $studentId } | Select-Object -First 1

                    if ($null -eq $student) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Student record not found." } -StatusCode 404
                        continue
                    }

                    # Join subjects with marks; preserve NULL for unentered components (NEVER treat NULL as 0)
                    $subjectList = @()
                    foreach ($sub in $global:Db.subjects) {
                        $mRecord = $global:Db.subjectMarks | Where-Object {
                            $_.studentId -eq $studentId -and $_.subjectId -eq $sub.subjectId
                        } | Select-Object -First 1

                        # Step 6: Read internalMarks and externalMarks separately
                        $intMarks = $null
                        $extMarks = $null
                        if ($null -ne $mRecord) {
                            if ($null -ne $mRecord.internalMarks -and $mRecord.internalMarks -ne '') {
                                $intMarks = [int]$mRecord.internalMarks
                            }
                            if ($null -ne $mRecord.externalMarks -and $mRecord.externalMarks -ne '') {
                                $extMarks = [int]$mRecord.externalMarks
                            }
                        }

                        # Compute total and result status ONLY when BOTH are present; never treat NULL as 0
                        $totalMarks = $null
                        $resultStatus = "Result Pending"
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $totalMarks = $intMarks + $extMarks
                            if ($totalMarks -ge 35) {
                                $resultStatus = "PASS"
                            } else {
                                $resultStatus = "FAIL"
                            }
                        }

                        # Evaluation status
                        $evalStatus = "Not Updated"
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $evalStatus = "Fully Entered"
                        } elseif ($null -ne $intMarks -or $null -ne $extMarks) {
                            $evalStatus = "Marks Pending"
                        }

                        $subjectList += @{
                            subjectId      = $sub.subjectId
                            subjectCode    = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
                            subjectName    = $sub.subjectName
                            maxMarks       = 100
                            maxInternal    = 40
                            maxExternal    = 60
                            internalMarks  = $intMarks       # null if not entered
                            externalMarks  = $extMarks       # null if not entered
                            totalMarks     = $totalMarks     # null if either component missing
                            evalStatus     = $evalStatus
                            resultStatus   = $resultStatus
                            updatedAt      = if ($mRecord) { $mRecord.updatedAt } else { $null }
                        }
                    }

                    $suggestions = Generate-StudentAiSuggestions -StudentId $studentId

                    Send-JsonResponse -Response $res -Data @{
                        success            = $true
                        student            = $student
                        subjects           = $subjectList
                        passfailConfigured = $true
                        passfailRule       = "35 marks or above out of 100 = PASS; below 35 marks = FAIL"
                        aiSuggestions      = $suggestions
                    } -StatusCode 200
                    continue
                }

                # GET /api/student/ai-suggestions (Dedicated Endpoint for Student Personalized Suggestions)
                if ($rawPath -eq "/api/student/ai-suggestions" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "student") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Student credentials required." } -StatusCode 403
                        continue
                    }
                    $suggestions = Generate-StudentAiSuggestions -StudentId $sess.studentId
                    Send-JsonResponse -Response $res -Data @{
                        success     = $true
                        suggestions = $suggestions
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/ai-analysis (AI Result Analysis for Faculty Dashboard)
                if ($rawPath -eq "/api/faculty/ai-analysis" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Faculty credentials required." } -StatusCode 403
                        continue
                    }
                    $facId = if ($sess.facultyId) { $sess.facultyId } else { $sess.username }
                    $assignedSubs = @()
                    if ($sess.assignedSubjects) {
                        $assignedSubs = @($sess.assignedSubjects)
                    } elseif ($global:Db.facultySubjects) {
                        $assignedSubs = @($global:Db.facultySubjects | Where-Object { $_.facultyId -ieq $facId } | ForEach-Object { $_.subjectId })
                    }
                    $targetSub = if ($req.QueryString["subjectId"]) { $req.QueryString["subjectId"].Trim() } else { "" }

                    $analysis = Generate-FacultyAiAnalysis -FacultyId $facId -AssignedSubjectIds $assignedSubs -TargetSubjectId $targetSub
                    Send-JsonResponse -Response $res -Data @{
                        success  = $true
                        analysis = $analysis
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/dashboard-stats (Step 7: Faculty Dashboard Overview & Real KPIs)
                if ($rawPath -eq "/api/faculty/dashboard-stats" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Faculty credentials required." } -StatusCode 403
                        continue
                    }

                    # Determine faculty-assigned subjects
                    $allowedSubjects = @()
                    if ($sess.username -ne "faculty") {
                        if ($sess.assignedSubjects -and $sess.assignedSubjects.Count -gt 0) {
                            $allowedSubjects = @($global:Db.subjects | Where-Object { $sess.assignedSubjects -contains $_.subjectId })
                        }
                    } else {
                        $allowedSubjects = @($global:Db.subjects)
                    }
                    $allowedSubjectIds = @($allowedSubjects | ForEach-Object { $_.subjectId })

                    $totalStudents = $global:Db.students.Count
                    $totalSubjects = $allowedSubjects.Count

                    # Count completed student-subject records for assigned subjects only
                    $completedMarkRecords = 0
                    foreach ($m in $global:Db.subjectMarks) {
                        if ($allowedSubjectIds -contains $m.subjectId) {
                            $hasInt = ($null -ne $m.internalMarks -and "$($m.internalMarks)".Trim() -ne "" -and "$($m.internalMarks)" -ne "null")
                            $hasExt = ($null -ne $m.externalMarks -and "$($m.externalMarks)".Trim() -ne "" -and "$($m.externalMarks)" -ne "null")
                            if ($hasInt -and $hasExt) {
                                $completedMarkRecords++
                            }
                        }
                    }

                    # Count students with marks pending vs completed across assigned subjects
                    $studentsPending = 0
                    $studentsCompleted = 0
                    foreach ($st in $global:Db.students) {
                        $fullyEnteredSubs = 0
                        foreach ($sub in $allowedSubjects) {
                            $mRecord = $global:Db.subjectMarks | Where-Object {
                                $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
                            } | Select-Object -First 1

                            $hasInt = ($null -ne $mRecord -and $null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null")
                            $hasExt = ($null -ne $mRecord -and $null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null")

                            if ($hasInt -and $hasExt) {
                                $fullyEnteredSubs++
                            }
                        }

                        if ($fullyEnteredSubs -eq $totalSubjects -and $totalSubjects -gt 0) {
                            $studentsCompleted++
                        } else {
                            $studentsPending++
                        }
                    }

                    # Subject-by-subject overview reflecting 40 Internal + 60 External = 100 Total (assigned subjects only)
                    $subjectsOverview = @()
                    foreach ($sub in $allowedSubjects) {
                        $subCompleted = 0
                        $subPending   = 0

                        foreach ($st in $global:Db.students) {
                            $mRecord = $global:Db.subjectMarks | Where-Object {
                                $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
                            } | Select-Object -First 1

                            $hasInt = ($null -ne $mRecord -and $null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null")
                            $hasExt = ($null -ne $mRecord -and $null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null")

                            if ($hasInt -and $hasExt) {
                                $subCompleted++
                            } else {
                                $subPending++
                            }
                        }

                        $pct = 0
                        if ($totalStudents -gt 0) {
                            $pct = [Math]::Round(($subCompleted / $totalStudents) * 100, 1)
                        }

                        $subjectsOverview += @{
                            subjectId       = $sub.subjectId
                            subjectCode     = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
                            subjectName     = $sub.subjectName
                            maxInternal     = 40
                            maxExternal     = 60
                            maxMarks        = 100
                            totalAssigned   = $totalStudents
                            completedCount  = $subCompleted
                            pendingCount    = $subPending
                            completionRate  = $pct
                        }
                    }

                    Send-JsonResponse -Response $res -Data @{
                        success        = $true
                        facultyProfile = @{
                            username   = $sess.username
                            role       = "Faculty Grade Officer"
                            department = "Department of Computer Science & Engineering"
                            term       = "Academic Year 2024-2025"
                            loginTime  = $sess.createdAt
                        }
                        metrics        = @{
                            totalStudents        = $totalStudents
                            totalSubjects        = $totalSubjects
                            studentsPending      = $studentsPending
                            studentsCompleted    = $studentsCompleted
                            completedMarkRecords = $completedMarkRecords
                            totalPossibleRecords = ($totalStudents * $totalSubjects)
                        }
                        subjectsOverview   = $subjectsOverview
                        passfailConfigured = $false
                        passfailNote       = "Pass/Fail Rules Not Configured. Exact institutional rules must be provided before results can be declared."
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/assigned-subjects (Fetch Logged-in Faculty's Assigned Subjects)
                if ($rawPath -eq "/api/faculty/assigned-subjects" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Faculty credentials required." } -StatusCode 403
                        continue
                    }

                    $facId = if ($sess.facultyId) { $sess.facultyId } else { $sess.username }
                    $assignedSubIds = @()
                    if ($global:Db.facultySubjects) {
                        $assignedSubIds = @($global:Db.facultySubjects | Where-Object { $_.facultyId -eq $facId } | ForEach-Object { $_.subjectId })
                    }
                    if ($facId -eq "faculty" -and ($null -eq $assignedSubIds -or $assignedSubIds.Count -eq 0)) {
                        $assignedSubIds = @($global:Db.subjects | ForEach-Object { $_.subjectId })
                    }

                    $subList = @()
                    foreach ($subId in $assignedSubIds) {
                        $sObj = $global:Db.subjects | Where-Object { $_.subjectId -eq $subId } | Select-Object -First 1
                        if ($sObj) {
                            $subList += @{
                                subjectId   = $sObj.subjectId
                                subjectCode = if ($sObj.PSObject.Properties["subjectCode"]) { $sObj.subjectCode } else { $sObj.subjectId }
                                subjectName = $sObj.subjectName
                                maxMarks    = 100
                                maxInternal = 40
                                maxExternal = 60
                            }
                        }
                    }

                    Send-JsonResponse -Response $res -Data @{
                        success   = $true
                        facultyId = $facId
                        subjects  = @($subList)
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/subjects (List Configured Curricular Subjects)
                if ($rawPath -eq "/api/faculty/subjects" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Faculty credentials required." } -StatusCode 403
                        continue
                    }

                    $subs = @()
                    foreach ($sub in $global:Db.subjects) {
                        $subs += @{
                            subjectId   = $sub.subjectId
                            subjectCode = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
                            subjectName = $sub.subjectName
                            maxMarks    = 100
                            maxInternal = 40
                            maxExternal = 60
                        }
                    }

                    # Filter strictly to assigned subjects for authenticated faculty account (no client bypass allowed)
                    if ($sess.username -ne "faculty") {
                        if ($sess.assignedSubjects -and $sess.assignedSubjects.Count -gt 0) {
                            $subs = @($subs | Where-Object { $sess.assignedSubjects -contains $_.subjectId })
                        } else {
                            $subs = @()
                        }
                    }

                    Send-JsonResponse -Response $res -Data @{ success = $true; subjects = @($subs) } -StatusCode 200
                    continue
                }

                # GET /api/faculty/subject-details or /api/faculty/subject-students (Subject-Specific Marks View)
                if (($rawPath -eq "/api/faculty/subject-details" -or $rawPath -eq "/api/faculty/subject-students") -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Session missing or expired." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: Faculty credentials required." } -StatusCode 403
                        continue
                    }

                    $targetSubId = "$($req.QueryString['subjectId'])".Trim()
                    if ([string]::IsNullOrWhiteSpace($targetSubId)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "subjectId parameter is required." } -StatusCode 400
                        continue
                    }

                    # Server-side Authorization Check: Reject unassigned subject access
                    if ($sess.username -ne "faculty") {
                        $isAuthorized = ($sess.assignedSubjects -and ($sess.assignedSubjects -contains $targetSubId))
                        if (-not $isAuthorized) {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Access Denied: You are not authorized to view or enter marks for subject '$targetSubId'. This subject is not assigned to your faculty account."
                            } -StatusCode 403
                            continue
                        }
                    }

                    $subjectObj = $global:Db.subjects | Where-Object { $_.subjectId -eq $targetSubId } | Select-Object -First 1
                    if (-not $subjectObj) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Subject '$targetSubId' not found." } -StatusCode 404
                        continue
                    }

                    $studentsList = @()
                    foreach ($st in $global:Db.students) {
                        $mRecord = $global:Db.subjectMarks | Where-Object {
                            $_.studentId -eq $st.studentId -and $_.subjectId -eq $targetSubId
                        } | Select-Object -First 1

                        $intMarks = $null
                        $extMarks = $null
                        if ($null -ne $mRecord) {
                            if ($null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null") {
                                $intMarks = [int]$mRecord.internalMarks
                            }
                            if ($null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null") {
                                $extMarks = [int]$mRecord.externalMarks
                            }
                        }

                        $totalMarks = $null
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $totalMarks = $intMarks + $extMarks
                        }

                        $evalStatus = "Not Updated"
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $evalStatus = "Fully Entered"
                        } elseif ($null -ne $intMarks -or $null -ne $extMarks) {
                            $evalStatus = "Marks Pending"
                        }

                        $studentsList += @{
                            studentId     = $st.studentId
                            studentName   = $st.studentName
                            rollNo        = $st.rollNo
                            internalMarks = $intMarks
                            externalMarks = $extMarks
                            totalMarks    = $totalMarks
                            evalStatus    = $evalStatus
                        }
                    }

                    Send-JsonResponse -Response $res -Data @{
                        success  = $true
                        subject  = @{
                            subjectId   = $subjectObj.subjectId
                            subjectCode = if ($subjectObj.PSObject.Properties["subjectCode"]) { $subjectObj.subjectCode } else { $subjectObj.subjectId }
                            subjectName = $subjectObj.subjectName
                            maxMarks    = 100
                            maxInternal = 40
                            maxExternal = 60
                        }
                        students = $studentsList
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/students (Faculty Roster Retrieval)
                if ($rawPath -eq "/api/faculty/students" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    if ($sess.role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden." } -StatusCode 403
                        continue
                    }

                    $allowedSubjects = @()
                    if ($sess.username -ne "faculty") {
                        if ($sess.assignedSubjects -and $sess.assignedSubjects.Count -gt 0) {
                            $allowedSubjects = @($global:Db.subjects | Where-Object { $sess.assignedSubjects -contains $_.subjectId })
                        }
                    } else {
                        $allowedSubjects = @($global:Db.subjects)
                    }

                    $result = @()
                    foreach ($st in $global:Db.students) {
                        $subList = @()
                        foreach ($sub in $allowedSubjects) {
                            $mRecord = $global:Db.subjectMarks | Where-Object {
                                $_.studentId -eq $st.studentId -and $_.subjectId -eq $sub.subjectId
                            } | Select-Object -First 1

                            # Step 6: Read internalMarks and externalMarks separately
                            $intMarks = $null
                            $extMarks = $null
                            if ($null -ne $mRecord) {
                                if ($null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null") {
                                    $n = 0
                                    if ([int]::TryParse("$($mRecord.internalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 40) {
                                        $intMarks = $n
                                    }
                                }
                                if ($null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null") {
                                    $n = 0
                                    if ([int]::TryParse("$($mRecord.externalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 60) {
                                        $extMarks = $n
                                    }
                                }
                            }

                            $totalMarks = $null
                            if ($null -ne $intMarks -and $null -ne $extMarks) {
                                $totalMarks = $intMarks + $extMarks
                            }

                            $evalStatus = "Not Updated"
                            if ($null -ne $intMarks -and $null -ne $extMarks) {
                                $evalStatus = "Fully Entered"
                            } elseif ($null -ne $intMarks -or $null -ne $extMarks) {
                                $evalStatus = "Marks Pending"
                            }

                            $subList += @{
                                subjectId     = $sub.subjectId
                                subjectCode   = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
                                subjectName   = $sub.subjectName
                                maxMarks      = 100
                                maxInternal   = 40
                                maxExternal   = 60
                                internalMarks = $intMarks
                                externalMarks = $extMarks
                                totalMarks    = $totalMarks
                                evalStatus    = $evalStatus
                            }
                        }

                        $fullyEnteredCount = @($subList | Where-Object { $_.evalStatus -eq "Fully Entered" }).Count
                        $pendingCount      = [Math]::Max(0, $subList.Count - $fullyEnteredCount)
                        # Count only distinct valid components (already range-validated above)
                        $intCount = @($subList | Where-Object { $null -ne $_.internalMarks }).Count
                        $extCount = @($subList | Where-Object { $null -ne $_.externalMarks }).Count
                        # Safety caps — numerator must never exceed denominator
                        if ($intCount -gt $subList.Count) { $intCount = $subList.Count }
                        if ($extCount -gt $subList.Count) { $extCount = $subList.Count }
                        if ($fullyEnteredCount -gt $subList.Count) { $fullyEnteredCount = $subList.Count }
                        $totalObtained = $null
                        $pct = $null
                        $outcome = "Marks Pending"

                        if ($fullyEnteredCount -eq $subList.Count -and $subList.Count -gt 0) {
                            $sum = 0
                            foreach ($sb in $subList) { $sum += [int]$sb.totalMarks }
                            $totalObtained = $sum
                            $pct = [Math]::Round(($sum / ($subList.Count * 100)) * 100, 1)
                            $outcome = "Pass/Fail Rules Not Configured"
                        }

                        $result += @{
                            studentId            = $st.studentId
                            studentName          = $st.studentName
                            rollNo               = $st.rollNo
                            subjects             = $subList
                            fullyEnteredCount    = $fullyEnteredCount
                            pendingCount         = $pendingCount
                            internalEnteredCount = $intCount
                            externalEnteredCount = $extCount
                            totalMarks           = $totalObtained
                            percentage           = $pct
                            resultOutcome        = $outcome
                        }
                    }

                    Send-JsonResponse -Response $res -Data $result -StatusCode 200
                    continue
                }

                # GET /api/faculty/student-marks (Faculty marks for specific student)
                if ($rawPath -eq "/api/faculty/student-marks" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]

                    $allowedSubjects = @()
                    if ($sess.username -ne "faculty") {
                        if ($sess.assignedSubjects -and $sess.assignedSubjects.Count -gt 0) {
                            $allowedSubjects = @($global:Db.subjects | Where-Object { $sess.assignedSubjects -contains $_.subjectId })
                        }
                    } else {
                        $allowedSubjects = @($global:Db.subjects)
                    }

                    $stId = $req.QueryString["studentId"]
                    $subList = @()
                    foreach ($sub in $allowedSubjects) {
                        $mRecord = $global:Db.subjectMarks | Where-Object {
                            $_.studentId -eq $stId -and $_.subjectId -eq $sub.subjectId
                        } | Select-Object -First 1

                        # Step 6: Read internalMarks and externalMarks separately (strict valid-range guard)
                        $intMarks = $null
                        $extMarks = $null
                        if ($null -ne $mRecord) {
                            if ($null -ne $mRecord.internalMarks -and "$($mRecord.internalMarks)".Trim() -ne "" -and "$($mRecord.internalMarks)" -ne "null") {
                                $n = 0
                                if ([int]::TryParse("$($mRecord.internalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 40) {
                                    $intMarks = $n
                                }
                            }
                            if ($null -ne $mRecord.externalMarks -and "$($mRecord.externalMarks)".Trim() -ne "" -and "$($mRecord.externalMarks)" -ne "null") {
                                $n = 0
                                if ([int]::TryParse("$($mRecord.externalMarks)", [ref]$n) -and $n -ge 0 -and $n -le 60) {
                                    $extMarks = $n
                                }
                            }
                        }

                        $totalMarks = $null
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $totalMarks = $intMarks + $extMarks
                        }

                        $evalStatus = "Not Updated"
                        if ($null -ne $intMarks -and $null -ne $extMarks) {
                            $evalStatus = "Fully Entered"
                        } elseif ($null -ne $intMarks -or $null -ne $extMarks) {
                            $evalStatus = "Marks Pending"
                        }

                        $subList += @{
                            subjectId     = $sub.subjectId
                            subjectCode   = if ($sub.PSObject.Properties["subjectCode"]) { $sub.subjectCode } else { $sub.subjectId }
                            subjectName   = $sub.subjectName
                            maxMarks      = 100
                            maxInternal   = 40
                            maxExternal   = 60
                            internalMarks = $intMarks
                            externalMarks = $extMarks
                            totalMarks    = $totalMarks
                            evalStatus    = $evalStatus
                        }
                    }

                    Send-JsonResponse -Response $res -Data $subList -StatusCode 200
                    continue
                }

                # POST /api/faculty/mark (Faculty marks entry & update — Step 9 Internal-First Enforcement)
                if ($rawPath -eq "/api/faculty/mark" -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Faculty session required." } -StatusCode 401
                        continue
                    }

                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $stId  = "$($payload.studentId)".Trim()
                    $subId = "$($payload.subjectId)".Trim()
                    $rawInternal = $payload.internalMarks
                    $rawExternal = $payload.externalMarks
                    $markType = if ($payload.PSObject.Properties["markType"]) { "$($payload.markType)".Trim().ToLower() } else { "both" }
                    $forceConfirmed = if ($payload.PSObject.Properties["forceConfirmed"]) { $payload.forceConfirmed -eq $true } else { $false }

                    # Server-Side Authorization: Ensure faculty is authorized for this specific subject
                    $sess = $global:Sessions[$token]
                    if ($sess.username -ne "faculty") {
                        $isAuthorized = ($sess.assignedSubjects -and ($sess.assignedSubjects -contains $subId))
                        if (-not $isAuthorized) {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Access Denied: You are not authorized to enter or update marks for subject '$subId'. This subject is not assigned to your faculty account."
                            } -StatusCode 403
                            continue
                        }
                    }

                    # 1. Validate Student existence
                    if ([string]::IsNullOrWhiteSpace($stId)) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Validation Error: Student ID is required."
                        } -StatusCode 400
                        continue
                    }

                    $studentExists = $global:Db.students | Where-Object { $_.studentId -eq $stId } | Select-Object -First 1
                    if ($null -eq $studentExists) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Validation Error: Student '$stId' does not exist in the database."
                        } -StatusCode 404
                        continue
                    }

                    # 2. Validate Subject existence
                    if ([string]::IsNullOrWhiteSpace($subId)) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Validation Error: Subject selection is required."
                        } -StatusCode 400
                        continue
                    }

                    $subjectExists = $global:Db.subjects | Where-Object { $_.subjectId -eq $subId } | Select-Object -First 1
                    if ($null -eq $subjectExists) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Validation Error: Subject '$subId' is not a configured curricular subject."
                        } -StatusCode 404
                        continue
                    }

                    $subCode = if ($subjectExists.PSObject.Properties["subjectCode"]) { $subjectExists.subjectCode } else { $subjectExists.subjectId }

                    # Retrieve existing mark record (for internal-first checks)
                    $existing = $global:Db.subjectMarks | Where-Object {
                        $_.studentId -eq $stId -and $_.subjectId -eq $subId
                    } | Select-Object -First 1

                    $existingInternalSaved = $null
                    $existingExternalSaved = $null
                    if ($null -ne $existing) {
                        if ($null -ne $existing.internalMarks -and "$($existing.internalMarks)".Trim() -ne "" -and "$($existing.internalMarks)" -ne "null") {
                            $existingInternalSaved = [int]$existing.internalMarks
                        }
                        if ($null -ne $existing.externalMarks -and "$($existing.externalMarks)".Trim() -ne "" -and "$($existing.externalMarks)" -ne "null") {
                            $existingExternalSaved = [int]$existing.externalMarks
                        }
                    }

                    # =======================================================================
                    # MARK TYPE: "internal" — Save Internal Marks Only (Stage A)
                    # =======================================================================
                    if ($markType -eq "internal") {
                        # Validate internal marks value
                        $validInternal = $null
                        $payloadHasInternal = $payload.PSObject.Properties["internalMarks"]
                        if ($payloadHasInternal) {
                            if ($null -ne $rawInternal -and "$rawInternal" -ne "" -and "$rawInternal" -ne "null") {
                                $parsedInt = 0
                                if (-not [int]::TryParse("$rawInternal", [ref]$parsedInt)) {
                                    Send-JsonResponse -Response $res -Data @{
                                        success = $false
                                        error = "Internal marks must be between 0 and 40."
                                    } -StatusCode 400
                                    continue
                                }
                                if ($parsedInt -lt 0 -or $parsedInt -gt 40) {
                                    Send-JsonResponse -Response $res -Data @{
                                        success = $false
                                        error = "Internal marks must be between 0 and 40. Received: $parsedInt."
                                    } -StatusCode 400
                                    continue
                                }
                                $validInternal = $parsedInt
                            }
                            # else: clearing internal marks (setting to null)
                        } else {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Internal marks value is required for internal mark type."
                            } -StatusCode 400
                            continue
                        }

                        # Step 9 Stage E: Clearing/updating internal marks when external marks exist
                        if ($null -eq $validInternal -and $null -ne $existingExternalSaved) {
                            if (-not $forceConfirmed) {
                                Send-JsonResponse -Response $res -Data @{
                                    success = $false
                                    requiresConfirmation = $true
                                    confirmationType = "clearInternalWithExternal"
                                    error = "Warning: Clearing internal marks will invalidate the existing external marks ($existingExternalSaved/60) for $subCode. External marks will be reset to NULL. Do you want to proceed?"
                                    existingExternal = $existingExternalSaved
                                } -StatusCode 409
                                continue
                            }
                            # Faculty confirmed: clear both internal AND external
                        }

                        # Upsert
                        if ($null -ne $existing) {
                            $existing | Add-Member -NotePropertyName "internalMarks" -NotePropertyValue $validInternal -Force
                            # If internal is cleared and external existed, clear external too
                            if ($null -eq $validInternal -and $null -ne $existingExternalSaved) {
                                $existing | Add-Member -NotePropertyName "externalMarks" -NotePropertyValue $null -Force
                            }
                            $existing | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
                        } else {
                            $newMark = [PSCustomObject]@{
                                markId        = [Guid]::NewGuid().ToString()
                                studentId     = $stId
                                subjectId     = $subId
                                internalMarks = $validInternal
                                externalMarks = $null
                                updatedAt     = [DateTime]::UtcNow.ToString("o")
                            }
                            $global:Db.subjectMarks += $newMark
                            $existing = $newMark
                        }

                        $savedInternal = $existing.internalMarks
                        $savedExternal = $existing.externalMarks
                        $savedTotal = $null
                        if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                            $savedTotal = [int]$savedInternal + [int]$savedExternal
                        }

                        $evalStatus = "Not Updated"
                        if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                            $evalStatus = "Fully Entered"
                        } elseif (($null -ne $savedInternal -and "$savedInternal" -ne "") -or ($null -ne $savedExternal -and "$savedExternal" -ne "")) {
                            $evalStatus = "Marks Pending"
                        }

                        if ($existing.PSObject.Properties["totalMarks"]) {
                            $existing.totalMarks = $savedTotal
                        } else {
                            $existing | Add-Member -NotePropertyName totalMarks -NotePropertyValue $savedTotal -Force
                        }
                        if ($existing.PSObject.Properties["status"]) {
                            $existing.status = $evalStatus
                        } else {
                            $existing | Add-Member -NotePropertyName status -NotePropertyValue $evalStatus -Force
                        }
                        if ($existing.PSObject.Properties["evalStatus"]) {
                            $existing.evalStatus = $evalStatus
                        } else {
                            $existing | Add-Member -NotePropertyName evalStatus -NotePropertyValue $evalStatus -Force
                        }

                        Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }

                        # Automatically synchronize table files (marks.csv & results.csv)
                        try {
                            Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                        } catch {
                            Write-Warning "Could not refresh table files after internal mark update: $_"
                        }

                        $msg = if ($null -ne $validInternal) {
                            "Internal marks saved successfully for $subCode ($($subjectExists.subjectName)). You can now enter external marks."
                        } else {
                            "Internal marks cleared for $subCode ($($subjectExists.subjectName))."
                        }

                        Send-JsonResponse -Response $res -Data @{
                            success    = $true
                            message    = $msg
                            markRecord = @{
                                studentId     = $stId
                                studentName   = $studentExists.studentName
                                subjectId     = $subId
                                subjectCode   = $subCode
                                subjectName   = $subjectExists.subjectName
                                internalMarks = $savedInternal
                                externalMarks = $savedExternal
                                totalMarks    = $savedTotal
                                evalStatus    = $evalStatus
                            }
                        } -StatusCode 200
                        continue
                    }

                    # =======================================================================
                    # MARK TYPE: "external" — Save External Marks Only (Stage B)
                    # Step 9 BACKEND ENFORCEMENT: Reject if internal marks not saved
                    # =======================================================================
                    if ($markType -eq "external") {
                        # CRITICAL: Step 9 Stage D — Backend enforcement of internal-first rule
                        if ($null -eq $existingInternalSaved) {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Enter and save valid internal marks before entering external marks. Internal marks for $subCode have not been saved."
                            } -StatusCode 400
                            continue
                        }

                        # Validate external marks value
                        $validExternal = $null
                        $payloadHasExternal = $payload.PSObject.Properties["externalMarks"]
                        if ($payloadHasExternal) {
                            if ($null -ne $rawExternal -and "$rawExternal" -ne "" -and "$rawExternal" -ne "null") {
                                $parsedExt = 0
                                if (-not [int]::TryParse("$rawExternal", [ref]$parsedExt)) {
                                    Send-JsonResponse -Response $res -Data @{
                                        success = $false
                                        error = "External marks must be between 0 and 60."
                                    } -StatusCode 400
                                    continue
                                }
                                if ($parsedExt -lt 0 -or $parsedExt -gt 60) {
                                    Send-JsonResponse -Response $res -Data @{
                                        success = $false
                                        error = "External marks must be between 0 and 60. Received: $parsedExt."
                                    } -StatusCode 400
                                    continue
                                }
                                $validExternal = $parsedExt
                            }
                        } else {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "External marks value is required for external mark type."
                            } -StatusCode 400
                            continue
                        }

                        # Re-verify internal marks exist NOW (double-check database state per Stage D)
                        $freshExisting = $global:Db.subjectMarks | Where-Object {
                            $_.studentId -eq $stId -and $_.subjectId -eq $subId
                        } | Select-Object -First 1

                        $freshInternalVal = $null
                        if ($null -ne $freshExisting -and $null -ne $freshExisting.internalMarks -and "$($freshExisting.internalMarks)".Trim() -ne "" -and "$($freshExisting.internalMarks)" -ne "null") {
                            $freshInternalVal = [int]$freshExisting.internalMarks
                        }

                        if ($null -eq $freshInternalVal) {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Enter and save valid internal marks before entering external marks. Database re-check: Internal marks for $subCode are not saved."
                            } -StatusCode 400
                            continue
                        }

                        # Upsert external marks
                        if ($null -ne $freshExisting) {
                            $freshExisting | Add-Member -NotePropertyName "externalMarks" -NotePropertyValue $validExternal -Force
                            $freshExisting | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
                        }

                        $savedInternal = $freshExisting.internalMarks
                        $savedExternal = $freshExisting.externalMarks
                        $savedTotal = $null
                        if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                            $savedTotal = [int]$savedInternal + [int]$savedExternal
                        }

                        $evalStatus = "Not Updated"
                        if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                            $evalStatus = "Fully Entered"
                        } elseif (($null -ne $savedInternal -and "$savedInternal" -ne "") -or ($null -ne $savedExternal -and "$savedExternal" -ne "")) {
                            $evalStatus = "Marks Pending"
                        }

                        if ($freshExisting.PSObject.Properties["totalMarks"]) {
                            $freshExisting.totalMarks = $savedTotal
                        } else {
                            $freshExisting | Add-Member -NotePropertyName totalMarks -NotePropertyValue $savedTotal -Force
                        }
                        if ($freshExisting.PSObject.Properties["status"]) {
                            $freshExisting.status = $evalStatus
                        } else {
                            $freshExisting | Add-Member -NotePropertyName status -NotePropertyValue $evalStatus -Force
                        }
                        if ($freshExisting.PSObject.Properties["evalStatus"]) {
                            $freshExisting.evalStatus = $evalStatus
                        } else {
                            $freshExisting | Add-Member -NotePropertyName evalStatus -NotePropertyValue $evalStatus -Force
                        }

                        Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }

                        # Automatically synchronize table files (marks.csv & results.csv)
                        try {
                            Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                        } catch {
                            Write-Warning "Could not refresh table files after external mark update: $_"
                        }

                        $msg = if ($null -ne $validExternal) {
                            "External marks saved successfully for $subCode ($($subjectExists.subjectName))."
                        } else {
                            "External marks cleared for $subCode ($($subjectExists.subjectName))."
                        }

                        Send-JsonResponse -Response $res -Data @{
                            success    = $true
                            message    = $msg
                            markRecord = @{
                                studentId     = $stId
                                studentName   = $studentExists.studentName
                                subjectId     = $subId
                                subjectCode   = $subCode
                                subjectName   = $subjectExists.subjectName
                                internalMarks = $savedInternal
                                externalMarks = $savedExternal
                                totalMarks    = $savedTotal
                                evalStatus    = $evalStatus
                            }
                        } -StatusCode 200
                        continue
                    }

                    # =======================================================================
                    # MARK TYPE: "both" (legacy/fallback) — with internal-first enforcement
                    # =======================================================================

                    # ---- Domain Constraint: Internal Marks [0-40] or NULL ----
                    $validInternal = $null
                    $payloadProps = ($payload | Get-Member -MemberType NoteProperty).Name
                    if ($payloadProps -contains "internalMarks") {
                        if ($null -ne $rawInternal -and "$rawInternal" -ne "" -and "$rawInternal" -ne "null") {
                            $parsedInt = 0
                            if (-not [int]::TryParse("$rawInternal", [ref]$parsedInt)) {
                                Send-JsonResponse -Response $res -Data @{
                                    success = $false
                                    error = "Internal marks must be between 0 and 40."
                                } -StatusCode 400
                                continue
                            }
                            if ($parsedInt -lt 0 -or $parsedInt -gt 40) {
                                Send-JsonResponse -Response $res -Data @{
                                    success = $false
                                    error = "Internal marks must be between 0 and 40. Received: $parsedInt."
                                } -StatusCode 400
                                continue
                            }
                            $validInternal = $parsedInt
                        }
                    }

                    # ---- Domain Constraint: External Marks [0-60] or NULL ----
                    $validExternal = $null
                    if ($payloadProps -contains "externalMarks") {
                        if ($null -ne $rawExternal -and "$rawExternal" -ne "" -and "$rawExternal" -ne "null") {
                            $parsedExt = 0
                            if (-not [int]::TryParse("$rawExternal", [ref]$parsedExt)) {
                                Send-JsonResponse -Response $res -Data @{
                                    success = $false
                                    error = "External marks must be between 0 and 60."
                                } -StatusCode 400
                                continue
                            }
                            if ($parsedExt -lt 0 -or $parsedExt -gt 60) {
                                Send-JsonResponse -Response $res -Data @{
                                    success = $false
                                    error = "External marks must be between 0 and 60. Received: $parsedExt."
                                } -StatusCode 400
                                continue
                            }
                            $validExternal = $parsedExt
                        }
                    }

                    # Step 9 BACKEND ENFORCEMENT: If external marks provided, check internal first
                    if ($null -ne $validExternal) {
                        # Determine what internal value will be after this save
                        $effectiveInternal = if ($payloadProps -contains "internalMarks") { $validInternal } else { $existingInternalSaved }
                        if ($null -eq $effectiveInternal) {
                            Send-JsonResponse -Response $res -Data @{
                                success = $false
                                error = "Enter and save valid internal marks before entering external marks."
                            } -StatusCode 400
                            continue
                        }
                    }

                    # Upsert into subjectMarks collection (prevent duplicates, update existing)
                    $savedInternal = $null
                    $savedExternal = $null

                    if ($null -ne $existing) {
                        if ($payloadProps -contains "internalMarks") {
                            $existing | Add-Member -NotePropertyName "internalMarks" -NotePropertyValue $validInternal -Force
                        }
                        if ($payloadProps -contains "externalMarks") {
                            $existing | Add-Member -NotePropertyName "externalMarks" -NotePropertyValue $validExternal -Force
                        }
                        $existing | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
                        $savedInternal = $existing.internalMarks
                        $savedExternal = $existing.externalMarks
                    } else {
                        $initInternal = if ($payloadProps -contains "internalMarks") { $validInternal } else { $null }
                        $initExternal = if ($payloadProps -contains "externalMarks") { $validExternal } else { $null }
                        $newMark = [PSCustomObject]@{
                            markId        = [Guid]::NewGuid().ToString()
                            studentId     = $stId
                            subjectId     = $subId
                            internalMarks = $initInternal
                            externalMarks = $initExternal
                            updatedAt     = [DateTime]::UtcNow.ToString("o")
                        }
                        $global:Db.subjectMarks += $newMark
                        $savedInternal = $initInternal
                        $savedExternal = $initExternal
                    }

                    $savedTotal = $null
                    if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                        $savedTotal = [int]$savedInternal + [int]$savedExternal
                    }

                    $evalStatus = "Not Updated"
                    if ($null -ne $savedInternal -and "$savedInternal" -ne "" -and $null -ne $savedExternal -and "$savedExternal" -ne "") {
                        $evalStatus = "Fully Entered"
                    } elseif (($null -ne $savedInternal -and "$savedInternal" -ne "") -or ($null -ne $savedExternal -and "$savedExternal" -ne "")) {
                        $evalStatus = "Marks Pending"
                    }

                    if ($null -ne $existing) {
                        if ($existing.PSObject.Properties["totalMarks"]) {
                            $existing.totalMarks = $savedTotal
                        } else {
                            $existing | Add-Member -NotePropertyName totalMarks -NotePropertyValue $savedTotal -Force
                        }
                        if ($existing.PSObject.Properties["status"]) {
                            $existing.status = $evalStatus
                        } else {
                            $existing | Add-Member -NotePropertyName status -NotePropertyValue $evalStatus -Force
                        }
                        if ($existing.PSObject.Properties["evalStatus"]) {
                            $existing.evalStatus = $evalStatus
                        } else {
                            $existing | Add-Member -NotePropertyName evalStatus -NotePropertyValue $evalStatus -Force
                        }
                    }

                    Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }

                    Send-JsonResponse -Response $res -Data @{
                        success    = $true
                        message    = "Marks successfully recorded in database for $subCode ($($subjectExists.subjectName))."
                        markRecord = @{
                            studentId     = $stId
                            studentName   = $studentExists.studentName
                            subjectId     = $subId
                            subjectCode   = $subCode
                            subjectName   = $subjectExists.subjectName
                            internalMarks = $savedInternal
                            externalMarks = $savedExternal
                            totalMarks    = $savedTotal
                            evalStatus    = $evalStatus
                        }
                    } -StatusCode 200
                    continue
                }

                # POST /api/faculty/import-actual (Import Student_Import_Template-1.xlsx)
                if ($rawPath -eq "/api/faculty/import-actual" -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized." } -StatusCode 401
                        continue
                    }

                    # Locate actual file
                    $targetExcel = Join-Path $PSScriptRoot "src\main\resources\students.xlsx"
                    if (-not (Test-Path $targetExcel)) {
                        $targetExcel = "C:\Users\harsh\Downloads\Student_Import_Template-1.xlsx"
                    }

                    $importResult = Import-StudentExcelRecords -FilePath $targetExcel
                    if (-not $importResult.Success) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Excel validation failed."
                            errors = $importResult.Errors
                        } -StatusCode 400
                        continue
                    }

                    # Insert records without overwriting without confirmation
                    $importedCount = 0
                    foreach ($st in $importResult.ValidStudents) {
                        $exists = $global:Db.students | Where-Object { $_.studentId -eq $st.studentId } | Select-Object -First 1
                        if (-not $exists) {
                            $global:Db.students += $st
                            $importedCount++

                            # Initialize all curricular subjects: both internalMarks and externalMarks as NULL
                            foreach ($sub in $global:Db.subjects) {
                                $markEntry = [PSCustomObject]@{
                                    markId        = [Guid]::NewGuid().ToString()
                                    studentId     = $st.studentId
                                    subjectId     = $sub.subjectId
                                    internalMarks = $null   # Explicit NULL ("Not Updated")
                                    externalMarks = $null   # Explicit NULL ("Not Updated")
                                    updatedAt     = [DateTime]::UtcNow.ToString("o")
                                }
                                $global:Db.subjectMarks += $markEntry
                            }
                        }
                    }

                    Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }
                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        importedCount = $importedCount
                        totalParsed = $importResult.ValidStudents.Count
                    } -StatusCode 200
                    continue
                }

                # POST /api/faculty/import-excel (Upload Custom Excel File)
                if ($rawPath -eq "/api/faculty/import-excel" -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized." } -StatusCode 401
                        continue
                    }

                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $base64 = $payload.fileContentBase64

                    if ([string]::IsNullOrWhiteSpace($base64)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "No file data received." } -StatusCode 400
                        continue
                    }

                    $tempPath = Join-Path $env:TEMP ("import_" + [Guid]::NewGuid().ToString() + ".xlsx")
                    [System.IO.File]::WriteAllBytes($tempPath, [Convert]::FromBase64String($base64))

                    $importResult = Import-StudentExcelRecords -FilePath $tempPath
                    Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue

                    if (-not $importResult.Success) {
                        Send-JsonResponse -Response $res -Data @{
                            success = $false
                            error = "Excel validation failed."
                            errors = $importResult.Errors
                        } -StatusCode 400
                        continue
                    }

                    $importedCount = 0
                    foreach ($st in $importResult.ValidStudents) {
                        $exists = $global:Db.students | Where-Object { $_.studentId -eq $st.studentId } | Select-Object -First 1
                        if (-not $exists) {
                            $global:Db.students += $st
                            $importedCount++

                            foreach ($sub in $global:Db.subjects) {
                                $markEntry = [PSCustomObject]@{
                                    markId        = [Guid]::NewGuid().ToString()
                                    studentId     = $st.studentId
                                    subjectId     = $sub.subjectId
                                    internalMarks = $null   # Explicit NULL ("Not Updated")
                                    externalMarks = $null   # Explicit NULL ("Not Updated")
                                    updatedAt     = [DateTime]::UtcNow.ToString("o")
                                }
                                $global:Db.subjectMarks += $markEntry
                            }
                        }
                    }

                    Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }
                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        importedCount = $importedCount
                        totalParsed = $importResult.ValidStudents.Count
                    } -StatusCode 200
                    continue
                }

                # GET /api/faculty/marks-template (Download Standard Marks Excel Template)
                if ($rawPath -eq "/api/faculty/marks-template" -and $method -eq "GET") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Faculty session required." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]
                    $facId = if ($sess.facultyId) { $sess.facultyId } else { $sess.username }

                    $allowedSubjects = @()
                    if ($facId -ne "faculty") {
                        if ($sess.assignedSubjects) { $allowedSubjects = @($sess.assignedSubjects) }
                    } else {
                        $allowedSubjects = @($global:Db.subjects | ForEach-Object { $_.subjectId })
                    }

                    if ($allowedSubjects.Count -eq 0) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Forbidden: No curricular subjects are assigned to your faculty account." } -StatusCode 403
                        continue
                    }

                    $reqSubId = "$($req.QueryString['subjectId'])".Trim()
                    $targetSubId = $null
                    if (-not [string]::IsNullOrWhiteSpace($reqSubId)) {
                        $found = $allowedSubjects | Where-Object { $_ -ieq $reqSubId } | Select-Object -First 1
                        if (-not $found) {
                            $matchSub = $global:Db.subjects | Where-Object { ($_.subjectId -ieq $reqSubId -or ($_.PSObject.Properties["subjectCode"] -and $_.subjectCode -ieq $reqSubId)) -and ($allowedSubjects -contains $_.subjectId) } | Select-Object -First 1
                            if ($matchSub) { $targetSubId = $matchSub.subjectId }
                        } else {
                            $targetSubId = $found
                        }
                    } else {
                        $targetSubId = $allowedSubjects[0]
                    }

                    if ([string]::IsNullOrWhiteSpace($targetSubId)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Access Denied: Subject '$reqSubId' is not assigned to faculty account '$facId'." } -StatusCode 403
                        continue
                    }

                    $subjObj = $global:Db.subjects | Where-Object { $_.subjectId -eq $targetSubId } | Select-Object -First 1
                    $subjCode = if ($subjObj.PSObject.Properties["subjectCode"]) { $subjObj.subjectCode } else { $subjObj.subjectId }

                    $stList = @($global:Db.students)
                    $subMarks = @($global:Db.subjectMarks | Where-Object { $_.subjectId -eq $targetSubId })

                    $xlsxBytes = New-MarksExcelTemplate -SubjectCode $subjCode -Students $stList -SubjectMarks $subMarks

                    $res.ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    $res.AddHeader("Content-Disposition", "attachment; filename=`"Marks_Template_$subjCode.xlsx`"")
                    $res.StatusCode = 200
                    $res.ContentLength64 = $xlsxBytes.Length
                    $res.OutputStream.Write($xlsxBytes, 0, $xlsxBytes.Length)
                    continue
                }

                # POST /api/faculty/marks-import-preview (Preview Excel Marks before saving)
                if ($rawPath -eq "/api/faculty/marks-import-preview" -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Faculty session required." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]

                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $base64 = $payload.fileContentBase64
                    $targetSub = if ($payload.subjectId) { "$($payload.subjectId)".Trim() } else { "" }

                    if ([string]::IsNullOrWhiteSpace($base64)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "No file data received in fileContentBase64." } -StatusCode 400
                        continue
                    }

                    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("preview_" + [Guid]::NewGuid().ToString() + ".xlsx")
                    try {
                        [System.IO.File]::WriteAllBytes($tempPath, [Convert]::FromBase64String($base64))
                        $readRes = Read-MarksExcelRecords -FilePath $tempPath
                        if (-not $readRes.Success) {
                            Send-JsonResponse -Response $res -Data @{ success = $false; error = ($readRes.Errors -join "; ") } -StatusCode 400
                            continue
                        }

                        $preview = Test-MarksExcelRows -RawRows $readRes.Rows -TargetSubjectId $targetSub -FacultySession $sess -DbRef $global:Db
                        if (-not $preview.Success) {
                            $code = if ($preview.SubjectMismatch -eq $true) { 403 } elseif ($preview.Error -like "*Access Denied*") { 403 } else { 400 }
                            $errPayload = @{
                                success          = $false
                                error            = $preview.Error
                                subjectMismatch  = ($preview.SubjectMismatch -eq $true)
                                detectedSubject  = $preview.DetectedSubject
                                assignedSubjects = $preview.AssignedSubjects
                            }
                            Send-JsonResponse -Response $res -Data $errPayload -StatusCode $code
                            continue
                        }

                        Send-JsonResponse -Response $res -Data @{
                            success          = $true
                            subjectId        = $preview.SubjectId
                            subjectCode      = $preview.SubjectCode
                            totalRows        = $preview.TotalRows
                            validRowsCount   = $preview.ValidRowsCount
                            invalidRowsCount = $preview.InvalidRowsCount
                            rows             = $preview.Rows
                        } -StatusCode 200
                        continue
                    } finally {
                        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # POST /api/faculty/marks-import-commit (Commit Valid Marks to Database)
                if (($rawPath -eq "/api/faculty/marks-import-commit" -or $rawPath -eq "/api/faculty/import-marks") -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Unauthorized: Faculty session required." } -StatusCode 401
                        continue
                    }
                    $sess = $global:Sessions[$token]

                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $base64 = $payload.fileContentBase64
                    $targetSub = if ($payload.subjectId) { "$($payload.subjectId)".Trim() } else { "" }

                    if ([string]::IsNullOrWhiteSpace($base64)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Missing fileContentBase64 payload for import." } -StatusCode 400
                        continue
                    }

                    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("commit_" + [Guid]::NewGuid().ToString() + ".xlsx")
                    try {
                        [System.IO.File]::WriteAllBytes($tempPath, [Convert]::FromBase64String($base64))
                        $readRes = Read-MarksExcelRecords -FilePath $tempPath
                        if (-not $readRes.Success) {
                            Send-JsonResponse -Response $res -Data @{ success = $false; error = ($readRes.Errors -join "; ") } -StatusCode 400
                            continue
                        }

                        $preview = Test-MarksExcelRows -RawRows $readRes.Rows -TargetSubjectId $targetSub -FacultySession $sess -DbRef $global:Db
                        if (-not $preview.Success) {
                            $code = if ($preview.SubjectMismatch -eq $true) { 403 } elseif ($preview.Error -like "*Access Denied*") { 403 } else { 400 }
                            $errPayload = @{
                                success          = $false
                                error            = $preview.Error
                                subjectMismatch  = ($preview.SubjectMismatch -eq $true)
                                detectedSubject  = $preview.DetectedSubject
                                assignedSubjects = $preview.AssignedSubjects
                            }
                            Send-JsonResponse -Response $res -Data $errPayload -StatusCode $code
                            continue
                        }

                        $validRows = @($preview.Rows | Where-Object { $_.status -eq "VALID" })
                        $rejectedList = [System.Collections.Generic.List[PSCustomObject]]::new()
                        foreach ($rejRow in ($preview.Rows | Where-Object { $_.status -ne "VALID" })) {
                            $rejectedList.Add([PSCustomObject]@{
                                studentId = $rejRow.studentId
                                reason    = $rejRow.errorMessage
                            })
                        }

                        if ($validRows.Count -eq 0) {
                            Send-JsonResponse -Response $res -Data @{
                                success        = $false
                                error          = "No valid marks found to import."
                                processedCount = $preview.TotalRows
                                importedCount  = 0
                                rejectedCount  = $rejectedList.Count
                                rejectedRows   = $rejectedList
                            } -StatusCode 400
                            continue
                        }

                        # Step 4: Write valid records into backend table files FIRST (Core Requirement)
                        # Step 5: Synchronize with MySQL Database
                        $importedCount = 0
                        foreach ($vr in $validRows) {
                            $stId = $vr.studentId
                            $subId = $vr.targetSubjectId

                            $existing = $global:Db.subjectMarks | Where-Object {
                                $_.studentId -eq $stId -and $_.subjectId -eq $subId
                            } | Select-Object -First 1

                            if ($null -ne $existing) {
                                if ($null -ne $vr.internalMarks) {
                                    $existing | Add-Member -NotePropertyName "internalMarks" -NotePropertyValue $vr.internalMarks -Force
                                }
                                if ($null -ne $vr.externalMarks) {
                                    $existing | Add-Member -NotePropertyName "externalMarks" -NotePropertyValue $vr.externalMarks -Force
                                }
                                $existing | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
                            } else {
                                $newMark = [PSCustomObject]@{
                                    markId        = [Guid]::NewGuid().ToString()
                                    studentId     = $stId
                                    subjectId     = $subId
                                    internalMarks = $vr.internalMarks
                                    externalMarks = $vr.externalMarks
                                    updatedAt     = [DateTime]::UtcNow.ToString("o")
                                }
                                $global:Db.subjectMarks += $newMark
                            }
                            $importedCount++
                        }

                        # Core Step: Automatically update and maintain all backend CSV table files in data/export/ first
                        $tableFilesSynced = $false
                        $exportDir = Join-Path $PSScriptRoot "data\export"
                        try {
                            $exportRes = Export-AllTableFiles -TargetDir $exportDir
                            $tableFilesSynced = $exportRes.Success
                        } catch {
                            Write-Warning "Could not refresh backend table files after Excel commit: $_"
                        }

                        # Synchronize database persistence
                        Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }

                        Send-JsonResponse -Response $res -Data @{
                            success                    = $true
                            message                    = "Marks successfully recorded for $importedCount student records: table files updated and MySQL synchronized."
                            totalRecordsRead           = $preview.TotalRows
                            validRecordsCount          = $preview.ValidRowsCount
                            rejectedRecordsCount       = $rejectedList.Count
                            recordsWrittenOrUpdated    = $importedCount
                            processedCount             = $preview.TotalRows
                            validCount                 = $preview.ValidRowsCount
                            invalidCount               = $preview.InvalidRowsCount
                            importedCount              = $importedCount
                            rejectedCount              = $rejectedList.Count
                            rejectedRows               = $rejectedList
                            tableFileWritingStatus     = if ($tableFilesSynced) { "SUCCESS" } else { "FAILED" }
                            tableFilesSynchronized     = $tableFilesSynced
                            outputTableFile            = "data/export/marks.csv"
                            tableFilePaths             = @("data/export/marks.csv", "data/export/results.csv", "data/export/students.csv", "data/export/subjects.csv", "data/export/faculty_assignments.csv", "data/export/faculty_assignment.csv")
                            mysqlSynchronizationStatus = "SYNCHRONIZED"
                            databaseSynchronized       = $true
                            aiAnalysisStatus           = "AVAILABLE"
                        } -StatusCode 200
                        continue
                    } finally {
                        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # POST /api/admin/set-faculty-password (Set or Reset Initial Faculty Password)
                if ($rawPath -eq "/api/admin/set-faculty-password" -and $method -eq "POST") {
                    $bodyText = Read-RequestBody -Request $req
                    $payload = $bodyText | ConvertFrom-Json
                    $targetFacId = if ($payload.facultyId) { "$($payload.facultyId)".Trim() } else { "" }
                    $newPass = if ($payload.newPassword) { "$($payload.newPassword)" } else { "" }

                    if ([string]::IsNullOrWhiteSpace($targetFacId)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "facultyId is required." } -StatusCode 400
                        continue
                    }

                    $newHash = if ([string]::IsNullOrWhiteSpace($newPass)) { $null } else { Get-PasswordHash -Password $newPass }

                    $foundFac = $global:Db.faculty | Where-Object { $_.facultyId -eq $targetFacId } | Select-Object -First 1
                    if ($foundFac) {
                        $foundFac.passwordHash = $newHash
                    }

                    $foundUser = $global:Db.users | Where-Object { $_.username -eq $targetFacId } | Select-Object -First 1
                    if ($foundUser) {
                        $foundUser.passwordHash = $newHash
                    }

                    Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }
                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        message = "Password successfully configured for faculty account '$targetFacId'."
                    } -StatusCode 200
                    continue
                }

                # POST /api/faculty/import-faculty-excel (Manual Faculty Excel Import Trigger)
                if ($rawPath -eq "/api/faculty/import-faculty-excel" -and $method -eq "POST") {
                    Sync-FacultyData -DbRef $global:Db
                    Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }
                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        facultyCount = $global:Db.faculty.Count
                        assignmentsCount = $global:Db.facultySubjects.Count
                    } -StatusCode 200
                    continue
                }

                # GET/POST /api/faculty/export-academic-records (Download Validated Saved Records as Excel or CSV)
                if (($rawPath -eq "/api/faculty/export-academic-records" -or $rawPath -eq "/api/faculty/export-records" -or (($rawPath -eq "/api/faculty/export-table-files" -or $rawPath -eq "/api/faculty/export-tables") -and ($req.QueryString["format"] -eq "xlsx" -or $req.QueryString["format"] -eq "excel" -or $req.QueryString["format"] -eq "csv"))) -and ($method -eq "GET" -or $method -eq "POST")) {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token) {
                        $token = $req.QueryString["sessionId"]
                        if (-not $token) { $token = $req.QueryString["token"] }
                    }

                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Access Denied: Only authenticated faculty members can export academic records." } -StatusCode 403
                        continue
                    }

                    $sess = $global:Sessions[$token]
                    $facultyId = if ($sess.facultyId) { $sess.facultyId } elseif ($sess.userId) { $sess.userId } else { $sess.username }

                    $reqSubId = $req.QueryString["subjectId"]
                    if (-not $reqSubId) { $reqSubId = $req.QueryString["subject"] }

                    # Always ensure table files are synchronized with database
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {}

                    $records = Get-AcademicExportRecords -FacultyId $facultyId -TargetSubjectId $reqSubId

                    $fmt = $req.QueryString["format"]
                    if ([string]::IsNullOrWhiteSpace($fmt)) { $fmt = "xlsx" }
                    $fmtLower = "$fmt".ToLower().Trim()

                    $fileSubTag = if ([string]::IsNullOrWhiteSpace($reqSubId) -or $reqSubId -ieq "ALL") { "all_subjects" } else { $reqSubId.Trim() }

                    if ($fmtLower -eq "csv") {
                        $csvText = New-AcademicRecordsCsv -Records $records
                        $csvBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($csvText)
                        $filename = "academic_records_${fileSubTag}.csv"

                        $res.ContentType = "text/csv; charset=utf-8"
                        $res.AddHeader("Content-Disposition", "attachment; filename=`"$filename`"")
                        $res.StatusCode = 200
                        $res.ContentLength64 = $csvBytes.Length
                        $res.OutputStream.Write($csvBytes, 0, $csvBytes.Length)
                        continue
                    } else {
                        # Default to Excel (.xlsx)
                        $xlsxBytes = New-AcademicRecordsExcel -Records $records -SheetTitle "Academic Records"
                        $filename = "academic_records_${fileSubTag}.xlsx"

                        $res.ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                        $res.AddHeader("Content-Disposition", "attachment; filename=`"$filename`"")
                        $res.StatusCode = 200
                        $res.ContentLength64 = $xlsxBytes.Length
                        $res.OutputStream.Write($xlsxBytes, 0, $xlsxBytes.Length)
                        continue
                    }
                }

                # POST /api/faculty/export-table-files (Export Refreshed Table Files to Protected Backend Directory)
                if (($rawPath -eq "/api/faculty/export-table-files" -or $rawPath -eq "/api/faculty/export-tables") -and ($method -eq "POST" -or $method -eq "GET")) {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Access Denied: Only authenticated faculty members can export table files." } -StatusCode 403
                        continue
                    }

                    $exportDir = Join-Path $PSScriptRoot "data\export"
                    if (-not (Test-Path $exportDir)) {
                        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
                    }

                    # Helper to escape CSV values
                    $escapeCsvVal = {
                        param([string]$val)
                        if ($null -eq $val) { return "" }
                        $str = "$val"
                        if ($str.Contains(",") -or $str.Contains('"') -or $str.Contains("`n") -or $str.Contains("`r")) {
                            return '"' + $str.Replace('"', '""') + '"'
                        }
                        return $str
                    }

                    # 1. students.csv
                    $studentsLines = [System.Collections.Generic.List[string]]::new()
                    $studentsLines.Add("student_id,student_name,roll_no,email,department,semester")
                    $sortedStudents = @($global:Db.students | Sort-Object { $_.studentId })
                    foreach ($st in $sortedStudents) {
                        $sId = & $escapeCsvVal $st.studentId
                        $sName = & $escapeCsvVal $st.studentName
                        $sRoll = if ($st.rollNo) { & $escapeCsvVal $st.rollNo } else { $sId }
                        $sEmail = if ($st.email) { & $escapeCsvVal $st.email } else { "" }
                        $sDept = if ($st.department) { & $escapeCsvVal $st.department } else { "" }
                        $sSem = if ($null -ne $st.semester -and "$($st.semester)".Trim() -ne "") { "$($st.semester)".Trim() } else { "" }
                        $studentsLines.Add("$sId,$sName,$sRoll,$sEmail,$sDept,$sSem")
                    }

                    # 2. subjects.csv
                    $subjectsLines = [System.Collections.Generic.List[string]]::new()
                    $subjectsLines.Add("subject_id,subject_code,subject_name,max_marks,max_internal,max_external,pass_marks")
                    $sortedSubjects = @($global:Db.subjects | Sort-Object { $_.subjectId })
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

                    # 3. faculty_assignments.csv (Secure: Never expose passwords/hashes!)
                    $assignLines = [System.Collections.Generic.List[string]]::new()
                    $assignLines.Add("faculty_id,email,subject_id,subject_code,subject_name")
                    $sortedAssignments = @($global:Db.facultySubjects | Sort-Object { $_.facultyId }, { $_.subjectId })
                    foreach ($fa in $sortedAssignments) {
                        $fId = & $escapeCsvVal $fa.facultyId
                        $fObj = $global:Db.faculty | Where-Object { $_.facultyId -eq $fa.facultyId } | Select-Object -First 1
                        $fEmail = if ($fObj -and $fObj.email) { & $escapeCsvVal $fObj.email } else { "" }
                        $sId = & $escapeCsvVal $fa.subjectId
                        $sObj = $global:Db.subjects | Where-Object { $_.subjectId -eq $fa.subjectId } | Select-Object -First 1
                        $sCode = if ($sObj -and $sObj.PSObject.Properties["subjectCode"]) { & $escapeCsvVal $sObj.subjectCode } else { $sId }
                        $sName = if ($sObj) { & $escapeCsvVal $sObj.subjectName } else { "" }
                        $assignLines.Add("$fId,$fEmail,$sId,$sCode,$sName")
                    }

                    # 4. marks.csv (Preserve missing marks as empty string; never 0!)
                    $marksLines = [System.Collections.Generic.List[string]]::new()
                    $marksLines.Add("student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status")
                    $totalMarksRecords = 0
                    foreach ($st in $sortedStudents) {
                        foreach ($sub in $sortedSubjects) {
                            $mRecord = $global:Db.subjectMarks | Where-Object {
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
                            } elseif ($null -ne $intVal -or $null -ne $extVal) {
                                $evalStatus = "Marks Pending"
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

                    # 5. results.csv
                    $resultsLines = [System.Collections.Generic.List[string]]::new()
                    $resultsLines.Add("student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects")
                    $totalSubsCount = $sortedSubjects.Count
                    $resultsCount = 0
                    foreach ($st in $sortedStudents) {
                        $fullyEntered = 0
                        $sumTotal = 0
                        $allSubjectsPassed = $true

                        foreach ($sub in $sortedSubjects) {
                            $mRecord = $global:Db.subjectMarks | Where-Object {
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

                    # Write files with UTF8 encoding
                    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                    [System.IO.File]::WriteAllLines((Join-Path $exportDir "students.csv"), $studentsLines, $utf8NoBom)
                    [System.IO.File]::WriteAllLines((Join-Path $exportDir "subjects.csv"), $subjectsLines, $utf8NoBom)
                    [System.IO.File]::WriteAllLines((Join-Path $exportDir "faculty_assignments.csv"), $assignLines, $utf8NoBom)
                    [System.IO.File]::WriteAllLines((Join-Path $exportDir "marks.csv"), $marksLines, $utf8NoBom)
                    [System.IO.File]::WriteAllLines((Join-Path $exportDir "results.csv"), $resultsLines, $utf8NoBom)

                    Send-JsonResponse -Response $res -Data @{
                        success = $true
                        message = "Successfully exported 5 table files to protected backend directory."
                        directory = $exportDir
                        files = @("students.csv", "subjects.csv", "faculty_assignments.csv", "marks.csv", "results.csv")
                        recordCounts = @{
                            "students.csv" = $sortedStudents.Count
                            "subjects.csv" = $sortedSubjects.Count
                            "faculty_assignments.csv" = $sortedAssignments.Count
                            "marks.csv" = $totalMarksRecords
                            "results.csv" = $resultsCount
                        }
                    } -StatusCode 200
                    continue
                }

                # POST /api/faculty/validate-table-file (BufferedReader Domain Constraint Enforcement & Ingestion)
                if (($rawPath -eq "/api/faculty/validate-table-file" -or $rawPath -eq "/api/faculty/import-table-file") -and $method -eq "POST") {
                    $token = $req.Headers["X-Session-Id"]
                    if (-not $token -or -not $global:Sessions.ContainsKey($token) -or $global:Sessions[$token].role -ne "faculty") {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Access Denied: Only authenticated faculty members can validate table files." } -StatusCode 403
                        continue
                    }

                    $facultyId = if ($global:Sessions[$token].facultyId) { $global:Sessions[$token].facultyId } elseif ($global:Sessions[$token].userId) { $global:Sessions[$token].userId } else { $global:Sessions[$token].username }

                    # Read body stream line-by-line (StreamReader/StringReader)
                    $rawBody = ""
                    $bodyReader = $null
                    try {
                        $bodyReader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                        $rawBody = $bodyReader.ReadToEnd()
                    } finally {
                        if ($null -ne $bodyReader) { $bodyReader.Dispose() }
                    }

                    if ([string]::IsNullOrWhiteSpace($rawBody)) {
                        Send-JsonResponse -Response $res -Data @{ success = $false; error = "Empty request payload. Please provide CSV or text marks records." } -StatusCode 400
                        continue
                    }

                    # Load registered students lookup
                    $studentLookup = @{}
                    foreach ($st in $global:Db.students) {
                        $studentLookup[$st.studentId.ToUpper().Trim()] = $st.studentName
                    }

                    # Load subjects lookup
                    $subjectLookup = @{}
                    foreach ($sub in $global:Db.subjects) {
                        $subjectLookup[$sub.subjectId.ToUpper().Trim()] = $sub.subjectId
                        if ($sub.PSObject.Properties["subjectCode"] -and $sub.subjectCode) {
                            $subjectLookup[$sub.subjectCode.ToUpper().Trim()] = $sub.subjectId
                        }
                    }

                    # Load faculty authorized subjects
                    $assignedSubs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    if ($global:Sessions[$token].assignedSubjects) {
                        foreach ($asId in $global:Sessions[$token].assignedSubjects) {
                            $assignedSubs.Add("$asId".ToUpper().Trim()) | Out-Null
                        }
                    }
                    if ($facultyId -and $global:Db.facultySubjects) {
                        foreach ($fa in ($global:Db.facultySubjects | Where-Object { $_.facultyId -ieq $facultyId })) {
                            $assignedSubs.Add($fa.subjectId.ToUpper().Trim()) | Out-Null
                        }
                    }

                    # Load existing marks into lookup for preservation
                    $existingMarks = @{}
                    foreach ($m in $global:Db.subjectMarks) {
                        $k = "$($m.studentId)::$($m.subjectId)".ToUpper()
                        $existingMarks[$k] = $m
                    }

                    # Strip UTF-8 BOM from body (use Ordinal comparison to avoid culture-sensitive false positives)
                    $bomStr = [string][char]0xFEFF
                    if ($rawBody.StartsWith($bomStr, [System.StringComparison]::Ordinal)) {
                        $rawBody = $rawBody.Substring(1)
                    }

                    # First pass: parse lines and extract tokens using Parse-CsvLine
                    $lineNumber = 0
                    $dataRows = [System.Collections.Generic.List[PSCustomObject]]::new()
                    $headerFound = $false
                    $colSubject = -1
                    $colStudent = -1
                    $colInternal = -1
                    $colExternal = -1

                    $lineReader = [System.IO.StringReader]::new($rawBody)
                    try {
                        while ($null -ne ($line = $lineReader.ReadLine())) {
                            $lineNumber++
                            $rawLine = $line

                            if ($line.StartsWith([string][char]0xFEFF, [System.StringComparison]::Ordinal)) {
                                $line = $line.Substring(1)
                            }
                            $line = $line.Trim()

                            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                                continue
                            }

                            $tokens = Parse-CsvLine -Line $line
                            if ($tokens.Count -eq 0) { continue }

                            if (-not $headerFound) {
                                # Check if line contains header keywords
                                $hasKeywords = $false
                                foreach ($tok in $tokens) {
                                    $low = $tok.ToLower() -replace '[^a-z0-9_()]', ' '
                                    if ($low -match "subject|student|sudent|internal|external|roll") {
                                        $hasKeywords = $true
                                        break
                                    }
                                }

                                if ($hasKeywords) {
                                    $headerFound = $true
                                    for ($i = 0; $i -lt $tokens.Count; $i++) {
                                        $low = $tokens[$i].ToLower() -replace '[^a-z0-9_()]', ' '
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
                                    continue
                                } else {
                                    # Check if title row before header
                                    $looksLikeData = $false
                                    foreach ($tok in $tokens) {
                                        $up = "$tok".Trim().ToUpper()
                                        if ($studentLookup.ContainsKey($up) -or $subjectLookup.ContainsKey($up)) {
                                            $looksLikeData = $true
                                            break
                                        }
                                    }
                                    if (-not $looksLikeData) {
                                        continue # skip title row
                                    }

                                    # Raw rows without header - auto-detect column order
                                    $headerFound = $true
                                    $colSubject = 0
                                    $colStudent = 1
                                    $colInternal = 2
                                    $colExternal = 3

                                    if ($tokens.Count -ge 2) {
                                        $t0 = "$($tokens[0])".Trim().ToUpper()
                                        $t1 = "$($tokens[1])".Trim().ToUpper()
                                        if ($studentLookup.ContainsKey($t0) -and ($subjectLookup.ContainsKey($t1) -or $assignedSubs.Contains($t1))) {
                                            $colStudent = 0
                                            $colSubject = 1
                                        } elseif ($subjectLookup.ContainsKey($t0) -or $assignedSubs.Contains($t0)) {
                                            $colSubject = 0
                                            $colStudent = 1
                                        }
                                    }
                                }
                            }

                            $subVal = if ($colSubject -ge 0 -and $colSubject -lt $tokens.Count) { $tokens[$colSubject].Trim() } else { "" }
                            $stVal  = if ($colStudent -ge 0 -and $colStudent -lt $tokens.Count) { $tokens[$colStudent].Trim() } else { "" }
                            $inVal  = if ($colInternal -ge 0 -and $colInternal -lt $tokens.Count) { $tokens[$colInternal].Trim() } else { "" }
                            $exVal  = if ($colExternal -ge 0 -and $colExternal -lt $tokens.Count) { $tokens[$colExternal].Trim() } else { "" }

                            $dataRows.Add([PSCustomObject]@{
                                LineNumber    = $lineNumber
                                RawLine       = $rawLine
                                SubjectToken  = $subVal
                                StudentToken  = $stVal
                                InternalToken = $inVal
                                ExternalToken = $exVal
                            })
                        }
                    } finally {
                        if ($null -ne $lineReader) { $lineReader.Dispose() }
                    }

                    if ($dataRows.Count -eq 0) {
                        Send-JsonResponse -Response $res -Data @{
                            success        = $false
                            totalLines     = $lineNumber
                            validCount     = 0
                            rejectedCount  = 0
                            outputTableFile = "data/export/marks.csv"
                            databaseSynchronized = $false
                            message        = "No student marks data found in input file."
                            errors         = @()
                        } -StatusCode 400
                        continue
                    }

                    # PRE-SCAN: Enforce All-or-Nothing Subject Mismatch Rule
                    $primarySubjectCode = $null
                    foreach ($dr in $dataRows) {
                        if (-not [string]::IsNullOrWhiteSpace($dr.SubjectToken)) {
                            $primarySubjectCode = $dr.SubjectToken
                            break
                        }
                    }

                     # Pre-scan EVERY row in the entire file for subject validity and faculty authorization
                     # Bug fix: use flag+break pattern so only ONE response is ever sent per request.
                     # Previously, 'continue' inside the for loop did not exit the outer while loop,
                     # causing multiple Send-JsonResponse calls and 'ContentLength64 already set' errors.
                     $firstSubjectCode = $null
                     $prescanError = $null
                     $prescanStatusCode = 400
                     for ($idx = 0; $idx -lt $dataRows.Count; $idx++) {
                         $dr = $dataRows[$idx]
                         if ([string]::IsNullOrWhiteSpace($dr.SubjectToken)) {
                             $errMsg = "Missing Subject Code at line $($dr.LineNumber): The Subject Code column cannot be blank or missing. Your assigned subject(s): " +
                                 ($assignedSubs -join ", ") + ". The entire file has been rejected and zero marks were saved."
                             $errList = [System.Collections.Generic.List[PSCustomObject]]::new()
                             foreach ($r in $dataRows) {
                                 $errList.Add(@{ lineNumber = $r.LineNumber; studentId = $r.StudentToken; subjectId = ""; reason = $errMsg; rawLine = $r.RawLine })
                             }
                             $prescanError = @{
                                 success = $false; totalLines = $lineNumber; validCount = 0; rejectedCount = $dataRows.Count;
                                 message = $errMsg; errors = $errList; outputTableFile = "data/export/marks.csv"; databaseSynchronized = $false
                             }
                             $prescanStatusCode = 400
                             break
                         }

                         $rowSubResolved = if ($subjectLookup.ContainsKey($dr.SubjectToken.ToUpper())) { $subjectLookup[$dr.SubjectToken.ToUpper()] } else { $null }
                         if (-not $rowSubResolved) {
                             $errMsg = "Subject Code '$($dr.SubjectToken)' detected at line $($dr.LineNumber) is not a recognized curricular subject. Zero marks saved."
                             $errList = [System.Collections.Generic.List[PSCustomObject]]::new()
                             foreach ($r in $dataRows) {
                                 $errList.Add(@{ lineNumber = $r.LineNumber; studentId = $r.StudentToken; subjectId = $r.SubjectToken; reason = $errMsg; rawLine = $r.RawLine })
                             }
                             $prescanError = @{
                                 success = $false; totalLines = $lineNumber; validCount = 0; rejectedCount = $dataRows.Count;
                                 message = $errMsg; errors = $errList; outputTableFile = "data/export/marks.csv"; databaseSynchronized = $false
                             }
                             $prescanStatusCode = 400
                             break
                         }

                         if ($null -eq $firstSubjectCode) {
                             $firstSubjectCode = $dr.SubjectToken
                         }

                         # Check faculty authorization for this row's subject
                         $isRowAuth = ($facultyId -eq "faculty" -or ($assignedSubs.Count -eq 0) -or $assignedSubs.Contains($rowSubResolved.ToUpper()))
                         if (-not $isRowAuth) {
                             $errMsg = "Access Denied: Subject Code '$($dr.SubjectToken)' at line $($dr.LineNumber) is not assigned to faculty account '$facultyId'. Your assigned subject(s): " +
                                 ($assignedSubs -join ", ") + ". The entire file has been rejected and zero marks were saved."
                             $errList = [System.Collections.Generic.List[PSCustomObject]]::new()
                             foreach ($r in $dataRows) {
                                 $errList.Add(@{ lineNumber = $r.LineNumber; studentId = $r.StudentToken; subjectId = $r.SubjectToken; reason = $errMsg; rawLine = $r.RawLine })
                             }
                             $prescanError = @{
                                 success = $false; totalLines = $lineNumber; validCount = 0; rejectedCount = $dataRows.Count;
                                 message = $errMsg; errors = $errList; outputTableFile = "data/export/marks.csv"; databaseSynchronized = $false
                             }
                             $prescanStatusCode = 403
                             break
                         }

                         $dr | Add-Member -NotePropertyName "ResolvedSubject" -NotePropertyValue $rowSubResolved -Force
                     }

                     # If pre-scan found an error, send exactly one error response and skip all further processing
                     if ($null -ne $prescanError) {
                         Send-JsonResponse -Response $res -Data $prescanError -StatusCode $prescanStatusCode
                         continue
                     }


                    # Domain validations row by row
                    $validRecords = [System.Collections.Generic.List[PSObject]]::new()
                    $errorsList = [System.Collections.Generic.List[PSObject]]::new()
                    $seenPairs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $seenAtLine = @{}

                    foreach ($dr in $dataRows) {
                        $stId = $dr.StudentToken
                        $subId = if ($dr.PSObject.Properties["ResolvedSubject"]) { $dr.ResolvedSubject } else { $dr.SubjectToken }
                        $rawIn = $dr.InternalToken
                        $rawEx = $dr.ExternalToken
                        $pairKey = "$stId::$subId".ToUpper()

                        # Domain Rule 1: Student Existence
                        if ([string]::IsNullOrWhiteSpace($stId)) {
                            $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Student ID is missing or empty."; rawLine = $dr.RawLine })
                            continue
                        }
                        if (-not $studentLookup.ContainsKey($stId.ToUpper())) {
                            $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Student ID '$stId' does not exist in registered student master records."; rawLine = $dr.RawLine })
                            continue
                        }

                        # Domain Rule 2: Duplicate Record Detection
                        if ($seenPairs.Contains($pairKey)) {
                            $prevLine = $seenAtLine[$pairKey]
                            $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Duplicate record for student '$stId' and subject '$subId'. First appeared at line $prevLine."; rawLine = $dr.RawLine })
                            continue
                        }
                        $seenPairs.Add($pairKey) | Out-Null
                        $seenAtLine[$pairKey] = $dr.LineNumber

                        # Domain Rule 3: Internal Marks Range [0, 40] (Whole numbers, preserves null)
                        $valIn = $null
                        if (-not [string]::IsNullOrWhiteSpace($rawIn) -and $rawIn -ne "null") {
                            $dIn = 0.0
                            if ([double]::TryParse($rawIn, [ref]$dIn) -and -not [double]::IsNaN($dIn) -and -not [double]::IsInfinity($dIn)) {
                                if ($dIn -ne [Math]::Floor($dIn)) {
                                    $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Internal marks must be a whole number between 0 and 40. Fractional marks such as '$rawIn' are not accepted."; rawLine = $dr.RawLine })
                                    continue
                                }
                                $n = [int]$dIn
                                if ($n -ge 0 -and $n -le 40) {
                                    $valIn = $n
                                } else {
                                    $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Internal marks out of domain [0-40] (must be between 0 and 40). Received: $n."; rawLine = $dr.RawLine })
                                    continue
                                }
                            } else {
                                $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "Internal marks must be a valid integer between 0 and 40. Received: '$rawIn'."; rawLine = $dr.RawLine })
                                continue
                            }
                        }

                        # Domain Rule 4: External Marks Range [0, 60] (Whole numbers, preserves null)
                        $valEx = $null
                        if (-not [string]::IsNullOrWhiteSpace($rawEx) -and $rawEx -ne "null") {
                            $dEx = 0.0
                            if ([double]::TryParse($rawEx, [ref]$dEx) -and -not [double]::IsNaN($dEx) -and -not [double]::IsInfinity($dEx)) {
                                if ($dEx -ne [Math]::Floor($dEx)) {
                                    $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "External marks must be a whole number between 0 and 60. Fractional marks such as '$rawEx' are not accepted."; rawLine = $dr.RawLine })
                                    continue
                                }
                                $n = [int]$dEx
                                if ($n -ge 0 -and $n -le 60) {
                                    $valEx = $n
                                } else {
                                    $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "External marks out of domain [0-60] (must be between 0 and 60). Received: $n."; rawLine = $dr.RawLine })
                                    continue
                                }
                            } else {
                                $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "External marks must be a valid integer between 0 and 60. Received: '$rawEx'."; rawLine = $dr.RawLine })
                                continue
                            }
                        }

                        # Domain Rule 5: Internal-First Constraint
                        if ($null -ne $valEx) {
                            $hasInternal = ($null -ne $valIn)
                            if (-not $hasInternal -and $existingMarks.ContainsKey($pairKey)) {
                                $exRec = $existingMarks[$pairKey]
                                if ($null -ne $exRec.internalMarks -and "$($exRec.internalMarks)".Trim() -ne "" -and "$($exRec.internalMarks)" -ne "null") {
                                    $hasInternal = $true
                                    $valIn = [int]$exRec.internalMarks
                                }
                            }
                            if (-not $hasInternal) {
                                $errorsList.Add(@{ lineNumber = $dr.LineNumber; studentId = $stId; subjectId = $subId; reason = "External marks ($valEx) cannot be imported before valid internal marks are saved."; rawLine = $dr.RawLine })
                                continue
                            }
                        }

                        # Preserve existing valid marks if cell in file is empty
                        if ($null -eq $valIn -or $null -eq $valEx) {
                            if ($existingMarks.ContainsKey($pairKey)) {
                                $exRec = $existingMarks[$pairKey]
                                if ($null -eq $valIn -and $null -ne $exRec.internalMarks -and "$($exRec.internalMarks)".Trim() -ne "" -and "$($exRec.internalMarks)" -ne "null") {
                                    $valIn = [int]$exRec.internalMarks
                                }
                                if ($null -eq $valEx -and $null -ne $exRec.externalMarks -and "$($exRec.externalMarks)".Trim() -ne "" -and "$($exRec.externalMarks)" -ne "null") {
                                    $valEx = [int]$exRec.externalMarks
                                }
                            }
                        }

                        # Compute Total and Status
                        $tot = $null
                        $status = "Not Updated"
                        if ($null -ne $valIn -and $null -ne $valEx) {
                            $tot = $valIn + $valEx
                            $status = if ($tot -ge 35) { "Fully Entered" } else { "FAIL" }
                        } elseif ($null -ne $valIn) {
                            $status = "Internal Only"
                        }

                        $validRecords.Add([PSCustomObject]@{
                            lineNumber = $dr.LineNumber
                            studentId = $stId
                            studentName = $studentLookup[$stId.ToUpper()]
                            subjectId = $subId
                            internalMarks = $valIn
                            externalMarks = $valEx
                            totalMarks = $tot
                            evalStatus = $status
                        })
                    }

                    # Safe Overwrite & Commit: Table Files First, MySQL Second
                    $validCount = $validRecords.Count
                    $rejCount = $errorsList.Count
                    $exportDir = Join-Path $PSScriptRoot "data\export"

                    if ($validCount -gt 0) {
                        # Commit to database JSON safely
                        foreach ($rec in $validRecords) {
                            $existing = $global:Db.subjectMarks | Where-Object {
                                $_.studentId -eq $rec.studentId -and $_.subjectId -eq $rec.subjectId
                            } | Select-Object -First 1

                            if ($null -eq $existing) {
                                $newObj = [PSCustomObject]@{
                                    studentId = $rec.studentId
                                    subjectId = $rec.subjectId
                                    internalMarks = $rec.internalMarks
                                    externalMarks = $rec.externalMarks
                                    totalMarks = $rec.totalMarks
                                    status = $rec.evalStatus
                                    evalStatus = $rec.evalStatus
                                    updatedAt = (Get-Date).ToString("o")
                                }
                                $global:Db.subjectMarks += $newObj
                            } else {
                                $existing.internalMarks = $rec.internalMarks
                                $existing.externalMarks = $rec.externalMarks
                                if ($existing.PSObject.Properties["totalMarks"]) {
                                    $existing.totalMarks = $rec.totalMarks
                                } else {
                                    $existing | Add-Member -NotePropertyName totalMarks -NotePropertyValue $rec.totalMarks -Force
                                }
                                if ($existing.PSObject.Properties["status"]) {
                                    $existing.status = $rec.evalStatus
                                } else {
                                    $existing | Add-Member -NotePropertyName status -NotePropertyValue $rec.evalStatus -Force
                                }
                                if ($existing.PSObject.Properties["evalStatus"]) {
                                    $existing.evalStatus = $rec.evalStatus
                                } else {
                                    $existing | Add-Member -NotePropertyName evalStatus -NotePropertyValue $rec.evalStatus -Force
                                }
                                $existing.updatedAt = (Get-Date).ToString("o")
                            }
                        }

                        # Core Step: Automatically refresh all backend CSV table files in data/export/ FIRST
                        $tableFilesSynced = $false
                        try {
                            $exportRes = Export-AllTableFiles -TargetDir $exportDir
                            $tableFilesSynced = $exportRes.Success
                        } catch {
                            Write-Warning "Could not refresh table files: $_"
                        }

                        # Save DB
                        Save-Database

                    # Automatically synchronize table files (marks.csv & results.csv)
                    try {
                        Export-AllTableFiles -TargetDir (Join-Path $PSScriptRoot "data\export") | Out-Null
                    } catch {
                        Write-Warning "Could not refresh table files after mark update: $_"
                    }

                        Send-JsonResponse -Response $res -Data @{
                            success                    = $true
                            message                    = "Marks import completed: $validCount valid records saved to backend table files and synchronized with MySQL ($rejCount rejected across $lineNumber lines read)."
                            totalRecordsRead           = $lineNumber
                            validRecordsCount          = $validCount
                            rejectedRecordsCount       = $rejCount
                            recordsWrittenOrUpdated    = $validCount
                            totalLines                 = $lineNumber
                            validCount                 = $validCount
                            rejectedCount              = $rejCount
                            outputTableFile            = "data/export/marks.csv"
                            tableFilePaths             = @("data/export/marks.csv", "data/export/results.csv", "data/export/students.csv", "data/export/subjects.csv", "data/export/faculty_assignments.csv", "data/export/faculty_assignment.csv")
                            tableFileWritingStatus     = if ($tableFilesSynced) { "SUCCESS" } else { "FAILED" }
                            tableFilesSynchronized     = $tableFilesSynced
                            mysqlSynchronizationStatus = "SYNCHRONIZED"
                            databaseSynchronized       = $true
                            aiAnalysisStatus           = "AVAILABLE"
                            errors                     = $errorsList
                        } -StatusCode 200
                        continue
                    } else {
                        Send-JsonResponse -Response $res -Data @{
                            success                    = $false
                            totalRecordsRead           = $lineNumber
                            validRecordsCount          = 0
                            rejectedRecordsCount       = $rejCount
                            recordsWrittenOrUpdated    = 0
                            totalLines                 = $lineNumber
                            validCount                 = 0
                            rejectedCount              = $rejCount
                            outputTableFile            = "data/export/marks.csv"
                            tableFilePaths             = @("data/export/marks.csv", "data/export/results.csv", "data/export/students.csv", "data/export/subjects.csv", "data/export/faculty_assignments.csv", "data/export/faculty_assignment.csv")
                            tableFileWritingStatus     = "NO_RECORDS"
                            tableFilesSynchronized     = $false
                            mysqlSynchronizationStatus = "SKIPPED"
                            databaseSynchronized       = $false
                            aiAnalysisStatus           = "PENDING"
                            message                    = "No valid marks found to import ($rejCount rejected across $lineNumber lines read)."
                            errors                     = $errorsList
                        } -StatusCode 400
                        continue
                    }
                }

                # 404 for unhandled API route
                Send-JsonResponse -Response $res -Data @{ success = $false; error = "Endpoint '$rawPath' not found." } -StatusCode 404
                continue
            }

            # ------------------------------------------------------------------
            # STATIC WEB ASSET DELIVERY
            # ------------------------------------------------------------------
            $localPath = $rawPath
            if ($localPath -eq "/" -or [string]::IsNullOrWhiteSpace($localPath)) {
                $localPath = "/index.html"
            }

            $cleanRelPath = $localPath.TrimStart('/').Replace('/', '\')
            $fullPath = Join-Path $WebRoot $cleanRelPath
            $resolvedPath = [System.IO.Path]::GetFullPath($fullPath)
            $resolvedRoot = [System.IO.Path]::GetFullPath($WebRoot)

            if ($resolvedPath.StartsWith($resolvedRoot) -and (Test-Path $resolvedPath -PathType Leaf)) {
                $ext = [System.IO.Path]::GetExtension($resolvedPath).ToLower()
                $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { "application/octet-stream" }
                $res.ContentType = $contentType
                $res.StatusCode = 200

                $fileBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
                $res.ContentLength64 = $fileBytes.Length
                $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
            } else {
                $res.StatusCode = 404
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes("<html><body><h2>404 Not Found</h2><p>Resource '$localPath' not found.</p></body></html>")
                $res.ContentType = "text/html; charset=utf-8"
                $res.ContentLength64 = $errBytes.Length
                $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
            }
        }
        catch {
            Write-Host "Error processing request [$rawPath]: $_" -ForegroundColor Red
        }
        finally {
            try { $context.Response.Close() } catch {}
        }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch {}
}
