-- ==============================================================================
-- Academic Result Input Validator - Relational Database Schema
-- Target Engine: MySQL 8.0+ / MariaDB 10.5+
-- Domain Integrity Enforcement: Strict CHECK constraints, Foreign Keys, Unique Keys
-- ==============================================================================

-- 1. Database Creation
CREATE DATABASE IF NOT EXISTS academic_result_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE academic_result_db;

-- ==============================================================================
-- Table: students
-- Preloaded student details from institutional roster (Option B)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS students (
    student_id      VARCHAR(32)     NOT NULL,
    student_name    VARCHAR(120)    NOT NULL,
    roll_no         VARCHAR(32)     NULL,
    email           VARCHAR(120)    NULL,
    department      VARCHAR(64)     NULL,
    semester        INT             NULL,
    created_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Primary & Unique Constraints
    CONSTRAINT pk_students PRIMARY KEY (student_id),
    CONSTRAINT uq_students_roll_no UNIQUE (roll_no),

    -- Domain Integrity Constraints
    CONSTRAINT chk_student_id_not_empty CHECK (CHAR_LENGTH(TRIM(student_id)) > 0),
    CONSTRAINT chk_student_name_not_empty CHECK (CHAR_LENGTH(TRIM(student_name)) > 0)
) ENGINE=InnoDB;

-- ==============================================================================
-- Table: subjects
-- Approved curricular subject definitions for academic tracking
-- ==============================================================================
CREATE TABLE IF NOT EXISTS subjects (
    subject_id      VARCHAR(20)     NOT NULL,
    subject_code    VARCHAR(20)     NOT NULL,
    subject_name    VARCHAR(100)    NOT NULL,
    max_marks       INT             NOT NULL DEFAULT 100,
    max_internal    INT             NOT NULL DEFAULT 40,
    max_external    INT             NOT NULL DEFAULT 60,
    pass_marks      INT             NOT NULL DEFAULT 40,
    created_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Primary & Unique Constraints
    CONSTRAINT pk_subjects PRIMARY KEY (subject_id),
    CONSTRAINT uq_subjects_name UNIQUE (subject_name),

    -- Domain Integrity Constraints
    CONSTRAINT chk_subject_id_not_empty CHECK (CHAR_LENGTH(TRIM(subject_id)) > 0),
    CONSTRAINT chk_subject_code_not_empty CHECK (CHAR_LENGTH(TRIM(subject_code)) > 0),
    CONSTRAINT chk_subject_name_not_empty CHECK (CHAR_LENGTH(TRIM(subject_name)) > 0),
    CONSTRAINT chk_max_marks_positive CHECK (max_marks > 0),
    CONSTRAINT chk_pass_marks_valid CHECK (pass_marks > 0 AND pass_marks <= max_marks)
) ENGINE=InnoDB;

