package com.academic.service;

import com.academic.config.DBConnection;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.StringReader;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Academic Result Input Validator - Table File Export Service
 *
 * Implements:
 * 1. Fetching latest records from MySQL database.
 * 2. Generating or refreshing 5 table files:
 *    - students.csv
 *    - subjects.csv
 *    - faculty_assignments.csv
 *    - marks.csv
 *    - results.csv
 * 3. Enforcing domain integrity constraints (Internal 0-40, External 0-60, Total 0-100).
 * 4. Preserving missing marks as empty string (NULL); never converting them to zero.
 * 5. Calculating totals and PASS/FAIL using existing rules (Subject pass >= 35, overall PASS if all >= 35).
 * 6. Using java.io.BufferedReader to read and validate the generated records stream line-by-line.
 * 7. Saving generated files in a protected backend directory outside the public web space.
 */
public class TableFileExportService {

    public static class ExportResult {
        public boolean success;
        public String message;
        public String error;
        public String targetDirectory;
        public List<String> generatedFiles = new ArrayList<>();
        public Map<String, Integer> recordCounts = new LinkedHashMap<>();
    }

    /**
     * Exports all 5 table files to the specified backend directory.
     * Uses MySQL via DBConnection.
     */
    public ExportResult exportAll(String targetDirPath) {
        ExportResult res = new ExportResult();

        File targetDir = new File(targetDirPath);
        if (!targetDir.exists()) {
            boolean created = targetDir.mkdirs();
            if (!created && !targetDir.exists()) {
                res.success = false;
                res.error = "Failed to create protected backend export directory: " + targetDir.getAbsolutePath();
                return res;
            }
        }
        res.targetDirectory = targetDir.getAbsolutePath();

        Connection conn = null;
        try {
            conn = DBConnection.getConnection();

            // 1. Export students.csv
            String studentsCsv = buildStudentsCsv(conn);
            int studentCount = validateAndWriteCsv(
                new File(targetDir, "students.csv"),
                studentsCsv,
                "student_id,student_name,roll_no,email,department,semester",
                6,
                "students.csv"
            );
            res.generatedFiles.add("students.csv");
            res.recordCounts.put("students.csv", studentCount);

            // 2. Export subjects.csv
            String subjectsCsv = buildSubjectsCsv(conn);
            int subjectCount = validateAndWriteCsv(
                new File(targetDir, "subjects.csv"),
                subjectsCsv,
                "subject_id,subject_code,subject_name,max_marks,max_internal,max_external,pass_marks",
                7,
                "subjects.csv"
            );
            res.generatedFiles.add("subjects.csv");
            res.recordCounts.put("subjects.csv", subjectCount);

            // 3. Export faculty_assignments.csv & faculty_assignment.csv
            String facultyCsv = buildFacultyAssignmentsCsv(conn);
            int facultyAssignCount = validateAndWriteCsv(
                new File(targetDir, "faculty_assignments.csv"),
                facultyCsv,
                "faculty_id,email,subject_id,subject_code,subject_name",
                5,
                "faculty_assignments.csv"
            );
            validateAndWriteCsv(
                new File(targetDir, "faculty_assignment.csv"),
                facultyCsv,
                "faculty_id,email,subject_id,subject_code,subject_name",
                5,
                "faculty_assignment.csv"
            );
            res.generatedFiles.add("faculty_assignments.csv");
            res.generatedFiles.add("faculty_assignment.csv");
            res.recordCounts.put("faculty_assignments.csv", facultyAssignCount);
            res.recordCounts.put("faculty_assignment.csv", facultyAssignCount);

            // 4. Export marks.csv
            String marksCsv = buildMarksCsv(conn);
            int marksCount = validateAndWriteCsv(
                new File(targetDir, "marks.csv"),
                marksCsv,
                "student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status",
                8,
                "marks.csv"
            );
            res.generatedFiles.add("marks.csv");
            res.recordCounts.put("marks.csv", marksCount);

            // 5. Export results.csv
            String resultsCsv = buildResultsCsv(conn);
            int resultsCount = validateAndWriteCsv(
                new File(targetDir, "results.csv"),
                resultsCsv,
                "student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects",
                8,
                "results.csv"
            );
            res.generatedFiles.add("results.csv");
            res.recordCounts.put("results.csv", resultsCount);

            res.success = true;
            res.message = String.format(
                "Successfully exported %d table files to protected backend directory. Validated via java.io.BufferedReader.",
                res.generatedFiles.size()
            );

        } catch (SQLException e) {
            res.success = false;
            res.error = "Database access error during table file export: " + e.getMessage();
        } catch (Exception e) {
            res.success = false;
            res.error = "Validation or export error: " + e.getMessage();
        } finally {
            if (conn != null) {
                try { conn.close(); } catch (SQLException ignored) {}
            }
        }

        return res;
    }

