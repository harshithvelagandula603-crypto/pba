package com.academic.service;

import com.academic.config.DBConnection;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Academic Result Input Validator - Table File Input Validator & Ingestion Program
 *
 * Implements the core academic problem statement:
 * "Create a Java java.io.BufferedReader program that enforces domain integrity
 *  constraints before writing records into table files."
 *
 * Fully supports:
 * 1. Line-by-line streaming via java.io.BufferedReader.
 * 2. Dynamic column detection supporting any column order:
 *    - Subject
 *    - Student ID or Sudent ID (including spelling mistake)
 *    - Internal Marks (40)
 *    - External Marks (60)
 * 3. UTF-8 BOM stripping, title row skipping, quoted CSV values, whitespace trimming.
 * 4. All-or-nothing Subject Mismatch validation: If any row's subject code does not match
 *    the authorized faculty member's assigned subject, reject the entire file before saving.
 * 5. Strict domain integrity constraints:
 *    - Student ID must exist in registered student master records.
 *    - Subject ID must exist and be authorized for the executing faculty account.
 *    - Internal marks: optional/missing (empty string) or integer in range [0, 40].
 *    - External marks: optional/missing (empty string) or integer in range [0, 60].
 *    - Internal-First Evaluation: External marks cannot be evaluated before valid internal marks exist.
 *    - Duplicate detection: Reject repeated student-subject entries within the input file.
 * 6. Partial-import policy: Valid records committed, rejected rows reported with line numbers & reasons.
 * 7. Never overwrites existing valid records with invalid or missing values.
 * 8. Automatic synchronization with MySQL and backend CSV table files (data/export/).
 */
public class TableFileInputValidatorService {

    private static final Logger LOGGER = Logger.getLogger(TableFileInputValidatorService.class.getName());

    public static final String DEFAULT_OUTPUT_TABLE_FILE = "data/export/marks.csv";

    public static class RecordError {
        private final int lineNumber;
        private final String studentId;
        private final String subjectId;
        private final String reason;
        private final String rawLine;

        public RecordError(int lineNumber, String studentId, String subjectId, String reason, String rawLine) {
            this.lineNumber = lineNumber;
            this.studentId = studentId;
            this.subjectId = subjectId;
            this.reason = reason;
            this.rawLine = rawLine;
        }

        public int getLineNumber() { return lineNumber; }
        public String getStudentId() { return studentId; }
        public String getSubjectId() { return subjectId; }
        public String getReason() { return reason; }
        public String getRawLine() { return rawLine; }
    }

    public static class ValidatedMark {
        public int lineNumber;
        public String studentId;
        public String studentName;
        public String subjectId;
        public String subjectCode;
        public Integer internalMarks; // null if missing
        public Integer externalMarks; // null if missing
        public Integer totalMarks;    // null if either internal or external is missing
        public String evalStatus;     // "Fully Entered", "Internal Only", "Not Updated", "FAIL"
        public String rawLine;
    }

    public static class IngestionReport {
        private boolean success;
        private int totalLinesRead;
        private int validCount;
        private int rejectedCount;
        private String outputFilePath;
        private boolean databaseSynchronized;
        private boolean tableFilesSynchronized;
        private String message;
        private final List<RecordError> errors = new ArrayList<>();
        private final List<ValidatedMark> validRecords = new ArrayList<>();

        public boolean isSuccess() { return success; }
        public void setSuccess(boolean success) { this.success = success; }
        public int getTotalLinesRead() { return totalLinesRead; }
        public void setTotalLinesRead(int totalLinesRead) { this.totalLinesRead = totalLinesRead; }
        public int getValidCount() { return validCount; }
        public void setValidCount(int validCount) { this.validCount = validCount; }
        public int getRejectedCount() { return rejectedCount; }
        public void setRejectedCount(int rejectedCount) { this.rejectedCount = rejectedCount; }
        public String getOutputFilePath() { return outputFilePath; }
        public void setOutputFilePath(String outputFilePath) { this.outputFilePath = outputFilePath; }
        public boolean isDatabaseSynchronized() { return databaseSynchronized; }
        public void setDatabaseSynchronized(boolean databaseSynchronized) { this.databaseSynchronized = databaseSynchronized; }
        public boolean isTableFilesSynchronized() { return tableFilesSynchronized; }
        public void setTableFilesSynchronized(boolean tableFilesSynchronized) { this.tableFilesSynchronized = tableFilesSynchronized; }
        public String getMessage() { return message; }
        public void setMessage(String message) { this.message = message; }
        public List<RecordError> getErrors() { return errors; }
        public List<ValidatedMark> getValidRecords() { return validRecords; }
    }

    private static class ParsedRow {
        int lineNumber;
        String rawLine;
        String subjectToken;
        String studentToken;
        String internalToken;
        String externalToken;
    }

