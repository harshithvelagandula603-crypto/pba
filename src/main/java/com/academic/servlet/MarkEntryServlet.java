package com.academic.servlet;

import com.academic.dao.StudentDAO;
import com.academic.dao.SubjectDAO;
import com.academic.dao.SubjectMarkDAO;
import com.academic.model.Student;
import com.academic.model.Subject;
import com.academic.model.SubjectMark;
import com.academic.service.ValidationService;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;

/**
 * Academic Result Input Validator - Mark Entry Servlet
 * Enforces internal-before-external workflow, server-side domain integrity constraints [0-40, 0-60],
 * and faculty permission verification before persisting marks into MySQL.
 */
@WebServlet(name = "MarkEntryServlet", urlPatterns = {"/api/faculty/mark"})
public class MarkEntryServlet extends BaseServlet {

    private final StudentDAO studentDAO = new StudentDAO();
    private final SubjectDAO subjectDAO = new SubjectDAO();
    private final SubjectMarkDAO markDAO = new SubjectMarkDAO();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);
        if (session == null || !"faculty".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized: Faculty session required.");
            return;
        }

        String body = readRequestBody(req);
        Map<String, String> payload = parseSimpleJson(body);

        String studentId = payload.get("studentId");
        String subjectId = payload.get("subjectId");
        String markType = payload.get("markType") != null ? payload.get("markType").toLowerCase() : "both";
        String rawInternal = payload.get("internalMarks");
        String rawExternal = payload.get("externalMarks");
        boolean forceConfirmed = "true".equalsIgnoreCase(payload.get("forceConfirmed"));

        if (studentId == null || studentId.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Validation Error: Student ID is required.");
            return;
        }
        studentId = studentId.trim();

        if (subjectId == null || subjectId.trim().isEmpty()) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Validation Error: Subject selection is required.");
            return;
        }
        subjectId = subjectId.trim();

        // 1. Enforce Faculty Authorization for this subject
        if (!session.isAssignedSubject(subjectId)) {
            sendError(resp, HttpServletResponse.SC_FORBIDDEN,
                String.format("Access Denied: You are not authorized to enter or update marks for subject '%s'. This subject is not assigned to your faculty account.", subjectId));
            return;
        }

        try {
            // 2. Validate Student Existence
            Student student = studentDAO.findById(studentId);
            if (student == null) {
                sendError(resp, HttpServletResponse.SC_NOT_FOUND,
                    String.format("Validation Error: Student '%s' does not exist in the database.", studentId));
                return;
            }

            // 3. Validate Subject Existence
            Subject subject = subjectDAO.findById(subjectId);
            if (subject == null) {
                sendError(resp, HttpServletResponse.SC_NOT_FOUND,
                    String.format("Validation Error: Subject '%s' is not a configured curricular subject.", subjectId));
                return;
            }

            // 4. Retrieve existing mark record
            List<SubjectMark> existingMarks = markDAO.findByStudentId(studentId);
            SubjectMark currentMark = null;
            for (SubjectMark sm : existingMarks) {
                if (subjectId.equalsIgnoreCase(sm.getSubjectId())) {
                    currentMark = sm;
                    break;
                }
            }

            Integer existingInternal = currentMark != null ? currentMark.getInternalMarks() : null;
            Integer existingExternal = currentMark != null ? currentMark.getExternalMarks() : null;

            Integer targetInternal = existingInternal;
            Integer targetExternal = existingExternal;

            // =======================================================================
            // Process by Mark Type
            // =======================================================================
            if ("internal".equals(markType)) {
                // Parse and validate internal marks [0-40]
                Integer parsedInternal = null;
                if (rawInternal != null && !rawInternal.trim().isEmpty() && !"null".equalsIgnoreCase(rawInternal.trim())) {
                    try {
                        parsedInternal = Integer.parseInt(rawInternal.trim());
                    } catch (NumberFormatException e) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Internal marks must be between 0 and 40.");
                        return;
                    }
                    if (!ValidationService.isValidInternalMark(parsedInternal)) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST,
                            String.format("Internal marks must be between 0 and 40. Received: %d.", parsedInternal));
                        return;
                    }
                }

                // Clearing internal marks while external marks exist
                if (parsedInternal == null && existingExternal != null && !forceConfirmed) {
                    String confJson = String.format(
                        "{\"success\":false,\"requiresConfirmation\":true,\"confirmationType\":\"clearInternalWithExternal\"," +
                        "\"error\":\"Warning: Clearing internal marks will invalidate the existing external marks (%d/60) for %s. External marks will be reset to NULL. Do you want to proceed?\"," +
                        "\"existingExternal\":%d}",
                        existingExternal, escapeJson(subject.getSubjectCode()), existingExternal
                    );
                    sendJson(resp, 409, confJson);
                    return;
                }

                targetInternal = parsedInternal;
                if (parsedInternal == null && existingExternal != null && forceConfirmed) {
                    targetExternal = null; // Clear external mark too
                    markDAO.updateBothMarks(studentId, subjectId, targetInternal, targetExternal);
                } else {
                    markDAO.updateInternalMark(studentId, subjectId, targetInternal);
                }

            } else if ("external".equals(markType)) {
                // Step 9 Internal-First Enforcement: External marks REJECTED if internal not saved
                if (existingInternal == null) {
                    sendError(resp, HttpServletResponse.SC_BAD_REQUEST,
                        String.format("Enter and save valid internal marks before entering external marks. Internal marks for %s have not been saved.", subject.getSubjectCode()));
                    return;
                }

                // Parse and validate external marks [0-60]
                Integer parsedExternal = null;
                if (rawExternal != null && !rawExternal.trim().isEmpty() && !"null".equalsIgnoreCase(rawExternal.trim())) {
                    try {
                        parsedExternal = Integer.parseInt(rawExternal.trim());
                    } catch (NumberFormatException e) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "External marks must be between 0 and 60.");
                        return;
                    }
                    if (!ValidationService.isValidExternalMark(parsedExternal)) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST,
                            String.format("External marks must be between 0 and 60. Received: %d.", parsedExternal));
                        return;
                    }
                }

                targetExternal = parsedExternal;
                markDAO.updateExternalMark(studentId, subjectId, targetExternal);

            } else {
                // Both marks update
                Integer parsedInternal = null;
                if (rawInternal != null && !rawInternal.trim().isEmpty() && !"null".equalsIgnoreCase(rawInternal.trim())) {
                    try {
                        parsedInternal = Integer.parseInt(rawInternal.trim());
                    } catch (NumberFormatException e) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Internal marks must be between 0 and 40.");
                        return;
                    }
                    if (!ValidationService.isValidInternalMark(parsedInternal)) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST,
                            String.format("Internal marks must be between 0 and 40. Received: %d.", parsedInternal));
                        return;
                    }
                }

                Integer parsedExternal = null;
                if (rawExternal != null && !rawExternal.trim().isEmpty() && !"null".equalsIgnoreCase(rawExternal.trim())) {
                    try {
                        parsedExternal = Integer.parseInt(rawExternal.trim());
                    } catch (NumberFormatException e) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "External marks must be between 0 and 60.");
                        return;
                    }
                    if (!ValidationService.isValidExternalMark(parsedExternal)) {
                        sendError(resp, HttpServletResponse.SC_BAD_REQUEST,
                            String.format("External marks must be between 0 and 60. Received: %d.", parsedExternal));
                        return;
                    }
                }

                if (parsedExternal != null && parsedInternal == null && existingInternal == null) {
                    sendError(resp, HttpServletResponse.SC_BAD_REQUEST, "Enter and save valid internal marks before entering external marks.");
                    return;
                }

                targetInternal = parsedInternal;
                targetExternal = parsedExternal;
                markDAO.updateBothMarks(studentId, subjectId, targetInternal, targetExternal);
            }

            Integer totalMarks = (targetInternal != null && targetExternal != null) ? (targetInternal + targetExternal) : null;
            String evalStatus;
            if (targetInternal != null && targetExternal != null) {
                evalStatus = "Fully Entered";
            } else if (targetInternal != null || targetExternal != null) {
                evalStatus = "Marks Pending";
            } else {
                evalStatus = "Not Updated";
            }

            String msg = "external".equals(markType) ?
                String.format("External marks saved successfully for %s (%s).", subject.getSubjectCode(), subject.getSubjectName()) :
                String.format("Internal marks saved successfully for %s (%s). You can now enter external marks.", subject.getSubjectCode(), subject.getSubjectName());

            String json = String.format(
                "{\"success\":true,\"message\":\"%s\",\"markRecord\":{\"studentId\":\"%s\",\"studentName\":\"%s\",\"subjectId\":\"%s\",\"subjectCode\":\"%s\",\"subjectName\":\"%s\",\"internalMarks\":%s,\"externalMarks\":%s,\"totalMarks\":%s,\"evalStatus\":\"%s\"}}",
                escapeJson(msg),
                escapeJson(student.getStudentId()),
                escapeJson(student.getStudentName()),
                escapeJson(subject.getSubjectId()),
                escapeJson(subject.getSubjectCode()),
                escapeJson(subject.getSubjectName()),
                targetInternal != null ? targetInternal : "null",
                targetExternal != null ? targetExternal : "null",
                totalMarks != null ? totalMarks : "null",
                evalStatus
            );
            sendJson(resp, HttpServletResponse.SC_OK, json);

        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error recording marks: " + e.getMessage());
        } catch (IllegalArgumentException e) {
            sendError(resp, HttpServletResponse.SC_BAD_REQUEST, e.getMessage());
        }
    }
}