-- ==============================================================================
-- Table: subject_marks
-- Subject evaluations per student - Step 6: Internal/External Split
-- Core Rules:
-- 1. Each subject has a maximum of 100 marks:
--    - Internal assessment : max 40 marks (0-40 or NULL)
--    - External examination : max 60 marks (0-60 or NULL)
--    - Total Subject Marks  : Internal + External (computed only when BOTH are present)
-- 2. A mark of 0 is a valid numeric score (distinct from NULL = "Not Updated").
-- 3. NULL explicitly signifies an unentered component ("Not Updated").
-- 4. If EITHER component is NULL, the subject is "Marks Pending" and total is withheld.
-- 5. PASS/FAIL rules are NOT configured yet; exact rules will be provided separately.
-- 6. Unique composite key prevents duplicate student-subject records.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS subject_marks (
    mark_id         BIGINT          AUTO_INCREMENT,
    student_id      VARCHAR(32)     NOT NULL,
    subject_id      VARCHAR(20)     NOT NULL,
    internal_marks  INT             NULL DEFAULT NULL,  -- Internal assessment: 0-40 or NULL
    external_marks  INT             NULL DEFAULT NULL,  -- External examination: 0-60 or NULL
    updated_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    -- Primary Key
    CONSTRAINT pk_subject_marks PRIMARY KEY (mark_id),

    -- Uniqueness: Each student can have only ONE record per subject
    CONSTRAINT uq_student_subject UNIQUE (student_id, subject_id),

    -- Relational Integrity Constraints
    CONSTRAINT fk_marks_student FOREIGN KEY (student_id)
        REFERENCES students(student_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    CONSTRAINT fk_marks_subject FOREIGN KEY (subject_id)
        REFERENCES subjects(subject_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,

    -- Domain Integrity: Internal [0-40] or NULL; External [0-60] or NULL
    CONSTRAINT chk_internal_marks_range CHECK (internal_marks IS NULL OR (internal_marks >= 0 AND internal_marks <= 40)),
    CONSTRAINT chk_external_marks_range CHECK (external_marks IS NULL OR (external_marks >= 0 AND external_marks <= 60))
) ENGINE=InnoDB;

-- ==============================================================================
-- Table: users
-- Role-Based Authentication accounts (Student & Faculty)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS users (
    account_id      INT             AUTO_INCREMENT,
    username        VARCHAR(80)     NOT NULL,
    password_hash   VARCHAR(255)    NOT NULL,
    role            ENUM('STUDENT', 'FACULTY') NOT NULL,
    student_id      VARCHAR(32)     NULL,
    account_status  ENUM('ACTIVE', 'INACTIVE', 'SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_login      TIMESTAMP       NULL DEFAULT NULL,

    -- Primary Key & Unique Constraints
    CONSTRAINT pk_users PRIMARY KEY (account_id),
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_student UNIQUE (student_id),

    -- Relational Constraint for Student Accounts
    CONSTRAINT fk_users_student FOREIGN KEY (student_id)
        REFERENCES students(student_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    -- Domain Integrity Constraints
    CONSTRAINT chk_username_not_empty CHECK (CHAR_LENGTH(TRIM(username)) > 0),
    CONSTRAINT chk_pwd_hash_not_empty CHECK (CHAR_LENGTH(TRIM(password_hash)) > 0)
) ENGINE=InnoDB;

-- ==============================================================================
-- Stored Procedures: Record Initialization (Option B)
-- ==============================================================================

DELIMITER //

-- Initialize required subjects for a single student.
-- Both internal_marks and external_marks are initialized as NULL ("Not Updated").
CREATE PROCEDURE IF NOT EXISTS sp_initialize_student_subjects(IN p_student_id VARCHAR(32))
BEGIN
    INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks)
    SELECT p_student_id, s.subject_id, NULL, NULL
    FROM subjects s
    WHERE NOT EXISTS (
        SELECT 1 FROM subject_marks sm
        WHERE sm.student_id = p_student_id AND sm.subject_id = s.subject_id
    );
END //

-- Initialize required subjects for all students in the database.
-- Both components initialized as NULL ("Not Updated").
CREATE PROCEDURE IF NOT EXISTS sp_initialize_all_pending_records()
BEGIN
    INSERT INTO subject_marks (student_id, subject_id, internal_marks, external_marks)
    SELECT st.student_id, sub.subject_id, NULL, NULL
    FROM students st
    CROSS JOIN subjects sub
    WHERE NOT EXISTS (
        SELECT 1 FROM subject_marks sm
        WHERE sm.student_id = st.student_id AND sm.subject_id = sub.subject_id
    );
END //

DELIMITER ;
 
-- ==============================================================================
-- Curricular Subject Seed Data (Step 8: 10 Institutional Curricular Subjects)
-- ==============================================================================
INSERT INTO subjects (subject_id, subject_code, subject_name, max_marks, max_internal, max_external, pass_marks) VALUES
('DBMS',      'DBMS',      'Database Management Systems',                100, 40, 60, 40),
('MATHS',     'Maths',     'Mathematics',                                100, 40, 60, 40),
('OOPS',      'OOPs',      'Object-Oriented Programming',                100, 40, 60, 40),
('SE',        'SE',        'Software Engineering',                       100, 40, 60, 40),
('COA',       'COA',       'Computer Organization and Architecture',     100, 40, 60, 40),
('SE_LAB',    'SE Lab',    'Software Engineering Laboratory',            100, 40, 60, 40),
('MATHS_LAB', 'Maths Lab', 'Mathematics Laboratory',                    100, 40, 60, 40),
('OOPS_LAB',  'OOPs Lab',  'Object-Oriented Programming Laboratory',    100, 40, 60, 40),
('SD_LAB',    'SD Lab',    'Software Development Laboratory',           100, 40, 60, 40),
('DBMS_LAB',  'DBMS Lab',  'Database Management Systems Laboratory',    100, 40, 60, 40)
ON DUPLICATE KEY UPDATE 
    subject_code = VALUES(subject_code),
    subject_name = VALUES(subject_name),
    max_internal = VALUES(max_internal),
    max_external = VALUES(max_external);

-- ==============================================================================
-- Default Faculty User Account
-- Note: Faculty accounts are protected by password authentication.
-- Password 'admin123' hash (bcrypt)
-- ==============================================================================
INSERT INTO users (username, password_hash, role, account_status) VALUES
('faculty', '$2a$12$e8YvA1y7Z/2bFh0G1l90b.jV8qS7x1kYwzB.7m3F9oO5L1p2Q8uC', 'FACULTY', 'ACTIVE')
ON DUPLICATE KEY UPDATE account_status = 'ACTIVE';

-- ==============================================================================
-- Table: faculty
-- Faculty members from institutional roster (Faculty_Details_Email_Addresses.xlsx)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS faculty (
    faculty_id      VARCHAR(32)     NOT NULL,
    email           VARCHAR(120)    NOT NULL,
    password_hash   VARCHAR(255)    NULL,
    account_status  ENUM('ACTIVE', 'INACTIVE', 'SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_faculty PRIMARY KEY (faculty_id),
    CONSTRAINT uq_faculty_email UNIQUE (email),
    CONSTRAINT chk_faculty_id_not_empty CHECK (CHAR_LENGTH(TRIM(faculty_id)) > 0)
) ENGINE=InnoDB;

-- ==============================================================================
-- Table: faculty_subjects
-- Faculty-to-Subject assignments (Many-to-Many / One-to-Many relational mapping)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS faculty_subjects (
    assignment_id   INT             AUTO_INCREMENT,
    faculty_id      VARCHAR(32)     NOT NULL,
    subject_id      VARCHAR(20)     NOT NULL,
    assigned_at     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_faculty_subjects PRIMARY KEY (assignment_id),
    CONSTRAINT uq_faculty_subject UNIQUE (faculty_id, subject_id),
    CONSTRAINT fk_fs_faculty FOREIGN KEY (faculty_id)
        REFERENCES faculty(faculty_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT fk_fs_subject FOREIGN KEY (subject_id)
        REFERENCES subjects(subject_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ==============================================================================
-- Faculty Seed Data (From Faculty_Details_Email_Addresses.xlsx)
-- Pre-loaded accounts with hashed passwords; unconfigured accounts handle safely.
-- ==============================================================================
INSERT INTO faculty (faculty_id, email, password_hash, account_status) VALUES
('FAC101', 'FAC101@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC102', 'FAC102@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC103', 'FAC103@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC104', 'FAC104@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC105', 'FAC105@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC106', 'FAC106@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC107', 'FAC107@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE'),
('FAC108', 'FAC108@edu.in', 'SHA256:d8c03e8783e7a0d4c82c47a549925e0cf5ec79a0e69ddc6b90f47bc52a78129c', 'ACTIVE')
ON DUPLICATE KEY UPDATE 
    email = VALUES(email),
    account_status = VALUES(account_status);

-- ==============================================================================
-- Faculty-Subject Assignments Seed Data
-- ==============================================================================
INSERT INTO faculty_subjects (faculty_id, subject_id) VALUES
('FAC101', 'DBMS'),
('FAC101', 'SE_LAB'),
('FAC102', 'MATHS'),
('FAC102', 'MATHS_LAB'),
('FAC103', 'OOPS'),
('FAC104', 'COA'),
('FAC105', 'SE'),
('FAC106', 'SD_LAB'),
('FAC107', 'OOPS_LAB'),
('FAC108', 'DBMS_LAB')
ON DUPLICATE KEY UPDATE 
    faculty_id = VALUES(faculty_id),
    subject_id = VALUES(subject_id);

-- ==============================================================================
-- Institutional Students Seed Data (From students.xlsx)
-- ==============================================================================
INSERT INTO students (student_id, student_name, roll_no) VALUES
('25QM1A66D6', 'Shiva Charan Goud', '25QM1A66D6'),
('25QM1A66D7', 'Koushik Reddy', '25QM1A66D7'),
('25QM1A66D8', 'Siddharth', '25QM1A66D8'),
('25QM1A66D9', 'Rahul', '25QM1A66D9'),
('25QM1A66E0', 'Mahendar', '25QM1A66E0'),
('25QM1A66E1', 'Sri Charthi', '25QM1A66E1'),
('25QM1A66E2', 'Aarthi', '25QM1A66E2'),
('25QM1A66E3', 'Madhupriya', '25QM1A66E3'),
('25QM1A66E4', 'Vishwa', '25QM1A66E4'),
('25QM1A66E5', 'Venkat Ganesh', '25QM1A66E5'),
('25QM1A66E6', 'Bhuva', '25QM1A66E6'),
('25QM1A66E7', 'Tanuja', '25QM1A66E7'),
('25QM1A66E8', 'Chanakya Vara Prasad', '25QM1A66E8'),
('25QM1A66E9', 'Ajay', '25QM1A66E9'),
('25QM1A66F0', 'Aash mitha', '25QM1A66F0'),
('25QM1A66F1', 'Sai Charan', '25QM1A66F1'),
('25QM1A66F2', 'Abhishek', '25QM1A66F2'),
('25QM1A66F3', 'Avinash', '25QM1A66F3'),
('25QM1A66F4', 'Raghu veer', '25QM1A66F4'),
('25QM1A66F5', 'Sharath', '25QM1A66F5'),
('25QM1A66F6', 'Sai Ganesh', '25QM1A66F6'),
('25QM1A66F7', 'Sarfaz', '25QM1A66F7'),
('25QM1A66F8', 'Siddu', '25QM1A66F8'),
('25QM1A66F9', 'Manasa', '25QM1A66F9'),
('25QM1A66G0', 'Hansika', '25QM1A66G0'),
('25QM1A66G1', 'Ezra', '25QM1A66G1'),
('25QM1A66G2', 'Sai Rohith', '25QM1A66G2'),
('25QM1A66G3', 'Suman Ali', '25QM1A66G3'),
('25QM1A66G4', 'Bhramanghna', '25QM1A66G4'),
('25QM1A66G5', 'Arshiya', '25QM1A66G5'),
('25QM1A66G6', 'Vinay', '25QM1A66G6'),
('25QM1A66G7', 'Veera', '25QM1A66G7'),
('25QM1A66G8', 'Yokshitha', '25QM1A66G8'),
('25QM1A66G9', 'Akhil', '25QM1A66G9')
ON DUPLICATE KEY UPDATE student_name = VALUES(student_name), roll_no = VALUES(roll_no);

-- Pre-initialize subject marks with NULL for all seeded students
CALL sp_initialize_all_pending_records();


