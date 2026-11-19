package com.academic.service;

import com.academic.config.DBConnection;
import com.academic.model.Student;
import com.academic.model.Subject;
import com.academic.model.SubjectMark;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.StringReader;
import java.util.logging.Logger;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * Academic Result Input Validator - Marks Excel Import & Validation Service
 *
 * Implements:
 * 1. Standard Excel (.xlsx) template generation with 4 columns:
 *    Subject Code, Student ID, Internal Marks (out of 40), External Marks (out of 60)
 * 2. Backend validation of faculty subject assignment & subject code matching
 * 3. Domain integrity constraints:
 *    - Student ID must exist in registered student records
 *    - Internal marks: 0-40 or NULL (empty)
 *    - External marks: 0-60 or NULL (empty)
 *    - Internal-First Enforcement: External marks rejected if valid internal marks not saved/provided
 *    - Preserves existing valid marks when file cell is empty
 *    - Duplicate row detection within file
 * 4. Two-phase processing: Preview with detailed validation status, followed by safe transactional commit.
 */
public class MarksImportService {

    public static class MarkRow {
        public int rowNumber;
        public String subjectCode;
        public String studentId;
        public String studentName;
        public Integer internalMarks;
        public Integer externalMarks;
        public String rawInternal;
        public String rawExternal;
        public String status; // "VALID" or "INVALID"
        public String errorMessage;
    }

    public static class PreviewResult {
        public boolean success;
        public String subjectId;
        public String subjectCode;
        public int totalRows;
        public int validRowsCount;
        public int invalidRowsCount;
        public List<MarkRow> rows = new ArrayList<>();
        public String error;
    }

    public static class CommitResult {
        public boolean success;
        public String message;
        public int processedCount;
        public int validCount;
        public int invalidCount;
        public int importedCount;
        public int rejectedCount;
        public List<Map<String, String>> rejectedRows = new ArrayList<>();
        public String error;
    }

    /**
     * Generates a standard OpenXML (.xlsx) template for the given subject and registered students.
     */
    public byte[] generateTemplate(String subjectCode, List<Student> students, Map<String, SubjectMark> existingMarks) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        try (ZipOutputStream zos = new ZipOutputStream(baos)) {
            // [Content_Types].xml
            zos.putNextEntry(new ZipEntry("[Content_Types].xml"));
            String ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n" +
                "  <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n" +
                "  <Default Extension=\"xml\" ContentType=\"application/xml\"/>\n" +
                "  <Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\n" +
                "  <Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n" +
                "</Types>";
            zos.write(ct.getBytes("UTF-8"));
            zos.closeEntry();

            // _rels/.rels
            zos.putNextEntry(new ZipEntry("_rels/.rels"));
            String rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "  <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>\n" +
                "</Relationships>";
            zos.write(rels.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/workbook.xml
            zos.putNextEntry(new ZipEntry("xl/workbook.xml"));
            String wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n" +
                "  <sheets>\n" +
                "    <sheet name=\"Marks\" sheetId=\"1\" r:id=\"rId1\"/>\n" +
                "  </sheets>\n" +
                "</workbook>";
            zos.write(wb.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/_rels/workbook.xml.rels
            zos.putNextEntry(new ZipEntry("xl/_rels/workbook.xml.rels"));
            String wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "  <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>\n" +
                "</Relationships>";
            zos.write(wbRels.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/worksheets/sheet1.xml
            zos.putNextEntry(new ZipEntry("xl/worksheets/sheet1.xml"));
            StringBuilder sheet = new StringBuilder();
            sheet.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
            sheet.append("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n");
            sheet.append("<sheetData>\n");

            // Header row
            sheet.append("<row r=\"1\">\n");
            sheet.append("  <c r=\"A1\" t=\"inlineStr\"><is><t>Subject Code</t></is></c>\n");
            sheet.append("  <c r=\"B1\" t=\"inlineStr\"><is><t>Student ID</t></is></c>\n");
            sheet.append("  <c r=\"C1\" t=\"inlineStr\"><is><t>Internal Marks (out of 40)</t></is></c>\n");
            sheet.append("  <c r=\"D1\" t=\"inlineStr\"><is><t>External Marks (out of 60)</t></is></c>\n");
            sheet.append("</row>\n");

            // Student rows
            int r = 2;
            for (Student s : students) {
                String stId = s.getStudentId();
                SubjectMark mark = (existingMarks != null) ? existingMarks.get(stId) : null;
                Integer intM = (mark != null) ? mark.getInternalMarks() : null;
                Integer extM = (mark != null) ? mark.getExternalMarks() : null;

                sheet.append("<row r=\"").append(r).append("\">\n");
                sheet.append("  <c r=\"A").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(subjectCode)).append("</t></is></c>\n");
                sheet.append("  <c r=\"B").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(stId)).append("</t></is></c>\n");
                if (intM != null) {
                    sheet.append("  <c r=\"C").append(r).append("\"><v>").append(intM).append("</v></c>\n");
                }
                if (extM != null) {
                    sheet.append("  <c r=\"D").append(r).append("\"><v>").append(extM).append("</v></c>\n");
                }
                sheet.append("</row>\n");
                r++;
            }

            sheet.append("</sheetData>\n");
            sheet.append("</worksheet>");
            zos.write(sheet.toString().getBytes("UTF-8"));
            zos.closeEntry();
        }
        return baos.toByteArray();
    }

