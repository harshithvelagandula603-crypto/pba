package com.academic.servlet;

import com.academic.config.DBConnection;
import com.academic.dao.FacultyDAO;
import com.academic.model.Subject;
import com.academic.service.TableFileInputValidatorService;

import javax.servlet.annotation.MultipartConfig;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.Part;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.util.*;

/**
 * Academic Result Input Validator - Table File Input Validator & Ingestion Servlet
 *
 * Endpoint:
 * - POST /api/faculty/validate-table-file
 * - POST /api/faculty/import-table-file
 *
 * Restricts access to authorized faculty sessions.
 * Streams input marks records through java.io.BufferedReader line-by-line,
 * applies domain integrity constraints (student existence, authorized subject,
 * internal [0,40], external [0,60], internal-first ordering, duplicate checks),
 * and commits only valid records to data/export/marks.csv while synchronizing with MySQL.
 */
@WebServlet(name = "TableFileInputValidatorServlet", urlPatterns = {
    "/api/faculty/validate-table-file",
    "/api/faculty/import-table-file"
})
@MultipartConfig(
    fileSizeThreshold = 1024 * 1024,
    maxFileSize = 10 * 1024 * 1024,
    maxRequestSize = 20 * 1024 * 1024
)
public class TableFileInputValidatorServlet extends BaseServlet {

    private final TableFileInputValidatorService validatorService = new TableFileInputValidatorService();
    private final FacultyDAO facultyDAO = new FacultyDAO();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);

        // Security requirement: Must be authenticated faculty member
        if (session == null || !"faculty".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized: Faculty authentication required.");
            return;
        }

        String facultyId = session.getUserId();

        // Retrieve authorized subjects for faculty
        Set<String> authorizedSubjectCodes = new HashSet<>();
        try {
            List<Subject> subjects = facultyDAO.getAssignedSubjects(facultyId);
            for (Subject s : subjects) {
                authorizedSubjectCodes.add(s.getSubjectId().toUpperCase());
                if (s.getSubjectCode() != null) {
                    authorizedSubjectCodes.add(s.getSubjectCode().toUpperCase());
                }
            }
        } catch (Exception e) {
            // Non-fatal, service will check DB directly
        }

        // Determine destination CSV table file path in protected backend folder
        String exportDir = getServletContext().getRealPath("/WEB-INF/export");
        if (exportDir == null || exportDir.trim().isEmpty()) {
            exportDir = new File("data/export").getAbsolutePath();
        }
        File outputTableFile = new File(exportDir, "marks.csv");

        // Obtain reader stream via java.io.BufferedReader from multipart upload or raw request body
        BufferedReader bufferedReader = null;
        try {
            String contentType = req.getContentType();
            if (contentType != null && contentType.toLowerCase().contains("multipart/form-data")) {
                Part filePart = req.getPart("file");
                if (filePart == null) {
                    filePart = req.getPart("tableFile");
                }
                if (filePart != null && filePart.getSize() > 0) {
                    bufferedReader = new BufferedReader(new InputStreamReader(filePart.getInputStream(), StandardCharsets.UTF_8));
                }
            }

            if (bufferedReader == null) {
                // Check for text parameter or raw body reader
                String textData = req.getParameter("content");
                if (textData == null) {
                    textData = req.getParameter("csvData");
                }
                if (textData != null && !textData.trim().isEmpty()) {
                    bufferedReader = new BufferedReader(new StringReader(textData));
                } else {
                    // Direct request body stream
                    bufferedReader = req.getReader();
                }
            }

            if (bufferedReader == null) {
                sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Missing input file or CSV content.");
                return;
            }

            // Execute line-by-line domain integrity validation via BufferedReader
            Connection conn = null;
            try {
                conn = DBConnection.getConnection();
            } catch (Exception ignored) {}

            TableFileInputValidatorService.IngestionReport report =
                validatorService.processAndValidateStream(bufferedReader, outputTableFile, facultyId, authorizedSubjectCodes, conn);

            // Construct JSON response
            StringBuilder json = new StringBuilder();
            json.append("{")
                .append("\"success\":").append(report.isSuccess()).append(",")
                .append("\"totalLines\":").append(report.getTotalLinesRead()).append(",")
                .append("\"validCount\":").append(report.getValidCount()).append(",")
                .append("\"rejectedCount\":").append(report.getRejectedCount()).append(",")
                .append("\"outputTableFile\":\"").append(escapeJson(report.getOutputFilePath())).append("\",")
                .append("\"databaseSynchronized\":").append(report.isDatabaseSynchronized()).append(",")
                .append("\"message\":\"").append(escapeJson(report.getMessage())).append("\",")
                .append("\"errors\":[");

            List<TableFileInputValidatorService.RecordError> errs = report.getErrors();
            for (int i = 0; i < errs.size(); i++) {
                TableFileInputValidatorService.RecordError err = errs.get(i);
                if (i > 0) json.append(",");
                json.append("{")
                    .append("\"lineNumber\":").append(err.getLineNumber()).append(",")
                    .append("\"studentId\":\"").append(escapeJson(err.getStudentId())).append("\",")
                    .append("\"subjectId\":\"").append(escapeJson(err.getSubjectId())).append("\",")
                    .append("\"reason\":\"").append(escapeJson(err.getReason())).append("\",")
                    .append("\"rawLine\":\"").append(escapeJson(err.getRawLine())).append("\"")
                    .append("}");
            }
            json.append("],");

            json.append("\"validRecords\":[");
            List<TableFileInputValidatorService.ValidatedMark> validList = report.getValidRecords();
            int maxEcho = Math.min(validList.size(), 50); // limit preview payload
            for (int i = 0; i < maxEcho; i++) {
                TableFileInputValidatorService.ValidatedMark vm = validList.get(i);
                if (i > 0) json.append(",");
                json.append("{")
                    .append("\"lineNumber\":").append(vm.lineNumber).append(",")
                    .append("\"studentId\":\"").append(escapeJson(vm.studentId)).append("\",")
                    .append("\"studentName\":\"").append(escapeJson(vm.studentName != null ? vm.studentName : "")).append("\",")
                    .append("\"subjectId\":\"").append(escapeJson(vm.subjectId)).append("\",")
                    .append("\"internalMarks\":").append(vm.internalMarks != null ? vm.internalMarks : "null").append(",")
                    .append("\"externalMarks\":").append(vm.externalMarks != null ? vm.externalMarks : "null").append(",")
                    .append("\"totalMarks\":").append(vm.totalMarks != null ? vm.totalMarks : "null").append(",")
                    .append("\"evalStatus\":\"").append(escapeJson(vm.evalStatus != null ? vm.evalStatus : "")).append("\"")
                    .append("}");
            }
            json.append("]}");

            sendJsonResponse(resp, report.isSuccess() ? HttpServletResponse.SC_OK : HttpServletResponse.SC_BAD_REQUEST, json.toString());

        } catch (Exception ex) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Error validating table file: " + ex.getMessage());
        } finally {
            if (bufferedReader != null) {
                try { bufferedReader.close(); } catch (IOException ignored) {}
            }
        }
    }

    private String escapeJson(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\b", "\\b")
                .replace("\f", "\\f")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}

