# Academic Result Input Validator

Enterprise academic result validation and management application featuring role-based access (Faculty / Student), strict domain integrity enforcement (`0–40` Internal Assessment, `0–60` External Examination, `0–100` Total), atomic Excel marks evaluation and import, and transactional SQL/JSON persistence.

---

## 1. Project Directory Structure

The project strictly follows the standard **Apache Maven Web Application** (`war`) specification, maintaining full compatibility with Apache Tomcat and standalone local execution.

```
Academic Result/
├── pom.xml                                    # Maven Project Configuration (Servlet 3.1, MySQL 8.2, POI 5.2.5)
├── server.ps1                                 # Standalone PowerShell Web & REST API Server (Port 8080)
├── index.html                                 # Root entry redirect to webapp portal
├── MARKS.xlsx                                 # Sample DBMS marks workbook for Excel import testing
├── Faculty_Details_Email_Addresses.xlsx       # Institutional faculty directory & account mapping
│
├── data/                                      # Standalone Server Persistence
│   └── academic_db.json                       # JSON relational database (Students, Subjects, Marks, Users)
│
├── src/main/
│   ├── java/com/academic/                     # Backend Java Source Code
│   │   ├── config/                            # Database connection manager (JDBC)
│   │   │   └── DBConnection.java
│   │   ├── dao/                               # Data Access Objects (SQL queries with DISTINCT guards)
│   │   │   ├── FacultyDAO.java
│   │   │   ├── StudentDAO.java
│   │   │   ├── SubjectDAO.java
│   │   │   └── SubjectMarkDAO.java
│   │   ├── model/                             # Domain entities & data models
│   │   │   ├── Faculty.java
│   │   │   ├── FacultySubject.java
│   │   │   ├── Student.java
│   │   │   ├── Subject.java
│   │   │   ├── SubjectMark.java
│   │   │   └── User.java
│   │   ├── service/                           # Business logic, stream parsing & domain validation
│   │   │   ├── MarksImportService.java
│   │   │   ├── StudentImportService.java
│   │   │   └── ValidationService.java
│   │   └── servlet/                           # HTTP Controllers & REST API Servlets
│   │       ├── AuthServlet.java               # /api/auth/*
│   │       ├── BaseServlet.java               # Base JSON controller & CORS
│   │       ├── FacultyServlet.java            # /api/faculty/*
│   │       ├── MarkEntryServlet.java          # /api/faculty/mark
│   │       ├── MarksImportServlet.java        # /api/faculty/marks-*
│   │       ├── SessionManager.java            # Session tracking & subject-level authorization
│   │       ├── StudentImportServlet.java      # /api/faculty/import-*
│   │       └── StudentServlet.java            # /api/student/*
│   │
│   ├── resources/                             # Backend Classpath Resources & Schemas
│   │   ├── db.properties                      # MySQL JDBC configuration (Credentials, pool settings)
│   │   ├── schema.sql                         # MySQL DDL (Tables, CHECK constraints, procedures, seeds)
│   │   ├── test_constraints.sql               # Domain constraint verification queries
│   │   ├── students.xlsx                      # Seed institutional student roster
│   │   ├── sample_student_roster.csv          # Sample CSV roster import format
│   │   └── Faculty_Details_Email_Addresses.xlsx
│   │
│   └── webapp/                                # Frontend Web Application (HTML, CSS, JS)
│       ├── index.html                         # Public landing portal & role navigation
│       ├── login.html                         # Unified role-based authentication portal
│       ├── faculty-dashboard.html             # Faculty metrics, assigned subjects, roster, Excel import
│       ├── enter-marks.html                   # Dedicated grading terminal for individual & batch marks
│       ├── student-dashboard.html             # Student result portal with aggregate gating
│       ├── css/
│       │   └── styles.css                     # Responsive design system & component styles
│       ├── js/
│       │   ├── auth.js                        # Session management & client-side authentication
│       │   ├── main.js                        # Shared UI helpers
│       │   ├── faculty-dashboard.js           # Faculty dashboard & Excel import controller
│       │   ├── enter-marks.js                 # Mark entry controller & domain validation
│       │   └── student-dashboard.js           # Student marks view controller
│       └── WEB-INF/
│           └── web.xml                        # Servlet 3.1 deployment descriptor
│
├── tests/                                     # Automated Integration Test Suites
│   ├── test_actual_marks_file.ps1             # Verification of real MARKS.xlsx workbook import
│   ├── test_faculty_flow.ps1                  # Faculty assignment and permissions suite
│   ├── test_faculty_visibility.ps1            # Faculty subject isolation & authorization suite
│   ├── test_marks_import.ps1                  # Excel marks template, preview, and commit suite
│   ├── test_step7.ps1                         # Dashboard metrics & student directory tests
│   ├── test_step8.ps1                         # Grade terminal & individual marks update tests
│   ├── test_step9_10.ps1                      # Domain constraints & automatic total tests
│   └── test_system.ps1                        # Full end-to-end system test suite
│
└── scratch/                                   # Local development verification scripts
    └── test_all_fixes.ps1                     # 43-assertion verification suite for FIX 1, 2, and 3
```

---

## 2. Core Domain Integrity Rules

1. **Internal Assessment:** Valid range is `[0, 40]` (or `NULL` for unentered / "Not Updated").
2. **External Examination:** Valid range is `[0, 60]` (or `NULL` for unentered / "Not Updated").
3. **Internal-First Workflow:** External marks cannot be entered or imported until valid internal marks are recorded.
4. **Total Calculation:** Total marks (`Internal + External`) are computed dynamically **only when both components are present**; total is strictly withheld while any component is pending.
5. **Excel Import Pre-Scan:** Every data row in an uploaded marks workbook is scanned before database writes. If any row contains a mismatched or blank subject code, the **entire file is rejected with zero marks saved**.
6. **Aggregate Result Gating:** Student totals, percentages, and standing are strictly withheld until **all 10 subjects** are fully evaluated.

---

## 3. How to Run the Application

### Option A: Standalone PowerShell Server (Zero Dependencies)
Run the built-in HTTP and REST server directly from PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File server.ps1 -Port 8080
```
Open your browser at: **[http://localhost:8080/](http://localhost:8080/)**

### Option B: Apache Maven / Tomcat (Java EE Deployment)
Build the WAR archive using Maven:
```bash
mvn clean package
```
Deploy the generated `target/academic-result-validator.war` to your Apache Tomcat `webapps/` folder.

---

## 4. Test Credentials
- **Faculty Administrator:** `faculty` / `admin123`
- **Assigned Faculty (DBMS & SE Lab):** Faculty ID `FAC101` (Email: `FAC101@edu.in`)
- **Sample Student Account:** Student ID `25QM1A66D6`

---

## 5. Running the Test Suites

To execute the comprehensive test suite verifying dashboard cards, entered-count calculation, and mixed-subject Excel validation:
```powershell
powershell -ExecutionPolicy Bypass -File scratch/test_all_fixes.ps1
```

To run the marks import verification test:
```powershell
powershell -ExecutionPolicy Bypass -File tests/test_actual_marks_file.ps1
```