    /**
     * Parses an uploaded Excel (.xlsx) file, verifies headers and rows, and returns PreviewResult.
     */
    public PreviewResult previewExcelMarks(java.io.File file, String facultyId, List<String> authorizedSubjectCodes) {
        PreviewResult result = new PreviewResult();
        if (file == null || !file.exists()) {
            result.success = false;
            result.error = "Excel file not found on server.";
            return result;
        }

        List<RawRow> rawRows = new ArrayList<>();
        String sheetSubjectCode = null;

        try (ZipFile zip = new ZipFile(file)) {
            // Read shared strings
            List<String> sharedStrings = new ArrayList<>();
            ZipEntry ssEntry = zip.getEntry("xl/sharedStrings.xml");
            if (ssEntry != null) {
                try (InputStream is = zip.getInputStream(ssEntry)) {
                    DocumentBuilder db = DocumentBuilderFactory.newInstance().newDocumentBuilder();
                    Document doc = db.parse(is);
                    NodeList siList = doc.getElementsByTagName("si");
                    for (int i = 0; i < siList.getLength(); i++) {
                        Node si = siList.item(i);
                        StringBuilder sb = new StringBuilder();
                        NodeList tList = ((Element) si).getElementsByTagName("t");
                        for (int j = 0; j < tList.getLength(); j++) {
                            sb.append(tList.item(j).getTextContent());
                        }
                        sharedStrings.add(sb.toString().trim());
                    }
                }
            }

            // Read sheet1
            ZipEntry sheetEntry = zip.getEntry("xl/worksheets/sheet1.xml");
            if (sheetEntry == null) {
                result.success = false;
                result.error = "Invalid Excel spreadsheet: worksheet 'sheet1.xml' not found.";
                return result;
            }

            try (InputStream is = zip.getInputStream(sheetEntry)) {
                DocumentBuilder db = DocumentBuilderFactory.newInstance().newDocumentBuilder();
                Document doc = db.parse(is);
                NodeList rows = doc.getElementsByTagName("row");

                boolean headerFound = false;
                String colSubject = null;
                String colStudent = null;
                String colInternal = null;
                String colExternal = null;

                for (int i = 0; i < rows.getLength(); i++) {
                    Element rowEl = (Element) rows.item(i);
                    int rowNum = Integer.parseInt(rowEl.getAttribute("r"));

                    Map<String, String> cells = new LinkedHashMap<>();
                    NodeList cList = rowEl.getElementsByTagName("c");
                    for (int j = 0; j < cList.getLength(); j++) {
                        Element c = (Element) cList.item(j);
                        String ref = c.getAttribute("r");
                        String colLetter = ref.replaceAll("[0-9]", "").toUpperCase();
                        String type = c.getAttribute("t");

                        String val = "";
                        if ("inlineStr".equals(type)) {
                            NodeList t = c.getElementsByTagName("t");
                            if (t.getLength() > 0) val = t.item(0).getTextContent();
                        } else {
                            NodeList v = c.getElementsByTagName("v");
                            if (v.getLength() > 0) {
                                val = v.item(0).getTextContent();
                                if ("s".equals(type)) {
                                    try {
                                        int idx = Integer.parseInt(val.trim());
                                        if (idx >= 0 && idx < sharedStrings.size()) {
                                            val = sharedStrings.get(idx);
                                        }
                                    } catch (Exception ignored) {}
                                }
                            } else {
                                NodeList isList = c.getElementsByTagName("is");
                                if (isList.getLength() > 0) {
                                    NodeList tList = ((Element) isList.item(0)).getElementsByTagName("t");
                                    if (tList.getLength() > 0) val = tList.item(0).getTextContent();
                                }
                            }
                        }
                        cells.put(colLetter, val.trim());
                    }

                    if (!headerFound) {
                        boolean hasHeaderKeywords = false;
                        for (String col : cells.keySet()) {
                            String hText = cells.get(col).toLowerCase();
                            if (hText.contains("subject") || hText.contains("student") || hText.contains("sudent")
                                || hText.contains("internal") || hText.contains("external")) {
                                hasHeaderKeywords = true;
                                break;
                            }
                        }

                        if (hasHeaderKeywords) {
                            headerFound = true;
                            List<String> colsWithContent = new ArrayList<>();
                            for (String col : cells.keySet()) {
                                if (!cells.get(col).isEmpty()) {
                                    colsWithContent.add(col);
                                }
                                String hText = cells.get(col).toLowerCase();
                                if (hText.contains("subject") && !hText.contains("mark")) {
                                    colSubject = col;
                                } else if (hText.contains("student") || hText.contains("sudent")) {
                                    colStudent = col;
                                } else if (hText.contains("internal")) {
                                    colInternal = col;
                                } else if (hText.contains("external")) {
                                    colExternal = col;
                                }
                            }

                            // Fallback by column order (1: Subject, 2: Student ID, 3: Internal Marks, 4: External Marks)
                            if (colSubject == null && colsWithContent.size() >= 1) colSubject = colsWithContent.get(0);
                            if (colStudent == null && colsWithContent.size() >= 2) colStudent = colsWithContent.get(1);
                            if (colInternal == null && colsWithContent.size() >= 3) colInternal = colsWithContent.get(2);
                            if (colExternal == null && colsWithContent.size() >= 4) colExternal = colsWithContent.get(3);
                            continue;
                        } else {
                            // Skip non-header title or empty rows prior to header
                            continue;
                        }
                    }

                    String sc = (colSubject != null) ? cells.getOrDefault(colSubject, "") : "";
                    String st = (colStudent != null) ? cells.getOrDefault(colStudent, "") : "";
                    String in = (colInternal != null) ? cells.getOrDefault(colInternal, "") : "";
                    String ex = (colExternal != null) ? cells.getOrDefault(colExternal, "") : "";

                    if (sc.isEmpty() && st.isEmpty() && in.isEmpty() && ex.isEmpty()) {
                        continue; // skip completely blank row
                    }

                    RawRow rObj = new RawRow();
                    rObj.rowNum = rowNum;
                    rObj.subjectCode = sc;
                    rObj.studentId = st;
                    rObj.rawInternal = in;
                    rObj.rawExternal = ex;
                    rawRows.add(rObj);
                    if (sheetSubjectCode == null && !sc.isEmpty()) {
                        sheetSubjectCode = sc;
                    }
                }

                if (!headerFound && rawRows.isEmpty()) {
                    result.success = false;
                    result.error = "Excel header row is missing required columns. Expected: 'Subject Code', 'Student ID' (or 'Sudent ID'), 'Internal Marks (out of 40)', 'External Marks (out of 60)'.";
                    return result;
                }
            }
        } catch (Exception e) {
            result.success = false;
            result.error = "Failed to parse Excel file: " + e.getMessage();
            return result;
        }

        if (rawRows.isEmpty()) {
            result.success = false;
            result.error = "No student marks data found in Excel sheet.";
            return result;
        }

        // Validate rows against database and faculty authorization
        return validateRows(rawRows, facultyId, authorizedSubjectCodes);
    }

