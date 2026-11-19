package com.academic.model;

import java.sql.Timestamp;

public class Student {
    private String studentId;
    private String studentName;
    private String rollNo;
    private String email;
    private String department;
    private Integer semester;
    private Timestamp createdAt;

    public Student() {}

    public Student(String studentId, String studentName, String rollNo, String email, String department, Integer semester) {
        this.studentId = studentId;
        this.studentName = studentName;
        this.rollNo = rollNo;
        this.email = email;
        this.department = department;
        this.semester = semester;
    }

    public String getStudentId() { return studentId; }
    public void setStudentId(String studentId) { this.studentId = studentId; }

    public String getStudentName() { return studentName; }
    public void setStudentName(String studentName) { this.studentName = studentName; }

    public String getRollNo() { return rollNo; }
    public void setRollNo(String rollNo) { this.rollNo = rollNo; }

    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getDepartment() { return department; }
    public void setDepartment(String department) { this.department = department; }

    public Integer getSemester() { return semester; }
    public void setSemester(Integer semester) { this.semester = semester; }

    public Timestamp getCreatedAt() { return createdAt; }
    public void setCreatedAt(Timestamp createdAt) { this.createdAt = createdAt; }
}
