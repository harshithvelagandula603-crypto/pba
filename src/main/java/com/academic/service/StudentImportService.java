package com.academic.service;

import com.academic.config.DBConnection;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Academic Result Input Validator - Student List Preload Importer
 * Implements Option B: Uses java.io.BufferedReader to read institutional CSV files,
 * enforces domain integrity constraints row-by-row, and initializes subject records
 * with NULL marks in a single atomic database transaction.
 */
public class StudentImportService {

    private static final Logger LOGGER = Logger.getLogger(StudentImportService.class.getName());

    public static class ImportResult {
        private final boolean success;
        private final int importedCount;
        private final List<String> errors;

        public ImportResult(boolean success, int importedCount, List<String> errors) {
            this.success = success;
            this.importedCount = importedCount;
            this.errors = errors;
        }

        public boolean isSuccess() { return success; }
        public int getImportedCount() { return importedCount; }
        public List<String> getErrors() { return errors; }
    }

    private static class ParsedStudent {
        String studentId;
        String studentName;
        String rollNo;
        String email;
        String department;
        Integer semester;
    }

    /**
     * Reads student records from an Excel (.xlsx) file with two columns:
     * Column A: Student ID
     * Column B: Student Name
     *
     * Validates:
     * 1. Missing Student ID
     * 2. Missing Student Name
     * 3. Duplicate Student ID within the file
     * 4. Duplicate Student ID existing in database
     *
     * Transactionally imports valid records into MySQL students table and initializes subject marks with NULL.
     */
    public ImportResult importStudentsFromExcelFile(java.io.File excelFile) {
        List<String> errors = new ArrayList<>();
        List<ParsedStudent> validStudents = new ArrayList<>();
        Set<String> seenStudentIds = new HashSet<>();

        if (excelFile == null || !excelFile.exists()) {
            errors.add("Excel file does not exist: " + (excelFile != null ? excelFile.getAbsolutePath() : "null"));
            return new ImportResult(false, 0, errors);
        }

        try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(excelFile)) {
            // 1. Read shared strings
            List<String> sharedStrings = new ArrayList<>();
            java.util.zip.ZipEntry ssEntry = zip.getEntry("xl/sharedStrings.xml");
            if (ssEntry != null) {
                try (java.io.InputStream is = zip.getInputStream(ssEntry)) {
                    javax.xml.parsers.DocumentBuilder db = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder();
                    org.w3c.dom.Document doc = db.parse(is);
                    org.w3c.dom.NodeList siList = doc.getElementsByTagName("si");
                    for (int i = 0; i < siList.getLength(); i++) {
                        org.w3c.dom.Node si = siList.item(i);
                        StringBuilder sb = new StringBuilder();
                        org.w3c.dom.NodeList tList = ((org.w3c.dom.Element) si).getElementsByTagName("t");
                        for (int j = 0; j < tList.getLength(); j++) {
                            sb.append(tList.item(j).getTextContent());
                        }
                        sharedStrings.add(sb.toString().trim());
                    }
                }
            }

            // 2. Read sheet1 (Students sheet)
            java.util.zip.ZipEntry sheetEntry = zip.getEntry("xl/worksheets/sheet1.xml");
            if (sheetEntry == null) {
                errors.add("Invalid Excel structure: xl/worksheets/sheet1.xml not found.");
                return new ImportResult(false, 0, errors);
            }

            try (java.io.InputStream is = zip.getInputStream(sheetEntry)) {
                javax.xml.parsers.DocumentBuilder db = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder();
                org.w3c.dom.Document doc = db.parse(is);
                org.w3c.dom.NodeList rowList = doc.getElementsByTagName("row");

                boolean isHeader = true;
                for (int i = 0; i < rowList.getLength(); i++) {
                    org.w3c.dom.Element rowElem = (org.w3c.dom.Element) rowList.item(i);
                    String rowNumStr = rowElem.getAttribute("r");
                    int rowNum = rowNumStr.isEmpty() ? (i + 1) : Integer.parseInt(rowNumStr);

                    String cellA = "";
                    String cellB = "";

                    org.w3c.dom.NodeList cList = rowElem.getElementsByTagName("c");
                    for (int j = 0; j < cList.getLength(); j++) {
                        org.w3c.dom.Element cElem = (org.w3c.dom.Element) cList.item(j);
                        String cellRef = cElem.getAttribute("r");
                        String cellType = cElem.getAttribute("t");
                        org.w3c.dom.NodeList vList = cElem.getElementsByTagName("v");
                        String val = (vList.getLength() > 0) ? vList.item(0).getTextContent().trim() : "";

                        if ("s".equals(cellType) && !val.isEmpty()) {
                            int strIndex = Integer.parseInt(val);
                            if (strIndex >= 0 && strIndex < sharedStrings.size()) {
                                val = sharedStrings.get(strIndex);
                            }
                        }

                        if (cellRef.startsWith("A")) {
                            cellA = val.trim();
                        } else if (cellRef.startsWith("B")) {
                            cellB = val.trim();
                        }
                    }

                    // Skip empty rows
                    if (cellA.isEmpty() && cellB.isEmpty()) {
                        continue;
                    }

                    // Validate Header row
                    if (isHeader) {
                        isHeader = false;
                        if (!cellA.toLowerCase().contains("student") || !cellB.toLowerCase().contains("name")) {
                            errors.add(String.format("Row %d: Invalid Excel header format. Expected Column A: 'Student ID', Column B: 'Student Name'. Found: '%s', '%s'", rowNum, cellA, cellB));
                            return new ImportResult(false, 0, errors);
                        }
                        continue;
                    }

                    // 1. Validate missing Student ID
                    if (cellA.isEmpty()) {
                        errors.add(String.format("Row %d: Missing Student ID. Student record cannot be imported without an ID.", rowNum));
                        continue;
                    }

                    // 2. Validate missing Student Name
                    if (cellB.isEmpty()) {
                        errors.add(String.format("Row %d: Missing Student Name for Student ID '%s'. Student record cannot be imported without a name.", rowNum, cellA));
                        continue;
                    }

                    // 3. Validate duplicate Student ID within file
                    if (!seenStudentIds.add(cellA)) {
                        errors.add(String.format("Row %d: Duplicate Student ID '%s' found in Excel file.", rowNum, cellA));
                        continue;
                    }

                    ParsedStudent student = new ParsedStudent();
                    student.studentId = cellA;
                    student.studentName = cellB;
                    student.rollNo = cellA; // Roll number defaults to unique Student ID
                    student.email = null;
                    student.department = null;
                    student.semester = null;

                    validStudents.add(student);
                }
            }

        } catch (Exception e) {
            errors.add("Error processing Excel file: " + e.getMessage());
            return new ImportResult(false, 0, errors);
        }