    private static class RawRow {
        int rowNum;
        String subjectCode;
        String studentId;
        String rawInternal;
        String rawExternal;
    }

    private PreviewResult validateRows(List<RawRow> rawRows, String facultyId, List<String> authorizedSubjectCodes) {
        PreviewResult res = new PreviewResult();
        res.totalRows = rawRows.size();

        // 1. Identify primary subject from first non-blank row
        String detectedSubjectCode = null;
        int firstRowNum = rawRows.isEmpty() ? 2 : rawRows.get(0).rowNum;
        for (RawRow rr : rawRows) {
            if (rr.subjectCode != null && !rr.subjectCode.trim().isEmpty()) {
                detectedSubjectCode = rr.subjectCode.trim();
                firstRowNum = rr.rowNum;
                break;
            }
        }

        if (detectedSubjectCode == null) {
            res.success = false;
            res.error = "Missing Subject Code: The Subject Code column is blank or absent in the uploaded file. " +
                        "Your assigned subject(s): " + (authorizedSubjectCodes != null ? String.join(", ", authorizedSubjectCodes) : "(none)") +
                        ". The entire file has been rejected and zero marks were saved.";
            return res;
        }

        // Verify faculty authorization
        boolean isAuthorized = false;
        if (authorizedSubjectCodes != null) {
            for (String authCode : authorizedSubjectCodes) {
                if (authCode.equalsIgnoreCase(detectedSubjectCode)) {
                    isAuthorized = true;
                    res.subjectCode = authCode;
                    res.subjectId = authCode;
                    break;
                }
            }
        }

        if (!isAuthorized && authorizedSubjectCodes != null && !authorizedSubjectCodes.isEmpty()) {
            res.success = false;
            res.error = String.format(
                "Access Denied: Subject Code '%s' in uploaded file is not assigned to faculty account '%s'. " +
                "Your assigned subject(s): %s. Zero marks were saved.",
                detectedSubjectCode, facultyId, String.join(", ", authorizedSubjectCodes));
            return res;
        }

        // 2. PRE-SCAN: Verify EVERY row has the expected subject code before any database writes
        final String expectedCode = detectedSubjectCode;
        for (RawRow rr : rawRows) {
            String rowCode = (rr.subjectCode != null) ? rr.subjectCode.trim() : "";
            if (rowCode.isEmpty()) {
                res.success = false;
                res.error = String.format(
                    "Missing Subject Code at row %d: The Subject Code column cannot be blank. " +
                    "Expected '%s'. Your assigned subject(s): %s. " +
                    "The entire file has been rejected and zero marks were saved.",
                    rr.rowNum, expectedCode,
                    (authorizedSubjectCodes != null ? String.join(", ", authorizedSubjectCodes) : "(none)"));
                return res;
            }
            if (!rowCode.equalsIgnoreCase(expectedCode)) {
                res.success = false;
                res.error = String.format(
                    "Subject Code mismatch at row %d: expected '%s', but found '%s'. " +
                    "The uploaded file contains mixed subject codes. Your assigned subject(s): %s. " +
                    "The entire file has been rejected and zero marks were saved.",
                    rr.rowNum, expectedCode, rowCode,
                    (authorizedSubjectCodes != null ? String.join(", ", authorizedSubjectCodes) : "(none)"));
                return res;
            }
        }

        // Load existing registered students and their current marks
        Map<String, String> registeredStudents = new HashMap<>(); // studentId -> studentName
        Map<String, Integer> existingSavedInternals = new HashMap<>(); // studentId -> internalMarks

        try (Connection conn = DBConnection.getConnection()) {
            // Students
            String stSql = "SELECT student_id, student_name FROM students";
            try (PreparedStatement stmt = conn.prepareStatement(stSql);
                 ResultSet rs = stmt.executeQuery()) {
                while (rs.next()) {
                    registeredStudents.put(rs.getString("student_id").trim().toUpperCase(), rs.getString("student_name"));
                }
            }

            // Existing internal marks for this subject
            String marksSql = "SELECT student_id, internal_marks FROM subject_marks WHERE subject_id = ?";
            try (PreparedStatement stmt = conn.prepareStatement(marksSql)) {
                stmt.setString(1, res.subjectId != null ? res.subjectId : detectedSubjectCode);
                try (ResultSet rs = stmt.executeQuery()) {
                    while (rs.next()) {
                        int val = rs.getInt("internal_marks");
                        if (!rs.wasNull()) {
                            existingSavedInternals.put(rs.getString("student_id").trim().toUpperCase(), val);
                        }
                    }
                }
            }
        } catch (SQLException e) {
            res.success = false;
            res.error = "Database error reading institutional records: " + e.getMessage();
            return res;
        }

        Set<String> seenStudentIds = new HashSet<>();
        int validCount = 0;
        int invalidCount = 0;

        // Convert extracted Excel records into a normalized text/CSV stream
        StringBuilder normalizedStream = new StringBuilder();
        normalizedStream.append("Subject,Student ID,Internal Marks,External Marks\n");
        for (RawRow rr : rawRows) {
            normalizedStream.append(escapeCsv(rr.subjectCode)).append(",")
                            .append(escapeCsv(rr.studentId)).append(",")
                            .append(escapeCsv(rr.rawInternal)).append(",")
                            .append(escapeCsv(rr.rawExternal)).append("\n");
        }

        // Use Java java.io.BufferedReader to read the normalized records line by line
        try (BufferedReader bufferedReader = new BufferedReader(new StringReader(normalizedStream.toString()))) {
            String csvLine;
            int csvLineNumber = 0;
            boolean headerSkipped = false;
            int rowIndex = 0;

            while ((csvLine = bufferedReader.readLine()) != null) {
                csvLineNumber++;
                if (!headerSkipped) {
                    headerSkipped = true;
                    continue; // Skip header
                }
                if (rowIndex >= rawRows.size()) break;
                RawRow rr = rawRows.get(rowIndex++);

                MarkRow row = new MarkRow();
                row.rowNumber = rr.rowNum;
                row.subjectCode = rr.subjectCode;
                row.studentId = rr.studentId;
                row.rawInternal = rr.rawInternal;
                row.rawExternal = rr.rawExternal;
                row.status = "VALID";

                List<String> rowErrors = new ArrayList<>();

                // A. Subject code check
                if (rr.subjectCode == null || rr.subjectCode.trim().isEmpty()) {
                    rowErrors.add("Missing Subject Code.");
                    row.status = "INVALID";
                } else if (!rr.subjectCode.trim().equalsIgnoreCase(res.subjectCode)) {
                    rowErrors.add(String.format("Subject Code mismatch: Row specifies '%s', but faculty assigned subject is '%s'.",
                        rr.subjectCode, res.subjectCode));
                    row.status = "INVALID";
                }

                // B. Student ID check
                String trimmedId = rr.studentId != null ? rr.studentId.trim().toUpperCase() : "";
                if (trimmedId.isEmpty()) {
                    rowErrors.add("Missing Student ID.");
                    row.status = "INVALID";
                } else {
                    if (!registeredStudents.containsKey(trimmedId)) {
                        rowErrors.add(String.format("Student ID '%s' not found in institutional student roster.", rr.studentId));
                        row.status = "INVALID";
                    } else {
                        row.studentName = registeredStudents.get(trimmedId);
                    }

                    if (!seenStudentIds.add(trimmedId)) {
                        rowErrors.add(String.format("Duplicate Student ID: '%s' appears multiple times in file.", rr.studentId));
                        row.status = "INVALID";
                    }
                }

                // C. Internal Marks check [0-40] or NULL
                if (rr.rawInternal != null && !rr.rawInternal.trim().isEmpty()) {
                    String sIn = rr.rawInternal.trim();
                    try {
                        double dIn = Double.parseDouble(sIn);
                        if (Double.isNaN(dIn) || Double.isInfinite(dIn)) {
                            rowErrors.add(String.format("Internal marks must be a valid integer between 0 and 40. Received: '%s'.", sIn));
                            row.status = "INVALID";
                        } else if (dIn != Math.floor(dIn)) {
                            rowErrors.add(String.format("Internal marks must be a whole number between 0 and 40. Fractional marks such as '%s' are not accepted.", sIn));
                            row.status = "INVALID";
                        } else {
                            int inVal = (int) dIn;
                            if (inVal < 0 || inVal > 40) {
                                rowErrors.add(String.format("Internal marks out of domain [0-40]. Received: %d.", inVal));
                                row.status = "INVALID";
                            } else {
                                row.internalMarks = inVal;
                            }
                        }
                    } catch (NumberFormatException e) {
                        rowErrors.add(String.format("Internal marks must be a valid integer between 0 and 40. Received: '%s'.", sIn));
                        row.status = "INVALID";
                    }
                } else {
                    row.internalMarks = null; // empty cell preserves NULL
                }

                // D. External Marks check [0-60] or NULL
                if (rr.rawExternal != null && !rr.rawExternal.trim().isEmpty()) {
                    String sEx = rr.rawExternal.trim();
                    try {
                        double dEx = Double.parseDouble(sEx);
                        if (Double.isNaN(dEx) || Double.isInfinite(dEx)) {
                            rowErrors.add(String.format("External marks must be a valid integer between 0 and 60. Received: '%s'.", sEx));
                            row.status = "INVALID";
                        } else if (dEx != Math.floor(dEx)) {
                            rowErrors.add(String.format("External marks must be a whole number between 0 and 60. Fractional marks such as '%s' are not accepted.", sEx));
                            row.status = "INVALID";
                        } else {
                            int exVal = (int) dEx;
                            if (exVal < 0 || exVal > 60) {
                                rowErrors.add(String.format("External marks out of domain [0-60]. Received: %d.", exVal));
                                row.status = "INVALID";
                            } else {
                                row.externalMarks = exVal;
                            }
                        }
                    } catch (NumberFormatException e) {
                        rowErrors.add(String.format("External marks must be a valid integer between 0 and 60. Received: '%s'.", sEx));
                        row.status = "INVALID";
                    }
                } else {
                    row.externalMarks = null; // empty cell preserves NULL
                }

                // E. Internal-First Enforcement
                // External marks can be entered ONLY if valid internal marks are in this row OR already saved in DB
                if (row.externalMarks != null) {
                    boolean hasValidInternal = (row.internalMarks != null) || (existingSavedInternals.containsKey(trimmedId));
                    if (!hasValidInternal) {
                        rowErrors.add("External marks cannot be imported before valid internal marks are saved.");
                        row.status = "INVALID";
                    }
                }

                if (!rowErrors.isEmpty()) {
                    row.errorMessage = String.join("; ", rowErrors);
                }

                if ("VALID".equals(row.status)) {
                    validCount++;
                } else {
                    invalidCount++;
                }

                res.rows.add(row);
            }
        } catch (IOException e) {
            res.success = false;
            res.error = "Error streaming normalized marks through BufferedReader: " + e.getMessage();
            return res;
        }

        res.success = true;
        res.validRowsCount = validCount;
        res.invalidRowsCount = invalidCount;
        return res;
    }

