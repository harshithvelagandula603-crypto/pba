package com.academic.servlet;

import com.academic.service.StudentImportService;

import javax.servlet.ServletContext;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.File;
import java.io.IOException;

/**
 * Academic Result Input Validator - Student Import Servlet
 * Connects Excel and CSV student preload routines to StudentImportService,
 * utilizing java.io.BufferedReader for CSV streams.
 */
@WebServlet(name = "StudentImportServlet", urlPatterns = {
    "/api/faculty/import-actual",
    "/api/faculty/import-excel",
    "/api/faculty/import-csv"
})
public class StudentImportServlet extends BaseServlet {

    private final StudentImportService importService = new StudentImportService();

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

        if (path.endsWith("/import-actual")) {
            handleImportActual(req, resp);
        } else if (path.endsWith("/import-csv")) {
            handleImportCsv(req, resp);
        } else {
            sendError(resp, HttpServletResponse.SC_NOT_IMPLEMENTED, "Custom file multipart upload requires standard multipart configuration.");
        }
    }

    private void handleImportActual(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        ServletContext ctx = req.getServletContext();
        String resourcePath = ctx != null ? ctx.getRealPath("/WEB-INF/classes/students.xlsx") : null;
        File file = (resourcePath != null) ? new File(resourcePath) : null;

        if (file == null || !file.exists()) {
            file = new File("src/main/resources/students.xlsx");
        }

        if (!file.exists()) {
            sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Roster template students.xlsx not found on server.");
            return;
        }

        StudentImportService.ImportResult result = importService.importStudentsFromExcelFile(file);
        if (result.isSuccess()) {
            String json = String.format(
                "{\"success\":true,\"message\":\"Successfully synchronized student roster with database.\",\"totalParsed\":%d,\"importedCount\":%d}",
                result.getImportedCount(),
                result.getImportedCount()
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);
        } else {
            StringBuilder errs = new StringBuilder();
            for (String e : result.getErrors()) {
                if (errs.length() > 0) errs.append("; ");
                errs.append(e);
            }
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, errs.toString());
        }
    }

    private void handleImportCsv(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        // Leverages java.io.BufferedReader in StudentImportService to read input stream line-by-line
        StudentImportService.ImportResult result = importService.importStudentsFromCSV(req.getReader());
        if (result.isSuccess()) {
            String json = String.format(
                "{\"success\":true,\"message\":\"Successfully imported %d student records via BufferedReader stream.\",\"importedCount\":%d}",
                result.getImportedCount(),
                result.getImportedCount()
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);
        } else {
            StringBuilder errs = new StringBuilder();
            for (String e : result.getErrors()) {
                if (errs.length() > 0) errs.append("; ");
                errs.append(e);
            }
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, errs.toString());
        }
    }
}
