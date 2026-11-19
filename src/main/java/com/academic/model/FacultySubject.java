package com.academic.model;

import java.sql.Timestamp;

public class FacultySubject {
    private Integer assignmentId;
    private String facultyId;
    private String subjectId;
    private Timestamp assignedAt;

    public FacultySubject() {}

    public FacultySubject(String facultyId, String subjectId) {
        this.facultyId = facultyId;
        this.subjectId = subjectId;
    }

    public Integer getAssignmentId() { return assignmentId; }
    public void setAssignmentId(Integer assignmentId) { this.assignmentId = assignmentId; }

    public String getFacultyId() { return facultyId; }
    public void setFacultyId(String facultyId) { this.facultyId = facultyId; }

    public String getSubjectId() { return subjectId; }
    public void setSubjectId(String subjectId) { this.subjectId = subjectId; }

    public Timestamp getAssignedAt() { return assignedAt; }
    public void setAssignedAt(Timestamp assignedAt) { this.assignedAt = assignedAt; }
}
