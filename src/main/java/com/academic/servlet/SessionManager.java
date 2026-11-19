package com.academic.servlet;

import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Academic Result Input Validator - Session Manager
 * Provides thread-safe session tracking supporting both X-Session-Id header tokens
 * and standard Servlet HttpSessions.
 */
public class SessionManager {

    public static class SessionData {
        private final String sessionId;
        private final String role; // "student" or "faculty"
        private final String studentId;
        private final String studentName;
        private final String facultyId;
        private final String username;
        private final List<String> assignedSubjects;
        private volatile long lastAccessed;

        public SessionData(String sessionId, String role, String studentId, String studentName,
                           String facultyId, String username, List<String> assignedSubjects) {
            this.sessionId = sessionId;
            this.role = role;
            this.studentId = studentId;
            this.studentName = studentName;
            this.facultyId = facultyId;
            this.username = username;
            this.assignedSubjects = assignedSubjects != null ? assignedSubjects : Collections.emptyList();
            this.lastAccessed = System.currentTimeMillis();
        }

        public String getSessionId() { return sessionId; }
        public String getRole() { return role; }
        public String getStudentId() { return studentId; }
        public String getStudentName() { return studentName; }
        public String getFacultyId() { return facultyId; }
        public String getUsername() { return username; }
        public List<String> getAssignedSubjects() { return assignedSubjects; }
        public long getLastAccessed() { return lastAccessed; }

        public void touch() {
            this.lastAccessed = System.currentTimeMillis();
        }

        public boolean isAssignedSubject(String subjectId) {
            if ("faculty".equalsIgnoreCase(this.username) || "admin".equalsIgnoreCase(this.username)) {
                return true; // Admin faculty has access to all subjects
            }
            if (subjectId == null || assignedSubjects == null) return false;
            for (String s : assignedSubjects) {
                if (s.equalsIgnoreCase(subjectId)) return true;
            }
            return false;
        }
    }

    private static final Map<String, SessionData> activeSessions = new ConcurrentHashMap<>();

    public static SessionData createStudentSession(String studentId, String studentName) {
        String token = UUID.randomUUID().toString();
        SessionData data = new SessionData(token, "student", studentId, studentName, null, studentId, null);
        activeSessions.put(token, data);
        return data;
    }

    public static SessionData createFacultySession(String facultyId, String email, List<String> assignedSubjects) {
        String token = UUID.randomUUID().toString();
        SessionData data = new SessionData(token, "faculty", null, null, facultyId, facultyId, assignedSubjects);
        activeSessions.put(token, data);
        return data;
    }

    public static SessionData getSession(String sessionId) {
        if (sessionId == null) return null;
        SessionData data = activeSessions.get(sessionId.trim());
        if (data != null) {
            data.touch();
        }
        return data;
    }

    public static void invalidate(String sessionId) {
        if (sessionId != null) {
            activeSessions.remove(sessionId.trim());
        }
    }
}