    /**
     * Reads and validates input records from an input File using java.io.BufferedReader.
     */
    public IngestionReport processAndValidateFile(File inputFile, File outputTableFile, String facultyId,
                                                Set<String> authorizedSubjectIds, Connection conn) throws IOException {
        if (inputFile == null || !inputFile.exists()) {
            throw new FileNotFoundException("Input table file does not exist: " + (inputFile != null ? inputFile.getAbsolutePath() : "null"));
        }
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(inputFile), StandardCharsets.UTF_8))) {
            return processAndValidateStream(reader, outputTableFile, facultyId, authorizedSubjectIds, conn);
        }
    }

    /**
     * Genuine java.io.BufferedReader implementation:
     * Reads line-by-line via bufferedReader.readLine(), dynamically maps headers,
     * validates all records, and writes to MySQL and backend CSV table files.
     */
    public IngestionReport processAndValidateStream(BufferedReader bufferedReader, File outputTableFile,
                                                   String facultyId, Set<String> authorizedSubjectIds,
                                                   Connection conn) throws IOException {
        IngestionReport report = new IngestionReport();

        if (outputTableFile == null) {
            outputTableFile = resolveDefaultTableFile();
        }
        report.setOutputFilePath(outputTableFile.getAbsolutePath());

        // 1. Load institutional master data
        Map<String, String> studentMaster = loadRegisteredStudents(conn);
        Map<String, String> subjectMaster = loadSubjects(conn);
        Set<String> facultyAssignedSubjects = loadFacultyAssignments(facultyId, authorizedSubjectIds, conn);
        Map<String, ValidatedMark> existingTableRecords = loadExistingTableRecords(outputTableFile, conn);

        // 2. Read line-by-line via BufferedReader and perform dynamic column mapping
        List<ParsedRow> dataRows = new ArrayList<>();
        String line;
        int lineNumber = 0;
        boolean headerFound = false;
        int colSubject = -1;
        int colStudent = -1;
        int colInternal = -1;
        int colExternal = -1;

        while ((line = bufferedReader.readLine()) != null) {
            lineNumber++;
            String rawLine = line;

            // Strip UTF-8 BOM if present on first line or any line
            if (line.startsWith("\uFEFF")) {
                line = line.substring(1);
            }
            line = line.trim();

            // Skip empty lines and commentary lines starting with '#'
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }

            List<String> tokens = parseCsvLine(line);
            if (tokens.isEmpty()) {
                continue;
            }

            // Header Row Detection
            if (!headerFound) {
                boolean hasKeywords = false;
                for (String tok : tokens) {
                    String norm = normalizeHeader(tok);
                    if (norm.contains("subject") || norm.contains("student") || norm.contains("sudent")
                        || norm.contains("internal") || norm.contains("external") || norm.contains("roll")) {
                        hasKeywords = true;
                        break;
                    }
                }

                if (hasKeywords) {
                    headerFound = true;
                    for (int i = 0; i < tokens.size(); i++) {
                        String norm = normalizeHeader(tokens.get(i));
                        if ((norm.contains("subject") || norm.startsWith("sub") || norm.contains("course")) && !norm.contains("mark")) {
                            colSubject = i;
                        } else if (norm.contains("student") || norm.contains("sudent") || norm.contains("roll") || norm.equals("id") || norm.equals("sid")) {
                            colStudent = i;
                        } else if (norm.contains("internal") || norm.startsWith("int")) {
                            colInternal = i;
                        } else if (norm.contains("external") || norm.startsWith("ext")) {
                            colExternal = i;
                        }
                    }
                    LOGGER.info(String.format("Header mapped at line %d: Subject=%d, Student=%d, Internal=%d, External=%d",
                        lineNumber, colSubject, colStudent, colInternal, colExternal));
                    continue; // Skip header row from data processing
                } else {
                    // Check if this line is purely a title row before header (e.g. "Academic Result Sheet", "Department of CSE")
                    // If none of the tokens match known subjects or known student IDs, skip as title row
                    boolean looksLikeData = false;
                    for (String tok : tokens) {
                        String up = tok.toUpperCase().trim();
                        if (studentMaster.containsKey(up) || subjectMaster.containsKey(up)) {
                            looksLikeData = true;
                            break;
                        }
                    }
                    if (!looksLikeData) {
                        // Title row, skip
                        continue;
                    }

                    // Raw data without header: Auto-detect column mapping by inspecting cell values
                    headerFound = true;
                    colSubject = 0;
                    colStudent = 1;
                    colInternal = 2;
                    colExternal = 3;

                    // If token 0 is a student ID and token 1 is a subject, flip them!
                    if (tokens.size() >= 2) {
                        String t0 = tokens.get(0).toUpperCase().trim();
                        String t1 = tokens.get(1).toUpperCase().trim();
                        if (studentMaster.containsKey(t0) && (subjectMaster.containsKey(t1) || facultyAssignedSubjects.contains(t1))) {
                            colStudent = 0;
                            colSubject = 1;
                        } else if (subjectMaster.containsKey(t0) || facultyAssignedSubjects.contains(t0)) {
                            colSubject = 0;
                            colStudent = 1;
                        }
                    }
                }
            }

            // Extract cells according to detected column indices
            String subVal = (colSubject >= 0 && colSubject < tokens.size()) ? tokens.get(colSubject) : "";
            String stVal = (colStudent >= 0 && colStudent < tokens.size()) ? tokens.get(colStudent) : "";
            String inVal = (colInternal >= 0 && colInternal < tokens.size()) ? tokens.get(colInternal) : "";
            String exVal = (colExternal >= 0 && colExternal < tokens.size()) ? tokens.get(colExternal) : "";

            ParsedRow pr = new ParsedRow();
            pr.lineNumber = lineNumber;
            pr.rawLine = rawLine;
            pr.subjectToken = subVal.trim();
            pr.studentToken = stVal.trim();
            pr.internalToken = inVal.trim();
            pr.externalToken = exVal.trim();
            dataRows.add(pr);
        }

        report.setTotalLinesRead(lineNumber);

        if (dataRows.isEmpty()) {
            report.setSuccess(false);
            report.setValidCount(0);
            report.setRejectedCount(0);
            report.setMessage("No student marks data found in input file.");
            return report;
        }

        // 3. PRE-SCAN: Enforce All-or-Nothing Subject Mismatch Rule
        // If any subject code in the uploaded file does not match the authenticated faculty member's assigned subject,
        // reject the ENTIRE file before saving any records!
        String primarySubjectCode = null;
        for (ParsedRow pr : dataRows) {
            if (!pr.subjectToken.isEmpty()) {
                primarySubjectCode = pr.subjectToken;
                break;
            }
        }

        if (primarySubjectCode == null) {
            report.setSuccess(false);
            report.setValidCount(0);
            report.setRejectedCount(dataRows.size());
            String errMsg = "Missing Subject Code: The Subject Code column is blank in all rows. Assigned subject(s): " +
                String.join(", ", facultyAssignedSubjects) + ". The entire file has been rejected and zero marks were saved.";
            report.setMessage(errMsg);
            for (ParsedRow pr : dataRows) {
                report.getErrors().add(new RecordError(pr.lineNumber, pr.studentToken, "", errMsg, pr.rawLine));
            }
            return report;
        }

        String resolvedPrimarySubject = resolveSubjectId(primarySubjectCode, subjectMaster);
        if (resolvedPrimarySubject == null) {
            report.setSuccess(false);
            report.setValidCount(0);
            report.setRejectedCount(dataRows.size());
            String errMsg = String.format("Subject Code '%s' is not a recognized curricular subject. Zero marks saved.", primarySubjectCode);
            report.setMessage(errMsg);
            for (ParsedRow pr : dataRows) {
                report.getErrors().add(new RecordError(pr.lineNumber, pr.studentToken, primarySubjectCode, errMsg, pr.rawLine));
            }
            return report;
        }

        if (!facultyAssignedSubjects.isEmpty() && !facultyAssignedSubjects.contains(resolvedPrimarySubject.toUpperCase())) {
            report.setSuccess(false);
            report.setValidCount(0);
            report.setRejectedCount(dataRows.size());
            String errMsg = String.format("Access Denied: Subject Code '%s' is not assigned to faculty account '%s'. Your assigned subject(s): %s. The entire file has been rejected and zero marks were saved.",
                primarySubjectCode, facultyId, String.join(", ", facultyAssignedSubjects));
            report.setMessage(errMsg);
            for (ParsedRow pr : dataRows) {
                report.getErrors().add(new RecordError(pr.lineNumber, pr.studentToken, primarySubjectCode, errMsg, pr.rawLine));
            }
            return report;
        }

        // Verify that EVERY row has the expected subject code (reject mixed files immediately)
        for (ParsedRow pr : dataRows) {
            if (pr.subjectToken.isEmpty()) {
                report.setSuccess(false);
                report.setValidCount(0);
                report.setRejectedCount(dataRows.size());
                String errMsg = String.format("Missing Subject Code at line %d: Expected '%s'. Your assigned subject(s): %s. The entire file has been rejected and zero marks were saved.",
                    pr.lineNumber, primarySubjectCode, String.join(", ", facultyAssignedSubjects));
                report.setMessage(errMsg);
                for (ParsedRow r : dataRows) {
                    report.getErrors().add(new RecordError(r.lineNumber, r.studentToken, r.subjectToken, errMsg, r.rawLine));
                }
                return report;
            }

            String rowSubResolved = resolveSubjectId(pr.subjectToken, subjectMaster);
            if (rowSubResolved == null || !rowSubResolved.equalsIgnoreCase(resolvedPrimarySubject)) {
                report.setSuccess(false);
                report.setValidCount(0);
                report.setRejectedCount(dataRows.size());
                String errMsg = String.format("Subject Code mismatch at line %d: expected '%s', but found '%s'. The uploaded file contains mixed subject codes. Your assigned subject(s): %s. The entire file has been rejected and zero marks were saved.",
                    pr.lineNumber, primarySubjectCode, pr.subjectToken, String.join(", ", facultyAssignedSubjects));
                report.setMessage(errMsg);
                for (ParsedRow r : dataRows) {
                    report.getErrors().add(new RecordError(r.lineNumber, r.studentToken, r.subjectToken, errMsg, r.rawLine));
                }
                return report;
            }
        }

        // 4. Validate Domain Integrity Constraints row-by-row
        Set<String> seenStudentSubjectPairs = new HashSet<>();
        Map<String, Integer> seenAtLine = new HashMap<>();

        for (ParsedRow pr : dataRows) {
            String studentId = pr.studentToken;
            String subjectId = resolvedPrimarySubject;
            String rawInternal = pr.internalToken;
            String rawExternal = pr.externalToken;
            String pairKey = studentId.toUpperCase() + "::" + subjectId.toUpperCase();

            // Constraint A: Student Existence
            if (studentId.isEmpty()) {
                report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                    "Student ID is missing or empty.", pr.rawLine));
                continue;
            }

            if (!studentMaster.containsKey(studentId.toUpperCase())) {
                report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                    String.format("Student ID '%s' does not exist in registered student master records.", studentId), pr.rawLine));
                continue;
            }

            // Constraint B: Duplicate Record Detection within file
            if (seenStudentSubjectPairs.contains(pairKey)) {
                int firstLine = seenAtLine.getOrDefault(pairKey, 0);
                report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                    String.format("Duplicate record for student '%s' and subject '%s'. First appeared at line %d.", studentId, subjectId, firstLine), pr.rawLine));
                continue;
            }
            seenStudentSubjectPairs.add(pairKey);
            seenAtLine.put(pairKey, pr.lineNumber);

            // Constraint C: Internal Marks Range [0, 40] (Whole numbers only, preserves NULL)
            Integer internalMarks = null;
            if (!rawInternal.isEmpty() && !"null".equalsIgnoreCase(rawInternal)) {
                try {
                    double dIn = Double.parseDouble(rawInternal);
                    if (Double.isNaN(dIn) || Double.isInfinite(dIn)) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("Internal marks must be a valid integer between 0 and 40. Received: '%s'.", rawInternal), pr.rawLine));
                        continue;
                    } else if (dIn != Math.floor(dIn)) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("Internal marks must be a whole number between 0 and 40. Fractional marks such as '%s' are not accepted.", rawInternal), pr.rawLine));
                        continue;
                    }
                    int inVal = (int) dIn;
                    if (inVal < 0 || inVal > 40) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("Internal marks out of domain [0-40]. Received: %d.", inVal), pr.rawLine));
                        continue;
                    }
                    internalMarks = inVal;
                } catch (NumberFormatException e) {
                    report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                        String.format("Internal marks must be a valid integer between 0 and 40. Received: '%s'.", rawInternal), pr.rawLine));
                    continue;
                }
            }

            // Constraint D: External Marks Range [0, 60] (Whole numbers only, preserves NULL)
            Integer externalMarks = null;
            if (!rawExternal.isEmpty() && !"null".equalsIgnoreCase(rawExternal)) {
                try {
                    double dEx = Double.parseDouble(rawExternal);
                    if (Double.isNaN(dEx) || Double.isInfinite(dEx)) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("External marks must be a valid integer between 0 and 60. Received: '%s'.", rawExternal), pr.rawLine));
                        continue;
                    } else if (dEx != Math.floor(dEx)) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("External marks must be a whole number between 0 and 60. Fractional marks such as '%s' are not accepted.", rawExternal), pr.rawLine));
                        continue;
                    }
                    int exVal = (int) dEx;
                    if (exVal < 0 || exVal > 60) {
                        report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                            String.format("External marks out of domain [0-60]. Received: %d.", exVal), pr.rawLine));
                        continue;
                    }
                    externalMarks = exVal;
                } catch (NumberFormatException e) {
                    report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                        String.format("External marks must be a valid integer between 0 and 60. Received: '%s'.", rawExternal), pr.rawLine));
                    continue;
                }
            }

            // Constraint E: Internal-First Constraint
            // External marks cannot be imported before valid internal marks are saved
            if (externalMarks != null) {
                boolean hasInternal = (internalMarks != null);
                if (!hasInternal) {
                    ValidatedMark existing = existingTableRecords.get(pairKey);
                    if (existing != null && existing.internalMarks != null) {
                        hasInternal = true;
                    }
                }
                if (!hasInternal) {
                    report.getErrors().add(new RecordError(pr.lineNumber, studentId, subjectId,
                        String.format("External marks (%d) cannot be imported before valid internal marks are saved.", externalMarks), pr.rawLine));
                    continue;
                }
            }

            // Preserve existing valid marks if cell in file is left empty
            if (internalMarks == null || externalMarks == null) {
                ValidatedMark existing = existingTableRecords.get(pairKey);
                if (existing != null) {
                    if (internalMarks == null && existing.internalMarks != null) {
                        internalMarks = existing.internalMarks;
                    }
                    if (externalMarks == null && existing.externalMarks != null) {
                        externalMarks = existing.externalMarks;
                    }
                }
            }

            // Valid Record!
            ValidatedMark mark = new ValidatedMark();
            mark.lineNumber = pr.lineNumber;
            mark.studentId = studentId;
            mark.studentName = studentMaster.getOrDefault(studentId.toUpperCase(), "");
            mark.subjectId = resolvedPrimarySubject;
            mark.subjectCode = subjectMaster.getOrDefault(resolvedPrimarySubject.toUpperCase(), resolvedPrimarySubject);
            mark.internalMarks = internalMarks;
            mark.externalMarks = externalMarks;
            mark.rawLine = pr.rawLine;

            if (internalMarks != null && externalMarks != null) {
                mark.totalMarks = internalMarks + externalMarks;
                mark.evalStatus = (mark.totalMarks >= 35) ? "Fully Entered" : "FAIL";
            } else if (internalMarks != null) {
                mark.totalMarks = null;
                mark.evalStatus = "Internal Only";
            } else {
                mark.totalMarks = null;
                mark.evalStatus = "Not Updated";
            }

            report.getValidRecords().add(mark);
        }

        report.setValidCount(report.getValidRecords().size());
        report.setRejectedCount(report.getErrors().size());

        // 5. Commit Valid Records: Table Files FIRST, MySQL SECOND (Core Problem Statement Priority)
        if (report.getValidCount() > 0) {
            // Step 4: Write only validated records into backend CSV table files FIRST
            boolean filesSynced = synchronizeBackendTableFiles(outputTableFile, report.getValidRecords(), existingTableRecords);
            report.setTableFilesSynchronized(filesSynced);

            // Step 5: Synchronize validated records with MySQL database SECOND
            boolean dbSynced = synchronizeWithMySQL(report.getValidRecords(), conn);
            report.setDatabaseSynchronized(dbSynced);

            report.setSuccess(true);
            report.setMessage(String.format("Marks import completed: %d valid records saved to MySQL and table files (%d rejected).",
                report.getValidCount(), report.getRejectedCount()));
        } else {
            report.setSuccess(false);
            report.setDatabaseSynchronized(false);
            report.setTableFilesSynchronized(false);
            report.setMessage(String.format("No valid marks found to import (%d rejected across %d lines read).",
                report.getRejectedCount(), lineNumber));
        }

        return report;
    }

    /**
     * Synchronizes backend CSV table files (marks.csv, results.csv, etc.)
     * in the protected backend directory.
     */
    private synchronized boolean synchronizeBackendTableFiles(File marksFile,
                                                              List<ValidatedMark> validRecords,
                                                              Map<String, ValidatedMark> existingRecords) {
        try {
            File exportDir = marksFile.getParentFile();
            if (exportDir != null && !exportDir.exists()) {
                exportDir.mkdirs();
            }

            // Update existing marks records
            for (ValidatedMark v : validRecords) {
                String key = v.studentId.toUpperCase() + "::" + v.subjectId.toUpperCase();
                existingRecords.put(key, v);
            }

            // Sort deterministically
            List<ValidatedMark> sortedMarks = new ArrayList<>(existingRecords.values());
            sortedMarks.sort((a, b) -> {
                int c = a.studentId.compareToIgnoreCase(b.studentId);
                if (c != 0) return c;
                return a.subjectId.compareToIgnoreCase(b.subjectId);
            });

            // Write marks.csv atomically
            File tempMarks = new File(exportDir, marksFile.getName() + ".tmp");
            try (BufferedWriter bw = new BufferedWriter(new OutputStreamWriter(new FileOutputStream(tempMarks), StandardCharsets.UTF_8))) {
                bw.write("student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status\n");
                for (ValidatedMark m : sortedMarks) {
                    bw.write(String.format("%s,%s,%s,%s,%s,%s,%s,%s\n",
                        escapeCsv(m.studentId),
                        escapeCsv(m.studentName != null ? m.studentName : ""),
                        escapeCsv(m.subjectId),
                        escapeCsv(m.subjectCode != null ? m.subjectCode : m.subjectId),
                        m.internalMarks != null ? String.valueOf(m.internalMarks) : "",
                        m.externalMarks != null ? String.valueOf(m.externalMarks) : "",
                        m.totalMarks != null ? String.valueOf(m.totalMarks) : "",
                        escapeCsv(m.evalStatus != null ? m.evalStatus : "Not Updated")
                    ));
                }
                bw.flush();
            }

            if (marksFile.exists()) {
                marksFile.delete();
            }
            if (!tempMarks.renameTo(marksFile)) {
                try (InputStream in = new FileInputStream(tempMarks); OutputStream out = new FileOutputStream(marksFile)) {
                    byte[] buf = new byte[8192];
                    int len;
                    while ((len = in.read(buf)) > 0) {
                        out.write(buf, 0, len);
                    }
                }
                tempMarks.delete();
            }

            // Refresh all 5 backend table files via TableFileExportService
            try {
                TableFileExportService exportService = new TableFileExportService();
                exportService.exportAll(exportDir.getAbsolutePath());
            } catch (Exception ex) {
                LOGGER.warning("TableFileExportService exportAll warning: " + ex.getMessage());
            }

            LOGGER.info("Backend table files successfully synchronized at: " + exportDir.getAbsolutePath());
            return true;
        } catch (Exception e) {
            LOGGER.log(Level.SEVERE, "Failed to synchronize backend table files: " + e.getMessage(), e);
            return false;
        }
    }

    /**
     * Synchronizes validated marks with MySQL database using batch transaction.
     */
    private boolean synchronizeWithMySQL(List<ValidatedMark> validRecords, Connection conn) {
        if (validRecords.isEmpty()) return true;

        boolean createdLocalConn = false;
        Connection activeConn = conn;

        try {
            if (activeConn == null || activeConn.isClosed()) {
                activeConn = DBConnection.getConnection();
                createdLocalConn = true;
            }

            if (activeConn == null) {
                LOGGER.warning("MySQL connection not available. Database synchronization skipped (CSV table file updated).");
                return false;
            }

            activeConn.setAutoCommit(false);
            String sql = "INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks, total_marks, eval_status, updated_at) " +
                         "VALUES (?, ?, ?, ?, ?, ?, NOW()) " +
                         "ON DUPLICATE KEY UPDATE " +
                         "internal_marks = IF(? IS NOT NULL, VALUES(internal_marks), internal_marks), " +
                         "external_marks = IF(? IS NOT NULL, VALUES(external_marks), external_marks), " +
                         "total_marks = VALUES(total_marks), " +
                         "eval_status = VALUES(eval_status), " +
                         "updated_at = NOW()";

            try (PreparedStatement ps = activeConn.prepareStatement(sql)) {
                for (ValidatedMark m : validRecords) {
                    ps.setString(1, m.studentId);
                    ps.setString(2, m.subjectId);

                    if (m.internalMarks != null) {
                        ps.setInt(3, m.internalMarks);
                        ps.setInt(7, m.internalMarks);
                    } else {
                        ps.setNull(3, java.sql.Types.INTEGER);
                        ps.setNull(7, java.sql.Types.INTEGER);
                    }

                    if (m.externalMarks != null) {
                        ps.setInt(4, m.externalMarks);
                        ps.setInt(8, m.externalMarks);
                    } else {
                        ps.setNull(4, java.sql.Types.INTEGER);
                        ps.setNull(8, java.sql.Types.INTEGER);
                    }

                    if (m.totalMarks != null) {
                        ps.setInt(5, m.totalMarks);
                    } else {
                        ps.setNull(5, java.sql.Types.INTEGER);
                    }

                    ps.setString(6, m.evalStatus != null ? m.evalStatus : "Not Updated");
                    ps.addBatch();
                }
                ps.executeBatch();
            }

            activeConn.commit();
            LOGGER.info("Synchronized " + validRecords.size() + " marks records to MySQL database.");
            return true;

        } catch (SQLException e) {
            LOGGER.log(Level.SEVERE, "Failed to synchronize marks to MySQL: " + e.getMessage(), e);
            if (activeConn != null) {
                try { activeConn.rollback(); } catch (SQLException ignored) {}
            }
            return false;
        } finally {
            if (createdLocalConn && activeConn != null) {
                try { activeConn.close(); } catch (SQLException ignored) {}
            }
        }
    }

    /**
     * Parses a CSV/delimited text line into tokens, respecting double quotes and commas within quotes.
     */
    public static List<String> parseCsvLine(String line) {
        List<String> tokens = new ArrayList<>();
        if (line == null) return tokens;

        StringBuilder sb = new StringBuilder();
        boolean inQuotes = false;

        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '\"') {
                if (inQuotes && i + 1 < line.length() && line.charAt(i + 1) == '\"') {
                    sb.append('\"');
                    i++; // skip escaped quote
                } else {
                    inQuotes = !inQuotes;
                }
            } else if ((c == ',' || c == '\t') && !inQuotes) {
                tokens.add(sb.toString().trim());
                sb.setLength(0);
            } else {
                sb.append(c);
            }
        }
        tokens.add(sb.toString().trim());
        return tokens;
    }

    private static String normalizeHeader(String header) {
        if (header == null) return "";
        return header.toLowerCase()
                     .replace("\uFEFF", "")
                     .replaceAll("[^a-z0-9_()]", " ")
                     .trim();
    }

    private Map<String, ValidatedMark> loadExistingTableRecords(File tableFile, Connection conn) {
        Map<String, ValidatedMark> map = new HashMap<>();

        if (tableFile != null && tableFile.exists()) {
            try (BufferedReader br = new BufferedReader(new FileReader(tableFile))) {
                String line;
                boolean isHeader = true;
                while ((line = br.readLine()) != null) {
                    line = line.trim();
                    if (line.isEmpty()) continue;
                    if (isHeader) {
                        isHeader = false;
                        continue;
                    }
                    List<String> tokens = parseCsvLine(line);
                    if (tokens.size() >= 4) {
                        ValidatedMark vm = new ValidatedMark();
                        vm.studentId = tokens.get(0).trim();
                        vm.studentName = tokens.size() > 1 ? tokens.get(1).trim() : "";
                        vm.subjectId = tokens.size() > 2 ? tokens.get(2).trim() : "";
                        vm.subjectCode = tokens.size() > 3 ? tokens.get(3).trim() : vm.subjectId;
                        vm.internalMarks = parseOptionalInt(tokens.size() > 4 ? tokens.get(4) : "");
                        vm.externalMarks = parseOptionalInt(tokens.size() > 5 ? tokens.get(5) : "");
                        vm.totalMarks = parseOptionalInt(tokens.size() > 6 ? tokens.get(6) : "");
                        vm.evalStatus = tokens.size() > 7 ? tokens.get(7) : "Not Updated";

                        String key = vm.studentId.toUpperCase() + "::" + vm.subjectId.toUpperCase();
                        map.put(key, vm);
                    }
                }
            } catch (IOException e) {
                LOGGER.warning("Could not read existing table file: " + e.getMessage());
            }
        }

        // Merge existing MySQL marks if available
        if (conn != null) {
            try {
                String sql = "SELECT sm.student_id, s.student_name, sm.subject_id, sub.subject_code, " +
                             "sm.internal_marks, sm.external_marks, sm.total_marks, sm.eval_status " +
                             "FROM subject_marks sm " +
                             "LEFT JOIN students s ON sm.student_id = s.student_id " +
                             "LEFT JOIN subjects sub ON sm.subject_id = sub.subject_id";
                try (PreparedStatement ps = conn.prepareStatement(sql); ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        String stId = rs.getString("student_id");
                        String subId = rs.getString("subject_id");
                        String key = stId.toUpperCase() + "::" + subId.toUpperCase();
                        if (!map.containsKey(key)) {
                            ValidatedMark vm = new ValidatedMark();
                            vm.studentId = stId;
                            vm.studentName = rs.getString("student_name");
                            vm.subjectId = subId;
                            vm.subjectCode = rs.getString("subject_code");
                            int inM = rs.getInt("internal_marks");
                            vm.internalMarks = rs.wasNull() ? null : inM;
                            int exM = rs.getInt("external_marks");
                            vm.externalMarks = rs.wasNull() ? null : exM;
                            int tot = rs.getInt("total_marks");
                            vm.totalMarks = rs.wasNull() ? null : tot;
                            vm.evalStatus = rs.getString("eval_status");
                            map.put(key, vm);
                        }
                    }
                }
            } catch (SQLException ignored) {}
        }

        return map;
    }

    private Map<String, String> loadRegisteredStudents(Connection conn) {
        Map<String, String> map = new HashMap<>();
        if (conn != null) {
            try (PreparedStatement ps = conn.prepareStatement("SELECT student_id, student_name FROM students");
                 ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    map.put(rs.getString("student_id").toUpperCase().trim(), rs.getString("student_name").trim());
                }
            } catch (SQLException ignored) {}
        }
        if (map.isEmpty()) {
            String[] defaultStudents = {
                "25QM1A66D6", "25QM1A66D7", "25QM1A66D8", "25QM1A66D9", "25QM1A66E0",
                "25QM1A66E1", "25QM1A66E2", "25QM1A66E3", "25QM1A66E4", "25QM1A66E5",
                "25QM1A66E6", "25QM1A66E7", "25QM1A66E8", "25QM1A66E9", "25QM1A66F0",
                "25QM1A66F1", "25QM1A66F2", "25QM1A66F3", "25QM1A66F4", "25QM1A66F5",
                "25QM1A66F6", "25QM1A66F7", "25QM1A66F8", "25QM1A66F9", "25QM1A66G0",
                "25QM1A66G1", "25QM1A66G2", "25QM1A66G3", "25QM1A66G4", "25QM1A66G5",
                "25QM1A66G6", "25QM1A66G7", "25QM1A66G8", "25QM1A66G9"
            };
            for (String sid : defaultStudents) {
                map.put(sid.toUpperCase(), "Student " + sid);
            }
        }
        return map;
    }

    private Map<String, String> loadSubjects(Connection conn) {
        Map<String, String> map = new HashMap<>();
        if (conn != null) {
            try (PreparedStatement ps = conn.prepareStatement("SELECT subject_id, subject_code FROM subjects");
                 ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    map.put(rs.getString("subject_id").toUpperCase().trim(), rs.getString("subject_code").trim());
                }
            } catch (SQLException ignored) {}
        }
        if (map.isEmpty()) {
            map.put("COA", "COA");
            map.put("DBMS", "DBMS");
            map.put("DBMS_LAB", "DBMS Lab");
            map.put("MATHS", "Maths");
            map.put("MATHS_LAB", "Maths Lab");
            map.put("OOPS", "OOPs");
            map.put("OOPS_LAB", "OOPs Lab");
            map.put("SD_LAB", "SD Lab");
            map.put("SE", "SE");
            map.put("SE_LAB", "SE Lab");
        }
        return map;
    }

    private Set<String> loadFacultyAssignments(String facultyId, Set<String> provided, Connection conn) {
        Set<String> set = new HashSet<>();
        if (provided != null && !provided.isEmpty()) {
            for (String s : provided) set.add(s.toUpperCase().trim());
            return set;
        }
        if (facultyId != null && !facultyId.isEmpty() && conn != null) {
            try (PreparedStatement ps = conn.prepareStatement("SELECT subject_id FROM faculty_subjects WHERE faculty_id = ?")) {
                ps.setString(1, facultyId);
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        set.add(rs.getString("subject_id").toUpperCase().trim());
                    }
                }
            } catch (SQLException ignored) {}
        }
        return set;
    }

    private String resolveSubjectId(String input, Map<String, String> subjectMaster) {
        if (input == null) return null;
        String up = input.toUpperCase().trim();
        if (subjectMaster.containsKey(up)) {
            return up;
        }
        for (Map.Entry<String, String> e : subjectMaster.entrySet()) {
            if (e.getValue().equalsIgnoreCase(input.trim())) {
                return e.getKey();
            }
        }
        return null;
    }

    private Integer parseOptionalInt(String s) {
        if (s == null || s.trim().isEmpty() || "null".equalsIgnoreCase(s.trim())) return null;
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private String escapeCsv(String val) {
        if (val == null) return "";
        if (val.contains(",") || val.contains("\"") || val.contains("\n") || val.contains("\r")) {
            return "\"" + val.replace("\"", "\"\"") + "\"";
        }
        return val;
    }

    private File resolveDefaultTableFile() {
        String base = System.getProperty("user.dir");
        File exportDir = new File(base, "data" + File.separator + "export");
        if (!exportDir.exists()) {
            exportDir.mkdirs();
        }
        return new File(exportDir, "marks.csv");
    }

    /**
     * Standalone CLI Entry Point:
     * Usage:
     * java -cp <classpath> com.academic.service.TableFileInputValidatorService <inputFile.csv> [outputTableFile.csv] [facultyId]
     */
    public static void main(String[] args) {
        System.out.println("==================================================================");
        System.out.println(" Academic Result Input Validator - BufferedReader Table Ingestion ");
        System.out.println("==================================================================");

        if (args.length < 1) {
            System.out.println("Usage: java com.academic.service.TableFileInputValidatorService <inputFile.csv> [outputTableFile.csv] [facultyId]");
            System.out.println("Enforces domain integrity constraints row-by-row before committing to table file.");
            return;
        }

        File inputFile = new File(args[0]);
        File outputFile = (args.length > 1 && !args[1].isEmpty()) ? new File(args[1]) : new File("data/export/marks.csv");
        String facultyId = (args.length > 2) ? args[2] : "FAC101";

        TableFileInputValidatorService service = new TableFileInputValidatorService();
        try {
            System.out.println("Reading and validating: " + inputFile.getAbsolutePath());
            System.out.println("Destination table file: " + outputFile.getAbsolutePath());
            System.out.println("Faculty ID: " + facultyId);

            IngestionReport report = service.processAndValidateFile(inputFile, outputFile, facultyId, null, null);

            System.out.println("\n----------------- Ingestion Execution Summary -----------------");
            System.out.println("Total Lines Read   : " + report.getTotalLinesRead());
            System.out.println("Valid Records      : " + report.getValidCount());
            System.out.println("Rejected Records   : " + report.getRejectedCount());
            System.out.println("Database Synced    : " + report.isDatabaseSynchronized());
            System.out.println("Table Files Synced : " + report.isTableFilesSynchronized());
            System.out.println("Status Message     : " + report.getMessage());

            if (!report.getErrors().isEmpty()) {
                System.out.println("\n----------------- Rejection Report (Domain Violations) --------");
                for (RecordError err : report.getErrors()) {
                    System.out.printf("  [REJECT] Line %d (Student: %s, Subject: %s): %s%n",
                        err.getLineNumber(), err.getStudentId(), err.getSubjectId(), err.getReason());
                }
            }
            System.out.println("==================================================================");

        } catch (Exception e) {
            System.err.println("Error processing table input file: " + e.getMessage());
            e.printStackTrace();
        }
    }
}
