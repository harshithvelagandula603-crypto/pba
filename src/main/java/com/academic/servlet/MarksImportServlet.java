package com.academic.servlet;

import com.academic.dao.FacultyDAO;
import com.academic.dao.StudentDAO;
import com.academic.dao.SubjectDAO;
import com.academic.dao.SubjectMarkDAO;
import com.academic.model.Student;
import com.academic.model.Subject;
import com.academic.model.SubjectMark;
import com.academic.service.MarksImportService;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.*;
import java.sql.SQLException;
import java.util.*;

/**
 * Academic Result Input Validator - Faculty Marks Import Servlet
 * Handles:
 * - GET /api/faculty/marks-template : Download Excel (.xlsx) template for assigned subject
 * - POST /api/faculty/marks-import-preview : Parses and validates uploaded Excel rows before save
 * - POST /api/faculty/marks-import-commit : Transactionally commits valid rows to database
 */
@WebServlet(name = "MarksImportServlet", urlPatterns = {
    "/api/faculty/marks-template",
    "/api/faculty/marks-import-preview",
    "/api/faculty/marks-import-commit"
})
public class MarksImportServlet extends BaseServlet {

    private final MarksImportService importService = new MarksImportService();
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

        if (path.endsWith("/marks-template")) {
            handleTemplateDownload(session, req, resp);
        } else {
            sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Unknown GET endpoint: " + path);
        }
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);
        if (session == null || !"faculty".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized: Faculty session required.");
            return;
        }

        String path = req.getServletPath();
        if (path == null) path = req.getPathInfo();

        if (path.endsWith("/marks-import-preview")) {
            handlePreview(session, req, resp);
        } else if (path.endsWith("/marks-import-commit")) {
            handleCommit(session, req, resp);
        } else {
            sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Unknown POST endpoint: " + path);
        }
    }

    private void handleTemplateDownload(SessionManager.SessionData session, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String reqSubId = req.getParameter("subjectId");
        List<String> authorizedSubjects = getFacultyAuthorizedSubjectCodes(session);

        if (authorizedSubjects.isEmpty()) {
            sendError(resp, HttpServletResponse.SC_FORBIDDEN, "No curricular subjects are assigned to your faculty account.");
            return;
        }

        String targetSubject = null;
        if (reqSubId != null && !reqSubId.trim().isEmpty()) {
            for (String s : authorizedSubjects) {
                if (s.equalsIgnoreCase(reqSubId.trim())) {
                    targetSubject = s;
                    break;
                }
            }
            if (targetSubject == null) {
                sendError(resp, HttpServletResponse.SC_FORBIDDEN, "Subject '" + reqSubId + "' is not assigned to your faculty account.");
                return;
            }
        } else {
            targetSubject = authorizedSubjects.get(0);
        }

        try {
            List<Student> students = studentDAO.findAll();
            Map<String, SubjectMark> existingMarks = new HashMap<>();
            for (Student st : students) {
                List<SubjectMark> smList = markDAO.findByStudentId(st.getStudentId());
                for (SubjectMark sm : smList) {
                    if (targetSubject.equalsIgnoreCase(sm.getSubjectId())) {
                        existingMarks.put(st.getStudentId(), sm);
                    }
                }
            }

            byte[] xlsxBytes = importService.generateTemplate(targetSubject, students, existingMarks);
            resp.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
            resp.setHeader("Content-Disposition", "attachment; filename=\"Marks_Template_" + targetSubject + ".xlsx\"");
            resp.setContentLength(xlsxBytes.length);
            resp.getOutputStream().write(xlsxBytes);
            resp.getOutputStream().flush();
        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error generating template: " + e.getMessage());
        }
    }

    private void handlePreview(SessionManager.SessionData session, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String body = readBody(req);
        String base64 = extractJsonString(body, "fileContentBase64");
        String subjectId = extractJsonString(body, "subjectId");

        if (base64 == null || base64.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Missing Excel fileContentBase64 in request payload.");
            return;
        }

        byte[] fileBytes;
        try {
            fileBytes = Base64.getDecoder().decode(base64.trim());
        } catch (IllegalArgumentException e) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Invalid Base64 file encoding.");
            return;
        }

        File tempFile = File.createTempFile("preview_", ".xlsx");
        try (FileOutputStream fos = new FileOutputStream(tempFile)) {
            fos.write(fileBytes);
        }

        List<String> authorizedSubjects = getFacultyAuthorizedSubjectCodes(session);
        MarksImportService.PreviewResult preview = importService.previewExcelMarks(tempFile, session.getUsername(), authorizedSubjects);
        tempFile.delete();

        if (!preview.success) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, preview.error != null ? preview.error : "Validation failed.");
            return;
        }

        StringBuilder rowsJson = new StringBuilder("[");
        for (int i = 0; i < preview.rows.size(); i++) {
            MarksImportService.MarkRow r = preview.rows.get(i);
            if (i > 0) rowsJson.append(",");
            rowsJson.append("{")
                .append("\"rowNumber\":").append(r.rowNumber).append(",")
                .append("\"subjectCode\":\"").append(escapeJson(r.subjectCode)).append("\",")
                .append("\"studentId\":\"").append(escapeJson(r.studentId)).append("\",")
                .append("\"studentName\":\"").append(escapeJson(r.studentName)).append("\",")
                .append("\"internalMarks\":").append(r.internalMarks != null ? r.internalMarks : "null").append(",")
                .append("\"externalMarks\":").append(r.externalMarks != null ? r.externalMarks : "null").append(",")
                .append("\"rawInternal\":\"").append(escapeJson(r.rawInternal)).append("\",")
                .append("\"rawExternal\":\"").append(escapeJson(r.rawExternal)).append("\",")
                .append("\"status\":\"").append(escapeJson(r.status)).append("\",")
                .append("\"errorMessage\":").append(r.errorMessage != null ? "\"" + escapeJson(r.errorMessage) + "\"" : "null")
                .append("}");
        }
        rowsJson.append("]");

        String json = String.format(
            "{\"success\":true,\"subjectId\":\"%s\",\"subjectCode\":\"%s\",\"totalRows\":%d,\"validRowsCount\":%d,\"invalidRowsCount\":%d,\"rows\":%s}",
            escapeJson(preview.subjectId),
            escapeJson(preview.subjectCode),
            preview.totalRows,
            preview.validRowsCount,
            preview.invalidRowsCount,
            rowsJson.toString()
        );
        sendJson(resp, HttpServletResponse.SC_OK, json);
    }

    private void handleCommit(SessionManager.SessionData session, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String body = readBody(req);
        String subjectId = extractJsonString(body, "subjectId");
        String base64 = extractJsonString(body, "fileContentBase64");

        List<String> authorizedSubjects = getFacultyAuthorizedSubjectCodes(session);
        if (subjectId != null && !authorizedSubjects.contains(subjectId.toUpperCase())) {
            sendError(resp, HttpServletResponse.SC_FORBIDDEN, "Access Denied: Subject '" + subjectId + "' is not assigned to your faculty account.");
            return;
        }

        if (base64 == null || base64.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "File data missing for import commit.");
            return;
        }

        byte[] fileBytes = Base64.getDecoder().decode(base64.trim());
        File tempFile = File.createTempFile("commit_", ".xlsx");
        try (FileOutputStream fos = new FileOutputStream(tempFile)) {
            fos.write(fileBytes);
        }

        MarksImportService.PreviewResult preview = importService.previewExcelMarks(tempFile, session.getUsername(), authorizedSubjects);
        tempFile.delete();

        if (!preview.success) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, preview.error != null ? preview.error : "Validation failed.");
            return;
        }

        try {
            MarksImportService.CommitResult cr = importService.commitValidMarks(preview.rows, preview.subjectId, session.getUsername());
            StringBuilder rejJson = new StringBuilder("[");
            for (int i = 0; i < cr.rejectedRows.size(); i++) {
                Map<String, String> rej = cr.rejectedRows.get(i);
                if (i > 0) rejJson.append(",");
                rejJson.append("{\"studentId\":\"").append(escapeJson(rej.get("studentId"))).append("\",\"reason\":\"").append(escapeJson(rej.get("reason"))).append("\"}");
            }
            rejJson.append("]");

            String json = String.format(
                "{\"success\":true,\"message\":\"%s\",\"processedCount\":%d,\"validCount\":%d,\"invalidCount\":%d,\"importedCount\":%d,\"rejectedCount\":%d,\"rejectedRows\":%s}",
                escapeJson(cr.message),
                cr.processedCount,
                cr.validCount,
                cr.invalidCount,
                cr.importedCount,
                cr.rejectedCount,
                rejJson.toString()
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);
        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database transaction error: " + e.getMessage());
        }
    }

    private List<String> getFacultyAuthorizedSubjectCodes(SessionManager.SessionData session) {
        List<String> list = new ArrayList<>();
        try {
            String facId = session.getFacultyId() != null ? session.getFacultyId() : session.getUsername();
            if ("faculty".equalsIgnoreCase(facId)) {
                List<Subject> all = subjectDAO.findAll();
                for (Subject s : all) list.add(s.getSubjectId().toUpperCase());
            } else {
                List<String> subIds = facultyDAO.findAssignedSubjectIds(facId);
                for (String s : subIds) list.add(s.toUpperCase());
            }
        } catch (SQLException ignored) {}
        return list;
    }

    private String readBody(HttpServletRequest req) throws IOException {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = req.getReader()) {
            String line;
            while ((line = reader.readLine()) != null) sb.append(line);
        }
        return sb.toString();
    }

    private String extractJsonString(String json, String key) {
        if (json == null) return null;
        String pattern = "\"" + key + "\"\\s*:\\s*\"([^\"]+)\"";
        java.util.regex.Matcher m = java.util.regex.Pattern.compile(pattern).matcher(json);
        if (m.find()) return m.group(1);
        return null;
    }
}
