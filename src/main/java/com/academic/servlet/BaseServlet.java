package com.academic.servlet;

import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.HashMap;
import java.util.Map;

/**
 * Academic Result Input Validator - Base Servlet
 * Common infrastructure for JSON serialization, session inspection, and CORS headers.
 */
public abstract class BaseServlet extends HttpServlet {

    protected void setCorsHeaders(HttpServletResponse resp) {
        resp.setHeader("Access-Control-Allow-Origin", "*");
        resp.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        resp.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Session-Id, Accept");
        resp.setCharacterEncoding("UTF-8");
    }

    @Override
    protected void doOptions(HttpServletRequest req, HttpServletResponse resp) {
        setCorsHeaders(resp);
        resp.setStatus(HttpServletResponse.SC_OK);
    }

    protected void sendJson(HttpServletResponse resp, int statusCode, String json) throws IOException {
        setCorsHeaders(resp);
        resp.setContentType("application/json;charset=UTF-8");
        resp.setStatus(statusCode);
        try (PrintWriter out = resp.getWriter()) {
            out.print(json);
            out.flush();
        }
    }

    protected void sendError(HttpServletResponse resp, int statusCode, String message) throws IOException {
        String safeMsg = escapeJson(message);
        sendJson(resp, statusCode, String.format("{\"success\":false,\"error\":\"%s\"}", safeMsg));
    }

    protected String readRequestBody(HttpServletRequest req) throws IOException {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = req.getReader()) {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append("\n");
            }
        }
        return sb.toString().trim();
    }

    /**
     * Resolves the current session from either the X-Session-Id request header
     * or standard Servlet HttpSession.
     */
    protected SessionManager.SessionData getAuthenticatedSession(HttpServletRequest req) {
        String token = req.getHeader("X-Session-Id");
        if (token != null && !token.trim().isEmpty()) {
            SessionManager.SessionData data = SessionManager.getSession(token);
            if (data != null) return data;
        }

        HttpSession httpSession = req.getSession(false);
        if (httpSession != null) {
            Object obj = httpSession.getAttribute("academic_session");
            if (obj instanceof SessionManager.SessionData) {
                return (SessionManager.SessionData) obj;
            }
        }
        return null;
    }

    /**
     * Minimal JSON string escaper.
     */
    protected String escapeJson(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder();
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < ' ') {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    /**
     * Parses simple top-level JSON key-values from a request string without external dependencies.
     */
    protected Map<String, String> parseSimpleJson(String json) {
        Map<String, String> map = new HashMap<>();
        if (json == null || json.trim().isEmpty()) return map;
        String clean = json.trim();
        if (clean.startsWith("{")) clean = clean.substring(1);
        if (clean.endsWith("}")) clean = clean.substring(0, clean.length() - 1);

        String[] pairs = clean.split(",(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)");
        for (String pair : pairs) {
            String[] kv = pair.split(":(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)", 2);
            if (kv.length == 2) {
                String k = kv[0].trim().replaceAll("^\"|\"$", "");
                String v = kv[1].trim();
                if (v.startsWith("\"") && v.endsWith("\"")) {
                    v = v.substring(1, v.length() - 1);
                }
                map.put(k, v);
            }
        }
        return map;
    }
}
