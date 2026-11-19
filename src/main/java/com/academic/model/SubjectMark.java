package com.academic.model;

import java.sql.Timestamp;

/**
 * Academic Result Input Validator - Subject Mark Entity (Step 6: Internal/External Split)
 *
 * Each subject has a maximum of 100 marks:
 *   - Internal assessment : max 40 marks  (stored as internalMarks, domain [0-40] or NULL)
 *   - External examination : max 60 marks  (stored as externalMarks, domain [0-60] or NULL)
 *   - Total Subject Marks  : internalMarks + externalMarks (computed ONLY when BOTH are non-null)
 *
 * NULL explicitly signifies an unentered component ("Not Updated"), never treated as zero.
 * If EITHER component is NULL, the subject is "Marks Pending" and total is withheld.
 *
 * PASS/FAIL rules are NOT configured yet. Do NOT use determinePassFail() until rules are provided.
 */
public class SubjectMark {
    private Long    markId;
    private String  studentId;
    private String  subjectId;
    private String  subjectName;        // Joined from subjects table

    // Step 6: Two separate nullable components
    private Integer internalMarks;      // NULL = Not Updated, 0-40 = valid score
    private Integer externalMarks;      // NULL = Not Updated, 0-60 = valid score

    private Timestamp updatedAt;

    public SubjectMark() {}

    public SubjectMark(String studentId, String subjectId, Integer internalMarks, Integer externalMarks) {
        this.studentId     = studentId;
        this.subjectId     = subjectId;
        this.internalMarks = internalMarks;
        this.externalMarks = externalMarks;
    }

    // ---- Getters & Setters ------------------------------------------------

    public Long getMarkId()                    { return markId; }
    public void setMarkId(Long markId)         { this.markId = markId; }

    public String getStudentId()                 { return studentId; }
    public void setStudentId(String studentId)   { this.studentId = studentId; }

    public String getSubjectId()                 { return subjectId; }
    public void setSubjectId(String subjectId)   { this.subjectId = subjectId; }

    public String getSubjectName()               { return subjectName; }
    public void setSubjectName(String n)         { this.subjectName = n; }

    public Integer getInternalMarks()            { return internalMarks; }
    public void setInternalMarks(Integer m)      { this.internalMarks = m; }

    public Integer getExternalMarks()            { return externalMarks; }
    public void setExternalMarks(Integer m)      { this.externalMarks = m; }

    public Timestamp getUpdatedAt()              { return updatedAt; }
    public void setUpdatedAt(Timestamp t)        { this.updatedAt = t; }

    // ---- Computed Properties ----------------------------------------------

    /**
     * Returns the computed total ONLY when BOTH components are present.
     * Returns null if either component is NULL ("Marks Pending").
     * Never treats NULL as 0.
     */
    public Integer getTotalMarks() {
        if (internalMarks == null || externalMarks == null) {
            return null; // Withheld - Marks Pending
        }
        return internalMarks + externalMarks;
    }

    /**
     * True only if BOTH internal and external marks have been entered.
     */
    public boolean isFullyUpdated() {
        return internalMarks != null && externalMarks != null;
    }

    /**
     * True if either component has been entered.
     */
    public boolean isPartiallyUpdated() {
        return internalMarks != null || externalMarks != null;
    }

    /**
     * Subject-level evaluation status for display.
     * "Not Updated"    = neither component entered
     * "Marks Pending"  = one component entered, the other missing
     * "Fully Entered"  = both components entered (total computable)
     */
    public String getEvaluationStatus() {
        if (!isPartiallyUpdated()) {
            return "Not Updated";
        }
        if (!isFullyUpdated()) {
            return "Marks Pending";
        }
        return "Fully Entered";
    }

    /**
     * Display helper for internal marks.
     * Returns "Not Updated" if null, else the actual score.
     */
    public String getInternalDisplay() {
        return (internalMarks == null) ? "Not Updated" : String.valueOf(internalMarks) + " / 40";
    }

    /**
     * Display helper for external marks.
     * Returns "Not Updated" if null, else the actual score.
     */
    public String getExternalDisplay() {
        return (externalMarks == null) ? "Not Updated" : String.valueOf(externalMarks) + " / 60";
    }

    /**
     * Display helper for total marks.
     * Returns "Marks Pending" if either component is missing, else total/100.
     */
    public String getTotalDisplay() {
        Integer total = getTotalMarks();
        return (total == null) ? "Marks Pending" : String.valueOf(total) + " / 100";
    }

    // ---- Legacy Compatibility (single 'marks' field) ----------------------
    // NOTE: The legacy getMarks()/setMarks() are preserved for backward
    // compatibility with any existing DAO or servlet that has not yet been
    // migrated to the split-marks model. Do NOT call these in new code.

    /**
     * @deprecated Use getInternalMarks() and getExternalMarks() instead.
     *             Returns getTotalMarks() for backward compatibility.
     */
    @Deprecated
    public Integer getMarks() {
        return getTotalMarks();
    }

    /**
     * @deprecated Use setInternalMarks() and setExternalMarks() instead.
     */
    @Deprecated
    public void setMarks(Integer marks) {
        // No-op: legacy setter; data is now split into internal + external
    }

    /**
     * @deprecated Use isFullyUpdated() instead.
     */
    @Deprecated
    public boolean isUpdated() {
        return isFullyUpdated();
    }

    /**
     * @deprecated Use getEvaluationStatus() instead.
     */
    @Deprecated
    public String getDisplayStatus() {
        return getEvaluationStatus();
    }
}
