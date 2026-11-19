-- ==============================================================================
-- Academic Result Input Validator - Domain Constraint & Integrity Test Suite
-- Purpose: Rigorous verification of database integrity rules (MySQL 8.0+)
-- ==============================================================================

USE academic_result_db;

-- ------------------------------------------------------------------------------
-- Setup: Clean Test Fixtures
-- ------------------------------------------------------------------------------
DELETE FROM subject_marks WHERE student_id LIKE 'TEST_%';
DELETE FROM users WHERE username LIKE 'test_%';
DELETE FROM students WHERE student_id LIKE 'TEST_%';
DELETE FROM subjects WHERE subject_id LIKE 'TEST_%';

-- Seed Valid Test Subject & Student
INSERT INTO subjects (subject_id, subject_name, max_marks, pass_marks)
VALUES ('TEST_CS101', 'Test Computer Systems', 100, 40);

INSERT INTO students (student_id, student_name, roll_no, email, department, semester)
VALUES ('TEST_STU01', 'Test Candidate One', 'TEST_R001', 'test1@academic.internal', 'Computer Science', 4);

-- ==============================================================================
-- TEST CASE 1: Duplicate Student ID Rejection
-- Expected: ERROR 1062 (23000): Duplicate entry 'TEST_STU01' for key 'PRIMARY'
-- ==============================================================================
-- INSERT INTO students (student_id, student_name, roll_no)
-- VALUES ('TEST_STU01', 'Another Name', 'TEST_R999');

-- ==============================================================================
-- TEST CASE 2: Missing / Empty Student Name Rejection
-- Expected: ERROR 3819 (HY000): Check constraint 'chk_student_name_not_empty' violated
-- ==============================================================================
-- INSERT INTO students (student_id, student_name, roll_no)
-- VALUES ('TEST_STU02', '   ', 'TEST_R002');

-- ==============================================================================
-- TEST CASE 3: Marks Below 0 Rejection
-- Expected: ERROR 3819 (HY000): Check constraint 'chk_marks_domain_range' violated
-- ==============================================================================
-- INSERT INTO subject_marks (student_id, subject_id, marks)
-- VALUES ('TEST_STU01', 'TEST_CS101', -5);

-- ==============================================================================
-- TEST CASE 4: Marks Above 100 Rejection
-- Expected: ERROR 3819 (HY000): Check constraint 'chk_marks_domain_range' violated
-- ==============================================================================
-- INSERT INTO subject_marks (student_id, subject_id, marks)
-- VALUES ('TEST_STU01', 'TEST_CS101', 105);

-- ==============================================================================
-- TEST CASE 5: Boundary Values (0 and 100) Acceptance
-- Expected: Both rows must successfully insert without violation
-- ==============================================================================
INSERT INTO subjects (subject_id, subject_name, max_marks, pass_marks)
VALUES ('TEST_CS102', 'Test Algorithms', 100, 40);

-- Valid Score 0 (Actual Zero)
INSERT INTO subject_marks (student_id, subject_id, marks)
VALUES ('TEST_STU01', 'TEST_CS101', 0);

-- Valid Score 100 (Maximum Boundary)
INSERT INTO subject_marks (student_id, subject_id, marks)
VALUES ('TEST_STU01', 'TEST_CS102', 100);

-- ==============================================================================
-- TEST CASE 6: NULL Mark Preservation (NULL != 0)
-- Expected: Initialized record must hold explicit NULL, distinct from 0
-- ==============================================================================
INSERT INTO subjects (subject_id, subject_name, max_marks, pass_marks)
VALUES ('TEST_CS103', 'Test Databases', 100, 40);

-- Initialize as NULL (Unentered mark / "Not Updated")
INSERT INTO subject_marks (student_id, subject_id, marks)
VALUES ('TEST_STU01', 'TEST_CS103', NULL);

-- Verification Query: Check differentiation between 0 and NULL
SELECT 
    sub.subject_name,
    sm.marks,
    CASE 
        WHEN sm.marks IS NULL THEN 'Not Updated (Explicit NULL)'
        WHEN sm.marks = 0 THEN 'Genuine Zero Score (Numeric 0)'
        ELSE CONCAT('Entered Score: ', sm.marks)
    END AS status_interpretation
FROM subject_marks sm
JOIN subjects sub ON sm.subject_id = sub.subject_id
WHERE sm.student_id = 'TEST_STU01';

-- ==============================================================================
-- TEST CASE 7: Duplicate Student-Subject Combination Prevention
-- Expected: ERROR 1062 (23000): Duplicate entry for key 'uq_student_subject'
-- ==============================================================================
-- INSERT INTO subject_marks (student_id, subject_id, marks)
-- VALUES ('TEST_STU01', 'TEST_CS101', 85);

-- ==============================================================================
-- TEST CASE 8: Invalid Foreign Key Reference Rejection
-- Expected: ERROR 1452 (23000): Cannot add or update a child row: foreign key constraint fails
-- ==============================================================================
-- INSERT INTO subject_marks (student_id, subject_id, marks)
-- VALUES ('NON_EXISTENT_STUDENT', 'TEST_CS101', 50);

-- ==============================================================================
-- TEST CASE 9: Safe Idempotent Initialization (Option B Workflow)
-- Expected: Existing marks remain intact; only missing subjects are populated with NULL
-- ==============================================================================
-- Adding a 4th subject
INSERT INTO subjects (subject_id, subject_name, max_marks, pass_marks)
VALUES ('TEST_CS104', 'Test Operating Systems', 100, 40);

-- Execute Stored Procedure
CALL sp_initialize_student_subjects('TEST_STU01');

-- Verify TEST_CS101 is still 0, TEST_CS102 is still 100, TEST_CS103 is still NULL, and TEST_CS104 is newly initialized as NULL
SELECT 
    sm.subject_id,
    sm.marks,
    IF(sm.marks IS NULL, 'NULL (Unentered)', CAST(sm.marks AS CHAR)) AS display_value
FROM subject_marks sm
WHERE sm.student_id = 'TEST_STU01'
ORDER BY sm.subject_id;

-- ------------------------------------------------------------------------------
-- Teardown: Clean Test Fixtures
-- ------------------------------------------------------------------------------
DELETE FROM subject_marks WHERE student_id = 'TEST_STU01';
DELETE FROM students WHERE student_id = 'TEST_STU01';
DELETE FROM subjects WHERE subject_id LIKE 'TEST_%';