        // If validation errors occurred, abort before modifying database
        if (!errors.isEmpty()) {
            return new ImportResult(false, 0, errors);
        }

        if (validStudents.isEmpty()) {
            errors.add("No student records found in the Excel sheet to import.");
            return new ImportResult(false, 0, errors);
        }

        return executeTransactionalImport(validStudents, errors);
    }

    /**
     * Reads a student list CSV through a java.io.BufferedReader stream,
     * validates all records, and inserts them transactionally.
     *
     * @param reader incoming reader stream (from file or upload)
     * @return ImportResult with success status and detailed error tracking
     */
    public ImportResult importStudentsFromCSV(Reader reader) {
        List<String> errors = new ArrayList<>();
        List<ParsedStudent> validStudents = new ArrayList<>();
        Set<String> seenStudentIds = new HashSet<>();
        Set<String> seenRollNos = new HashSet<>();

        // Reading line-by-line via java.io.BufferedReader
        try (BufferedReader br = new BufferedReader(reader)) {
            String line;
            int lineNumber = 0;
            boolean isHeader = true;

            while ((line = br.readLine()) != null) {
                lineNumber++;
                line = line.trim();

                // Skip blank lines and commentary lines starting with '#'
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }

                // Handle Header
                if (isHeader) {
                    isHeader = false;
                    if (!line.toLowerCase().contains("student_id") || !line.toLowerCase().contains("student_name")) {
                        errors.add(String.format("Line %d: Invalid CSV header format. Expected: 'student_id,student_name,roll_no,email,department,semester'", lineNumber));
                        return new ImportResult(false, 0, errors);
                    }
                    continue;
                }

                String[] tokens = line.split(",", -1);
                if (tokens.length < 3) {
                    errors.add(String.format("Line %d: Insufficient columns. Minimum required: student_id, student_name, roll_no.", lineNumber));
                    continue;
                }

                String studentId = tokens[0].trim();
                String studentName = tokens[1].trim();
                String rollNo = tokens[2].trim();
                String email = tokens.length > 3 ? tokens[3].trim() : null;
                String department = tokens.length > 4 ? tokens[4].trim() : null;
                Integer semester = null;

                if (tokens.length > 5 && !tokens[5].trim().isEmpty()) {
                    try {
                        semester = Integer.parseInt(tokens[5].trim());
                    } catch (NumberFormatException e) {
                        errors.add(String.format("Line %d: Invalid semester value '%s'. Must be an integer.", lineNumber, tokens[5]));
                    }
                }

                // Domain Validation
                try {
                    ValidationService.validateStudentDetails(studentId, studentName, rollNo);
                } catch (IllegalArgumentException e) {
                    errors.add(String.format("Line %d: %s", lineNumber, e.getMessage()));
                    continue;
                }

                // Duplicate Detection within the imported file
                if (!seenStudentIds.add(studentId)) {
                    errors.add(String.format("Line %d: Duplicate student_id '%s' found in CSV.", lineNumber, studentId));
                    continue;
                }
                if (!seenRollNos.add(rollNo)) {
                    errors.add(String.format("Line %d: Duplicate roll_no '%s' found in CSV.", lineNumber, rollNo));
                    continue;
                }

                ParsedStudent student = new ParsedStudent();
                student.studentId = studentId;
                student.studentName = studentName;
                student.rollNo = rollNo;
                student.email = email == null || email.isEmpty() ? null : email;
                student.department = department == null || department.isEmpty() ? null : department;
                student.semester = semester;

                validStudents.add(student);
            }

        } catch (IOException e) {
            errors.add("I/O Error while reading CSV stream: " + e.getMessage());
            return new ImportResult(false, 0, errors);
        }

        // If validation errors occurred, abort before touching the database
        if (!errors.isEmpty()) {
            return new ImportResult(false, 0, errors);
        }

        if (validStudents.isEmpty()) {
            errors.add("No student records found in CSV to import.");
            return new ImportResult(false, 0, errors);
        }

        return executeTransactionalImport(validStudents, errors);
    }

    private ImportResult executeTransactionalImport(List<ParsedStudent> validStudents, List<String> errors) {
        Connection conn = null;
        try {
            conn = DBConnection.getConnection();

            // Check for existing records in database to avoid overwriting without confirmation
            String checkSql = "SELECT student_id FROM students WHERE student_id = ?";
            try (PreparedStatement checkStmt = conn.prepareStatement(checkSql)) {
                for (ParsedStudent s : validStudents) {
                    checkStmt.setString(1, s.studentId);
                    try (java.sql.ResultSet rs = checkStmt.executeQuery()) {
                        if (rs.next()) {
                            errors.add(String.format("Student ID '%s' already exists in the database. Existing records are not overwritten without explicit confirmation.", s.studentId));
                        }
                    }
                }
            }

            if (!errors.isEmpty()) {
                return new ImportResult(false, 0, errors);
            }

            conn.setAutoCommit(false); // Begin Transaction

            String insertStudentSql = "INSERT INTO students (student_id, student_name, roll_no, email, department, semester) VALUES (?, ?, ?, ?, ?, ?)";
            String initSubjectsSql = "{CALL sp_initialize_student_subjects(?)}";

            try (PreparedStatement studentStmt = conn.prepareStatement(insertStudentSql);
                 CallableStatement initStmt = conn.prepareCall(initSubjectsSql)) {

                for (ParsedStudent s : validStudents) {
                    studentStmt.setString(1, s.studentId);
                    studentStmt.setString(2, s.studentName);
                    studentStmt.setString(3, s.rollNo != null ? s.rollNo : s.studentId);
                    studentStmt.setString(4, s.email);
                    studentStmt.setString(5, s.department);
                    if (s.semester != null) {
                        studentStmt.setInt(6, s.semester);
                    } else {
                        studentStmt.setNull(6, java.sql.Types.INTEGER);
                    }
                    studentStmt.addBatch();
                }

                studentStmt.executeBatch();

                // Initialize subject marks with NULL for every preloaded student
                for (ParsedStudent s : validStudents) {
                    initStmt.setString(1, s.studentId);
                    initStmt.addBatch();
                }
                initStmt.executeBatch();
            }

            conn.commit(); // Commit Transaction
            LOGGER.log(Level.INFO, "Successfully imported {0} students with initialized NULL marks.", validStudents.size());
            return new ImportResult(true, validStudents.size(), errors);

        } catch (SQLException e) {
            DBConnection.rollback(conn);
            LOGGER.log(Level.SEVERE, "Database error during student import transaction: " + e.getMessage(), e);
            errors.add("Database transaction rolled back: " + e.getMessage());
            return new ImportResult(false, 0, errors);
        } finally {
            if (conn != null) {
                try {
                    conn.setAutoCommit(true);
                } catch (SQLException ignored) {}
                DBConnection.close(conn);
            }
        }
    }
}
