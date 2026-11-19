package com.academic.dao;

import com.academic.config.DBConnection;
import com.academic.model.Faculty;
import com.academic.model.Subject;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

public class FacultyDAO {

    public boolean insertOrUpdate(Faculty faculty) throws SQLException {
        String sql = "INSERT INTO faculty (faculty_id, email, password_hash, account_status) VALUES (?, ?, ?, ?) " +
                     "ON DUPLICATE KEY UPDATE email = VALUES(email), account_status = VALUES(account_status)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, faculty.getFacultyId());
            stmt.setString(2, faculty.getEmail());
            stmt.setString(3, faculty.getPasswordHash());
            stmt.setString(4, faculty.getAccountStatus() != null ? faculty.getAccountStatus().name() : "ACTIVE");
            return stmt.executeUpdate() > 0;
        }
    }

    public Faculty findById(String facultyId) throws SQLException {
        String sql = "SELECT faculty_id, email, password_hash, account_status, created_at FROM faculty WHERE faculty_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, facultyId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    Faculty f = new Faculty();
                    f.setFacultyId(rs.getString("faculty_id"));
                    f.setEmail(rs.getString("email"));
                    f.setPasswordHash(rs.getString("password_hash"));
                    f.setAccountStatus(Faculty.Status.valueOf(rs.getString("account_status")));
                    f.setCreatedAt(rs.getTimestamp("created_at"));
                    return f;
                }
            }
        }
        return null;
    }

    public boolean assignSubject(String facultyId, String subjectId) throws SQLException {
        String sql = "INSERT INTO faculty_subjects (faculty_id, subject_id) VALUES (?, ?) " +
                     "ON DUPLICATE KEY UPDATE faculty_id = VALUES(faculty_id), subject_id = VALUES(subject_id)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, facultyId);
            stmt.setString(2, subjectId);
            return stmt.executeUpdate() > 0;
        }
    }

    public List<Subject> getAssignedSubjects(String facultyId) throws SQLException {
        String sql = "SELECT s.subject_id, s.subject_code, s.subject_name, s.max_marks, s.max_internal, s.max_external, s.pass_marks, s.created_at " +
                     "FROM subjects s " +
                     "INNER JOIN faculty_subjects fs ON s.subject_id = fs.subject_id " +
                     "WHERE fs.faculty_id = ? ORDER BY s.subject_code ASC";
        List<Subject> list = new ArrayList<>();
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, facultyId);
            try (ResultSet rs = stmt.executeQuery()) {
                while (rs.next()) {
                    Subject sub = new Subject();
                    sub.setSubjectId(rs.getString("subject_id"));
                    sub.setSubjectCode(rs.getString("subject_code"));
                    sub.setSubjectName(rs.getString("subject_name"));
                    sub.setMaxMarks(rs.getInt("max_marks"));
                    sub.setMaxInternal(rs.getInt("max_internal"));
                    sub.setMaxExternal(rs.getInt("max_external"));
                    sub.setPassMarks(rs.getInt("pass_marks"));
                    sub.setCreatedAt(rs.getTimestamp("created_at"));
                    list.add(sub);
                }
            }
        }
        return list;
    }

    public boolean isSubjectAssigned(String facultyId, String subjectId) throws SQLException {
        String sql = "SELECT 1 FROM faculty_subjects WHERE faculty_id = ? AND subject_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, facultyId);
            stmt.setString(2, subjectId);
            try (ResultSet rs = stmt.executeQuery()) {
                return rs.next();
            }
        }
    }

    public boolean updatePassword(String facultyId, String passwordHash) throws SQLException {
        String sql = "UPDATE faculty SET password_hash = ? WHERE faculty_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, passwordHash);
            stmt.setString(2, facultyId);
            return stmt.executeUpdate() > 0;
        }
    }
}