    // --------------------------------------------------------------------------
    // Query Builders (MySQL Database Source)
    // --------------------------------------------------------------------------

    private String buildStudentsCsv(Connection conn) throws SQLException {
        StringBuilder sb = new StringBuilder();
        sb.append("student_id,student_name,roll_no,email,department,semester\n");

        String sql = "SELECT student_id, student_name, roll_no, email, department, semester FROM students ORDER BY student_id ASC";
        try (PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                String id = rs.getString("student_id");
                String name = rs.getString("student_name");
                String rollNo = rs.getString("roll_no");
                String email = rs.getString("email");
                String dept = rs.getString("department");
                int sem = rs.getInt("semester");
                String semStr = rs.wasNull() ? "" : String.valueOf(sem);

                sb.append(escapeCsv(id)).append(",")
                  .append(escapeCsv(name)).append(",")
                  .append(escapeCsv(rollNo != null ? rollNo : id)).append(",")
                  .append(escapeCsv(email != null ? email : "")).append(",")
                  .append(escapeCsv(dept != null ? dept : "")).append(",")
                  .append(escapeCsv(semStr)).append("\n");
            }
        }
        return sb.toString();
    }

    private String buildSubjectsCsv(Connection conn) throws SQLException {
        StringBuilder sb = new StringBuilder();
        sb.append("subject_id,subject_code,subject_name,max_marks,max_internal,max_external,pass_marks\n");

        String sql = "SELECT subject_id, subject_code, subject_name, max_marks, max_internal, max_external, pass_marks FROM subjects ORDER BY subject_id ASC";
        try (PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                sb.append(escapeCsv(rs.getString("subject_id"))).append(",")
                  .append(escapeCsv(rs.getString("subject_code"))).append(",")
                  .append(escapeCsv(rs.getString("subject_name"))).append(",")
                  .append(rs.getInt("max_marks")).append(",")
                  .append(rs.getInt("max_internal")).append(",")
                  .append(rs.getInt("max_external")).append(",")
                  .append(rs.getInt("pass_marks")).append("\n");
            }
        }
        return sb.toString();
    }

    private String buildFacultyAssignmentsCsv(Connection conn) throws SQLException {
        StringBuilder sb = new StringBuilder();
        sb.append("faculty_id,email,subject_id,subject_code,subject_name\n");

        // Never expose passwords or password hashes!
        String sql = "SELECT fs.faculty_id, f.email, s.subject_id, s.subject_code, s.subject_name " +
                     "FROM faculty_subjects fs " +
                     "JOIN faculty f ON fs.faculty_id = f.faculty_id " +
                     "JOIN subjects s ON fs.subject_id = s.subject_id " +
                     "ORDER BY fs.faculty_id ASC, s.subject_id ASC";
        try (PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                sb.append(escapeCsv(rs.getString("faculty_id"))).append(",")
                  .append(escapeCsv(rs.getString("email"))).append(",")
                  .append(escapeCsv(rs.getString("subject_id"))).append(",")
                  .append(escapeCsv(rs.getString("subject_code"))).append(",")
                  .append(escapeCsv(rs.getString("subject_name"))).append("\n");
            }
        }
        return sb.toString();
    }

    private String buildMarksCsv(Connection conn) throws SQLException {
        StringBuilder sb = new StringBuilder();
        sb.append("student_id,student_name,subject_id,subject_code,internal_marks,external_marks,total_marks,eval_status\n");

        String sql = "SELECT st.student_id, st.student_name, s.subject_id, s.subject_code, " +
                     "       sm.internal_marks, sm.external_marks " +
                     "FROM students st " +
                     "CROSS JOIN subjects s " +
                     "LEFT JOIN subject_marks sm ON st.student_id = sm.student_id AND s.subject_id = sm.subject_id " +
                     "ORDER BY st.student_id ASC, s.subject_id ASC";

        try (PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                String stId = rs.getString("student_id");
                String stName = rs.getString("student_name");
                String subId = rs.getString("subject_id");
                String subCode = rs.getString("subject_code");

                int rawInternal = rs.getInt("internal_marks");
                Integer internal = rs.wasNull() ? null : rawInternal;

                int rawExternal = rs.getInt("external_marks");
                Integer external = rs.wasNull() ? null : rawExternal;

                // Validate domain bounds
                if (internal != null && (internal < 0 || internal > 40)) {
                    continue; // Skip invalid record
                }
                if (external != null && (external < 0 || external > 60)) {
                    continue; // Skip invalid record
                }

                // Preserving missing marks as empty string; NEVER 0!
                String intStr = internal != null ? String.valueOf(internal) : "";
                String extStr = external != null ? String.valueOf(external) : "";

                Integer total = null;
                String evalStatus;
                if (internal != null && external != null) {
                    total = internal + external;
                    evalStatus = "Fully Entered";
                } else if (internal != null || external != null) {
                    evalStatus = "Marks Pending";
                } else {
                    evalStatus = "Not Updated";
                }

                String totStr = total != null ? String.valueOf(total) : "";

                sb.append(escapeCsv(stId)).append(",")
                  .append(escapeCsv(stName)).append(",")
                  .append(escapeCsv(subId)).append(",")
                  .append(escapeCsv(subCode)).append(",")
                  .append(intStr).append(",")
                  .append(extStr).append(",")
                  .append(totStr).append(",")
                  .append(escapeCsv(evalStatus)).append("\n");
            }
        }
        return sb.toString();
    }

    private String buildResultsCsv(Connection conn) throws SQLException {
        StringBuilder sb = new StringBuilder();
        sb.append("student_id,student_name,roll_no,total_marks,percentage,result_status,fully_entered_count,total_subjects\n");

        // First determine total number of curricular subjects
        int totalSubjectsCount = 0;
        String countSubsSql = "SELECT COUNT(*) FROM subjects";
        try (PreparedStatement stmt = conn.prepareStatement(countSubsSql);
             ResultSet rs = stmt.executeQuery()) {
            if (rs.next()) {
                totalSubjectsCount = rs.getInt(1);
            }
        }

        // Query each student and their subject marks
        String studentsSql = "SELECT student_id, student_name, roll_no FROM students ORDER BY student_id ASC";
        String marksSql = "SELECT s.subject_id, sm.internal_marks, sm.external_marks " +
                          "FROM subjects s " +
                          "LEFT JOIN subject_marks sm ON s.subject_id = sm.subject_id AND sm.student_id = ? " +
                          "ORDER BY s.subject_id ASC";

        try (PreparedStatement stStmt = conn.prepareStatement(studentsSql);
             PreparedStatement marksStmt = conn.prepareStatement(marksSql);
             ResultSet stRs = stStmt.executeQuery()) {

            while (stRs.next()) {
                String stId = stRs.getString("student_id");
                String stName = stRs.getString("student_name");
                String rollNo = stRs.getString("roll_no");

                marksStmt.setString(1, stId);
                int fullyEntered = 0;
                int sumTotal = 0;
                boolean allSubjectsPassed = true;
                boolean allSubjectsComplete = (totalSubjectsCount > 0);

                try (ResultSet mRs = marksStmt.executeQuery()) {
                    int subSeen = 0;
                    while (mRs.next()) {
                        subSeen++;
                        int rawInt = mRs.getInt("internal_marks");
                        Integer intM = mRs.wasNull() ? null : rawInt;

                        int rawExt = mRs.getInt("external_marks");
                        Integer extM = mRs.wasNull() ? null : rawExt;

                        if (intM != null && extM != null && intM >= 0 && intM <= 40 && extM >= 0 && extM <= 60) {
                            fullyEntered++;
                            int subTot = intM + extM;
                            sumTotal += subTot;
                            if (subTot < 35) {
                                allSubjectsPassed = false;
                            }
                        } else {
                            allSubjectsComplete = false;
                        }
                    }
                    if (subSeen < totalSubjectsCount) {
                        allSubjectsComplete = false;
                    }
                }

                String totStr = "";
                String pctStr = "";
                String resultStatus;

                if (allSubjectsComplete && fullyEntered == totalSubjectsCount && totalSubjectsCount > 0) {
                    totStr = String.valueOf(sumTotal);
                    double pct = ((double) sumTotal / (totalSubjectsCount * 100.0)) * 100.0;
                    pctStr = String.format("%.2f", pct);
                    resultStatus = allSubjectsPassed ? "PASS" : "FAIL";
                } else {
                    resultStatus = "RESULT WITHHELD";
                }

                sb.append(escapeCsv(stId)).append(",")
                  .append(escapeCsv(stName)).append(",")
                  .append(escapeCsv(rollNo != null ? rollNo : stId)).append(",")
                  .append(totStr).append(",")
                  .append(pctStr).append(",")
                  .append(escapeCsv(resultStatus)).append(",")
                  .append(fullyEntered).append(",")
                  .append(totalSubjectsCount).append("\n");
            }
        }
        return sb.toString();
    }

    // --------------------------------------------------------------------------
    // java.io.BufferedReader Pipeline Validation & File Writing
    // --------------------------------------------------------------------------

    /**
     * Genuinely leverages java.io.BufferedReader to read and validate the generated
     * CSV stream line-by-line before persisting to disk.
     *
     * @param destinationFile final target file in protected backend directory
     * @param csvContent generated CSV text
     * @param expectedHeader comma-separated expected column header
     * @param expectedColumns number of columns expected on every row
     * @param fileNameLabel human-readable file label for error reporting
     * @return valid record count read and verified
     * @throws IOException if I/O or domain integrity validation fails
     */
    public int validateAndWriteCsv(File destinationFile, String csvContent,
                                   String expectedHeader, int expectedColumns,
                                   String fileNameLabel) throws IOException {

        // 1. Stage 1: Validation using java.io.BufferedReader over StringReader stream
        int validatedRows = 0;
        try (BufferedReader br = new BufferedReader(new StringReader(csvContent))) {
            String headerLine = br.readLine();
            if (headerLine == null) {
                throw new IOException("Stream validation failed for " + fileNameLabel + ": Empty file content.");
            }
            if (!headerLine.trim().equalsIgnoreCase(expectedHeader.trim())) {
                throw new IOException(String.format(
                    "Stream validation failed for %s: Header mismatch. Expected '%s', but found '%s'.",
                    fileNameLabel, expectedHeader, headerLine));
            }

            String line;
            int lineNum = 1;
            while ((line = br.readLine()) != null) {
                lineNum++;
                if (line.trim().isEmpty()) {
                    continue; // Skip trailing empty lines
                }

                String[] tokens = splitCsvLine(line);
                if (tokens.length < expectedColumns) {
                    throw new IOException(String.format(
                        "Stream validation failed for %s at line %d: Expected %d columns, but found %d columns. Line: %s",
                        fileNameLabel, lineNum, expectedColumns, tokens.length, line));
                }

                // Domain Integrity checks based on file type
                if (fileNameLabel.equals("marks.csv")) {
                    validateMarksRow(tokens, lineNum);
                } else if (fileNameLabel.equals("results.csv")) {
                    validateResultsRow(tokens, lineNum);
                } else if (fileNameLabel.equals("students.csv")) {
                    if (tokens[0].trim().isEmpty()) {
                        throw new IOException("Stream validation failed for students.csv at line " + lineNum + ": Student ID is empty.");
                    }
                } else if (fileNameLabel.equals("subjects.csv")) {
                    if (tokens[0].trim().isEmpty()) {
                        throw new IOException("Stream validation failed for subjects.csv at line " + lineNum + ": Subject ID is empty.");
                    }
                }

                validatedRows++;
            }
        }

        // 2. Stage 2: Write validated content to the protected backend file
        File parent = destinationFile.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }

        try (BufferedWriter bw = new BufferedWriter(new FileWriter(destinationFile))) {
            bw.write(csvContent);
            bw.flush();
        }

        // 3. Stage 3: Post-write verification using java.io.BufferedReader over FileReader
        // Confirms that the persisted file on disk is intact and readable
        int postWriteCount = 0;
        try (BufferedReader fileBr = new BufferedReader(new FileReader(destinationFile))) {
            String fHeader = fileBr.readLine();
            if (fHeader == null || !fHeader.trim().equalsIgnoreCase(expectedHeader.trim())) {
                throw new IOException("Post-write verification failed for " + destinationFile.getName() + ": Header corrupted on disk.");
            }
            while (fileBr.readLine() != null) {
                postWriteCount++;
            }
        }

        if (postWriteCount != validatedRows) {
            throw new IOException(String.format(
                "Post-write row count mismatch for %s: validated %d, but file has %d lines.",
                destinationFile.getName(), validatedRows, postWriteCount));
        }

        return validatedRows;
    }

    private void validateMarksRow(String[] tokens, int lineNum) throws IOException {
        String stId = tokens[0].trim();
        String subId = tokens[2].trim();
        String rawInternal = tokens[4].trim();
        String rawExternal = tokens[5].trim();
        String rawTotal = tokens[6].trim();

        if (stId.isEmpty()) {
            throw new IOException("Validation error in marks.csv at line " + lineNum + ": Missing student ID.");
        }
        if (subId.isEmpty()) {
            throw new IOException("Validation error in marks.csv at line " + lineNum + ": Missing subject ID.");
        }

        Integer intVal = null;
        if (!rawInternal.isEmpty()) {
            try {
                intVal = Integer.parseInt(rawInternal);
                if (intVal < 0 || intVal > 40) {
                    throw new IOException("Domain violation in marks.csv at line " + lineNum + ": Internal mark " + intVal + " outside [0-40].");
                }
            } catch (NumberFormatException e) {
                throw new IOException("Domain violation in marks.csv at line " + lineNum + ": Non-numeric internal mark: " + rawInternal);
            }
        }

        Integer extVal = null;
        if (!rawExternal.isEmpty()) {
            try {
                extVal = Integer.parseInt(rawExternal);
                if (extVal < 0 || extVal > 60) {
                    throw new IOException("Domain violation in marks.csv at line " + lineNum + ": External mark " + extVal + " outside [0-60].");
                }
            } catch (NumberFormatException e) {
                throw new IOException("Domain violation in marks.csv at line " + lineNum + ": Non-numeric external mark: " + rawExternal);
            }
        }

        if (intVal != null && extVal != null) {
            int expectedTot = intVal + extVal;
            if (rawTotal.isEmpty()) {
                throw new IOException("Calculation error in marks.csv at line " + lineNum + ": Missing total marks for fully evaluated record.");
            }
            try {
                int totVal = Integer.parseInt(rawTotal);
                if (totVal != expectedTot) {
                    throw new IOException("Calculation error in marks.csv at line " + lineNum + ": Total " + totVal + " != sum (" + expectedTot + ").");
                }
            } catch (NumberFormatException e) {
                throw new IOException("Calculation error in marks.csv at line " + lineNum + ": Non-numeric total marks: " + rawTotal);
            }
        } else {
            // Missing component: total must be empty (preserved missing)
            if (!rawTotal.isEmpty()) {
                throw new IOException("Calculation violation in marks.csv at line " + lineNum + ": Total marks present when evaluation is incomplete.");
            }
        }
    }

    private void validateResultsRow(String[] tokens, int lineNum) throws IOException {
        String stId = tokens[0].trim();
        String rawTotal = tokens[3].trim();
        String rawPercentage = tokens[4].trim();
        String status = tokens[5].trim();

        if (stId.isEmpty()) {
            throw new IOException("Validation error in results.csv at line " + lineNum + ": Missing student ID.");
        }

        if ("PASS".equalsIgnoreCase(status) || "FAIL".equalsIgnoreCase(status)) {
            if (rawTotal.isEmpty() || rawPercentage.isEmpty()) {
                throw new IOException("Calculation error in results.csv at line " + lineNum + ": PASS/FAIL declared with missing total/percentage.");
            }
        } else if ("RESULT WITHHELD".equalsIgnoreCase(status)) {
            // If withheld, total and percentage must remain empty
            if (!rawTotal.isEmpty() || !rawPercentage.isEmpty()) {
                throw new IOException("Domain violation in results.csv at line " + lineNum + ": Total/percentage exposed for incomplete result.");
            }
        }
    }

    // --------------------------------------------------------------------------
    // CSV Utilities
    // --------------------------------------------------------------------------

    private static String escapeCsv(String text) {
        if (text == null) return "";
        if (text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r")) {
            return "\"" + text.replace("\"", "\"\"") + "\"";
        }
        return text;
    }

    private static String[] splitCsvLine(String line) {
        List<String> list = new ArrayList<>();
        boolean inQuotes = false;
        StringBuilder cur = new StringBuilder();

        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '\"') {
                if (inQuotes && i + 1 < line.length() && line.charAt(i + 1) == '\"') {
                    cur.append('\"');
                    i++; // skip escaped quote
                } else {
                    inQuotes = !inQuotes;
                }
            } else if (c == ',' && !inQuotes) {
                list.add(cur.toString());
                cur.setLength(0);
            } else {
                cur.append(c);
            }
        }
        list.add(cur.toString());
        return list.toArray(new String[0]);
    }

    // --------------------------------------------------------------------------
    // Academic Records Export (Excel & CSV)
    // --------------------------------------------------------------------------

    public String buildAcademicRecordsCsv(String facultyId, String targetSubjectId) throws SQLException {
        try (Connection conn = DBConnection.getConnection()) {
            StringBuilder sb = new StringBuilder();
            sb.append("student_id,student_name,roll_no,subject_id,subject_code,subject_name,internal_marks,external_marks,total_marks,result_status,eval_status\n");

            String sql = "SELECT st.student_id, st.student_name, st.roll_no, s.subject_id, s.subject_code, s.subject_name, " +
                         "       sm.internal_marks, sm.external_marks " +
                         "FROM students st " +
                         "CROSS JOIN subjects s ";

            if (facultyId != null && !facultyId.trim().isEmpty() && !"faculty".equalsIgnoreCase(facultyId)) {
                sql += "JOIN faculty_subjects fs ON s.subject_id = fs.subject_id AND fs.faculty_id = ? ";
            }

            sql += "LEFT JOIN subject_marks sm ON st.student_id = sm.student_id AND s.subject_id = sm.subject_id ";

            if (targetSubjectId != null && !targetSubjectId.trim().isEmpty() && !"ALL".equalsIgnoreCase(targetSubjectId)) {
                sql += "WHERE s.subject_id = ? OR s.subject_code = ? ";
            }

            sql += "ORDER BY st.student_id ASC, s.subject_id ASC";

            try (PreparedStatement stmt = conn.prepareStatement(sql)) {
                int paramIdx = 1;
                if (facultyId != null && !facultyId.trim().isEmpty() && !"faculty".equalsIgnoreCase(facultyId)) {
                    stmt.setString(paramIdx++, facultyId.trim());
                }
                if (targetSubjectId != null && !targetSubjectId.trim().isEmpty() && !"ALL".equalsIgnoreCase(targetSubjectId)) {
                    stmt.setString(paramIdx++, targetSubjectId.trim());
                    stmt.setString(paramIdx++, targetSubjectId.trim());
                }

                try (ResultSet rs = stmt.executeQuery()) {
                    while (rs.next()) {
                        String stId = rs.getString("student_id");
                        String stName = rs.getString("student_name");
                        String rollNo = rs.getString("roll_no");
                        if (rollNo == null || rollNo.trim().isEmpty()) rollNo = stId;
                        String subId = rs.getString("subject_id");
                        String subCode = rs.getString("subject_code");
                        String subName = rs.getString("subject_name");

                        int rawInternal = rs.getInt("internal_marks");
                        Integer internal = rs.wasNull() ? null : rawInternal;

                        int rawExternal = rs.getInt("external_marks");
                        Integer external = rs.wasNull() ? null : rawExternal;

                        Integer total = null;
                        String evalStatus = "Not Updated";
                        String resStatus = "Not Updated";

                        if (internal != null && external != null) {
                            total = internal + external;
                            evalStatus = "Fully Entered";
                            resStatus = (total >= 35) ? "PASS" : "FAIL";
                        } else if (internal != null || external != null) {
                            evalStatus = (internal != null) ? "Internal Only" : "External Only";
                            resStatus = "Marks Pending";
                        }

                        String intStr = internal != null ? String.valueOf(internal) : "";
                        String extStr = external != null ? String.valueOf(external) : "";
                        String totStr = total != null ? String.valueOf(total) : "";

                        sb.append(escapeCsv(stId)).append(",")
                          .append(escapeCsv(stName)).append(",")
                          .append(escapeCsv(rollNo)).append(",")
                          .append(escapeCsv(subId)).append(",")
                          .append(escapeCsv(subCode)).append(",")
                          .append(escapeCsv(subName)).append(",")
                          .append(intStr).append(",")
                          .append(extStr).append(",")
                          .append(totStr).append(",")
                          .append(escapeCsv(resStatus)).append(",")
                          .append(escapeCsv(evalStatus)).append("\n");
                    }
                }
            }
            return sb.toString();
        }
    }

    public byte[] buildAcademicRecordsExcel(String facultyId, String targetSubjectId) throws SQLException, IOException {
        String csv = buildAcademicRecordsCsv(facultyId, targetSubjectId);
        java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
        try (java.util.zip.ZipOutputStream zos = new java.util.zip.ZipOutputStream(baos)) {
            // [Content_Types].xml
            zos.putNextEntry(new java.util.zip.ZipEntry("[Content_Types].xml"));
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
            zos.putNextEntry(new java.util.zip.ZipEntry("_rels/.rels"));
            String rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "  <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>\n" +
                "</Relationships>";
            zos.write(rels.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/workbook.xml
            zos.putNextEntry(new java.util.zip.ZipEntry("xl/workbook.xml"));
            String wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n" +
                "  <sheets>\n" +
                "    <sheet name=\"Academic Records\" sheetId=\"1\" r:id=\"rId1\"/>\n" +
                "  </sheets>\n" +
                "</workbook>";
            zos.write(wb.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/_rels/workbook.xml.rels
            zos.putNextEntry(new java.util.zip.ZipEntry("xl/_rels/workbook.xml.rels"));
            String wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n" +
                "  <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>\n" +
                "</Relationships>";
            zos.write(wbRels.getBytes("UTF-8"));
            zos.closeEntry();

            // xl/worksheets/sheet1.xml
            zos.putNextEntry(new java.util.zip.ZipEntry("xl/worksheets/sheet1.xml"));
            StringBuilder sheet = new StringBuilder();
            sheet.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
            sheet.append("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n");
            sheet.append("<sheetData>\n");

            // Header row
            sheet.append("<row r=\"1\">\n");
            sheet.append("  <c r=\"A1\" t=\"inlineStr\"><is><t>Student ID</t></is></c>\n");
            sheet.append("  <c r=\"B1\" t=\"inlineStr\"><is><t>Student Name</t></is></c>\n");
            sheet.append("  <c r=\"C1\" t=\"inlineStr\"><is><t>Roll No</t></is></c>\n");
            sheet.append("  <c r=\"D1\" t=\"inlineStr\"><is><t>Subject ID</t></is></c>\n");
            sheet.append("  <c r=\"E1\" t=\"inlineStr\"><is><t>Subject Code</t></is></c>\n");
            sheet.append("  <c r=\"F1\" t=\"inlineStr\"><is><t>Subject Name</t></is></c>\n");
            sheet.append("  <c r=\"G1\" t=\"inlineStr\"><is><t>Internal Marks (0-40)</t></is></c>\n");
            sheet.append("  <c r=\"H1\" t=\"inlineStr\"><is><t>External Marks (0-60)</t></is></c>\n");
            sheet.append("  <c r=\"I1\" t=\"inlineStr\"><is><t>Total Marks (0-100)</t></is></c>\n");
            sheet.append("  <c r=\"J1\" t=\"inlineStr\"><is><t>Result Status</t></is></c>\n");
            sheet.append("  <c r=\"K1\" t=\"inlineStr\"><is><t>Evaluation Status</t></is></c>\n");
            sheet.append("</row>\n");

            String[] lines = csv.split("\n");
            int r = 2;
            for (int i = 1; i < lines.length; i++) {
                String line = lines[i].trim();
                if (line.isEmpty()) continue;
                String[] cols = splitCsvLine(line);
                if (cols.length < 11) continue;

                sheet.append("<row r=\"").append(r).append("\">\n");
                sheet.append("  <c r=\"A").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[0])).append("</t></is></c>\n");
                sheet.append("  <c r=\"B").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[1])).append("</t></is></c>\n");
                sheet.append("  <c r=\"C").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[2])).append("</t></is></c>\n");
                sheet.append("  <c r=\"D").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[3])).append("</t></is></c>\n");
                sheet.append("  <c r=\"E").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[4])).append("</t></is></c>\n");
                sheet.append("  <c r=\"F").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[5])).append("</t></is></c>\n");
                if (!cols[6].trim().isEmpty()) {
                    sheet.append("  <c r=\"G").append(r).append("\"><v>").append(cols[6].trim()).append("</v></c>\n");
                }
                if (!cols[7].trim().isEmpty()) {
                    sheet.append("  <c r=\"H").append(r).append("\"><v>").append(cols[7].trim()).append("</v></c>\n");
                }
                if (!cols[8].trim().isEmpty()) {
                    sheet.append("  <c r=\"I").append(r).append("\"><v>").append(cols[8].trim()).append("</v></c>\n");
                }
                sheet.append("  <c r=\"J").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[9])).append("</t></is></c>\n");
                sheet.append("  <c r=\"K").append(r).append("\" t=\"inlineStr\"><is><t>").append(escapeXml(cols[10])).append("</t></is></c>\n");
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

    private static String escapeXml(String text) {
        if (text == null) return "";
        return text.replace("&", "&amp;")
                   .replace("<", "&lt;")
                   .replace(">", "&gt;")
                   .replace("\"", "&quot;")
                   .replace("'", "&apos;");
    }
}

