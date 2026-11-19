package com.academic.service;

import java.util.List;

/**
 * Academic Result Input Validator - Domain Integrity Service
 * Preserves the core problem statement: Enforces domain integrity constraints
 * before any academic record is permitted to enter persistent storage.
 */
public class ValidationService {

    public static final int MIN_MARK          = 0;
    public static final int MAX_MARK          = 100;   // Legacy total boundary
    public static final int MAX_INTERNAL_MARK = 40;    // Step 6: Internal assessment maximum
    public static final int MAX_EXTERNAL_MARK = 60;    // Step 6: External examination maximum
    public static final int DEFAULT_PASS_MARK = 40;    // Placeholder – exact rules not yet configured

    /**
     * Enforces the primary domain integrity constraint on mark entries.
     * Rule:
     * - A mark of NULL is valid (signifying an unentered/pending mark).
     * - A numeric mark must satisfy: 0 <= mark <= 100.
     * - Values < 0 or > 100 are strictly invalid.
     *
     * @param mark the integer mark, or null for unentered
     * @return true if valid according to domain constraints, false otherwise
     */
    public static boolean isValidMark(Integer mark) {
        if (mark == null) {
            return true; // Explicit NULL permitted for pending subjects
        }
        return mark >= MIN_MARK && mark <= MAX_MARK;
    }
    /**
     * Validates an internal mark (assessment component).
     * Rule: NULL is valid (pending); numeric must satisfy 0 <= mark <= 40.
     *
     * @param mark the integer internal mark, or null for unentered
     * @return true if valid, false otherwise
     */
    public static boolean isValidInternalMark(Integer mark) {
        if (mark == null) return true;
        return mark >= MIN_MARK && mark <= MAX_INTERNAL_MARK;
    }

    /**
     * Validates an external mark (examination component).
     * Rule: NULL is valid (pending); numeric must satisfy 0 <= mark <= 60.
     *
     * @param mark the integer external mark, or null for unentered
     * @return true if valid, false otherwise
     */
    public static boolean isValidExternalMark(Integer mark) {
        if (mark == null) return true;
        return mark >= MIN_MARK && mark <= MAX_EXTERNAL_MARK;
    }

    /**
     * Parses and validates an internal mark string.
     * Empty/blank/"null" → returns null (unentered).
     *
     * @param rawMark input string from web forms
     * @return Integer (0-40) or null
     * @throws IllegalArgumentException if outside [0-40]
     */
    public static Integer parseAndValidateInternalMark(String rawMark) {
        if (rawMark == null || rawMark.trim().isEmpty() || "null".equalsIgnoreCase(rawMark.trim())) {
            return null;
        }
        try {
            int parsed = Integer.parseInt(rawMark.trim());
            if (parsed < MIN_MARK || parsed > MAX_INTERNAL_MARK) {
                throw new IllegalArgumentException(
                    String.format("Domain Constraint Violation: Internal mark %d is outside permitted boundary [%d - %d].",
                        parsed, MIN_MARK, MAX_INTERNAL_MARK));
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(
                "Domain Constraint Violation: Internal mark must be a valid integer or empty (NULL). Found: '" + rawMark + "'");
        }
    }

    /**
     * Parses and validates an external mark string.
     * Empty/blank/"null" → returns null (unentered).
     *
     * @param rawMark input string from web forms
     * @return Integer (0-60) or null
     * @throws IllegalArgumentException if outside [0-60]
     */
    public static Integer parseAndValidateExternalMark(String rawMark) {
        if (rawMark == null || rawMark.trim().isEmpty() || "null".equalsIgnoreCase(rawMark.trim())) {
            return null;
        }
        try {
            int parsed = Integer.parseInt(rawMark.trim());
            if (parsed < MIN_MARK || parsed > MAX_EXTERNAL_MARK) {
                throw new IllegalArgumentException(
                    String.format("Domain Constraint Violation: External mark %d is outside permitted boundary [%d - %d].",
                        parsed, MIN_MARK, MAX_EXTERNAL_MARK));
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(
                "Domain Constraint Violation: External mark must be a valid integer or empty (NULL). Found: '" + rawMark + "'");
        }
    }

    /**
     * Enforces student entity domain constraints.
     */
    public static void validateStudentDetails(String studentId, String studentName, String rollNo) {
        if (studentId == null || studentId.trim().isEmpty()) {
            throw new IllegalArgumentException("Student ID cannot be null or blank.");
        }
        if (studentName == null || studentName.trim().isEmpty()) {
            throw new IllegalArgumentException("Student Name cannot be null or blank.");
        }
        if (rollNo == null || rollNo.trim().isEmpty()) {
            throw new IllegalArgumentException("Roll Number cannot be null or blank.");
        }
    }

    /**
     * Enforces the requirement that aggregate results (Total, Percentage, PASS/FAIL)
     * are computed ONLY after all required subjects have non-NULL marks.
     *
     * @param marks list of marks for all enrolled subjects
     * @return true if all marks are present, false if any mark remains NULL ("Not Updated")
     */
    public static boolean canComputeAggregateResult(List<Integer> marks, int totalRequiredSubjects) {
        if (marks == null || marks.size() < totalRequiredSubjects) {
            return false;
        }
        for (Integer mark : marks) {
            if (mark == null) {
                return false; // At least one subject remains "Not Updated"
            }
        }
        return true;
    }

    /**
     * Computes the total marks only when all subjects are evaluated.
     */
    public static Integer calculateTotalMarks(List<Integer> marks, int totalRequiredSubjects) {
        if (!canComputeAggregateResult(marks, totalRequiredSubjects)) {
            return null; // Withheld until complete
        }
        int total = 0;
        for (Integer mark : marks) {
            total += mark;
        }
        return total;
    }

    /**
     * Determines the PASS/FAIL outcome across evaluated marks.
     */
    public static String determineResultStatus(List<Integer> marks, int totalRequiredSubjects, int passMarkThreshold) {
        if (!canComputeAggregateResult(marks, totalRequiredSubjects)) {
            return "RESULT WITHHELD (INCOMPLETE)";
        }
        for (Integer mark : marks) {
            if (mark < passMarkThreshold) {
                return "FAIL";
            }
        }
        return "PASS";
    }

    /**
     * Computes the percentage marks only when all subjects are evaluated.
     */
    public static Double calculatePercentage(List<Integer> marks, int totalRequiredSubjects) {
        if (!canComputeAggregateResult(marks, totalRequiredSubjects)) {
            return null; // Withheld until complete
        }
        Integer total = calculateTotalMarks(marks, totalRequiredSubjects);
        if (total == null || totalRequiredSubjects <= 0) {
            return null;
        }
        return ((double) total / (totalRequiredSubjects * 100.0)) * 100.0;
    }
}