    /**
     * Executes database upsert transaction for all VALID rows.
     * Invalid rows are skipped and returned in rejectedRows.
     * IMPORTANT: caller MUST have already run validateRows() and confirmed preview.success == true
     * before calling this method. A failed preview means zero marks should be saved.
     */
    public CommitResult commitValidMarks(List<MarkRow> rows, String subjectId, String facultyId) throws SQLException {
        CommitResult cr = new CommitResult();
        cr.processedCount = rows != null ? rows.size() : 0;

        if (rows == null || rows.isEmpty()) {
            cr.success = false;
            cr.error = "No marks rows provided for import.";
            return cr;
        }

        // Safety guard: reject entire batch if any row still has a subject code mismatch
        // (defense-in-depth in case commitValidMarks is called without a clean preview)
        for (MarkRow r : rows) {
            if ("VALID".equalsIgnoreCase(r.status) && r.subjectCode != null
                    && !r.subjectCode.trim().isEmpty()
                    && !r.subjectCode.trim().equalsIgnoreCase(subjectId)) {
                cr.success = false;
                cr.error = String.format(
                    "Subject Code mismatch detected during commit: row for '%s' does not match target subject '%s'. " +
                    "Zero marks saved.", r.subjectCode, subjectId);
                return cr;
            }
        }

        Connection conn = null;
        try {
            conn = DBConnection.getConnection();
            conn.setAutoCommit(false); // start transaction

            String sql =
                "INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks) " +
                "VALUES (?, ?, ?, ?) " +
                "ON DUPLICATE KEY UPDATE " +
                "  internal_marks = IF(? IS NOT NULL, VALUES(internal_marks), internal_marks), " +
                "  external_marks = IF(? IS NOT NULL, VALUES(external_marks), external_marks)";

            try (PreparedStatement stmt = conn.prepareStatement(sql)) {
                int imported = 0;
                int rejected = 0;

                for (MarkRow r : rows) {
                    if (!"VALID".equalsIgnoreCase(r.status)) {
                        rejected++;
                        Map<String, String> rej = new HashMap<>();
                        rej.put("studentId", r.studentId != null ? r.studentId : "N/A");
                        rej.put("reason", r.errorMessage != null ? r.errorMessage : "Validation error");
                        cr.rejectedRows.add(rej);
                        continue;
                    }

                    stmt.setString(1, r.studentId);
                    stmt.setString(2, subjectId);

                    // Insert values
                    if (r.internalMarks != null) {
                        stmt.setInt(3, r.internalMarks);
                        stmt.setInt(5, r.internalMarks);
                    } else {
                        stmt.setNull(3, java.sql.Types.INTEGER);
                        stmt.setNull(5, java.sql.Types.INTEGER);
                    }

                    if (r.externalMarks != null) {
                        stmt.setInt(4, r.externalMarks);
                        stmt.setInt(6, r.externalMarks);
                    } else {
                        stmt.setNull(4, java.sql.Types.INTEGER);
                        stmt.setNull(6, java.sql.Types.INTEGER);
                    }

                    stmt.executeUpdate();
                    imported++;
                }

                conn.commit(); // atomic commit
                cr.success = true;
                cr.validCount = imported;
                cr.invalidCount = rejected;
                cr.importedCount = imported;
                cr.rejectedCount = rejected;
                cr.message = String.format("Marks import completed: %d imported, %d rejected.", imported, rejected);

                // Automatically maintain and refresh backend CSV table files:
                // students.csv, subjects.csv, faculty_assignments.csv, marks.csv, results.csv
                try {
                    File exportDir = new File(System.getProperty("user.dir"), "data" + File.separator + "export");
                    TableFileExportService exportService = new TableFileExportService();
                    exportService.exportAll(exportDir.getAbsolutePath());
                } catch (Exception ex) {
                    Logger.getLogger(MarksImportService.class.getName())
                          .warning("Failed to refresh backend CSV table files: " + ex.getMessage());
                }
            }
        } catch (SQLException e) {
            if (conn != null) {
                try { conn.rollback(); } catch (SQLException ignored) {}
            }
            cr.success = false;
            cr.error = "Transaction failed: " + e.getMessage();
            throw e;
        } finally {
            if (conn != null) {
                try { conn.setAutoCommit(true); conn.close(); } catch (SQLException ignored) {}
            }
        }

        return cr;
    }

    private static String escapeCsv(String text) {
        if (text == null) return "";
        if (text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r")) {
            return "\"" + text.replace("\"", "\"\"") + "\"";
        }
        return text;
    }

    private static String escapeXml(String text) {
        if (text == null) return "";
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }
}
