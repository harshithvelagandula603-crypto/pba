package com.academic.servlet;

import com.academic.service.TableFileExportService;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.File;
import java.io.IOException;

/**
 * Academic Result Input Validator - Table File Export Servlet
 *
 * Endpoint: POST /api/faculty/export-table-files
 *
 * Restricts export access to authorized faculty/admin users.
 * Fetches the latest records from MySQL, validates them using java.io.BufferedReader,
 * and writes the refreshed 5 CSV table files to a protected backend directory.
 */
@WebServlet(name = "TableFileExportServlet", urlPatterns = {
    "/api/faculty/export-table-files",
    "/api/faculty/export-academic-records",
    "/api/faculty/export-records"
})
public class TableFileExportServlet extends BaseServlet {

    private final TableFileExportService exportService = new TableFileExportService();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        doGet(req, resp);
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);

        // Security check: only authenticated faculty/admin role permitted
        if (session == null || !"faculty".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_FORBIDDEN, "Access Denied: Only authenticated faculty members can export academic records.");
            return;
        }

        String format = req.getParameter("format");
        String subjectId = req.getParameter("subjectId");
        if (subjectId == null) subjectId = req.getParameter("subject");

        String facultyId = session.getUserId();
        if (facultyId == null) facultyId = session.getUsername();

        // If format is requested (or endpoint is export-academic-records / export-records)
        String servletPath = req.getServletPath() != null ? req.getServletPath() : "";
        boolean isDownloadEndpoint = servletPath.contains("export-academic-records") || servletPath.contains("export-records") || (format != null && !format.trim().isEmpty());

        if (isDownloadEndpoint) {
            String fmt = (format != null && !format.trim().isEmpty()) ? format.trim().toLowerCase() : "xlsx";
            String subTag = (subjectId != null && !subjectId.trim().isEmpty() && !"ALL".equalsIgnoreCase(subjectId)) ? subjectId.trim() : "all_subjects";

            try {
                if ("csv".equalsIgnoreCase(fmt)) {
                    String csv = exportService.buildAcademicRecordsCsv(facultyId, subjectId);
                    byte[] bytes = csv.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                    resp.setContentType("text/csv; charset=UTF-8");
                    resp.setHeader("Content-Disposition", "attachment; filename=\"academic_records_" + subTag + ".csv\"");
                    resp.setContentLength(bytes.length);
                    resp.getOutputStream().write(bytes);
                    return;
                } else {
                    byte[] excelBytes = exportService.buildAcademicRecordsExcel(facultyId, subjectId);
                    resp.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
                    resp.setHeader("Content-Disposition", "attachment; filename=\"academic_records_" + subTag + ".xlsx\"");
                    resp.setContentLength(excelBytes.length);
                    resp.getOutputStream().write(excelBytes);
                    return;
                }
            } catch (Exception e) {
                sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Export generation error: " + e.getMessage());
                return;
            }
        }

        // Determine protected backend directory for table files generation
        String targetDir = getServletContext().getRealPath("/WEB-INF/export");
        if (targetDir == null || targetDir.trim().isEmpty()) {
            targetDir = new File("data/export").getAbsolutePath();
        }

        TableFileExportService.ExportResult result = exportService.exportAll(targetDir);

        if (!result.success) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, result.error != null ? result.error : "Failed to export table files.");
            return;
        }

        StringBuilder filesJson = new StringBuilder("[");
        for (int i = 0; i < result.generatedFiles.size(); i++) {
            if (i > 0) filesJson.append(",");
            filesJson.append("\"").append(escapeJson(result.generatedFiles.get(i))).append("\"");
        }
        filesJson.append("]");

        StringBuilder countsJson = new StringBuilder("{");
        int idx = 0;
        for (var entry : result.recordCounts.entrySet()) {
            if (idx > 0) countsJson.append(",");
            countsJson.append("\"").append(escapeJson(entry.getKey())).append("\":").append(entry.getValue());
            idx++;
        }
        countsJson.append("}");

        String json = String.format(
            "{\"success\":true,\"message\":\"%s\",\"directory\":\"%s\",\"files\":%s,\"recordCounts\":%s}",
            escapeJson(result.message),
            escapeJson(result.targetDirectory),
            filesJson.toString(),
            countsJson.toString()
        );

        sendJson(resp, HttpServletResponse.SC_OK, json);
    }
}

