package com.academic.model;

import java.sql.Timestamp;

public class Faculty {
    public enum Status {
        ACTIVE,
        INACTIVE,
        SUSPENDED
    }

    private String facultyId;
    private String email;
    private String passwordHash;
    private Status accountStatus = Status.ACTIVE;
    private Timestamp createdAt;

    public Faculty() {}

    public Faculty(String facultyId, String email, String passwordHash) {
        this.facultyId = facultyId;
        this.email = email;
        this.passwordHash = passwordHash;
    }

    public String getFacultyId() { return facultyId; }
    public void setFacultyId(String facultyId) { this.facultyId = facultyId; }

    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }

    public String getPasswordHash() { return passwordHash; }
    public void setPasswordHash(String passwordHash) { this.passwordHash = passwordHash; }

    public Status getAccountStatus() { return accountStatus; }
    public void setAccountStatus(Status accountStatus) { this.accountStatus = accountStatus; }

    public Timestamp getCreatedAt() { return createdAt; }
    public void setCreatedAt(Timestamp createdAt) { this.createdAt = createdAt; }
}
