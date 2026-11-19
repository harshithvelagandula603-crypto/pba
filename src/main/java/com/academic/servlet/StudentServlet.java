package com.academic.servlet;

import com.academic.dao.StudentDAO;
import com.academic.dao.SubjectMarkDAO;
import com.academic.model.Student;
import com.academic.model.SubjectMark;
import com.academic.service.ValidationService;

import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Academic Result Input Validator - Student Records Servlet
 * Securely delivers authenticated student marks and aggregate results from MySQL database.
 */
@WebServlet(name = "StudentServlet", urlPatterns = {"/api/student/*", "/api/student/records"})
public class StudentServlet extends BaseServlet {

    private final StudentDAO studentDAO = new StudentDAO();
    private final SubjectMarkDAO markDAO = new SubjectMarkDAO();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        setCorsHeaders(resp);
        SessionManager.SessionData session = getAuthenticatedSession(req);
        if (session == null || !"student".equalsIgnoreCase(session.getRole())) {
            sendError(resp, HttpServletResponse.SC_UNAUTHORIZED, "Unauthorized: Valid student session required.");
            return;
        }

        String studentId = session.getStudentId();
        try {
            Student student = studentDAO.findById(studentId);
            if (student == null) {
                sendError(resp, HttpServletResponse.SC_NOT_FOUND, "Student record not found in database.");
                return;
            }

            List<SubjectMark> marks = markDAO.findByStudentId(studentId);
            List<Integer> totalMarksList = new ArrayList<>();
            boolean allFullyEntered = !marks.isEmpty();

            StringBuilder subjectsJson = new StringBuilder("[");
            for (int i = 0; i < marks.size(); i++) {
                SubjectMark sm = marks.get(i);
                if (i > 0) subjectsJson.append(",");

                Integer internal = sm.getInternalMarks();
                Integer external = sm.getExternalMarks();
                Integer total = sm.getTotalMarks();

                if (internal == null || external == null) {
                    allFullyEntered = false;
                } else {
                    totalMarksList.add(total);
                }

                String evalStatus;
                if (internal != null && external != null) {
                    evalStatus = "Fully Entered";
                } else if (internal != null || external != null) {
                    evalStatus = "Marks Pending";
                } else {
                    evalStatus = "Not Updated";
                }

                String resultStatus = "Result Pending";
                if (internal != null && external != null && total != null) {
                    resultStatus = (total >= 35) ? "PASS" : "FAIL";
                }

                subjectsJson.append("{")
                    .append("\"subjectId\":\"").append(escapeJson(sm.getSubjectId())).append("\",")
                    .append("\"subjectCode\":\"").append(escapeJson(sm.getSubjectId())).append("\",")
                    .append("\"subjectName\":\"").append(escapeJson(sm.getSubjectName())).append("\",")
                    .append("\"maxMarks\":100,")
                    .append("\"maxInternal\":40,")
                    .append("\"maxExternal\":60,")
                    .append("\"internalMarks\":").append(internal != null ? internal : "null").append(",")
                    .append("\"externalMarks\":").append(external != null ? external : "null").append(",")
                    .append("\"totalMarks\":").append(total != null ? total : "null").append(",")
                    .append("\"evalStatus\":\"").append(evalStatus).append("\",")
                    .append("\"resultStatus\":\"").append(resultStatus).append("\"")
                    .append("}");
            }
            subjectsJson.append("]");

            Integer aggregateTotal = null;
            Double aggregatePercentage = null;
            if (allFullyEntered && !marks.isEmpty()) {
                aggregateTotal = ValidationService.calculateTotalMarks(totalMarksList, marks.size());
                aggregatePercentage = ValidationService.calculatePercentage(totalMarksList, marks.size());
            }

            String json = String.format(
                "{\"success\":true,\"student\":{\"studentId\":\"%s\",\"studentName\":\"%s\",\"rollNo\":\"%s\",\"department\":%s,\"semester\":%s}," +
                "\"subjects\":%s,\"allFullyEntered\":%b,\"aggregateTotal\":%s,\"aggregatePercentage\":%s,\"passfailConfigured\":true,\"passfailRule\":\"35 marks or above out of 100 = PASS; below 35 marks = FAIL\"}",
                escapeJson(student.getStudentId()),
                escapeJson(student.getStudentName()),
                escapeJson(student.getRollNo() != null ? student.getRollNo() : student.getStudentId()),
                student.getDepartment() != null ? "\"" + escapeJson(student.getDepartment()) + "\"" : "null",
                student.getSemester() != null ? student.getSemester() : "null",
                subjectsJson.toString(),
                allFullyEntered,
                aggregateTotal != null ? aggregateTotal : "null",
                aggregatePercentage != null ? String.format("%.2f", aggregatePercentage) : "null"
            );

            sendJson(resp, HttpServletResponse.SC_OK, json);

        } catch (SQLException e) {
            sendError(resp, HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Database error retrieving student records: " + e.getMessage());
        }
    }
}
