package com.academic.dao;

import com.academic.config.DBConnection;
import com.academic.model.Subject;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Academic Result Input Validator - Subject Data Access Object
 * Queries curricular subject configurations from MySQL database.
 */
public class SubjectDAO {

    public List<Subject> findAll() throws SQLException {
        List<Subject> list = new ArrayList<>();
        String sql = "SELECT subject_id, subject_code, subject_name, max_marks, max_internal, max_external, pass_marks, created_at " +
                     "FROM subjects ORDER BY subject_id ASC";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                list.add(mapRow(rs));
            }
        }
        return list;
    }

    public Subject findById(String subjectId) throws SQLException {
        String sql = "SELECT subject_id, subject_code, subject_name, max_marks, max_internal, max_external, pass_marks, created_at " +
                     "FROM subjects WHERE subject_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, subjectId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return mapRow(rs);
                }
            }
        }
        return null;
    }

    public int countTotalSubjects() throws SQLException {
        String sql = "SELECT COUNT(*) FROM subjects";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            if (rs.next()) {
                return rs.getInt(1);
            }
        }
        return 0;
    }

    private Subject mapRow(ResultSet rs) throws SQLException {
        Subject s = new Subject();
        s.setSubjectId(rs.getString("subject_id"));
        s.setSubjectCode(rs.getString("subject_code"));
        s.setSubjectName(rs.getString("subject_name"));
        s.setMaxMarks(rs.getInt("max_marks"));
        s.setMaxInternal(rs.getInt("max_internal"));
        s.setMaxExternal(rs.getInt("max_external"));
        s.setPassMarks(rs.getInt("pass_marks"));
        s.setCreatedAt(rs.getTimestamp("created_at"));
        return s;
    }
}
