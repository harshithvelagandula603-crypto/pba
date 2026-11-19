package com.academic.servlet;

import com.academic.dao.FacultyDAO;
import com.academic.dao.StudentDAO;
import com.academic.model.Faculty;
import com.academic.model.Student;
import com.academic.model.Subject;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;
import java.io.IOException;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Academic Result Input Validator - Authentication Servlet
 * Connects frontend login requests directly to MySQL StudentDAO and FacultyDAO.
 */
@WebServlet(name = "AuthServlet", urlPatterns = {"/api/auth/*", "/api/auth/student", "/api/auth/faculty", "/api/auth/logout"})
public class AuthServlet extends BaseServlet {

    private final StudentDAO studentDAO = new StudentDAO();
    private final FacultyDAO facultyDAO = new FacultyDAO();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        String path = req.getPathInfo();
        String servletPath = req.getServletPath();
        String fullPath = (servletPath != null ? servletPath : "") + (path != null ? path : "");

        String body = readRequestBody(req);
        Map<String, String> payload = parseSimpleJson(body);

        if (fullPath.endsWith("/student") || fullPath.endsWith("/student-login")) {
            handleStudentLogin(payload, req, resp);
        } else if (fullPath.endsWith("/faculty") || fullPath.endsWith("/faculty-login")) {
            handleFacultyLogin(payload, req, resp);
        } else if (fullPath.endsWith("/logout")) {
            handleLogout(req, resp);
        } else {
            sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Unknown authentication endpoint: " + fullPath);
        }
    }

    private void handleStudentLogin(Map<String, String> payload, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String studentId = payload.get("studentId");
        if (studentId == null || studentId.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Student ID is required.");
            return;
        }
        studentId = studentId.trim();

        try {
            Student student = studentDAO.findById(studentId);
            if (student == null) {
                sendError(resp, HttpServletResponse.SC_NOT_FOUND,
                    String.format("Invalid Student ID '%s'. No matching student record found in institutional records.", studentId));
                return;
            }

            SessionManager.SessionData sessionData = SessionManager.createStudentSession(student.getStudentId(), student.getStudentName());
            HttpSession httpSession = req.getSession(true);
            httpSession.setAttribute("academic_session", sessionData);

            String json = String.format(
                "{\"success\":true,\"session\":{\"sessionId\":\"%s\",\"role\":\"student\",\"studentId\":\"%s\",\"studentName\":\"%s\"}}",
                sessionData.getSessionId(),
                escapeJson(student.getStudentId()),
                escapeJson(student.getStudentName())
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);

        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error verifying Student ID: " + e.getMessage());
        }
    }

    private void handleFacultyLogin(Map<String, String> payload, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String facultyId = payload.get("facultyId");
        String username = payload.get("username");
        String email = payload.get("email");
        String password = payload.get("password");

        // Allow identifier from either facultyId or username
        String identifier = facultyId != null && !facultyId.trim().isEmpty() ? facultyId.trim() : (username != null ? username.trim() : null);

        if (identifier == null || identifier.isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Faculty ID or username is required.");
            return;
        }

        // Support admin master account: faculty / admin123
        if ("faculty".equalsIgnoreCase(identifier) && "admin123".equals(password)) {
            SessionManager.SessionData sessionData = SessionManager.createFacultySession("faculty", "admin@academic.edu", null);
            HttpSession httpSession = req.getSession(true);
            httpSession.setAttribute("academic_session", sessionData);

            String json = String.format(
                "{\"success\":true,\"session\":{\"sessionId\":\"%s\",\"role\":\"faculty\",\"username\":\"faculty\",\"facultyId\":\"FACULTY_ADMIN\",\"assignedSubjects\":[]}}",
                sessionData.getSessionId()
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);
            return;
        }

        if (email == null || email.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Registered email address is required.");
            return;
        }
        email = email.trim();

        try {
            Faculty faculty = facultyDAO.findById(identifier);
            if (faculty == null) {
                sendError(resp, HttpServletResponse.SC_UNAUTHORIZED,
                    String.format("Authentication failed. Faculty ID '%s' not registered.", identifier));
                return;
            }

            if (!email.equalsIgnoreCase(faculty.getEmail())) {
                sendError(resp, HttpServletResponse.SC_UNAUTHORIZED,
                    "Invalid registered email address. Authentication rejected.");
                return;
            }

            List<Subject> assigned = facultyDAO.getAssignedSubjects(faculty.getFacultyId());
            List<String> subjectIds = new ArrayList<>();
            StringBuilder subjectsJson = new StringBuilder("[");
            for (int i = 0; i < assigned.size(); i++) {
                Subject s = assigned.get(i);
                subjectIds.add(s.getSubjectId());
                if (i > 0) subjectsJson.append(",");
                subjectsJson.append("\"").append(escapeJson(s.getSubjectId())).append("\"");
            }
            subjectsJson.append("]");

            SessionManager.SessionData sessionData = SessionManager.createFacultySession(faculty.getFacultyId(), faculty.getEmail(), subjectIds);
            HttpSession httpSession = req.getSession(true);
            httpSession.setAttribute("academic_session", sessionData);

            String json = String.format(
                "{\"success\":true,\"session\":{\"sessionId\":\"%s\",\"role\":\"faculty\",\"username\":\"%s\",\"facultyId\":\"%s\",\"email\":\"%s\",\"assignedSubjects\":%s}}",
                sessionData.getSessionId(),
                escapeJson(faculty.getFacultyId()),
                escapeJson(faculty.getFacultyId()),
                escapeJson(faculty.getEmail()),
                subjectsJson.toString()
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);

        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error authenticating faculty: " + e.getMessage());
        }
    }

    private void handleLogout(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String token = req.getHeader("X-Session-Id");
        if (token != null) {
            SessionManager.invalidate(token);
        }
        HttpSession session = req.getSession(false);
        if (session != null) {
            session.invalidate();
        }
        sendJson(resp, HttpServletResponse.SC_OK, "{\"success\":true,\"message\":\"Logged out successfully.\"}");
    }
}
