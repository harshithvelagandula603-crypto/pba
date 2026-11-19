package com.academic.servlet;

import com.academic.dao.FacultyDAO;
import com.academic.dao.StudentDAO;
import com.academic.dao.SubjectDAO;
import com.academic.dao.SubjectMarkDAO;
import com.academic.model.Student;
import com.academic.model.Subject;
import com.academic.model.SubjectMark;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Academic Result Input Validator - Faculty Servlet
 * Handles faculty dashboard KPIs, assigned subjects visibility, student rosters, and mark retrieval.
 */
@WebServlet(name = "FacultyServlet", urlPatterns = {
    "/api/faculty/dashboard-stats",
    "/api/faculty/assigned-subjects",
    "/api/faculty/subjects",
    "/api/faculty/students",
    "/api/faculty/student-marks"
})
public class FacultyServlet extends BaseServlet {

    private final StudentDAO studentDAO = new StudentDAO();
    private final FacultyDAO facultyDAO = new FacultyDAO();
    private final SubjectDAO subjectDAO = new SubjectDAO();
    private final SubjectMarkDAO markDAO = new SubjectMarkDAO();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);
        if (session == null || !"faculty".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized: Faculty session required.");
            return;
        }

        String path = req.getServletPath();
        if (path == null) path = req.getPathInfo();

        try {
            if (path.endsWith("/dashboard-stats")) {
                handleDashboardStats(session, resp);
            } else if (path.endsWith("/assigned-subjects")) {
                handleAssignedSubjects(session, resp);
            } else if (path.endsWith("/subjects")) {
                handleSubjects(session, resp);
            } else if (path.endsWith("/students")) {
                handleStudents(resp);
            } else if (path.endsWith("/student-marks")) {
                handleStudentMarks(session, req, resp);
            } else {
                sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Unknown faculty endpoint: " + path);
            }
        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error processing faculty request: " + e.getMessage());
        }
    }

    private void handleDashboardStats(SessionManager.SessionData session, HttpServletResponse resp) throws SQLException, IOException {
        int totalStudents = studentDAO.countTotalStudents();
        List<Subject> assigned = getPermittedSubjects(session);
        int completedMarks = markDAO.countCompletedMarkRecords();
        int pendingStudents = markDAO.countStudentsWithPendingMarks(assigned.size());

        StringBuilder overviewJson = new StringBuilder("[");
        for (int i = 0; i < assigned.size(); i++) {
            Subject s = assigned.get(i);
            if (i > 0) overviewJson.append(",");
            overviewJson.append("{")
                .append("\"subjectId\":\"").append(escapeJson(s.getSubjectId())).append("\",")
                .append("\"subjectCode\":\"").append(escapeJson(s.getSubjectCode())).append("\",")
                .append("\"subjectName\":\"").append(escapeJson(s.getSubjectName())).append("\",")
                .append("\"maxMarks\":").append(s.getMaxMarks()).append(",")
                .append("\"maxInternal\":").append(s.getMaxInternal()).append(",")
                .append("\"maxExternal\":").append(s.getMaxExternal()).append(",")
                .append("\"passMarks\":").append(s.getPassMarks()).append(",")
                .append("\"enteredCount\":0,")
                .append("\"pendingCount\":").append(totalStudents)
                .append("}");
        }
        overviewJson.append("]");

        String json = String.format(
            "{\"success\":true,\"metrics\":{\"totalStudents\":%d,\"totalSubjects\":%d,\"studentsPending\":%d,\"completedMarkRecords\":%d},\"subjectsOverview\":%s}",
            totalStudents,
            assigned.size(),
            pendingStudents,
            completedMarks,
            overviewJson.toString()
        );
        sendJson(resp, HttpServletResponse.SC_OK, json);
    }

    private void handleAssignedSubjects(SessionManager.SessionData session, HttpServletResponse resp) throws SQLException, IOException {
        List<Subject> assigned = getPermittedSubjects(session);
        StringBuilder sb = new StringBuilder("{\"success\":true,\"subjects\":[");
        for (int i = 0; i < assigned.size(); i++) {
            Subject s = assigned.get(i);
            if (i > 0) sb.append(",");
            sb.append("{")
              .append("\"subjectId\":\"").append(escapeJson(s.getSubjectId())).append("\",")
              .append("\"subjectCode\":\"").append(escapeJson(s.getSubjectCode())).append("\",")
              .append("\"subjectName\":\"").append(escapeJson(s.getSubjectName())).append("\",")
              .append("\"maxMarks\":").append(s.getMaxMarks()).append(",")
              .append("\"maxInternal\":").append(s.getMaxInternal()).append(",")
              .append("\"maxExternal\":").append(s.getMaxExternal())
              .append("}");
        }
        sb.append("]}");
        sendJson(resp, HttpServletResponse.SC_OK, sb.toString());
    }

    private void handleSubjects(SessionManager.SessionData session, HttpServletResponse resp) throws SQLException, IOException {
        // Enforce strict faculty subject isolation (bypass attempts rejected)
        List<Subject> subjects = getPermittedSubjects(session);
        StringBuilder sb = new StringBuilder("{\"success\":true,\"subjects\":[");
        for (int i = 0; i < subjects.size(); i++) {
            Subject s = subjects.get(i);
            if (i > 0) sb.append(",");
            sb.append("{")
              .append("\"subjectId\":\"").append(escapeJson(s.getSubjectId())).append("\",")
              .append("\"subjectCode\":\"").append(escapeJson(s.getSubjectCode())).append("\",")
              .append("\"subjectName\":\"").append(escapeJson(s.getSubjectName())).append("\",")
              .append("\"maxMarks\":").append(s.getMaxMarks()).append(",")
              .append("\"maxInternal\":").append(s.getMaxInternal()).append(",")
              .append("\"maxExternal\":").append(s.getMaxExternal())
              .append("}");
        }
        sb.append("]}");
        sendJson(resp, HttpServletResponse.SC_OK, sb.toString());
    }

    private void handleStudents(HttpServletResponse resp) throws SQLException, IOException {
        List<Student> students = studentDAO.findAll();
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < students.size(); i++) {
            Student s = students.get(i);
            if (i > 0) sb.append(",");
            sb.append("{")
              .append("\"studentId\":\"").append(escapeJson(s.getStudentId())).append("\",")
              .append("\"studentName\":\"").append(escapeJson(s.getStudentName())).append("\",")
              .append("\"rollNo\":\"").append(escapeJson(s.getRollNo() != null ? s.getRollNo() : s.getStudentId())).append("\",")
              .append("\"email\":").append(s.getEmail() != null ? "\"" + escapeJson(s.getEmail()) + "\"" : "null").append(",")
              .append("\"department\":").append(s.getDepartment() != null ? "\"" + escapeJson(s.getDepartment()) + "\"" : "null").append(",")
              .append("\"semester\":").append(s.getSemester() != null ? s.getSemester() : "null").append(",")
              .append("\"status\":\"Not Updated\"")
              .append("}");
        }
        sb.append("]");
        sendJson(resp, HttpServletResponse.SC_OK, sb.toString());
    }

    private void handleStudentMarks(SessionManager.SessionData session, HttpServletRequest req, HttpServletResponse resp) throws SQLException, IOException {
        String studentId = req.getParameter("studentId");
        if (studentId == null || studentId.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Student ID query parameter is required.");
            return;
        }
        studentId = studentId.trim();

        List<SubjectMark> allMarks = markDAO.findByStudentId(studentId);
        List<SubjectMark> filtered = new ArrayList<>();

        for (SubjectMark sm : allMarks) {
            if (session.isAssignedSubject(sm.getSubjectId())) {
                filtered.add(sm);
            }
        }

        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < filtered.size(); i++) {
            SubjectMark sm = filtered.get(i);
            if (i > 0) sb.append(",");
            Integer internal = sm.getInternalMarks();
            Integer external = sm.getExternalMarks();
            Integer total = sm.getTotalMarks();

            String status;
            if (internal != null && external != null) {
                status = "Fully Entered";
            } else if (internal != null || external != null) {
                status = "Marks Pending";
            } else {
                status = "Not Updated";
            }

            sb.append("{")
              .append("\"markId\":\"").append(sm.getMarkId() != null ? sm.getMarkId() : "").append("\",")
              .append("\"studentId\":\"").append(escapeJson(sm.getStudentId())).append("\",")
              .append("\"subjectId\":\"").append(escapeJson(sm.getSubjectId())).append("\",")
              .append("\"subjectCode\":\"").append(escapeJson(sm.getSubjectId())).append("\",")
              .append("\"subjectName\":\"").append(escapeJson(sm.getSubjectName())).append("\",")
              .append("\"internalMarks\":").append(internal != null ? internal : "null").append(",")
              .append("\"externalMarks\":").append(external != null ? external : "null").append(",")
              .append("\"totalMarks\":").append(total != null ? total : "null").append(",")
              .append("\"evalStatus\":\"").append(status).append("\"")
              .append("}");
        }
        sb.append("]");
        sendJson(resp, HttpServletResponse.SC_OK, sb.toString());
    }

    private List<Subject> getPermittedSubjects(SessionManager.SessionData session) throws SQLException {
        if ("faculty".equalsIgnoreCase(session.getUsername()) || "admin".equalsIgnoreCase(session.getUsername())) {
            return subjectDAO.findAll();
        }
        return facultyDAO.getAssignedSubjects(session.getFacultyId());
    }
}
