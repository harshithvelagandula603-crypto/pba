/**
 * Academic Result Input Validator - Faculty Dashboard Controller (Step 7)
 * Implements:
 * - Session verification and faculty profile metadata population
 * - Real KPI metrics from database (Total Students, Total Subjects, Pending Students, Completed Marks)
 * - Configured Curricular Subjects overview reflecting 40 Internal + 60 External = 100 Total marks
 * - Student Directory with live search by Student ID / Name and filter tabs (All, Pending, Completed)
 * - Individual subject mark entry & update (separate Internal [0-40] and External [0-60] inputs)
 * - Explicit preservation of NULL ("Not Updated") vs genuine 0 score
 * - PASS/FAIL rules displayed as "Pass/Fail Rules Not Configured" (never assumes or invents rules)
 * - Handlers for empty databases, missing records, and Excel student roster imports
 */

document.addEventListener('DOMContentLoaded', async () => {
  function escapeHtml(text) {
    if (!text) return '';
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  // Elements: Header & Profile
  const facultyPillText        = document.getElementById('facultyPillText');
  const logoutBtn              = document.getElementById('logoutBtn');
  const facultyWelcomeMsg      = document.getElementById('facultyWelcomeMsg');
  const profileUsername        = document.getElementById('profileUsername');
  const profileRole            = document.getElementById('profileRole');
  const profileDept            = document.getElementById('profileDept');
  const profileSessionStatus   = document.getElementById('profileSessionStatus');

  // Elements: KPI Metrics
  const kpiTotalStudents       = document.getElementById('kpiTotalStudents');
  const kpiTotalSubjects       = document.getElementById('kpiTotalSubjects');
  const kpiPendingStudents     = document.getElementById('kpiPendingStudents');
  const kpiCompletedMarks      = document.getElementById('kpiCompletedMarks');
  // kpiMyAssignedSubjects is populated inside loadAssignedSubjects() after fetch

  // Elements: Configured Subjects Table
  const subjectsOverviewTableBody = document.getElementById('subjectsOverviewTableBody');

  // Elements: Student Directory & Search
  const rosterTableBody        = document.getElementById('rosterTableBody');
  const rosterSearchInput      = document.getElementById('rosterSearchInput');
  const filterAll              = document.getElementById('filterAll');
  const filterPending          = document.getElementById('filterPending');
  const filterCompleted        = document.getElementById('filterCompleted');

  // Elements: Mark Entry
  const studentSelect          = document.getElementById('studentSelect');
  const markEditingArea        = document.getElementById('markEditingArea');
  const gradingStudentName     = document.getElementById('gradingStudentName');
  const gradingStudentId       = document.getElementById('gradingStudentId');
  const facultyMarksTableBody  = document.getElementById('facultyMarksTableBody');
  const markUpdateFeedback     = document.getElementById('markUpdateFeedback');

  // Elements: Excel Marks Import
  const importSubjectSelect    = document.getElementById('importSubjectSelect');
  const btnDownloadTemplate    = document.getElementById('btnDownloadTemplate');
  const excelMarksFileInput    = document.getElementById('excelMarksFileInput');
  const btnPreviewMarks        = document.getElementById('btnPreviewMarks');
  const marksPreviewArea       = document.getElementById('marksPreviewArea');
  const previewSubjectDisplay  = document.getElementById('previewSubjectDisplay');
  const chipTotalRows          = document.getElementById('chipTotalRows');
  const chipValidRows          = document.getElementById('chipValidRows');
  const chipInvalidRows        = document.getElementById('chipInvalidRows');
  const previewTableBody       = document.getElementById('previewTableBody');
  const btnCancelPreview       = document.getElementById('btnCancelPreview');
  const btnCommitMarksImport   = document.getElementById('btnCommitMarksImport');
  const marksImportResultsArea = document.getElementById('marksImportResultsArea');
  const resProcessedCount      = document.getElementById('resProcessedCount');
  const resValidCount          = document.getElementById('resValidCount');
  const resInvalidCount        = document.getElementById('resInvalidCount');
  const resImportedCount       = document.getElementById('resImportedCount');
  const resRejectedCount       = document.getElementById('resRejectedCount');
  const rejectedDetailsBox     = document.getElementById('rejectedDetailsBox');
  const rejectedTableBody      = document.getElementById('rejectedTableBody');
  const btnCloseResults        = document.getElementById('btnCloseResults');
  const importFeedback         = document.getElementById('importFeedback');

  let currentPreviewPayload    = null; // cached base64 and subject for commit

  // State
  let cachedStudents = [];
  let cachedSubjects = [];
  let currentFilter = 'all'; // 'all', 'pending', 'completed'

  // ==========================================================================
  // 1. Session Verification & Authorization
  // ==========================================================================
  const rawSession = sessionStorage.getItem('academic_session');
  if (!rawSession) {
    window.location.replace('login.html?role=faculty');
    return;
  }

  let session;
  try {
    session = JSON.parse(rawSession);
  } catch (e) {
    sessionStorage.removeItem('academic_session');
    window.location.replace('login.html?role=faculty');
    return;
  }

  if (session.role !== 'faculty') {
    window.location.replace('login.html?role=faculty');
    return;
  }

  // Populate authenticated session details
  const displayUser = session.username || 'Authorized Faculty';
  if (facultyPillText) facultyPillText.textContent = `Faculty: ${displayUser}`;
  if (profileUsername) profileUsername.textContent = displayUser;
  if (profileRole) profileRole.textContent = 'Faculty Grade Officer';
  if (profileDept) profileDept.textContent = 'Computer Science & Engineering';
  if (profileSessionStatus) profileSessionStatus.textContent = 'Authenticated & Active';
  if (facultyWelcomeMsg) {
    facultyWelcomeMsg.textContent = `Welcome back, ${displayUser}! Oversee registered students, track internal and external mark submissions, and verify academic evaluations.`;
  }

  // Logout Handler
  if (logoutBtn) {
    logoutBtn.addEventListener('click', async () => {
      try {
        await fetch('/api/auth/logout', {
          method: 'POST',
          headers: { 'X-Session-Id': session.sessionId }
        });
      } catch (ignored) {}
      sessionStorage.removeItem('academic_session');
      window.location.replace('login.html?role=faculty');
    });
  }

  // ==========================================================================
  // 2. Load Real Dashboard Metrics & Configured Subjects
  // ==========================================================================
  async function loadDashboardStats() {
    try {
      const response = await fetch('/api/faculty/dashboard-stats', {
        headers: {
          'Accept': 'application/json',
          'X-Session-Id': session.sessionId
        }
      });

      if (!response.ok) {
        if (response.status === 401 || response.status === 403) {
          sessionStorage.removeItem('academic_session');
          window.location.replace('login.html?role=faculty');
          return;
        }
        throw new Error(`Failed to load metrics. HTTP ${response.status}`);
      }

      const data = await response.json();
      if (!data.success) throw new Error(data.error || 'Server error loading stats');

      // Update KPI Cards with real database counts
      const m = data.metrics || {};
      if (kpiTotalStudents)   kpiTotalStudents.textContent   = m.totalStudents !== undefined ? m.totalStudents : 0;
      if (kpiTotalSubjects)   kpiTotalSubjects.textContent   = m.totalSubjects !== undefined ? m.totalSubjects : 0;
      if (kpiPendingStudents) kpiPendingStudents.textContent = m.studentsPending !== undefined ? m.studentsPending : 0;
      if (kpiCompletedMarks)  kpiCompletedMarks.textContent  = m.completedMarkRecords !== undefined ? m.completedMarkRecords : 0;

      // Update Subjects Overview Table (Defensively filter to assigned subjects)
      let overview = data.subjectsOverview || [];
      if (session && session.assignedSubjects && session.assignedSubjects.length > 0 && session.username !== 'faculty') {
        const assignedUpper = session.assignedSubjects.map(s => (s || '').toUpperCase());
        overview = overview.filter(s => assignedUpper.includes((s.subjectId || '').toUpperCase()));
      }
      cachedSubjects = overview;
      renderSubjectsOverview(cachedSubjects, m.totalStudents || 0);

    } catch (err) {
      if (kpiTotalStudents) kpiTotalStudents.textContent = '0';
      if (kpiTotalSubjects) kpiTotalSubjects.textContent = '0';
      if (kpiPendingStudents) kpiPendingStudents.textContent = '0';
      if (kpiCompletedMarks) kpiCompletedMarks.textContent = '0';

      if (subjectsOverviewTableBody) {
        subjectsOverviewTableBody.innerHTML = `
          <tr>
            <td colspan="8" style="text-align: center; color: var(--color-error); padding: 20px;">
              Unable to load subject configurations from database. ${err.message}
            </td>
          </tr>
        `;
      }
    }
  }

  function renderSubjectsOverview(subjects, totalStudents) {
    if (!subjectsOverviewTableBody) return;
    subjectsOverviewTableBody.innerHTML = '';

    if (subjects.length === 0) {
      subjectsOverviewTableBody.innerHTML = `
        <tr>
          <td colspan="8" style="text-align: center; color: var(--color-text-secondary); padding: 24px;">
            No curricular subjects configured in database.
          </td>
        </tr>
      `;
      return;
    }

    subjects.forEach(sub => {
      const tr = document.createElement('tr');

      // Code (Abbreviation)
      const codeTd = document.createElement('td');
      codeTd.style.fontWeight = '600';
      codeTd.textContent = sub.subjectCode || sub.subjectId;

      // Name
      const nameTd = document.createElement('td');
      nameTd.textContent = sub.subjectName;

      // Internal Weight
      const intTd = document.createElement('td');
      intTd.innerHTML = `<strong>40</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">(Internal)</span>`;

      // External Weight
      const extTd = document.createElement('td');
      extTd.innerHTML = `<strong>60</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">(External)</span>`;

      // Total Marks
      const totTd = document.createElement('td');
      totTd.innerHTML = `<strong>100</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">(Total)</span>`;

      // Mark Entry Progress
      const progTd = document.createElement('td');
      const rate = sub.completionRate !== undefined ? sub.completionRate : 0;
      progTd.innerHTML = `
        <div style="font-weight: 600; font-size: 0.8125rem;">
          ${sub.completedCount} / ${sub.totalAssigned} Students (${rate}%)
        </div>
        <div class="progress-track" aria-label="Progress: ${rate}%">
          <div class="progress-fill" style="width: ${rate}%;"></div>
        </div>
      `;

      // Unentered Status
      const statusTd = document.createElement('td');
      if (sub.pendingCount === 0 && sub.totalAssigned > 0) {
        statusTd.innerHTML = `<span class="badge badge-complete">All Evaluated</span>`;
      } else if (sub.totalAssigned === 0) {
        statusTd.innerHTML = `<span class="badge badge-not-updated">No Students</span>`;
      } else {
        statusTd.innerHTML = `<span class="badge badge-withheld">${sub.pendingCount} Pending</span>`;
      }

      // Action
      const actionTd = document.createElement('td');
      const enterBtn = document.createElement('button');
      enterBtn.className = 'btn btn-secondary';
      enterBtn.style.padding = '5px 12px';
      enterBtn.style.fontSize = '0.78125rem';
      enterBtn.textContent = 'Enter Marks';
      enterBtn.addEventListener('click', () => {
        // Jump to marks entry and select first pending student if available
        const markSection = document.getElementById('section-marks-entry');
        if (markSection) markSection.scrollIntoView({ behavior: 'smooth' });

        if (studentSelect && cachedStudents.length > 0) {
          // Find first student who has not completed this subject
          const studentNeedingMark = cachedStudents.find(s => {
            const m = (s.subjects || []).find(sb => sb.subjectId === sub.subjectId);
            return !m || m.evalStatus !== 'Fully Entered';
          });
          const targetId = studentNeedingMark ? studentNeedingMark.studentId : cachedStudents[0].studentId;
          studentSelect.value = targetId;
          loadStudentForGrading(targetId);
        }
      });
      actionTd.appendChild(enterBtn);

      tr.appendChild(codeTd);
      tr.appendChild(nameTd);
      tr.appendChild(intTd);
      tr.appendChild(extTd);
      tr.appendChild(totTd);
      tr.appendChild(progTd);
      tr.appendChild(statusTd);
      tr.appendChild(actionTd);
      subjectsOverviewTableBody.appendChild(tr);
    });
  }

  // ==========================================================================
  // 3. Load Student Roster Directory
  // ==========================================================================
  async function loadRoster() {
    try {
      const response = await fetch('/api/faculty/students', {
        headers: {
          'Accept': 'application/json',
          'X-Session-Id': session.sessionId
        }
      });

      if (!response.ok) {
        if (response.status === 401 || response.status === 403) {
          sessionStorage.removeItem('academic_session');
          window.location.replace('login.html?role=faculty');
          return;
        }
        throw new Error('Failed to retrieve student directory');
      }

      cachedStudents = await response.json();
      renderRoster(cachedStudents);
      populateStudentSelect(cachedStudents);

    } catch (err) {
      if (rosterTableBody) {
        rosterTableBody.innerHTML = `
          <tr>
            <td colspan="8" style="text-align: center; color: var(--color-error); padding: 24px;">
              Error retrieving student directory: ${err.message}
            </td>
          </tr>
        `;
      }
    }
  }

  function renderRoster(students) {
    if (!rosterTableBody) return;
    rosterTableBody.innerHTML = '';

    const filterText = (rosterSearchInput ? rosterSearchInput.value : '').toLowerCase().trim();

    // Filter by Search Query
    let filtered = students.filter(s =>
      (s.studentId && s.studentId.toLowerCase().includes(filterText)) ||
      (s.studentName && s.studentName.toLowerCase().includes(filterText))
    );

    // Filter by Tab (All, Pending, Completed)
    if (currentFilter === 'pending') {
      filtered = filtered.filter(s => s.pendingCount > 0 || !s.fullyEnteredCount || s.fullyEnteredCount < (s.subjects ? s.subjects.length : 1));
    } else if (currentFilter === 'completed') {
      filtered = filtered.filter(s => s.pendingCount === 0 && s.fullyEnteredCount === (s.subjects ? s.subjects.length : 0));
    }

    // Empty Database or Empty Search State
    if (filtered.length === 0) {
      if (students.length === 0) {
        rosterTableBody.innerHTML = `
          <tr>
            <td colspan="8">
              <div class="empty-state-box">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
                  <circle cx="9" cy="7" r="4"></circle>
                </svg>
                <div class="empty-state-title">No Students Registered in Database</div>
                <div class="empty-state-text">
                  The institutional roster is currently empty. Use the Excel Import utility below to import student records.
                </div>
              </div>
            </td>
          </tr>
        `;
      } else {
        rosterTableBody.innerHTML = `
          <tr>
            <td colspan="8">
              <div class="empty-state-box">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <circle cx="11" cy="11" r="8"></circle>
                  <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
                </svg>
                <div class="empty-state-title">No Matching Students Found</div>
                <div class="empty-state-text">
                  No records match your search criteria "${filterText || currentFilter}". Try a different Student ID, name, or reset the filter.
                </div>
              </div>
            </td>
          </tr>
        `;
      }
      return;
    }

    filtered.forEach(s => {
      const tr = document.createElement('tr');

      // Student ID
      const idTd = document.createElement('td');
      idTd.style.fontWeight = '600';
      idTd.textContent = s.studentId;

      // Student Name
      const nameTd = document.createElement('td');
      nameTd.textContent = s.studentName;

      const totalSubs = (s.subjects && s.subjects.length > 0) ? s.subjects.length : 1;
      const rawFully = s.fullyEnteredCount !== undefined ? Number(s.fullyEnteredCount) : 0;
      const fullyEntered = Math.min(Math.max(0, isNaN(rawFully) ? 0 : rawFully), totalSubs);
      const isComplete = fullyEntered === totalSubs && totalSubs > 0;

      // Evaluation Status Badge
      const statusTd = document.createElement('td');
      if (isComplete) {
        statusTd.innerHTML = `<span class="badge badge-complete">Fully Entered (${fullyEntered}/${totalSubs})</span>`;
      } else {
        const pendingCount = totalSubs - fullyEntered;
        statusTd.innerHTML = `<span class="badge badge-withheld">Marks Pending (${pendingCount} incomplete)</span>`;
      }

      // Internal Marks Summary (completed distinct valid internal components / total required)
      const intTd = document.createElement('td');
      const rawInt = s.internalEnteredCount !== undefined ? Number(s.internalEnteredCount) : 0;
      const intEntered = Math.min(Math.max(0, isNaN(rawInt) ? 0 : rawInt), totalSubs);
      intTd.innerHTML = `<strong>${intEntered}</strong> / ${totalSubs} Entered`;

      // External Marks Summary (completed distinct valid external components / total required)
      const extTd = document.createElement('td');
      const rawExt = s.externalEnteredCount !== undefined ? Number(s.externalEnteredCount) : 0;
      const extEntered = Math.min(Math.max(0, isNaN(rawExt) ? 0 : rawExt), totalSubs);
      extTd.innerHTML = `<strong>${extEntered}</strong> / ${totalSubs} Entered`;

      // Total Score (Withheld if incomplete)
      const totalTd = document.createElement('td');
      if (isComplete && s.totalMarks !== null && s.totalMarks !== undefined) {
        totalTd.innerHTML = `<strong>${s.totalMarks}</strong> / ${totalSubs * 100} <span style="color: var(--color-text-secondary); font-size: 0.75rem;">(${s.percentage}%)</span>`;
      } else {
        totalTd.innerHTML = `<span style="color: var(--color-text-secondary); font-size: 0.8125rem;">Withheld (Incomplete)</span>`;
      }

      // Academic Standing (Pass/Fail Rules Not Configured)
      const standingTd = document.createElement('td');
      if (isComplete) {
        standingTd.innerHTML = `<span class="badge badge-withheld" title="Pass/Fail rules not configured yet">Pass/Fail Rules Not Configured</span>`;
      } else {
        standingTd.innerHTML = `<span class="badge badge-withheld">Marks Pending</span>`;
      }

      // Action Button
      const actionTd = document.createElement('td');
      const editBtn = document.createElement('button');
      editBtn.className = 'btn btn-secondary';
      editBtn.style.padding = '5px 12px';
      editBtn.style.fontSize = '0.78125rem';
      editBtn.textContent = 'Enter / Edit Marks';
      editBtn.addEventListener('click', () => {
        if (studentSelect) {
          studentSelect.value = s.studentId;
          loadStudentForGrading(s.studentId);
          const markSection = document.getElementById('section-marks-entry');
          if (markSection) markSection.scrollIntoView({ behavior: 'smooth' });
        }
      });
      actionTd.appendChild(editBtn);

      tr.appendChild(idTd);
      tr.appendChild(nameTd);
      tr.appendChild(statusTd);
      tr.appendChild(intTd);
      tr.appendChild(extTd);
      tr.appendChild(totalTd);
      tr.appendChild(standingTd);
      tr.appendChild(actionTd);
      rosterTableBody.appendChild(tr);
    });
  }

  function populateStudentSelect(students) {
    if (!studentSelect) return;
    const currentVal = studentSelect.value;
    studentSelect.innerHTML = '<option value="">-- Choose a Student from Database --</option>';

    if (students.length === 0) {
      studentSelect.innerHTML = '<option value="">-- No Students Registered in Database --</option>';
      return;
    }

    students.forEach(s => {
      const opt = document.createElement('option');
      opt.value = s.studentId;
      const statusLabel = (s.fullyEnteredCount === (s.subjects ? s.subjects.length : 0)) ? '✓ Completed' : 'Pending Marks';
      opt.textContent = `${s.studentId} — ${s.studentName} [${statusLabel}]`;
      studentSelect.appendChild(opt);
    });

    if (currentVal) studentSelect.value = currentVal;
  }

  // Search & Filter Listeners
  if (rosterSearchInput) {
    rosterSearchInput.addEventListener('input', () => renderRoster(cachedStudents));
  }

  function setFilterTab(activeBtn, filterValue) {
    [filterAll, filterPending, filterCompleted].forEach(btn => {
      if (btn) {
        btn.classList.remove('active');
        btn.setAttribute('aria-selected', 'false');
      }
    });
    if (activeBtn) {
      activeBtn.classList.add('active');
      activeBtn.setAttribute('aria-selected', 'true');
    }
    currentFilter = filterValue;
    renderRoster(cachedStudents);
  }

  if (filterAll) filterAll.addEventListener('click', () => setFilterTab(filterAll, 'all'));
  if (filterPending) filterPending.addEventListener('click', () => setFilterTab(filterPending, 'pending'));
  if (filterCompleted) filterCompleted.addEventListener('click', () => setFilterTab(filterCompleted, 'completed'));

  // ==========================================================================
  // 4. Mark Entry & Evaluation Workflow (Internal: 0-40, External: 0-60)
  // ==========================================================================
  if (studentSelect) {
    studentSelect.addEventListener('change', () => {
      const selectedId = studentSelect.value;
      if (selectedId) {
        loadStudentForGrading(selectedId);
      } else {
        if (markEditingArea) markEditingArea.style.display = 'none';
      }
    });
  }

  async function loadStudentForGrading(studentId) {
    if (!markEditingArea) return;
    markEditingArea.style.display = 'block';
    if (markUpdateFeedback) markUpdateFeedback.style.display = 'none';

    const student = cachedStudents.find(s => s.studentId === studentId);
    if (student) {
      if (gradingStudentName) gradingStudentName.textContent = student.studentName;
      if (gradingStudentId) gradingStudentId.textContent = student.studentId;
    }

    try {
      const response = await fetch(`/api/faculty/student-marks?studentId=${encodeURIComponent(studentId)}`, {
        headers: {
          'Accept': 'application/json',
          'X-Session-Id': session.sessionId
        }
      });

      if (!response.ok) throw new Error('Failed to retrieve marks for student');
      const marksData = await response.json();
      renderGradingTable(studentId, marksData);

    } catch (err) {
      if (facultyMarksTableBody) {
        facultyMarksTableBody.innerHTML = `
          <tr>
            <td colspan="6" style="text-align: center; color: var(--color-error); padding: 16px;">
              Error loading subject marks: ${err.message}
            </td>
          </tr>
        `;
      }
    }
  }

  function renderGradingTable(studentId, subjects) {
    if (!facultyMarksTableBody) return;
    facultyMarksTableBody.innerHTML = '';

    subjects.forEach(sub => {
      const tr = document.createElement('tr');

      // Subject Code (Abbreviation)
      const codeTd = document.createElement('td');
      codeTd.style.fontWeight = '600';
      codeTd.textContent = sub.subjectCode || sub.subjectId;

      // Subject Name (Full Form)
      const nameTd = document.createElement('td');
      nameTd.textContent = sub.subjectName;

      // Current Component Status
      const statusTd = document.createElement('td');
      const hasInt = sub.internalMarks !== null && sub.internalMarks !== undefined &&
                     sub.internalMarks !== '' && !isNaN(Number(sub.internalMarks)) &&
                     Number(sub.internalMarks) >= 0 && Number(sub.internalMarks) <= 40;
      const hasExt = sub.externalMarks !== null && sub.externalMarks !== undefined &&
                     sub.externalMarks !== '' && !isNaN(Number(sub.externalMarks)) &&
                     Number(sub.externalMarks) >= 0 && Number(sub.externalMarks) <= 60;
      let compCount = 0;
      if (hasInt) compCount++;
      if (hasExt) compCount++;
      const totalReqComps = 2; // Internal (0-40) and External (0-60)
      const compRatioText = `${compCount} / ${totalReqComps} Entered`;

      if (!hasInt && !hasExt) {
        statusTd.innerHTML = `<span class="badge badge-not-updated">Not Updated (${compRatioText})</span>`;
      } else if (!hasInt || !hasExt) {
        const intDisplay = hasInt ? `${sub.internalMarks}/40` : '<span style="color:#856404;">Pending</span>';
        const extDisplay = hasExt ? `${sub.externalMarks}/60` : '<span style="color:#856404;">Pending</span>';
        statusTd.innerHTML = `<span class="badge badge-withheld">Marks Pending (${compRatioText} &bull; Int: ${intDisplay}, Ext: ${extDisplay})</span>`;
      } else {
        const total = Number(sub.internalMarks) + Number(sub.externalMarks);
        statusTd.innerHTML = `<strong>${total} / 100</strong> <span class="badge badge-complete" style="margin-left: 6px;">Fully Entered (${compRatioText})</span>`;
      }

      // Internal Marks Input [0 - 40]
      const intTd = document.createElement('td');
      const intInput = document.createElement('input');
      intInput.type = 'number';
      intInput.min = '0';
      intInput.max = '40';
      intInput.step = '1';
      intInput.className = 'mark-input-box';
      intInput.placeholder = hasInt ? sub.internalMarks : '0-40';
      if (hasInt) intInput.value = sub.internalMarks;
      intTd.appendChild(intInput);

      // External Marks Input [0 - 60]
      const extTd = document.createElement('td');
      const extInput = document.createElement('input');
      extInput.type = 'number';
      extInput.min = '0';
      extInput.max = '60';
      extInput.step = '1';
      extInput.className = 'mark-input-box';
      extInput.placeholder = hasExt ? sub.externalMarks : '0-60';
      if (hasExt) extInput.value = sub.externalMarks;
      extTd.appendChild(extInput);

      // Action Buttons TD
      const actionTd = document.createElement('td');
      const saveBtn = document.createElement('button');
      saveBtn.className = 'mark-action-btn';
      saveBtn.textContent = 'Save Marks';
      saveBtn.addEventListener('click', async () => {
        const rawInt = intInput.value.trim();
        const rawExt = extInput.value.trim();

        // Validate Internal Marks: 0-40 or null
        let valInt = null;
        if (rawInt !== '') {
          const num = Number(rawInt);
          if (isNaN(num) || num < 0 || num > 40) {
            showMarkFeedback('error', `Domain Constraint Violation: Internal mark for ${sub.subjectCode || sub.subjectId} must be an integer between 0 and 40.`);
            return;
          }
          valInt = num;
        }

        // Validate External Marks: 0-60 or null
        let valExt = null;
        if (rawExt !== '') {
          const num = Number(rawExt);
          if (isNaN(num) || num < 0 || num > 60) {
            showMarkFeedback('error', `Domain Constraint Violation: External mark for ${sub.subjectCode || sub.subjectId} must be an integer between 0 and 60.`);
            return;
          }
          valExt = num;
        }

        await submitMarkUpdate(studentId, sub.subjectId, valInt, valExt);
      });

      const clearBtn = document.createElement('button');
      clearBtn.className = 'mark-clear-btn';
      clearBtn.textContent = 'Reset to NULL';
      clearBtn.title = 'Resets marks to NULL (Not Updated), preserving unentered state.';
      clearBtn.addEventListener('click', async () => {
        intInput.value = '';
        extInput.value = '';
        await submitMarkUpdate(studentId, sub.subjectId, null, null);
      });

      actionTd.appendChild(saveBtn);
      actionTd.appendChild(clearBtn);

      tr.appendChild(codeTd);
      tr.appendChild(nameTd);
      tr.appendChild(statusTd);
      tr.appendChild(intTd);
      tr.appendChild(extTd);
      tr.appendChild(actionTd);
      facultyMarksTableBody.appendChild(tr);
    });
  }

  async function submitMarkUpdate(studentId, subjectId, internalVal, externalVal) {
    if (markUpdateFeedback) markUpdateFeedback.style.display = 'none';

    try {
      const response = await fetch('/api/faculty/mark', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Session-Id': session.sessionId
        },
        body: JSON.stringify({
          studentId: studentId,
          subjectId: subjectId,
          internalMarks: internalVal, // null or 0-40
          externalMarks: externalVal  // null or 0-60
        })
      });

      const data = await response.json();
      if (response.ok && data.success) {
        const intMsg = internalVal === null ? 'NULL (Not Updated)' : `${internalVal}/40`;
        const extMsg = externalVal === null ? 'NULL (Not Updated)' : `${externalVal}/60`;
        showMarkFeedback('success', `Success: Marks for ${subjectId} saved. Internal: ${intMsg}, External: ${extMsg}. Total recalculated and stored.`);

        // Seamlessly refresh grading view, KPIs, and roster
        await loadStudentForGrading(studentId);
        await loadDashboardStats();
        await loadRoster();

      } else {
        showMarkFeedback('error', `Update failed: ${data.error || 'Server validation error'}`);
      }
    } catch (err) {
      showMarkFeedback('error', `Network error while saving marks: ${err.message}`);
    }
  }

  function showMarkFeedback(type, message) {
    if (!markUpdateFeedback) return;
    markUpdateFeedback.className = `import-feedback ${type}`;
    markUpdateFeedback.textContent = message;
    markUpdateFeedback.style.display = 'block';
  }

  // ==========================================================================
  // 5. Excel Marks Importer (Template Download, Preview & Commit)
  // ==========================================================================
  let assignedSubjectsList = [];

  function populateImportSubjects(subjects) {
    assignedSubjectsList = subjects || [];
    if (!importSubjectSelect) return;
    importSubjectSelect.innerHTML = '';

    if (!subjects || subjects.length === 0) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = '-- No Subjects Assigned --';
      importSubjectSelect.appendChild(opt);
      if (btnDownloadTemplate) btnDownloadTemplate.disabled = true;
      if (btnPreviewMarks) btnPreviewMarks.disabled = true;
      return;
    }

    subjects.forEach(sub => {
      const opt = document.createElement('option');
      opt.value = sub.subjectId;
      opt.textContent = `${sub.subjectCode || sub.subjectId} - ${sub.subjectName}`;
      importSubjectSelect.appendChild(opt);
    });

    const exportSubjectSelect = document.getElementById('exportSubjectSelect');
    if (exportSubjectSelect) {
      exportSubjectSelect.innerHTML = '<option value="ALL">All Assigned Subjects</option>';
      subjects.forEach(sub => {
        const opt = document.createElement('option');
        opt.value = sub.subjectId;
        opt.textContent = `${sub.subjectCode || sub.subjectId} - ${sub.subjectName}`;
        exportSubjectSelect.appendChild(opt);
      });
    }

    if (btnDownloadTemplate) btnDownloadTemplate.disabled = false;
    if (btnPreviewMarks) btnPreviewMarks.disabled = false;
  }

  // 5.1 Download Standard Excel Template
  if (btnDownloadTemplate) {
    btnDownloadTemplate.addEventListener('click', async () => {
      const selectedSubId = importSubjectSelect ? importSubjectSelect.value : '';
      if (!selectedSubId) {
        showImportFeedback('error', 'Please select an assigned subject first.');
        return;
      }

      const originalText = btnDownloadTemplate.innerHTML;
      btnDownloadTemplate.disabled = true;
      btnDownloadTemplate.textContent = 'Generating Template...';
      hideImportFeedback();

      try {
        const response = await fetch(`/api/faculty/marks-template?subjectId=${encodeURIComponent(selectedSubId)}`, {
          method: 'GET',
          headers: {
            'X-Session-Id': session.sessionId
          }
        });

        if (!response.ok) {
          const errData = await response.json().catch(() => ({}));
          throw new Error(errData.error || `Download failed with HTTP ${response.status}`);
        }

        const blob = await response.blob();
        const downloadUrl = window.URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.style.display = 'none';
        a.href = downloadUrl;
        a.download = `Marks_Template_${selectedSubId}.xlsx`;
        document.body.appendChild(a);
        a.click();
        window.URL.revokeObjectURL(downloadUrl);
        document.body.removeChild(a);

        showImportFeedback('success', `Excel template downloaded for <strong>${selectedSubId}</strong>. Fill in Internal & External marks and upload below.`);
      } catch (err) {
        showImportFeedback('error', `Template download failed: ${err.message}`);
      } finally {
        btnDownloadTemplate.disabled = false;
        btnDownloadTemplate.innerHTML = originalText;
      }
    });
  }

  // 5.2 Preview Marks
  if (btnPreviewMarks && excelMarksFileInput) {
    btnPreviewMarks.addEventListener('click', async () => {
      const file = excelMarksFileInput.files[0];
      if (!file) {
        showImportFeedback('error', 'Please choose an Excel (.xlsx or .xls) marks file first.');
        return;
      }

      const selectedSubId = importSubjectSelect ? importSubjectSelect.value : '';
      if (!selectedSubId) {
        showImportFeedback('error', 'Please select an assigned subject.');
        return;
      }

      btnPreviewMarks.disabled = true;
      btnPreviewMarks.textContent = 'Analyzing & Validating...';
      hideImportFeedback();
      if (marksPreviewArea) marksPreviewArea.style.display = 'none';
      if (marksImportResultsArea) marksImportResultsArea.style.display = 'none';

      try {
        const reader = new FileReader();
        reader.onload = async (e) => {
          try {
            const base64Data = e.target.result.split(',')[1];
            currentPreviewPayload = {
              fileName: file.name,
              subjectId: selectedSubId,
              fileContentBase64: base64Data
            };

            const response = await fetch('/api/faculty/marks-import-preview', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'X-Session-Id': session.sessionId
              },
              body: JSON.stringify(currentPreviewPayload)
            });

            const data = await response.json();
            if (response.ok && data.success) {
              renderMarksPreview(data);
            } else if (data.subjectMismatch) {
              // Subject mismatch: render a prominent block error, block all further steps
              currentPreviewPayload = null; // clear payload so commit cannot proceed
              if (marksPreviewArea) marksPreviewArea.style.display = 'none';
              showSubjectMismatchError(data);
            } else {
              showImportFeedback('error', `Preview validation rejected: ${data.error || 'Invalid marks file structure or domain constraints violated.'}`);
            }
          } catch (postErr) {
            showImportFeedback('error', `Failed to preview marks: ${postErr.message}`);
          } finally {
            btnPreviewMarks.disabled = false;
            btnPreviewMarks.innerHTML = `
              <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <circle cx="11" cy="11" r="8"></circle>
                <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
              </svg>
              Preview Marks
            `;
          }
        };
        reader.readAsDataURL(file);
      } catch (err) {
        showImportFeedback('error', `File reading error: ${err.message}`);
        btnPreviewMarks.disabled = false;
        btnPreviewMarks.textContent = 'Preview Marks';
      }
    });
  }

  function renderMarksPreview(previewData) {
    if (!marksPreviewArea || !previewTableBody) return;

    if (previewSubjectDisplay) {
      previewSubjectDisplay.textContent = `Assigned Subject: ${previewData.subjectCode || previewData.subjectId}`;
    }
    if (chipTotalRows) chipTotalRows.textContent = `Total: ${previewData.totalRows || 0} rows`;
    if (chipValidRows) chipValidRows.textContent = `Valid: ${previewData.validRowsCount || 0}`;
    if (chipInvalidRows) chipInvalidRows.textContent = `Invalid: ${previewData.invalidRowsCount || 0}`;

    previewTableBody.innerHTML = '';
    const rows = previewData.rows || [];

    rows.forEach(r => {
      const tr = document.createElement('tr');
      const isValid = (r.status === 'VALID');
      tr.className = isValid ? 'preview-row-valid' : 'preview-row-invalid';

      const intDisplay = (r.internalMarks !== null && r.internalMarks !== undefined)
        ? `<strong>${r.internalMarks}</strong> / 40`
        : (r.rawInternal && r.rawInternal.trim() !== ''
            ? `<span style="color: #721C24; font-weight: 600;" title="Invalid value">${r.rawInternal} (Invalid)</span>`
            : `<span class="badge badge-not-updated">Empty (NULL)</span>`);

      const extDisplay = (r.externalMarks !== null && r.externalMarks !== undefined)
        ? `<strong>${r.externalMarks}</strong> / 60`
        : (r.rawExternal && r.rawExternal.trim() !== ''
            ? `<span style="color: #721C24; font-weight: 600;" title="Invalid value">${r.rawExternal} (Invalid)</span>`
            : `<span class="badge badge-not-updated">Empty (NULL)</span>`);

      const statusBadge = isValid
        ? `<span class="badge-valid-status">✓ Valid</span>`
        : `<span class="badge-invalid-status">✗ Invalid</span>`;

      const remarksDisplay = isValid
        ? `<span style="color: #155724; font-size: 0.8125rem;">Ready to import</span>`
        : `<span style="color: #721C24; font-size: 0.8125rem; font-weight: 600;">${r.errorMessage || 'Invalid record'}</span>`;

      tr.innerHTML = `
        <td style="color: #64748B; font-weight: 600; text-align: center;">${r.rowNumber}</td>
        <td style="font-weight: 700; color: #1E3A5F;">${r.studentId || 'N/A'}</td>
        <td>${r.studentName || 'Unknown Student'}</td>
        <td>${intDisplay}</td>
        <td>${extDisplay}</td>
        <td>${statusBadge}</td>
        <td>${remarksDisplay}</td>
      `;

      previewTableBody.appendChild(tr);
    });

    if (btnCommitMarksImport) {
      btnCommitMarksImport.disabled = (previewData.validRowsCount === 0);
      btnCommitMarksImport.textContent = `Import ${previewData.validRowsCount} Valid Marks`;
    }

    marksPreviewArea.style.display = 'block';
    marksPreviewArea.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  // 5.3 Commit Valid Marks to Database
  if (btnCommitMarksImport) {
    btnCommitMarksImport.addEventListener('click', async () => {
      if (!currentPreviewPayload) {
        showImportFeedback('error', 'No active preview payload found. Please preview an Excel file first.');
        return;
      }

      btnCommitMarksImport.disabled = true;
      btnCommitMarksImport.textContent = 'Importing Valid Marks...';
      hideImportFeedback();

      try {
        const response = await fetch('/api/faculty/marks-import-commit', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Session-Id': session.sessionId
          },
          body: JSON.stringify(currentPreviewPayload)
        });

        const data = await response.json();
        if (response.ok && data.success) {
          showImportFeedback('success', `Import Successful: ${data.importedCount} student mark records saved to database.`);
          displayImportResults(data);

          if (marksPreviewArea) marksPreviewArea.style.display = 'none';
          if (excelMarksFileInput) excelMarksFileInput.value = '';
          currentPreviewPayload = null;

          // Refresh dashboard metrics, roster table, and AI analysis
          await loadDashboardStats();
          await loadRoster();
          await loadAiResultAnalysis();
        } else {
          showImportFeedback('error', `Import halted: ${data.error || 'Failed to save marks.'}`);
          if (data.rejectedRows && data.rejectedRows.length > 0) {
            displayImportResults(data);
          }
        }
      } catch (err) {
        showImportFeedback('error', `Import commit failed: ${err.message}`);
      } finally {
        btnCommitMarksImport.disabled = false;
        btnCommitMarksImport.textContent = 'Import Valid Marks';
      }
    });
  }

  function displayImportResults(data) {
    if (!marksImportResultsArea) return;

    if (resProcessedCount) resProcessedCount.textContent = `Rows Processed: ${data.processedCount || data.totalRecordsRead || 0}`;
    if (resValidCount)     resValidCount.textContent     = `Valid Rows: ${data.validCount !== undefined ? data.validCount : (data.importedCount || 0)}`;
    if (resInvalidCount)   resInvalidCount.textContent   = `Invalid Rows: ${data.invalidCount !== undefined ? data.invalidCount : (data.rejectedCount || 0)}`;
    if (resImportedCount)  resImportedCount.textContent  = `Successful Imports: ${data.importedCount || data.validCount || 0}`;
    if (resRejectedCount)  resRejectedCount.textContent  = `Rejected Rows: ${data.rejectedCount || 0}`;

    const resTableStatus = document.getElementById('resTableStatus');
    const resDbStatus    = document.getElementById('resDbStatus');
    const resAiStatus    = document.getElementById('resAiStatus');
    if (resTableStatus) resTableStatus.textContent = data.tableFileWritingStatus || (data.tableFilesSynchronized ? 'SUCCESS' : 'PENDING');
    if (resDbStatus)    resDbStatus.textContent    = data.mysqlSynchronizationStatus || (data.databaseSynchronized ? 'SYNCHRONIZED' : 'PENDING');
    if (resAiStatus)    resAiStatus.textContent    = data.aiAnalysisStatus || 'AVAILABLE';

    if (rejectedDetailsBox && rejectedTableBody) {
      rejectedTableBody.innerHTML = '';
      if (data.rejectedRows && data.rejectedRows.length > 0) {
        data.rejectedRows.forEach(rej => {
          const row = document.createElement('tr');
          row.innerHTML = `
            <td style="font-weight: 700; color: #721C24;">${rej.studentId || 'N/A'}</td>
            <td style="color: #721C24; font-size: 0.8125rem;">${rej.reason || 'Validation error'}</td>
          `;
          rejectedTableBody.appendChild(row);
        });
        rejectedDetailsBox.style.display = 'block';
      } else {
        rejectedDetailsBox.style.display = 'none';
      }
    }

    marksImportResultsArea.style.display = 'block';
    marksImportResultsArea.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  if (btnCancelPreview) {
    btnCancelPreview.addEventListener('click', () => {
      if (marksPreviewArea) marksPreviewArea.style.display = 'none';
      if (excelMarksFileInput) excelMarksFileInput.value = '';
      currentPreviewPayload = null;
      hideImportFeedback();
    });
  }

  if (btnCloseResults) {
    btnCloseResults.addEventListener('click', () => {
      if (marksImportResultsArea) marksImportResultsArea.style.display = 'none';
    });
  }

  // ==========================================================================
  // 5.4 Export Academic Records (Excel .xlsx and CSV .csv)
  // ==========================================================================
  const btnExportExcel = document.getElementById('btnExportExcel');
  const btnExportCsv = document.getElementById('btnExportCsv');
  const exportSubjectSelect = document.getElementById('exportSubjectSelect');
  const exportFeedback = document.getElementById('exportFeedback');
  const btnQuickExportExcel = document.getElementById('btnQuickExportExcel');
  const btnQuickExportCsv = document.getElementById('btnQuickExportCsv');
  const btnExportTableFiles = document.getElementById('btnExportTableFiles');
  const exportTableFeedback = document.getElementById('exportTableFeedback');

  async function downloadAcademicRecords(format) {
    const targetSub = exportSubjectSelect ? exportSubjectSelect.value : 'ALL';
    const subParam = targetSub && targetSub !== 'ALL' ? `&subjectId=${encodeURIComponent(targetSub)}` : '';
    const exportUrl = `/api/faculty/export-academic-records?format=${format}${subParam}`;

    hideExportFeedback();
    const btn = format === 'xlsx' ? btnExportExcel : btnExportCsv;
    let originalHtml = '';
    if (btn) {
      btn.disabled = true;
      originalHtml = btn.innerHTML;
      btn.innerHTML = `
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="spin">
          <line x1="12" y1="2" x2="12" y2="6"></line>
          <line x1="12" y1="18" x2="12" y2="22"></line>
          <line x1="4.93" y1="4.93" x2="7.76" y2="7.76"></line>
          <line x1="16.24" y1="16.24" x2="19.07" y2="19.07"></line>
          <line x1="2" y1="12" x2="6" y2="12"></line>
          <line x1="18" y1="12" x2="22" y2="12"></line>
          <line x1="4.93" y1="19.07" x2="7.76" y2="16.24"></line>
          <line x1="16.24" y1="7.76" x2="19.07" y2="4.93"></line>
        </svg>
        Exporting ${format.toUpperCase()}...
      `;
    }

    try {
      const response = await fetch(exportUrl, {
        method: 'GET',
        headers: {
          'X-Session-Id': session.sessionId
        }
      });

      if (!response.ok) {
        let errText = `Server error HTTP ${response.status}`;
        try {
          const errData = await response.json();
          if (errData && errData.error) errText = errData.error;
        } catch (_) {}
        showExportFeedback('error', `<strong>Export Failed:</strong> ${escapeHtml(errText)}`);
        return;
      }

      const blob = await response.blob();
      const disposition = response.headers.get('Content-Disposition') || '';
      let filename = `academic_records_${targetSub || 'all'}.${format}`;
      const match = disposition.match(/filename="?([^";]+)"?/i);
      if (match && match[1]) {
        filename = match[1];
      }

      const blobUrl = window.URL.createObjectURL(blob);
      const downloadLink = document.createElement('a');
      downloadLink.href = blobUrl;
      downloadLink.download = filename;
      document.body.appendChild(downloadLink);
      downloadLink.click();
      document.body.removeChild(downloadLink);
      window.URL.revokeObjectURL(blobUrl);

      const sizeKb = (blob.size / 1024).toFixed(1);
      showExportFeedback('success', `
        <div style="font-weight: 700; font-size: 0.95rem; margin-bottom: 4px;">✓ Export Successful</div>
        <div style="font-size: 0.85rem;">Downloaded <strong>${escapeHtml(filename)}</strong> (${sizeKb} KB) containing the latest validated academic records.</div>
      `);
    } catch (err) {
      showExportFeedback('error', `<strong>Network / Request Error:</strong> ${escapeHtml(err.message)}`);
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.innerHTML = originalHtml;
      }
    }
  }

  function showExportFeedback(type, messageHtml) {
    if (!exportFeedback) return;
    exportFeedback.className = `import-feedback ${type}`;
    exportFeedback.innerHTML = messageHtml;
    exportFeedback.style.display = 'block';
  }

  function hideExportFeedback() {
    if (exportFeedback) {
      exportFeedback.className = 'import-feedback';
      exportFeedback.style.display = 'none';
      exportFeedback.innerHTML = '';
    }
  }

  if (btnExportExcel) {
    btnExportExcel.addEventListener('click', () => downloadAcademicRecords('xlsx'));
  }
  if (btnExportCsv) {
    btnExportCsv.addEventListener('click', () => downloadAcademicRecords('csv'));
  }
  if (btnQuickExportExcel) {
    btnQuickExportExcel.addEventListener('click', () => downloadAcademicRecords('xlsx'));
  }
  if (btnQuickExportCsv) {
    btnQuickExportCsv.addEventListener('click', () => downloadAcademicRecords('csv'));
  }

  // Backward compatibility: keep btnExportTableFiles if present
  if (btnExportTableFiles) {
    btnExportTableFiles.addEventListener('click', async () => {
      btnExportTableFiles.disabled = true;
      const originalHtml = btnExportTableFiles.innerHTML;
      btnExportTableFiles.innerHTML = `Exporting Table Files...`;
      hideExportTableFeedback();

      try {
        const response = await fetch('/api/faculty/export-table-files', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Session-Id': session.sessionId
          }
        });
        const data = await response.json();
        if (response.ok && data.success) {
          showExportTableFeedback('success', `✓ Table Files Export Successful: ${escapeHtml(data.message || '')}`);
        } else {
          showExportTableFeedback('error', `<strong>Export Failed:</strong> ${escapeHtml(data.error || 'Server error.')}`);
        }
      } catch (err) {
        showExportTableFeedback('error', `<strong>Error:</strong> ${escapeHtml(err.message)}`);
      } finally {
        btnExportTableFiles.disabled = false;
        btnExportTableFiles.innerHTML = originalHtml;
      }
    });
  }

  function showExportTableFeedback(type, messageHtml) {
    if (!exportTableFeedback) return;
    exportTableFeedback.className = `import-feedback ${type}`;
    exportTableFeedback.innerHTML = messageHtml;
    exportTableFeedback.style.display = 'block';
  }

  function hideExportTableFeedback() {
    if (exportTableFeedback) {
      exportTableFeedback.className = 'import-feedback';
      exportTableFeedback.style.display = 'none';
      exportTableFeedback.innerHTML = '';
    }
  }

  // ==========================================================================
  // 5.5 Validate & Ingest Table File (BufferedReader Domain Integrity Engine)
  // ==========================================================================
  const btnValidateTableFile = document.getElementById('btnValidateTableFile');
  const tableFileInput = document.getElementById('tableFileInput');
  const tableFileValidationFeedback = document.getElementById('tableFileValidationFeedback');

  if (btnValidateTableFile) {
    btnValidateTableFile.addEventListener('click', async () => {
      if (!tableFileInput || !tableFileInput.files || tableFileInput.files.length === 0) {
        showTableFileValidationFeedback('error', '<strong>Please select a CSV or text file</strong> to validate and ingest.');
        return;
      }

      const file = tableFileInput.files[0];
      const validExts = ['.csv', '.txt'];
      const fileNameLower = file.name.toLowerCase();
      if (!validExts.some(ext => fileNameLower.endsWith(ext))) {
        showTableFileValidationFeedback('error', '<strong>Invalid file format.</strong> Only <code>.csv</code> or <code>.txt</code> files can be streamed through the BufferedReader validator.');
        return;
      }

      btnValidateTableFile.disabled = true;
      const originalHtml = btnValidateTableFile.innerHTML;
      btnValidateTableFile.innerHTML = `
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="spin">
          <line x1="12" y1="2" x2="12" y2="6"></line>
          <line x1="12" y1="18" x2="12" y2="22"></line>
          <line x1="4.93" y1="4.93" x2="7.76" y2="7.76"></line>
          <line x1="16.24" y1="16.24" x2="19.07" y2="19.07"></line>
          <line x1="2" y1="12" x2="6" y2="12"></line>
          <line x1="18" y1="12" x2="22" y2="12"></line>
          <line x1="4.93" y1="19.07" x2="7.76" y2="16.24"></line>
          <line x1="16.24" y1="7.76" x2="19.07" y2="4.93"></line>
        </svg>
        Validating Records via BufferedReader...
      `;
      hideTableFileValidationFeedback();

      try {
        const fileContent = await file.text();
        const response = await fetch('/api/faculty/validate-table-file', {
          method: 'POST',
          headers: {
            'Content-Type': 'text/plain; charset=UTF-8',
            'X-Session-Id': session.sessionId
          },
          body: fileContent
        });

        const data = await response.json();
        if (response.ok && data.success) {
          let rejectionsHtml = '';
          if (data.errors && data.errors.length > 0) {
            const errItems = data.errors.slice(0, 10).map(e => `
              <li><strong>Line ${e.lineNumber}</strong> [${escapeHtml(e.studentId)}, ${escapeHtml(e.subjectId)}]: ${escapeHtml(e.reason)}</li>
            `).join('');
            const moreNote = data.errors.length > 10 ? `<li><em>...and ${data.errors.length - 10} more rejected records</em></li>` : '';
            rejectionsHtml = `
              <div style="margin-top: 10px; padding: 10px; background: #FFF3CD; color: #856404; border-radius: 4px;">
                <strong>Rejected Lines (${data.errors.length} domain violations):</strong>
                <ul style="margin: 6px 0 0; padding-left: 18px; font-size: 0.8125rem;">
                  ${errItems}
                  ${moreNote}
                </ul>
              </div>
            `;
          }

          showTableFileValidationFeedback('success', `
            <div style="font-weight: 700; font-size: 0.95rem; margin-bottom: 6px;">✓ Table File Ingestion Successful</div>
            <div style="font-size: 0.875rem; margin-bottom: 8px;">${escapeHtml(data.message)}</div>
            <div style="font-size: 0.8125rem; color: #1E3A5F; background: #EEF2F6; padding: 10px 14px; border-radius: 4px; margin-bottom: 8px;">
              <div><strong>Backend Table Files:</strong> <code>data/export/marks.csv</code> &bull; <code>data/export/results.csv</code> &bull; <strong>Status:</strong> <span style="color: #2E7D32; font-weight: 700;">${data.tableFileWritingStatus || 'SUCCESS'}</span></div>
              <div style="margin-top: 4px;"><strong>MySQL Persistence:</strong> <span style="color: #2E7D32; font-weight: 700;">${data.mysqlSynchronizationStatus || 'SYNCHRONIZED'}</span> &bull; <strong>AI Result Analysis:</strong> <span style="color: #0D6EFD; font-weight: 700;">${data.aiAnalysisStatus || 'AVAILABLE'}</span></div>
            </div>
            <div style="display: flex; gap: 14px; font-size: 0.8125rem; flex-wrap: wrap;">
              <span><strong>Records Read:</strong> ${data.totalRecordsRead || data.totalLines || 0}</span>
              <span style="color: #2E7D32;"><strong>Valid Written:</strong> ${data.validRecordsCount || data.validCount || 0}</span>
              <span style="color: #C62828;"><strong>Rejected:</strong> ${data.rejectedRecordsCount || data.rejectedCount || 0}</span>
            </div>
            <div style="margin-top: 10px; display: flex; gap: 10px; flex-wrap: wrap;">
              <a href="#section-export" class="btn btn-secondary" style="font-size: 0.8125rem; padding: 4px 12px; text-decoration: none; display: inline-flex; align-items: center; gap: 6px;">
                <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
                Export Saved Academic Records (.xlsx / .csv) &rarr;
              </a>
            </div>
            ${rejectionsHtml}
          `);

          // Clear file input
          tableFileInput.value = '';
          // Refresh current subject marks, roster, and AI analysis
          if (typeof currentSubjectId !== 'undefined' && currentSubjectId) {
            loadStudentMarksForSubject(currentSubjectId);
          }
          await loadDashboardStats();
          await loadAiResultAnalysis();
        } else {
          let errsList = '';
          if (data.errors && data.errors.length > 0) {
            errsList = '<ul style="margin: 6px 0 0; padding-left: 18px; font-size: 0.8125rem;">' +
              data.errors.slice(0, 8).map(e => `<li><strong>Line ${e.lineNumber}</strong>: ${escapeHtml(e.reason)}</li>`).join('') +
              '</ul>';
          }
          showTableFileValidationFeedback('error', `
            <strong>Validation Failed:</strong> ${escapeHtml(data.message || data.error || 'Validation errors detected.')}
            ${errsList}
          `);
        }
      } catch (err) {
        showTableFileValidationFeedback('error', `
          <strong>Request Error:</strong> ${escapeHtml(err.message)}
        `);
      } finally {
        btnValidateTableFile.disabled = false;
        btnValidateTableFile.innerHTML = originalHtml;
      }
    });
  }

  function showTableFileValidationFeedback(type, messageHtml) {
    if (!tableFileValidationFeedback) return;
    tableFileValidationFeedback.className = `import-feedback ${type}`;
    tableFileValidationFeedback.innerHTML = messageHtml;
    tableFileValidationFeedback.style.display = 'block';
  }

  function hideTableFileValidationFeedback() {
    if (tableFileValidationFeedback) {
      tableFileValidationFeedback.className = 'import-feedback';
      tableFileValidationFeedback.style.display = 'none';
      tableFileValidationFeedback.innerHTML = '';
    }
  }

  function showImportFeedback(type, messageHtml) {
    if (!importFeedback) return;
    importFeedback.className = `import-feedback ${type}`;
    importFeedback.innerHTML = messageHtml;
    importFeedback.style.display = 'block';
  }

  function hideImportFeedback() {
    if (importFeedback) {
      importFeedback.className = 'import-feedback';
      importFeedback.style.display = 'none';
      importFeedback.innerHTML = '';
    }
  }

  /**
   * Renders a prominent subject mismatch error panel.
   * Blocks the import completely — commit button stays disabled.
   * @param {Object} data - The API error response with subjectMismatch=true
   */
  function showSubjectMismatchError(data) {
    if (!importFeedback) return;

    // Disable commit button — user must not proceed
    if (btnCommitMarksImport) {
      btnCommitMarksImport.disabled = true;
      btnCommitMarksImport.textContent = 'Import Blocked';
    }

    const detected  = data.detectedSubject  || 'Unknown Subject';
    const assigned  = Array.isArray(data.assignedSubjects) && data.assignedSubjects.length > 0
                      ? data.assignedSubjects.join(', ')
                      : 'your assigned subject';

    importFeedback.className = 'import-feedback error';
    importFeedback.innerHTML = `
      <div style="display:flex; align-items:flex-start; gap:14px;">
        <div style="flex-shrink:0; width:42px; height:42px; border-radius:50%; background:#FEE2E2;
                    display:flex; align-items:center; justify-content:center;">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#DC2626"
               stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <circle cx="12" cy="12" r="10"></circle>
            <line x1="15" y1="9" x2="9" y2="15"></line>
            <line x1="9" y1="9" x2="15" y2="15"></line>
          </svg>
        </div>
        <div style="flex:1;">
          <div style="font-size:1rem; font-weight:700; color:#7F1D1D; margin-bottom:8px;">
            ⛔ Subject Mismatch — Import Blocked
          </div>
          <div style="font-size:0.9rem; color:#991B1B; line-height:1.6;">
            <div style="margin-bottom:6px;">
              <strong>File contains subject:</strong>
              <span style="background:#FEE2E2; border:1px solid #FCA5A5; border-radius:4px;
                           padding:2px 8px; font-family:monospace; margin-left:4px;">${escapeHtml(detected)}</span>
            </div>
            <div style="margin-bottom:10px;">
              <strong>Your assigned subject:</strong>
              <span style="background:#D1FAE5; border:1px solid #6EE7B7; border-radius:4px;
                           padding:2px 8px; font-family:monospace; color:#065F46; margin-left:4px;">${escapeHtml(assigned)}</span>
            </div>
            <div style="padding:10px 14px; background:#FFF7F7; border-left:4px solid #DC2626;
                        border-radius:0 4px 4px 0; font-size:0.875rem; color:#7F1D1D; line-height: 1.5;">
              <strong>${escapeHtml(data.error || `The uploaded file contains '${detected}', but your assigned subject is ${assigned}.`)}</strong><br>
              <span style="display:inline-block; margin-top:4px; color:#991B1B;">Zero marks were saved. Please upload the correct file for your assigned subject.</span>
            </div>
            <div style="margin-top:14px; display:flex; gap:10px; flex-wrap:wrap;">
              <button type="button" id="btnMismatchChooseAnother" class="btn" style="background:#DC2626; color:#ffffff; border:none; padding:8px 16px; border-radius:6px; font-weight:600; font-size:0.875rem; cursor:pointer; display:inline-flex; align-items:center; gap:6px;">
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                  <polyline points="17 8 12 3 7 8"></polyline>
                  <line x1="12" y1="3" x2="12" y2="15"></line>
                </svg>
                Upload Correct File
              </button>
              <button type="button" id="btnMismatchClear" class="btn" style="background:#F3F4F6; color:#374151; border:1px solid #D1D5DB; padding:8px 16px; border-radius:6px; font-weight:500; font-size:0.875rem; cursor:pointer;">
                Clear Selection
              </button>
            </div>
          </div>
        </div>
      </div>
    `;
    importFeedback.style.display = 'block';
    importFeedback.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

    const btnChooseAnother = document.getElementById('btnMismatchChooseAnother');
    if (btnChooseAnother) {
      btnChooseAnother.addEventListener('click', () => {
        if (excelMarksFileInput) {
          excelMarksFileInput.value = '';
          excelMarksFileInput.click();
        }
      });
    }

    const btnClear = document.getElementById('btnMismatchClear');
    if (btnClear) {
      btnClear.addEventListener('click', () => {
        if (excelMarksFileInput) {
          excelMarksFileInput.value = '';
        }
        hideImportFeedback();
      });
    }
  }

  // ==========================================================================
  // Load & Render Logged-in Faculty's Assigned Subjects
  // ==========================================================================
  const assignedSubjectsContainer = document.getElementById('assignedSubjectsContainer');
  const mySubjectsSubtitle = document.getElementById('mySubjectsSubtitle');

  async function loadAssignedSubjects() {
    if (!assignedSubjectsContainer) return;
    try {
      const response = await fetch('/api/faculty/assigned-subjects', {
        headers: {
          'Accept': 'application/json',
          'X-Session-Id': session.sessionId
        }
      });

      if (!response.ok) {
        if (response.status === 401 || response.status === 403) {
          sessionStorage.removeItem('academic_session');
          window.location.replace('login.html?role=faculty');
          return;
        }
        throw new Error(`Failed to load assigned subjects (HTTP ${response.status})`);
      }

      const data = await response.json();
      if (!data.success) throw new Error(data.error || 'Unable to fetch assigned subjects');

      const facId = data.facultyId || session.facultyId || session.username;
      if (mySubjectsSubtitle) {
        mySubjectsSubtitle.innerHTML = `Authorized Curricular Subjects for <strong>${facId}</strong>. Click <strong>Open Subject</strong> to enter and manage marks.`;
      }

      const assignedList = data.subjects || [];
      renderAssignedSubjects(assignedList, facId);
      populateImportSubjects(assignedList);

      // Populate KPI: My Assigned Subjects (faculty-specific count)
      const kpiMyAssignedSubjects = document.getElementById('kpiMyAssignedSubjects');
      if (kpiMyAssignedSubjects) kpiMyAssignedSubjects.textContent = assignedList.length;
    } catch (err) {
      if (assignedSubjectsContainer) {
        assignedSubjectsContainer.innerHTML = `
          <div style="text-align: center; color: var(--color-error); padding: 24px; grid-column: 1 / -1;">
            Failed to load assigned subjects: ${err.message}
          </div>
        `;
      }
    }
  }

  function renderAssignedSubjects(subjects, facultyId) {
    if (!assignedSubjectsContainer) return;
    assignedSubjectsContainer.innerHTML = '';

    if (!subjects || subjects.length === 0) {
      assignedSubjectsContainer.innerHTML = `
        <div class="empty-state-box" style="grid-column: 1 / -1;">
          <p class="empty-state-title">No Subjects Assigned</p>
          <p class="empty-state-text">No curricular subjects are currently assigned to Faculty ID <strong>${facultyId}</strong>.</p>
        </div>
      `;
      return;
    }

    subjects.forEach(sub => {
      const card = document.createElement('div');
      card.className = 'assigned-subject-card';
      card.id = `assignedCard_${sub.subjectId}`;

      card.innerHTML = `
        <div>
          <div class="assigned-subject-header">
            <span class="assigned-subject-code-badge">
              <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"></path>
                <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"></path>
              </svg>
              ${sub.subjectCode || sub.subjectId}
            </span>
            <span class="assigned-subject-weight-badge">Max: ${sub.maxMarks || 100} Marks</span>
          </div>
          <h3 class="assigned-subject-title">${sub.subjectName}</h3>
        </div>
        <div class="assigned-subject-footer">
          <a href="enter-marks.html?subjectId=${encodeURIComponent(sub.subjectId)}" class="btn-open-subject" id="btnOpenSubject_${sub.subjectId}">
            <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
              <polyline points="15 3 21 3 21 9"></polyline>
              <line x1="10" y1="14" x2="21" y2="3"></line>
            </svg>
            Open Subject
          </a>
        </div>
      `;

      assignedSubjectsContainer.appendChild(card);
    });
  }

  // ==========================================================================
  // 5.5 AI Result Analysis & Class Performance Insights (Step 6)
  // ==========================================================================
  const aiAnalysisContainer = document.getElementById('aiAnalysisContainer');
  const btnRefreshAiAnalysis = document.getElementById('btnRefreshAiAnalysis');

  async function loadAiResultAnalysis(subjectId) {
    if (!aiAnalysisContainer) return;
    try {
      let url = '/api/faculty/ai-analysis';
      if (subjectId) {
        url += `?subjectId=${encodeURIComponent(subjectId)}`;
      }
      const response = await fetch(url, {
        headers: { 'X-Session-Id': session.sessionId }
      });
      if (!response.ok) {
        throw new Error(`Failed to load AI Result Analysis (HTTP ${response.status})`);
      }
      const resData = await response.json();
      if (!resData.success || !resData.analysis) {
        throw new Error(resData.error || 'No analysis data returned.');
      }

      renderAiResultAnalysis(resData.analysis);
    } catch (err) {
      aiAnalysisContainer.innerHTML = `
        <div style="padding: 16px; background: #FFF3CD; color: #856404; border-radius: 6px; font-size: 0.875rem;">
          <strong>AI Analysis Note:</strong> ${escapeHtml(err.message)}
        </div>
      `;
    }
  }

  function renderAiResultAnalysis(analysis) {
    if (!aiAnalysisContainer) return;
    const overall = analysis.overall || {};
    const subjectWise = analysis.subjectWiseStats || [];
    const subjectsAttn = analysis.subjectsNeedingAttention || [];
    const studentsSupport = analysis.studentsNeedingSupport || [];
    const insights = analysis.performanceInsights || [];

    let subjectsAttnHtml = '';
    if (subjectsAttn.length > 0) {
      subjectsAttnHtml = `
        <div style="margin-bottom: 20px;">
          <h4 style="font-size: 0.9375rem; font-weight: 700; color: #721C24; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#721C24" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line></svg>
            Subjects Needing Faculty Attention (${subjectsAttn.length})
          </h4>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 10px;">
            ${subjectsAttn.map(s => `
              <div style="background: #FFF5F5; border: 1px solid #F5C6CB; border-left: 4px solid #DC3545; border-radius: 6px; padding: 10px 14px;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
                  <strong style="color: #721C24;">${escapeHtml(s.subjectCode)} - ${escapeHtml(s.subjectName)}</strong>
                  <span class="badge badge-fail" style="font-size: 0.75rem;">Pass: ${s.passPercentage}%</span>
                </div>
                <div style="font-size: 0.8125rem; color: #495057;">
                  Mean Score: <strong>${s.avgTotal}/100</strong> &bull; ${escapeHtml(s.reason)}
                </div>
              </div>
            `).join('')}
          </div>
        </div>
      `;
    } else {
      subjectsAttnHtml = `
        <div style="margin-bottom: 18px; padding: 10px 14px; background: #E8F5E9; border-left: 4px solid #2E7D32; border-radius: 4px; font-size: 0.8125rem; color: #1B5E20;">
          ✓ All evaluated subjects currently maintain pass rates above institutional threshold benchmarks.
        </div>
      `;
    }

    let studentsSupportHtml = '';
    if (studentsSupport.length > 0) {
      studentsSupportHtml = `
        <div style="margin-bottom: 20px;">
          <h4 style="font-size: 0.9375rem; font-weight: 700; color: #856404; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#856404" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="8" x2="12" y2="12"></line><line x1="12" y1="16" x2="12.01" y2="16"></line></svg>
            Students Needing Academic Support (${studentsSupport.length})
          </h4>
          <div class="table-responsive" style="max-height: 240px; overflow-y: auto;">
            <table class="data-table" style="margin: 0; font-size: 0.8125rem;">
              <thead>
                <tr>
                  <th scope="col">Student ID</th>
                  <th scope="col">Name</th>
                  <th scope="col">Subject</th>
                  <th scope="col">Marks</th>
                  <th scope="col">Identified Concern &amp; Recommended Support</th>
                </tr>
              </thead>
              <tbody>
                ${studentsSupport.slice(0, 15).map(st => `
                  <tr>
                    <td style="font-weight: 700;">${escapeHtml(st.studentId)}</td>
                    <td>${escapeHtml(st.studentName)}</td>
                    <td><code>${escapeHtml(st.subjectCode)}</code></td>
                    <td><strong style="color: ${st.totalMarks !== null && st.totalMarks < 35 ? '#C62828' : '#333'};">${st.totalMarks !== null ? st.totalMarks + '/100' : 'Int: ' + st.internalMarks + '/40'}</strong></td>
                    <td>${escapeHtml(st.reason)} &bull; <em>${escapeHtml(st.supportAction)}</em></td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
        </div>
      `;
    }

    let insightsHtml = '';
    if (insights.length > 0) {
      insightsHtml = `
        <div style="background: #F0F4F8; border-left: 4px solid #0D6EFD; border-radius: 6px; padding: 14px 18px; margin-top: 14px;">
          <h4 style="font-size: 0.875rem; font-weight: 700; color: #1E3A5F; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#0D6EFD" stroke-width="2"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>
            Pedagogical Performance Insights &amp; Strategic Interventions
          </h4>
          <ul style="margin: 0; padding-left: 20px; font-size: 0.8125rem; color: #2C3E50; line-height: 1.6;">
            ${insights.map(txt => `<li>${escapeHtml(txt)}</li>`).join('')}
          </ul>
        </div>
      `;
    }

    aiAnalysisContainer.innerHTML = `
      <!-- Overall KPI Grid -->
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px; margin-bottom: 20px;">
        <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 14px;">
          <div style="font-size: 0.75rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Class Average Score</div>
          <div style="font-size: 1.5rem; font-weight: 800; color: #1E3A5F; margin: 4px 0;">${overall.avgTotal || 0} <span style="font-size: 0.875rem; color: #6C757D;">/ 100</span></div>
          <div style="font-size: 0.75rem; color: #495057;">Internal: <strong>${overall.avgInternal || 0}/40</strong> &bull; External: <strong>${overall.avgExternal || 0}/60</strong></div>
        </div>

        <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 14px;">
          <div style="font-size: 0.75rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Pass / Fail Percentage</div>
          <div style="font-size: 1.5rem; font-weight: 800; color: ${overall.passPercentage >= 70 ? '#2E7D32' : '#C62828'}; margin: 4px 0;">
            ${overall.passPercentage || 0}% <span style="font-size: 0.8125rem; color: #6C757D;">PASS</span>
          </div>
          <div style="font-size: 0.75rem; color: #495057;">Passed: <strong>${overall.passCount || 0}</strong> &bull; Failed: <strong style="color: #C62828;">${overall.failCount || 0}</strong></div>
        </div>

        <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 14px;">
          <div style="font-size: 0.75rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Score Extremes</div>
          <div style="font-size: 1.125rem; font-weight: 700; color: #2E7D32; margin-top: 4px;">High: ${overall.highestScore || 0}/100</div>
          <div style="font-size: 0.875rem; font-weight: 700; color: #C62828; margin-bottom: 2px;">Low: ${overall.lowestScore || 0}/100</div>
          <div style="font-size: 0.7rem; color: #6C757D; text-overflow: ellipsis; overflow: hidden; white-space: nowrap;">Top: ${escapeHtml(overall.highestStudent || 'N/A')}</div>
        </div>

        <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 14px;">
          <div style="font-size: 0.75rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Class Performance Tier</div>
          <div style="font-size: 1.05rem; font-weight: 800; color: #0D6EFD; margin: 6px 0;">${escapeHtml(overall.classPerformance || 'Pending')}</div>
          <div style="font-size: 0.75rem; color: #6C757D;">Engine: <span style="font-weight: 600; color: #2E7D32;">${escapeHtml(analysis.aiSource || 'Institutional Engine')}</span></div>
        </div>
      </div>

      ${subjectsAttnHtml}
      ${studentsSupportHtml}
      ${insightsHtml}
    `;
  }

  if (btnRefreshAiAnalysis) {
    btnRefreshAiAnalysis.addEventListener('click', async () => {
      btnRefreshAiAnalysis.disabled = true;
      btnRefreshAiAnalysis.textContent = 'Analyzing...';
      try {
        await loadAiResultAnalysis();
      } finally {
        btnRefreshAiAnalysis.disabled = false;
        btnRefreshAiAnalysis.innerHTML = `
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="23 4 23 10 17 10"></polyline>
            <polyline points="1 20 1 14 7 14"></polyline>
            <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path>
          </svg>
          Refresh AI Analysis
        `;
      }
    });
  }

  // ==========================================================================
  // 6. Initial Load
  // ==========================================================================
  await loadAssignedSubjects();
  await loadDashboardStats();
  await loadRoster();
  await loadAiResultAnalysis();

  // ==========================================================================
  // 7. Fixed Sidebar Navigation Controller & Scrollspy
  // ==========================================================================
  const sidebarNavLinks = document.querySelectorAll('.sidebar-nav-link');
  sidebarNavLinks.forEach(link => {
    link.addEventListener('click', () => {
      sidebarNavLinks.forEach(l => l.classList.remove('active'));
      link.classList.add('active');
    });
  });

  const observedSections = [
    document.getElementById('section-my-subjects'),
    document.getElementById('section-subjects'),
    document.getElementById('section-import'),
    document.getElementById('section-validate-table'),
    document.getElementById('section-export'),
    document.getElementById('section-ai-analysis')
  ].filter(Boolean);

  if ('IntersectionObserver' in window && observedSections.length > 0) {
    const navObserver = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          const id = entry.target.id;
          sidebarNavLinks.forEach(link => {
            if (link.getAttribute('href') === '#' + id) {
              link.classList.add('active');
            } else {
              link.classList.remove('active');
            }
          });
        }
      });
    }, {
      rootMargin: '-80px 0px -55% 0px',
      threshold: 0
    });

    observedSections.forEach(sec => navObserver.observe(sec));
  }
});
