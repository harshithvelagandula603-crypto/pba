package com.academic.model;

import java.sql.Timestamp;

/**
 * Academic Result Input Validator - Subject Entity
 * Step 8: Configured Curricular Subject with code abbreviation and full name.
 * 40 max internal + 60 max external = 100 max marks.
 */
public class Subject {
    private String subjectId;
    private String subjectCode;
    private String subjectName;
    private int maxMarks = 100;
    private int maxInternal = 40;
    private int maxExternal = 60;
    private int passMarks = 40;
    private Timestamp createdAt;

    public Subject() {}

    public Subject(String subjectId, String subjectCode, String subjectName, int maxMarks, int maxInternal, int maxExternal, int passMarks) {
        this.subjectId = subjectId;
        this.subjectCode = subjectCode;
        this.subjectName = subjectName;
        this.maxMarks = maxMarks;
        this.maxInternal = maxInternal;
        this.maxExternal = maxExternal;
        this.passMarks = passMarks;
    }

    public String getSubjectId() { return subjectId; }
    public void setSubjectId(String subjectId) { this.subjectId = subjectId; }

    public String getSubjectCode() { return subjectCode; }
    public void setSubjectCode(String subjectCode) { this.subjectCode = subjectCode; }

    public String getSubjectName() { return subjectName; }
    public void setSubjectName(String subjectName) { this.subjectName = subjectName; }

    public int getMaxMarks() { return maxMarks; }
    public void setMaxMarks(int maxMarks) { this.maxMarks = maxMarks; }

    public int getMaxInternal() { return maxInternal; }
    public void setMaxInternal(int maxInternal) { this.maxInternal = maxInternal; }

    public int getMaxExternal() { return maxExternal; }
    public void setMaxExternal(int maxExternal) { this.maxExternal = maxExternal; }

    public int getPassMarks() { return passMarks; }
    public void setPassMarks(int passMarks) { this.passMarks = passMarks; }

    public Timestamp getCreatedAt() { return createdAt; }
    public void setCreatedAt(Timestamp createdAt) { this.createdAt = createdAt; }
}
