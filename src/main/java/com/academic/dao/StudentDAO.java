package com.academic.dao;

import com.academic.config.DBConnection;
import com.academic.model.Student;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

public class StudentDAO {

    public boolean insert(Student student) throws SQLException {
        String sql = "INSERT INTO students (student_id, student_name, roll_no, email, department, semester) VALUES (?, ?, ?, ?, ?, ?)";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, student.getStudentId());
            stmt.setString(2, student.getStudentName());
            stmt.setString(3, student.getRollNo() != null ? student.getRollNo() : student.getStudentId());
            stmt.setString(4, student.getEmail());
            stmt.setString(5, student.getDepartment());
            if (student.getSemester() != null) {
                stmt.setInt(6, student.getSemester());
            } else {
                stmt.setNull(6, java.sql.Types.INTEGER);
            }
            return stmt.executeUpdate() > 0;
        }
    }

    public boolean existsById(String studentId) throws SQLException {
        String sql = "SELECT 1 FROM students WHERE student_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            try (ResultSet rs = stmt.executeQuery()) {
                return rs.next();
            }
        }
    }

    public Student findById(String studentId) throws SQLException {
        String sql = "SELECT student_id, student_name, roll_no, email, department, semester, created_at FROM students WHERE student_id = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, studentId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return mapRow(rs);
                }
            }
        }
        return null;
    }

    public Student findByRollNo(String rollNo) throws SQLException {
        String sql = "SELECT student_id, student_name, roll_no, email, department, semester, created_at FROM students WHERE roll_no = ?";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, rollNo);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return mapRow(rs);
                }
            }
        }
        return null;
    }

    public List<Student> findAll() throws SQLException {
        List<Student> list = new ArrayList<>();
        String sql = "SELECT student_id, student_name, roll_no, email, department, semester, created_at FROM students ORDER BY roll_no ASC";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql);
             ResultSet rs = stmt.executeQuery()) {
            while (rs.next()) {
                list.add(mapRow(rs));
            }
        }
        return list;
    }

    /**
     * Step 7: Returns total number of registered students in database.
     */
    public int countTotalStudents() throws SQLException {
        String sql = "SELECT COUNT(*) FROM students";
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
     * Step 7: Searches students by Student ID or Student Name with parameterized LIKE query.
     */
    public List<Student> searchByNameOrId(String query) throws SQLException {
        List<Student> list = new ArrayList<>();
        String sql = "SELECT student_id, student_name, roll_no, email, department, semester, created_at " +
                     "FROM students WHERE LOWER(student_id) LIKE ? OR LOWER(student_name) LIKE ? ORDER BY student_id ASC";
        String pattern = "%" + (query != null ? query.trim().toLowerCase() : "") + "%";
        try (Connection conn = DBConnection.getConnection();
             PreparedStatement stmt = conn.prepareStatement(sql)) {
            stmt.setString(1, pattern);
            stmt.setString(2, pattern);
            try (ResultSet rs = stmt.executeQuery()) {
                while (rs.next()) {
                    list.add(mapRow(rs));
                }
            }
        }
        return list;
    }

    private Student mapRow(ResultSet rs) throws SQLException {
        Student s = new Student();
        s.setStudentId(rs.getString("student_id"));
        s.setStudentName(rs.getString("student_name"));
        s.setRollNo(rs.getString("roll_no"));
        s.setEmail(rs.getString("email"));
        s.setDepartment(rs.getString("department"));
        int sem = rs.getInt("semester");
        s.setSemester(rs.wasNull() ? null : sem);
        s.setCreatedAt(rs.getTimestamp("created_at"));
        return s;
    }
}
