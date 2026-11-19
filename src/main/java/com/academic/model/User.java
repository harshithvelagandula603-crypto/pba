package com.academic.model;

import java.sql.Timestamp;

public class User {
    public enum Role {
        STUDENT,
        FACULTY
    }

    public enum Status {
        ACTIVE,
        INACTIVE,
        SUSPENDED
    }

    private Integer accountId;
    private String username;
    private String passwordHash;
    private Role role;
    private String studentId;
    private Status accountStatus = Status.ACTIVE;
    private Timestamp createdAt;
    private Timestamp lastLogin;

    public User() {}

    public User(String username, String passwordHash, Role role, String studentId) {
        this.username = username;
        this.passwordHash = passwordHash;
        this.role = role;
        this.studentId = studentId;
    }

    public Integer getAccountId() { return accountId; }
    public void setAccountId(Integer accountId) { this.accountId = accountId; }

    public String getUsername() { return username; }
    public void setUsername(String username) { this.username = username; }

    public String getPasswordHash() { return passwordHash; }
    public void setPasswordHash(String passwordHash) { this.passwordHash = passwordHash; }

    public Role getRole() { return role; }
    public void setRole(Role role) { this.role = role; }

    public String getStudentId() { return studentId; }
    public void setStudentId(String studentId) { this.studentId = studentId; }

    public Status getAccountStatus() { return accountStatus; }
    public void setAccountStatus(Status accountStatus) { this.accountStatus = accountStatus; }

    public Timestamp getCreatedAt() { return createdAt; }
    public void setCreatedAt(Timestamp createdAt) { this.createdAt = createdAt; }

    public Timestamp getLastLogin() { return lastLogin; }
    public void setLastLogin(Timestamp lastLogin) { this.lastLogin = lastLogin; }
}
