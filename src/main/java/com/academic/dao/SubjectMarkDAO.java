package com.academic.dao;

import com.academic.config.DBConnection;
import com.academic.model.SubjectMark;
import com.academic.service.ValidationService;

import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Academic Result Input Validator - Subject Mark DAO (Step 6: Internal/External Split)
 *
 * All queries now operate on the split-marks schema:
 *   - internal_marks : INT NULL [0-40]   — internal assessment component
 *   - external_marks : INT NULL [0-60]   — external examination component
 *   - Total marks are NEVER persisted; they are computed in memory via SubjectMark.getTotalMarks()
 *
 * NULL is explicitly preserved as Java null (not converted to 0).
 */
public class SubjectMarkDAO {

    /**
     * Retrieves all subject marks for a given student.
     * Joins with the subjects table to include the subject name.
     * Crucially preserves SQL NULL as Java null for BOTH internal and external components.
     */
    public List<SubjectMark> findByStudentId(String studentId) throws SQLException {
        List<SubjectMark> marks = new ArrayList<>();
        String sql =
            "SELECT sm.mark_id, ? AS student_id, s.subject_id, s.subject_name, " +
            "       sm.internal_marks, sm.external_marks, sm.updated_at " +
            "FROM subjects s " +
            "LEFT JOIN subject_marks sm ON s.subject_id = sm.subject_id AND sm.student_id = ? " +
            "ORDER BY s.subject_id ASC";

        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            stmt.setString(2, studentId);
            try (ResultSet rs = stmt.executeQuery()) {
                while (rs.next()) {
                    SubjectMark mark = new SubjectMark();

                    long markId = rs.getLong("mark_id");
                    mark.setMarkId(rs.wasNull() ? null : markId);
                    mark.setStudentId(studentId);
                    mark.setSubjectId(rs.getString("subject_id"));
                    mark.setSubjectName(rs.getString("subject_name"));

                    // Internal Marks: Strictly preserves NULL (Not Updated) vs genuine score 0
                    int rawInternal = rs.getInt("internal_marks");
                    mark.setInternalMarks(rs.wasNull() ? null : rawInternal);

                    // External Marks: Strictly preserves NULL (Not Updated) vs genuine score 0
                    int rawExternal = rs.getInt("external_marks");
                    mark.setExternalMarks(rs.wasNull() ? null : rawExternal);

                    mark.setUpdatedAt(rs.getTimestamp("updated_at"));
                    marks.add(mark);
                }
            }
        }
        return marks;
    }

    /**
     * Updates the internal marks component for a student-subject pair.
     * Domain constraint enforced in Java before touching MySQL: [0-40] or NULL.
     *
     * @param studentId     target student
     * @param subjectId     target subject
     * @param internalMarks score (0-40) or null to reset to unentered
     * @return true if updated successfully
     * @throws IllegalArgumentException if internalMarks violates domain constraints
     */
    public boolean updateInternalMark(String studentId, String subjectId, Integer internalMarks)
            throws SQLException, IllegalArgumentException {

        if (!ValidationService.isValidInternalMark(internalMarks)) {
            throw new IllegalArgumentException(
                String.format("Domain Constraint Violation: Internal mark must be between %d and %d, or NULL. Received: %s",
                    ValidationService.MIN_MARK, ValidationService.MAX_INTERNAL_MARK, internalMarks));
        }

        String sql = "INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks) " +
                     "VALUES (?, ?, ?, NULL) " +
                     "ON DUPLICATE KEY UPDATE internal_marks = VALUES(internal_marks)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            stmt.setString(2, subjectId);
            if (internalMarks == null) {
                stmt.setNull(3, java.sql.Types.INTEGER);
            } else {
                stmt.setInt(3, internalMarks);
            }
            return stmt.executeUpdate() > 0;
        }
    }

    /**
     * Updates the external marks component for a student-subject pair.
     * Domain constraint enforced in Java before touching MySQL: [0-60] or NULL.
     *
     * @param studentId     target student
     * @param subjectId     target subject
     * @param externalMarks score (0-60) or null to reset to unentered
     * @return true if updated successfully
     * @throws IllegalArgumentException if externalMarks violates domain constraints
     */
    public boolean updateExternalMark(String studentId, String subjectId, Integer externalMarks)
            throws SQLException, IllegalArgumentException {

        if (!ValidationService.isValidExternalMark(externalMarks)) {
            throw new IllegalArgumentException(
                String.format("Domain Constraint Violation: External mark must be between %d and %d, or NULL. Received: %s",
                    ValidationService.MIN_MARK, ValidationService.MAX_EXTERNAL_MARK, externalMarks));
        }

        String sql = "INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks) " +
                     "VALUES (?, ?, NULL, ?) " +
                     "ON DUPLICATE KEY UPDATE external_marks = VALUES(external_marks)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            stmt.setString(2, subjectId);
            if (externalMarks == null) {
                stmt.setNull(3, java.sql.Types.INTEGER);
            } else {
                stmt.setInt(3, externalMarks);
            }
            return stmt.executeUpdate() > 0;
        }
    }

    /**
     * Updates BOTH internal and external marks in a single upsert.
     * Either component may independently be null.
     */
    public boolean updateBothMarks(String studentId, String subjectId,
                                   Integer internalMarks, Integer externalMarks)
            throws SQLException, IllegalArgumentException {

        if (!ValidationService.isValidInternalMark(internalMarks)) {
            throw new IllegalArgumentException(
                String.format("Domain Constraint Violation: Internal mark must be between %d and %d, or NULL. Received: %s",
                    ValidationService.MIN_MARK, ValidationService.MAX_INTERNAL_MARK, internalMarks));
        }
        if (!ValidationService.isValidExternalMark(externalMarks)) {
            throw new IllegalArgumentException(
                String.format("Domain Constraint Violation: External mark must be between %d and %d, or NULL. Received: %s",
                    ValidationService.MIN_MARK, ValidationService.MAX_EXTERNAL_MARK, externalMarks));
        }

        String sql = "INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks) " +
                     "VALUES (?, ?, ?, ?) " +
                     "ON DUPLICATE KEY UPDATE internal_marks = VALUES(internal_marks), external_marks = VALUES(external_marks)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            stmt.setString(2, subjectId);
            if (internalMarks == null) {
                stmt.setNull(3, java.sql.Types.INTEGER);
            } else {
                stmt.setInt(3, internalMarks);
            }
            if (externalMarks == null) {
                stmt.setNull(4, java.sql.Types.INTEGER);
            } else {
                stmt.setInt(4, externalMarks);
            }
            return stmt.executeUpdate() > 0;
        }
    }

    /**
     * Calls the stored procedure to initialize all pending subjects with NULL marks for a student.
     * Both internal_marks and external_marks will be NULL ("Not Updated").
     */
    public void initializeSubjectsForStudent(String studentId) throws SQLException {
        String callSql = "{CALL sp_initialize_student_subjects(?)}";
        try (Connection conn = DBConnection.getConnection();
             CallableStatement cstmt = conn.prepareCall(callSql)) {
            cstmt.setString(1, studentId);
            cstmt.execute();
        }
    }

    /**
     * Step 7: Counts total student-subject records where BOTH internal and external marks are entered.
     */
    public int countCompletedMarkRecords() throws SQLException {
        String sql = "SELECT COUNT(DISTINCT sm.mark_id) FROM subject_marks sm WHERE sm.internal_marks IS NOT NULL AND sm.external_marks IS NOT NULL AND sm.internal_marks BETWEEN 0 AND 40 AND sm.external_marks BETWEEN 0 AND 60";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            if (rs.next()) {
                return rs.getInt(1);
            }
        }
        return 0;
    }

    /**
     * Step 7: Counts number of students who have at least one subject with missing internal or external marks.
     * Uses COUNT(DISTINCT sm.subject_id) to avoid duplicate counting from joined table rows.
     */
    public int countStudentsWithPendingMarks(int totalConfiguredSubjects) throws SQLException {
        String sql =
            "SELECT COUNT(DISTINCT s.student_id) " +
            "FROM students s " +
            "LEFT JOIN subject_marks sm ON s.student_id = sm.student_id " +
            "    AND sm.internal_marks IS NOT NULL AND sm.external_marks IS NOT NULL " +
            "    AND sm.internal_marks BETWEEN 0 AND 40 AND sm.external_marks BETWEEN 0 AND 60 " +
            "GROUP BY s.student_id " +
            "HAVING COUNT(DISTINCT sm.subject_id) < ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setInt(1, totalConfiguredSubjects);
            try (ResultSet rs = stmt.executeQuery()) {
                int count = 0;
                while (rs.next()) {
                    count++;
                }
                return count;
            }
        }
    }
}
