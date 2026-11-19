/**
 * Academic Result Input Validator - Enter / Update Subject Marks Controller
 * Steps 9–10: Domain Integrity Validation & Automatic Result Calculation
 *
 * Internal-First Enforcement:
 *   Stage A: Internal marks field always enabled. Save internal marks first.
 *   Stage B: External marks field DISABLED until valid internal marks are confirmed saved.
 *   Stage C: Missing marks displayed as "Not Updated" / "Not Available" / "Marks Pending".
 *   Stage D: Backend enforcement (server rejects external marks without saved internal).
 *   Stage E: Updating internal marks when external exist requires confirmation.
 */
(function() {
  'use strict';

  // State
  let currentSession = null;
  let cachedStudents = [];
  let cachedSubjects = [];
  let currentStudentMarks = [];
  let selectedStudentId = null;

  // DOM Elements
  const facultyUsernameEl      = document.getElementById('facultyUsername');
  const btnLogout              = document.getElementById('btnLogout');
  const studentSelect          = document.getElementById('studentSelect');
  const studentFilterInput     = document.getElementById('studentFilterInput');
  const subjectSelect          = document.getElementById('subjectSelect');
  const internalMarksInput     = document.getElementById('internalMarksInput');
  const externalMarksInput     = document.getElementById('externalMarksInput');
  const totalMarksScoreDisplay = document.getElementById('totalMarksScoreDisplay');
  const totalCalcExplanation   = document.getElementById('totalCalcExplanation');
  const marksEntryForm         = document.getElementById('marksEntryForm');
  const btnSaveMarks           = document.getElementById('btnSaveMarks');
  const btnSubmitText          = document.getElementById('btnSubmitText');
  const btnResetForm           = document.getElementById('btnResetForm');
  const formAlertBanner        = document.getElementById('formAlertBanner');
  const alertIcon              = document.getElementById('alertIcon');
  const alertMessage           = document.getElementById('alertMessage');

  // Step 9: Separate Save Buttons
  const btnSaveInternal        = document.getElementById('btnSaveInternal');
  const btnSaveExternal        = document.getElementById('btnSaveExternal');
  const externalLockBanner     = document.getElementById('externalLockBanner');

  // Error Message Elements
  const studentSelectError     = document.getElementById('studentSelectError');
  const subjectSelectError     = document.getElementById('subjectSelectError');
  const internalMarksError     = document.getElementById('internalMarksError');
  const externalMarksError     = document.getElementById('externalMarksError');

  // Selected Student Profile Card
  const selectedStudentCard        = document.getElementById('selectedStudentCard');
  const selectedStudentNameDisplay = document.getElementById('selectedStudentNameDisplay');
  const selectedStudentIdDisplay   = document.getElementById('selectedStudentIdDisplay');

  // Table Elements
  const currentStudentOverviewName = document.getElementById('currentStudentOverviewName');
  const studentMarksTableBody      = document.getElementById('studentMarksTableBody');
  const studentProgressIndicator   = document.getElementById('studentProgressIndicator');
  const studentProgressBadge       = document.getElementById('studentProgressBadge');

  // Relocated Student Directory & Marks-Entry Status Elements
  const rosterTableBody      = document.getElementById('rosterTableBody');
  const rosterSearchInput    = document.getElementById('rosterSearchInput');
  const filterAll            = document.getElementById('filterAll');
  const filterPending        = document.getElementById('filterPending');
  const filterCompleted      = document.getElementById('filterCompleted');
  let currentRosterFilter    = 'all';

  // Initialize
  document.addEventListener('DOMContentLoaded', () => {
    checkFacultyAuth();
    setupEventListeners();
    loadSubjectsAndStudents();
  });

  /**
   * 1. Session Verification
   */
  function checkFacultyAuth() {
    try {
      const raw = sessionStorage.getItem('academic_session');
      if (!raw) {
        window.location.replace('login.html?role=faculty');
        return;
      }
      currentSession = JSON.parse(raw);
      if (!currentSession || currentSession.role !== 'faculty') {
        sessionStorage.removeItem('academic_session');
        window.location.replace('login.html?role=faculty');
        return;
      }
      if (facultyUsernameEl && currentSession.username) {
        facultyUsernameEl.textContent = currentSession.username;
      }
    } catch (e) {
      sessionStorage.removeItem('academic_session');
      window.location.replace('login.html?role=faculty');
    }
  }

  /**
   * 2. Event Listeners Setup
   */
  function setupEventListeners() {
    // Logout
    if (btnLogout) {
      btnLogout.addEventListener('click', async () => {
        try {
          if (currentSession && currentSession.sessionId) {
            await fetch('/api/auth/logout', {
              method: 'POST',
              headers: { 'X-Session-Id': currentSession.sessionId }
            });
          }
        } catch (e) {
          // ignore
        } finally {
          sessionStorage.removeItem('academic_session');
          window.location.replace('login.html?role=faculty');
        }
      });
    }

    // Student Filter Input
    if (studentFilterInput) {
      studentFilterInput.addEventListener('input', () => {
        filterStudentOptions(studentFilterInput.value);
      });
    }

    // Student Select Change
    if (studentSelect) {
      studentSelect.addEventListener('change', () => {
        const stId = studentSelect.value;
        selectStudent(stId);
      });
    }

    // Subject Select Change
    if (subjectSelect) {
      subjectSelect.addEventListener('change', () => {
        clearFieldError(subjectSelect, subjectSelectError);
        populateFieldsForSelectedSubject();
        renderRoster(cachedStudents);
      });
    }

    // Roster Search & Filter Listeners (Relocated Student Directory)
    if (rosterSearchInput) {
      rosterSearchInput.addEventListener('input', () => renderRoster(cachedStudents));
    }
    if (filterAll) filterAll.addEventListener('click', () => setRosterFilterTab(filterAll, 'all'));
    if (filterPending) filterPending.addEventListener('click', () => setRosterFilterTab(filterPending, 'pending'));
    if (filterCompleted) filterCompleted.addEventListener('click', () => setRosterFilterTab(filterCompleted, 'completed'));

    // Live Mark Input Calculation & Validation
    if (internalMarksInput) {
      internalMarksInput.addEventListener('input', () => {
        validateInternalMarks();
        updateCalculatedTotal();
      });
    }

    if (externalMarksInput) {
      externalMarksInput.addEventListener('input', () => {
        validateExternalMarks();
        updateCalculatedTotal();
      });
    }

    // Reset Form
    if (btnResetForm) {
      btnResetForm.addEventListener('click', () => {
        clearMarksInputs();
        hideAlert();
      });
    }

    // Step 9: Save Internal Marks Button
    if (btnSaveInternal) {
      btnSaveInternal.addEventListener('click', () => handleSaveInternal());
    }

    // Step 9: Save External Marks Button
    if (btnSaveExternal) {
      btnSaveExternal.addEventListener('click', () => handleSaveExternal());
    }

    // Form Submit (legacy - now handled by individual save buttons)
    if (marksEntryForm) {
      marksEntryForm.addEventListener('submit', (e) => {
        e.preventDefault();
        // Delegate to the appropriate save action
        const subId = subjectSelect ? subjectSelect.value.trim() : '';
        if (!subId || !selectedStudentId) {
          showAlert('error', 'Please select a student and subject first.');
          return;
        }
        // Check if external is enabled
        if (externalMarksInput && !externalMarksInput.disabled) {
          // Save both via external path (internal should already be saved)
          handleSaveExternal();
        } else {
          handleSaveInternal();
        }
      });
    }
  }

  /**
   * 3. Load 10 Subjects and Student Roster
   */
  async function loadSubjectsAndStudents() {
    try {
      const headers = { 'X-Session-Id': currentSession.sessionId };

      // Load Subjects
      const subjectsRes = await fetch('/api/faculty/subjects', { headers });
      if (subjectsRes.ok) {
        const subjectsData = await subjectsRes.json();
        let rawSubjects = subjectsData.subjects || [];
        if (!Array.isArray(rawSubjects)) {
          rawSubjects = (rawSubjects && typeof rawSubjects === 'object' && rawSubjects.subjectId) ? [rawSubjects] : [];
        }
        cachedSubjects = rawSubjects;
        populateSubjectDropdown(cachedSubjects);
      }

      // Load Students
      const studentsRes = await fetch('/api/faculty/students', { headers });
      if (studentsRes.ok) {
        const studentsData = await studentsRes.json();
        let rawStudents = Array.isArray(studentsData) ? studentsData : (studentsData.students || []);
        if (!Array.isArray(rawStudents)) {
          rawStudents = (rawStudents && typeof rawStudents === 'object' && rawStudents.studentId) ? [rawStudents] : [];
        }
        cachedStudents = rawStudents;
        populateStudentDropdown(cachedStudents);
      }

      // Check URL parameters for pre-selected student or subject
      const urlParams = new URLSearchParams(window.location.search);
      const preStudentId = urlParams.get('studentId') || urlParams.get('student');
      const preSubjectId = urlParams.get('subjectId') || urlParams.get('subject');

      if (preSubjectId) {
        // Enforce faculty authorization for opened subject
        const isAuthorized = cachedSubjects.some(s => (s.subjectId || '').toUpperCase() === preSubjectId.toUpperCase());
        if (!isAuthorized && currentSession && currentSession.username !== 'faculty') {
          showAlert('error', `Access Denied: You are not authorized to view or enter marks for subject '${preSubjectId}'. This subject is not assigned to your faculty account.`);
          if (btnSaveInternal) btnSaveInternal.disabled = true;
          if (btnSaveExternal) btnSaveExternal.disabled = true;
          if (internalMarksInput) internalMarksInput.disabled = true;
          if (externalMarksInput) externalMarksInput.disabled = true;
          if (subjectSelect) subjectSelect.disabled = true;
          if (studentSelect) studentSelect.disabled = true;
          return;
        }

        const matched = cachedSubjects.find(s => (s.subjectId || '').toUpperCase() === preSubjectId.toUpperCase());
        if (matched && subjectSelect) {
          subjectSelect.value = matched.subjectId;
          const pageTitle = document.querySelector('h1');
          if (pageTitle) {
            pageTitle.innerHTML = `<svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path></svg> Grade Entry: ${matched.subjectCode || matched.subjectId} &mdash; ${matched.subjectName}`;
          }
        }
      }

      if (preStudentId) {
        studentSelect.value = preStudentId;
        await selectStudent(preStudentId);
      } else if (cachedStudents.length > 0) {
        studentSelect.value = cachedStudents[0].studentId;
        await selectStudent(cachedStudents[0].studentId);
      }

      if (preSubjectId) {
        populateFieldsForSelectedSubject();
      } else if (cachedSubjects.length > 0) {
        subjectSelect.value = cachedSubjects[0].subjectId;
        populateFieldsForSelectedSubject();
      }

      // Render the relocated Student Directory & Marks-Entry Status table
      renderRoster(cachedStudents);
    } catch (err) {
      showAlert('error', `Failed to load institutional data: ${err.message}`);
    }
  }

  /**
   * 4. Populate Subject Dropdown (Faculty Assigned Subjects with Abbreviation & Full Name)
   */
  function populateSubjectDropdown(subjects) {
    if (!subjectSelect) return;
    subjectSelect.innerHTML = '<option value="">-- Choose One of Your Assigned Subjects --</option>';

    if (!Array.isArray(subjects) || subjects.length === 0) {
      return;
    }

    subjects.forEach((sub, idx) => {
      const opt = document.createElement('option');
      opt.value = sub.subjectId;
      const code = sub.subjectCode || sub.subjectId;
      opt.textContent = `${idx + 1}. ${code} — ${sub.subjectName}`;
      subjectSelect.appendChild(opt);
    });
  }

  /**
   * 5. Populate Student Dropdown
   */
  function populateStudentDropdown(students) {
    if (!studentSelect) return;
    studentSelect.innerHTML = '<option value="">-- Choose a Registered Student --</option>';

    if (!students || students.length === 0) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = '-- No Students in Database (Import Roster First) --';
      opt.disabled = true;
      studentSelect.appendChild(opt);
      return;
    }

    students.forEach(st => {
      const opt = document.createElement('option');
      opt.value = st.studentId;
      opt.textContent = `${st.studentId} — ${st.studentName}`;
      studentSelect.appendChild(opt);
    });
  }

  /**
   * Filter Student Select Options by Text (Searches both Student ID and Student Name)
   */
  function filterStudentOptions(filterText) {
    const q = (filterText || '').trim().toLowerCase();
    const filtered = cachedStudents.filter(s => {
      const id = (s.studentId || '').toLowerCase();
      const name = (s.studentName || '').toLowerCase();
      const roll = (s.rollNo || '').toLowerCase();
      return id.includes(q) || name.includes(q) || roll.includes(q);
    });
    populateStudentDropdown(filtered);
    if (selectedStudentId && filtered.some(s => s.studentId === selectedStudentId)) {
      studentSelect.value = selectedStudentId;
    }
  }

  /**
   * 6. Select Student Action
   */
  async function selectStudent(studentId) {
    selectedStudentId = studentId;
    clearFieldError(studentSelect, studentSelectError);

    if (!studentId) {
      if (selectedStudentCard) selectedStudentCard.classList.remove('active');
      if (currentStudentOverviewName) currentStudentOverviewName.textContent = 'Select a Student';
      if (studentProgressIndicator) studentProgressIndicator.style.display = 'none';
      renderEmptyTable();
      clearMarksInputs();
      return;
    }

    const st = cachedStudents.find(s => s.studentId === studentId);
    if (st) {
      if (selectedStudentCard) {
        selectedStudentCard.classList.add('active');
        selectedStudentNameDisplay.textContent = st.studentName;
        selectedStudentIdDisplay.textContent = st.studentId;
      }
      if (currentStudentOverviewName) {
        currentStudentOverviewName.textContent = `${st.studentName} (${st.studentId})`;
      }
    }

    await fetchAndRenderStudentMarks(studentId);
    populateFieldsForSelectedSubject();
  }

  /**
   * 7. Fetch and Render Student Marks Table
   */
  async function fetchAndRenderStudentMarks(studentId) {
    try {
      studentMarksTableBody.innerHTML = `
        <tr>
          <td colspan="7" style="text-align: center; color: var(--color-text-secondary); padding: 24px;">
            Loading subject evaluations from database...
          </td>
        </tr>
      `;

      const res = await fetch(`/api/faculty/student-marks?studentId=${encodeURIComponent(studentId)}`, {
        headers: { 'X-Session-Id': currentSession.sessionId }
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}: Failed to fetch student marks`);
      }

      currentStudentMarks = await res.json();
      renderStudentMarksTable(currentStudentMarks);

    } catch (err) {
      studentMarksTableBody.innerHTML = `
        <tr>
          <td colspan="7" style="text-align: center; color: var(--color-error); padding: 24px;">
            Error loading marks: ${err.message}
          </td>
        </tr>
      `;
    }
  }

  /**
   * 8. Render Student Marks Table (Step 9/10 Enhanced)
   */
  function renderStudentMarksTable(marks) {
    if (!studentMarksTableBody) return;
    studentMarksTableBody.innerHTML = '';

    // Filter to assigned subjects only (defensive frontend safeguard)
    const assignedIds = (cachedSubjects || []).map(s => (s.subjectId || '').toUpperCase());
    const displayMarks = (assignedIds.length > 0 && currentSession && currentSession.username !== 'faculty')
      ? (marks || []).filter(m => assignedIds.includes((m.subjectId || '').toUpperCase()))
      : (marks || []);

    if (!displayMarks || displayMarks.length === 0) {
      renderEmptyTable();
      return;
    }

    let fullyEnteredCount = 0;
    let overallTotal = 0;
    let allComplete = displayMarks.length > 0;

    displayMarks.forEach(item => {
      const hasInternal = item.internalMarks !== null && item.internalMarks !== undefined &&
                          item.internalMarks !== '' && !isNaN(Number(item.internalMarks)) &&
                          Number(item.internalMarks) >= 0 && Number(item.internalMarks) <= 40;
      const hasExternal = item.externalMarks !== null && item.externalMarks !== undefined &&
                          item.externalMarks !== '' && !isNaN(Number(item.externalMarks)) &&
                          Number(item.externalMarks) >= 0 && Number(item.externalMarks) <= 60;
      const isFullyEntered = hasInternal && hasExternal;

      let completedComponents = 0;
      if (hasInternal) completedComponents++;
      if (hasExternal) completedComponents++;
      const totalRequiredComponents = 2; // 2 distinct required components: Internal (0-40) and External (0-60)
      const componentRatioText = `${completedComponents} / ${totalRequiredComponents} Entered`;

      if (isFullyEntered) {
        fullyEnteredCount++;
        overallTotal += (Number(item.internalMarks) + Number(item.externalMarks));
      } else {
        allComplete = false;
      }

      const tr = document.createElement('tr');
      if (subjectSelect && subjectSelect.value === item.subjectId) {
        tr.style.backgroundColor = '#EFF6FF';
      }

      // 1. Subject Code
      const tdCode = document.createElement('td');
      const codeSpan = document.createElement('span');
      codeSpan.className = 'badge-subject-code';
      codeSpan.textContent = item.subjectCode || item.subjectId;
      tdCode.appendChild(codeSpan);

      // 2. Curricular Subject Title
      const tdName = document.createElement('td');
      tdName.innerHTML = `<strong>${escapeHtml(item.subjectName)}</strong>`;

      // 3. Internal Marks
      const tdInt = document.createElement('td');
      tdInt.style.textAlign = 'right';
      if (hasInternal) {
        tdInt.innerHTML = `<strong>${item.internalMarks}</strong> <span style="color: #64748B; font-size: 0.75rem;">/ 40</span>`;
      } else {
        tdInt.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
      }

      // 4. External Marks (Step 9: Show lock icon if internal not saved)
      const tdExt = document.createElement('td');
      tdExt.style.textAlign = 'right';
      if (hasExternal) {
        tdExt.innerHTML = `<strong>${item.externalMarks}</strong> <span style="color: #64748B; font-size: 0.75rem;">/ 60</span>`;
      } else if (!hasInternal) {
        tdExt.innerHTML = `<span class="badge badge-not-updated" title="Enter internal marks first">🔒 Not Updated</span>`;
      } else {
        tdExt.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
      }

      // 5. Total Marks (Step 10: Automatic calculation)
      const tdTot = document.createElement('td');
      tdTot.style.textAlign = 'right';
      if (isFullyEntered) {
        const total = Number(item.internalMarks) + Number(item.externalMarks);
        tdTot.innerHTML = `<strong style="color: var(--color-primary); font-size: 1.0625rem;">${total}</strong> <span style="color: #64748B; font-size: 0.75rem;">/ 100</span>`;
      } else {
        tdTot.innerHTML = `<span class="badge badge-withheld">Not Available</span>`;
      }

      // 6. Evaluation Status Badge (Step 9/10 Stage C)
      const tdStatus = document.createElement('td');
      if (completedComponents === 0) {
        tdStatus.innerHTML = `<span class="badge badge-not-updated">Not Updated (${componentRatioText})</span>`;
      } else if (completedComponents === totalRequiredComponents) {
        tdStatus.innerHTML = `<span class="badge badge-complete">Fully Entered (${componentRatioText})</span>`;
      } else {
        tdStatus.innerHTML = `<span class="badge badge-withheld">Marks Pending (${componentRatioText})</span>`;
      }

      // 7. Action: Quick Edit Button
      const tdAction = document.createElement('td');
      tdAction.style.textAlign = 'center';
      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.className = 'btn btn-secondary';
      editBtn.style.padding = '4px 10px';
      editBtn.style.fontSize = '0.78125rem';
      editBtn.textContent = 'Edit';
      editBtn.title = `Load ${item.subjectCode} into entry form`;
      editBtn.addEventListener('click', () => {
        if (subjectSelect) {
          subjectSelect.value = item.subjectId;
          clearFieldError(subjectSelect, subjectSelectError);
          populateFieldsForSelectedSubject();
          internalMarksInput.focus();
        }
      });
      tdAction.appendChild(editBtn);

      tr.appendChild(tdCode);
      tr.appendChild(tdName);
      tr.appendChild(tdInt);
      tr.appendChild(tdExt);
      tr.appendChild(tdTot);
      tr.appendChild(tdStatus);
      tr.appendChild(tdAction);

      studentMarksTableBody.appendChild(tr);
    });

    // Step 10: Overall Summary Row when all assigned subjects complete
    if (allComplete && displayMarks.length > 0) {
      const maxTotal = displayMarks.length * 100;
      const percentage = ((overallTotal / maxTotal) * 100).toFixed(2);

      const summaryTr = document.createElement('tr');
      summaryTr.style.backgroundColor = '#F0FFF4';
      summaryTr.style.fontWeight = '700';
      summaryTr.innerHTML = `
        <td colspan="2" style="text-align: right; color: var(--color-primary); font-size: 0.9375rem; padding: 12px 16px;">
          Overall Aggregate (${displayMarks.length} Assigned Subjects)
        </td>
        <td style="text-align: right; color: #456B91; font-size: 0.875rem;">
          Σ Internal
        </td>
        <td style="text-align: right; color: #456B91; font-size: 0.875rem;">
          Σ External
        </td>
        <td style="text-align: right; color: var(--color-primary); font-size: 1.125rem;">
          ${overallTotal} / ${maxTotal}
        </td>
        <td style="color: #456B91; font-size: 0.875rem;">
          ${percentage}%
        </td>
        <td style="text-align: center;">
          <span class="badge badge-withheld" style="font-size: 0.7rem;">P/F: Not Configured</span>
        </td>
      `;
      studentMarksTableBody.appendChild(summaryTr);
    } else if (displayMarks.length > 0) {
      const pendingCount = displayMarks.length - fullyEnteredCount;
      const summaryTr = document.createElement('tr');
      summaryTr.style.backgroundColor = '#FFF8E1';
      summaryTr.innerHTML = `
        <td colspan="4" style="text-align: right; color: #B45309; font-size: 0.875rem; padding: 12px 16px;">
          <strong>Result Pending</strong> — ${fullyEnteredCount} of ${displayMarks.length} assigned subjects complete, ${pendingCount} pending
        </td>
        <td style="text-align: right;">
          <span class="badge badge-withheld">Not Available</span>
        </td>
        <td>
          <span class="badge badge-withheld">Result Pending</span>
        </td>
        <td></td>
      `;
      studentMarksTableBody.appendChild(summaryTr);
    }

    // Update Progress Indicator
    if (studentProgressIndicator && studentProgressBadge) {
      studentProgressIndicator.style.display = 'block';
      const totalSubs = displayMarks.length;
      const completedSubs = Math.min(fullyEnteredCount, totalSubs);
      studentProgressBadge.textContent = `${completedSubs} / ${totalSubs} Entered`;
      studentProgressBadge.className = (completedSubs === totalSubs && totalSubs > 0) ? 'badge badge-complete' : 'badge badge-withheld';
    }
  }

  function renderEmptyTable() {
    if (!studentMarksTableBody) return;
    studentMarksTableBody.innerHTML = `
      <tr>
        <td colspan="7" style="text-align: center; color: var(--color-text-secondary); padding: 36px 20px;">
          <svg viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style="color: #94A3B8; margin-bottom: 8px;">
            <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
            <circle cx="9" cy="7" r="4"></circle>
          </svg>
          <div>Please select a student from the dropdown on the left to view their complete academic evaluation records.</div>
        </td>
      </tr>
    `;
  }

  /**
   * 9. Populate Form Fields When Subject Selected
   * Step 9: Enable/disable external marks based on saved internal marks state
   */
  function populateFieldsForSelectedSubject() {
    const subId = subjectSelect ? subjectSelect.value : '';
    if (!subId || !selectedStudentId) {
      clearMarksInputs();
      return;
    }

    // Highlight row in table
    const rows = studentMarksTableBody ? studentMarksTableBody.querySelectorAll('tr') : [];
    rows.forEach(r => {
      r.style.backgroundColor = '';
    });

    const m = currentStudentMarks.find(item => item.subjectId === subId);

    // Determine if internal marks are saved in database
    const hasInternalSaved = m && (m.internalMarks !== null && m.internalMarks !== undefined);
    const hasExternalSaved = m && (m.externalMarks !== null && m.externalMarks !== undefined);

    // Fill internal marks field
    if (m && hasInternalSaved) {
      internalMarksInput.value = m.internalMarks;
    } else {
      internalMarksInput.value = '';
    }

    // Fill external marks field
    if (m && hasExternalSaved) {
      externalMarksInput.value = m.externalMarks;
    } else {
      externalMarksInput.value = '';
    }

    // Step 9: External marks field state based on saved internal marks
    updateExternalFieldState(hasInternalSaved);

    // Update button text
    if (btnSaveInternal) {
      btnSaveInternal.textContent = hasInternalSaved ? '✏️ Update Internal Marks' : '💾 Save Internal Marks';
    }
    if (btnSaveExternal) {
      btnSaveExternal.textContent = hasExternalSaved ? '✏️ Update External Marks' : '💾 Save External Marks';
    }
    // Legacy button text
    if (btnSubmitText) {
      btnSubmitText.textContent = (hasInternalSaved || hasExternalSaved) ? 'Update Marks' : 'Save Marks';
    }

    validateInternalMarks();
    validateExternalMarks();
    updateCalculatedTotal();
  }

  /**
   * Step 9: Enable/disable external marks field based on internal marks state
   */
  function updateExternalFieldState(hasInternalSaved) {
    if (!externalMarksInput) return;

    if (hasInternalSaved) {
      // Internal marks are saved — enable external marks
      externalMarksInput.disabled = false;
      externalMarksInput.placeholder = '0 – 60 (or empty)';
      externalMarksInput.title = '';
      if (externalLockBanner) externalLockBanner.style.display = 'none';
      if (btnSaveExternal) {
        btnSaveExternal.disabled = false;
        btnSaveExternal.title = '';
      }
    } else {
      // Internal marks NOT saved — disable external marks (Step 9 Stage B)
      externalMarksInput.disabled = true;
      externalMarksInput.value = '';
      externalMarksInput.placeholder = '🔒 Save internal marks first';
      externalMarksInput.title = 'Enter and save valid internal marks before entering external marks.';
      if (externalLockBanner) externalLockBanner.style.display = 'flex';
      if (btnSaveExternal) {
        btnSaveExternal.disabled = true;
        btnSaveExternal.title = 'Save internal marks first';
      }
    }
  }

  /**
   * 10. Live Total Score Calculation (Step 10)
   */
  function updateCalculatedTotal() {
    const intVal = internalMarksInput ? internalMarksInput.value.trim() : '';
    const extVal = externalMarksInput ? externalMarksInput.value.trim() : '';

    const isIntValid = intVal === '' || (/^\d+$/.test(intVal) && parseInt(intVal, 10) >= 0 && parseInt(intVal, 10) <= 40);
    const isExtValid = extVal === '' || (/^\d+$/.test(extVal) && parseInt(extVal, 10) >= 0 && parseInt(extVal, 10) <= 60);

    if (!isIntValid || !isExtValid) {
      if (totalMarksScoreDisplay) {
        totalMarksScoreDisplay.textContent = 'Invalid';
        totalMarksScoreDisplay.style.color = 'var(--color-error)';
      }
      if (totalCalcExplanation) totalCalcExplanation.textContent = 'Correct boundary errors above to compute total score';
      return;
    }

    if (totalMarksScoreDisplay) totalMarksScoreDisplay.style.color = 'var(--color-primary)';

    if (intVal !== '' && extVal !== '') {
      const i = parseInt(intVal, 10);
      const e = parseInt(extVal, 10);
      const total = i + e;
      if (totalMarksScoreDisplay) totalMarksScoreDisplay.textContent = `${total} / 100`;
      if (totalCalcExplanation) totalCalcExplanation.textContent = `Internal: ${i}/40 + External: ${e}/60 = ${total}/100`;
    } else if (intVal !== '') {
      if (totalMarksScoreDisplay) totalMarksScoreDisplay.textContent = '-- / 100';
      if (totalCalcExplanation) totalCalcExplanation.textContent = `Marks Pending — Internal: ${intVal}/40, External: Not Updated`;
    } else if (extVal !== '') {
      if (totalMarksScoreDisplay) totalMarksScoreDisplay.textContent = '-- / 100';
      if (totalCalcExplanation) totalCalcExplanation.textContent = `Marks Pending — Internal: Not Updated, External: ${extVal}/60`;
    } else {
      if (totalMarksScoreDisplay) totalMarksScoreDisplay.textContent = '-- / 100';
      if (totalCalcExplanation) totalCalcExplanation.textContent = 'Not Available — Enter both internal and external marks';
    }
  }

  /**
   * 11. Field Validations
   */
  function validateInternalMarks() {
    if (!internalMarksInput) return true;
    const val = internalMarksInput.value.trim();
    if (val === '') {
      clearFieldError(internalMarksInput, internalMarksError);
      return true;
    }
    if (!/^\d+$/.test(val)) {
      showFieldError(internalMarksInput, internalMarksError, 'Internal marks must be between 0 and 40.');
      return false;
    }
    const num = parseInt(val, 10);
    if (num < 0 || num > 40) {
      showFieldError(internalMarksInput, internalMarksError, `Internal marks must be between 0 and 40. Received: ${num}.`);
      return false;
    }
    clearFieldError(internalMarksInput, internalMarksError);
    return true;
  }

  function validateExternalMarks() {
    if (!externalMarksInput) return true;
    const val = externalMarksInput.value.trim();
    if (val === '') {
      clearFieldError(externalMarksInput, externalMarksError);
      return true;
    }
    if (!/^\d+$/.test(val)) {
      showFieldError(externalMarksInput, externalMarksError, 'External marks must be between 0 and 60.');
      return false;
    }
    const num = parseInt(val, 10);
    if (num < 0 || num > 60) {
      showFieldError(externalMarksInput, externalMarksError, `External marks must be between 0 and 60. Received: ${num}.`);
      return false;
    }
    clearFieldError(externalMarksInput, externalMarksError);
    return true;
  }

  function showFieldError(inputEl, errorEl, msg) {
    if (inputEl) inputEl.classList.add('is-invalid');
    if (errorEl) {
      errorEl.textContent = msg;
      errorEl.classList.add('visible');
    }
  }

  function clearFieldError(inputEl, errorEl) {
    if (inputEl) inputEl.classList.remove('is-invalid');
    if (errorEl) {
      errorEl.textContent = '';
      errorEl.classList.remove('visible');
    }
  }

  function clearMarksInputs() {
    if (internalMarksInput) internalMarksInput.value = '';
    if (externalMarksInput) {
      externalMarksInput.value = '';
      externalMarksInput.disabled = true;
      externalMarksInput.placeholder = '🔒 Save internal marks first';
    }
    clearFieldError(internalMarksInput, internalMarksError);
    clearFieldError(externalMarksInput, externalMarksError);
    updateCalculatedTotal();
    if (btnSubmitText) btnSubmitText.textContent = 'Save / Update Marks';
    if (btnSaveInternal) btnSaveInternal.textContent = '💾 Save Internal Marks';
    if (btnSaveExternal) {
      btnSaveExternal.textContent = '💾 Save External Marks';
      btnSaveExternal.disabled = true;
    }
    if (externalLockBanner) externalLockBanner.style.display = 'flex';
  }

  /**
   * 12. Step 9 Stage A: Save Internal Marks Handler
   */
  async function handleSaveInternal() {
    hideAlert();
    const stId = studentSelect ? studentSelect.value.trim() : '';
    const subId = subjectSelect ? subjectSelect.value.trim() : '';

    if (!stId) {
      showFieldError(studentSelect, studentSelectError, 'Please select a student from the database.');
      showAlert('error', 'Please select a student.');
      return;
    }
    if (!subId) {
      showFieldError(subjectSelect, subjectSelectError, 'Please select one of the 10 configured curricular subjects.');
      showAlert('error', 'Please select a subject.');
      return;
    }

    const isValid = validateInternalMarks();
    if (!isValid) {
      showAlert('error', 'Internal marks must be between 0 and 40.');
      return;
    }

    const rawInt = internalMarksInput.value.trim();
    const payload = {
      studentId: stId,
      subjectId: subId,
      markType: 'internal',
      internalMarks: rawInt === '' ? null : parseInt(rawInt, 10)
    };

    await submitMarkPayload(payload, 'internal');
  }

  /**
   * 13. Step 9 Stage B: Save External Marks Handler
   */
  async function handleSaveExternal() {
    hideAlert();
    const stId = studentSelect ? studentSelect.value.trim() : '';
    const subId = subjectSelect ? subjectSelect.value.trim() : '';

    if (!stId) {
      showFieldError(studentSelect, studentSelectError, 'Please select a student from the database.');
      showAlert('error', 'Please select a student.');
      return;
    }
    if (!subId) {
      showFieldError(subjectSelect, subjectSelectError, 'Please select one of the 10 configured curricular subjects.');
      showAlert('error', 'Please select a subject.');
      return;
    }

    // Pre-check: internal marks must be saved
    const m = currentStudentMarks.find(item => item.subjectId === subId);
    if (!m || m.internalMarks === null || m.internalMarks === undefined) {
      showAlert('error', 'Enter and save valid internal marks before entering external marks.');
      return;
    }

    const isValid = validateExternalMarks();
    if (!isValid) {
      showAlert('error', 'External marks must be between 0 and 60.');
      return;
    }

    const rawExt = externalMarksInput.value.trim();
    const payload = {
      studentId: stId,
      subjectId: subId,
      markType: 'external',
      externalMarks: rawExt === '' ? null : parseInt(rawExt, 10)
    };

    await submitMarkPayload(payload, 'external');
  }

  /**
   * 14. Submit Mark Payload to Server
   */
  async function submitMarkPayload(payload, saveType) {
    setSubmitting(true, saveType);

    try {
      const response = await fetch('/api/faculty/mark', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Session-Id': currentSession.sessionId
        },
        body: JSON.stringify(payload)
      });

      const data = await response.json();

      // Step 9 Stage E: Handle confirmation requirement
      if (response.status === 409 && data.requiresConfirmation) {
        const confirmed = confirm(
          data.error + '\n\nClick OK to confirm clearing both marks, or Cancel to keep existing values.'
        );
        if (confirmed) {
          payload.forceConfirmed = true;
          await submitMarkPayload(payload, saveType);
          return;
        } else {
          showAlert('error', 'Operation cancelled. Existing marks preserved.');
          setSubmitting(false, saveType);
          return;
        }
      }

      if (!response.ok || !data.success) {
        throw new Error(data.error || 'Unable to save marks. Please try again.');
      }

      // Success
      if (saveType === 'internal' && data.markRecord && data.markRecord.internalMarks !== null) {
        showAlert('success', data.message || 'Internal marks saved successfully. You can now enter external marks.');
      } else if (saveType === 'external') {
        showAlert('success', data.message || 'External marks saved successfully.');
      } else {
        showAlert('success', data.message || 'Marks saved successfully.');
      }

      // Refresh table to confirm persistence
      await fetchAndRenderStudentMarks(payload.studentId);
      // Re-populate form to update field states
      populateFieldsForSelectedSubject();
      // Synchronize the relocated Student Directory & Marks-Entry Status table
      await reloadStudentRoster();

    } catch (err) {
      showAlert('error', err.message);
    } finally {
      setSubmitting(false, saveType);
    }
  }

  function setSubmitting(isSubmitting, saveType) {
    if (btnSaveInternal && saveType === 'internal') {
      btnSaveInternal.disabled = isSubmitting;
      if (isSubmitting) {
        btnSaveInternal.textContent = '⏳ Saving Internal...';
      }
    }
    if (btnSaveExternal && saveType === 'external') {
      btnSaveExternal.disabled = isSubmitting;
      if (isSubmitting) {
        btnSaveExternal.textContent = '⏳ Saving External...';
      }
    }
    if (btnSaveMarks) {
      btnSaveMarks.disabled = isSubmitting;
      if (isSubmitting) {
        if (btnSubmitText) btnSubmitText.textContent = 'Saving to Database...';
      }
    }
  }

  function showAlert(type, message) {
    if (!formAlertBanner || !alertMessage || !alertIcon) return;

    formAlertBanner.className = `alert-banner ${type} visible`;
    alertMessage.textContent = message;

    if (type === 'success') {
      alertIcon.innerHTML = `
        <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path>
        <polyline points="22 4 12 14.01 9 11.01"></polyline>
      `;
    } else {
      alertIcon.innerHTML = `
        <circle cx="12" cy="12" r="10"></circle>
        <line x1="12" y1="8" x2="12" y2="12"></line>
        <line x1="12" y1="16" x2="12.01" y2="16"></line>
      `;
    }
  }

  function hideAlert() {
    if (formAlertBanner) {
      formAlertBanner.className = 'alert-banner';
    }
  }

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/[&<>'"]/g, tag => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    }[tag] || tag));
  }

  // ==========================================================================
  // Relocated Student Directory & Marks-Entry Status Controller
  // ==========================================================================
  function setRosterFilterTab(activeBtn, filterValue) {
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
    currentRosterFilter = filterValue;
    renderRoster(cachedStudents);
  }

  async function reloadStudentRoster() {
    try {
      const headers = { 'X-Session-Id': currentSession.sessionId };
      const studentsRes = await fetch('/api/faculty/students', { headers });
      if (studentsRes.ok) {
        const studentsData = await studentsRes.json();
        let rawStudents = Array.isArray(studentsData) ? studentsData : (studentsData.students || []);
        if (!Array.isArray(rawStudents)) {
          rawStudents = (rawStudents && typeof rawStudents === 'object' && rawStudents.studentId) ? [rawStudents] : [];
        }
        cachedStudents = rawStudents;
        renderRoster(cachedStudents);
      }
    } catch (e) {
      // ignore
    }
  }

  function renderRoster(students) {
    if (!rosterTableBody) return;
    rosterTableBody.innerHTML = '';

    const filterText = (rosterSearchInput ? rosterSearchInput.value : '').toLowerCase().trim();
    const activeSubId = subjectSelect ? (subjectSelect.value || '').trim() : '';

    // Filter by Search Query
    let filtered = (students || []).filter(s =>
      (s.studentId && s.studentId.toLowerCase().includes(filterText)) ||
      (s.studentName && s.studentName.toLowerCase().includes(filterText))
    );

    // Filter by Tab (All, Pending, Completed)
    if (currentRosterFilter === 'pending') {
      filtered = filtered.filter(s => {
        if (activeSubId) {
          const sub = (s.subjects || []).find(x => (x.subjectId || '').toUpperCase() === activeSubId.toUpperCase());
          return !sub || sub.evalStatus !== 'Fully Entered';
        }
        return s.pendingCount > 0 || !s.fullyEnteredCount || s.fullyEnteredCount < (s.subjects ? s.subjects.length : 1);
      });
    } else if (currentRosterFilter === 'completed') {
      filtered = filtered.filter(s => {
        if (activeSubId) {
          const sub = (s.subjects || []).find(x => (x.subjectId || '').toUpperCase() === activeSubId.toUpperCase());
          return sub && sub.evalStatus === 'Fully Entered';
        }
        return s.pendingCount === 0 && s.fullyEnteredCount === (s.subjects ? s.subjects.length : 0);
      });
    }

    if (filtered.length === 0) {
      if (!students || students.length === 0) {
        rosterTableBody.innerHTML = `
          <tr>
            <td colspan="8">
              <div class="empty-state-box">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
                  <circle cx="9" cy="7" r="4"></circle>
                </svg>
                <div class="empty-state-title">No Students Registered in Database</div>
                <div class="empty-state-text">The institutional roster is currently empty.</div>
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
                <div class="empty-state-text">No records match your search criteria "${filterText || currentRosterFilter}". Try a different Student ID, name, or reset the filter.</div>
              </div>
            </td>
          </tr>
        `;
      }
      return;
    }

    filtered.forEach(s => {
      const tr = document.createElement('tr');

      // 1. Student ID
      const idTd = document.createElement('td');
      idTd.style.fontWeight = '600';
      idTd.textContent = s.studentId;

      // 2. Student Name
      const nameTd = document.createElement('td');
      nameTd.textContent = s.studentName;

      // Check if viewing a specific assigned subject
      const curSub = activeSubId ? (s.subjects || []).find(x => (x.subjectId || '').toUpperCase() === activeSubId.toUpperCase()) : null;

      const totalSubs = (s.subjects && s.subjects.length > 0) ? s.subjects.length : 1;
      const rawFully = s.fullyEnteredCount !== undefined ? Number(s.fullyEnteredCount) : 0;
      const fullyEntered = Math.min(Math.max(0, isNaN(rawFully) ? 0 : rawFully), totalSubs);
      const isCompleteOverall = fullyEntered === totalSubs && totalSubs > 0;

      // 3. Evaluation Status Badge
      const statusTd = document.createElement('td');
      if (curSub) {
        const hasInt = curSub.internalMarks !== null && curSub.internalMarks !== undefined && curSub.internalMarks !== '' && !isNaN(Number(curSub.internalMarks)) && Number(curSub.internalMarks) >= 0 && Number(curSub.internalMarks) <= 40;
        const hasExt = curSub.externalMarks !== null && curSub.externalMarks !== undefined && curSub.externalMarks !== '' && !isNaN(Number(curSub.externalMarks)) && Number(curSub.externalMarks) >= 0 && Number(curSub.externalMarks) <= 60;
        let compCount = 0;
        if (hasInt) compCount++;
        if (hasExt) compCount++;
        const compRatioText = `${compCount}/2 Entered`;

        if (curSub.evalStatus === 'Fully Entered' || (hasInt && hasExt)) {
          statusTd.innerHTML = `<span class="badge badge-complete">Fully Entered (${compRatioText})</span>`;
        } else if (hasInt || hasExt) {
          statusTd.innerHTML = `<span class="badge badge-withheld">Marks Pending (${compRatioText})</span>`;
        } else {
          statusTd.innerHTML = `<span class="badge badge-not-updated">Not Updated (${compRatioText})</span>`;
        }
      } else {
        if (isCompleteOverall) {
          statusTd.innerHTML = `<span class="badge badge-complete">Fully Entered (${fullyEntered}/${totalSubs})</span>`;
        } else {
          const pendingCount = totalSubs - fullyEntered;
          statusTd.innerHTML = `<span class="badge badge-withheld">Marks Pending (${pendingCount} incomplete)</span>`;
        }
      }

      // 4. Internal Marks
      const intTd = document.createElement('td');
      if (curSub) {
        if (curSub.internalMarks !== null && curSub.internalMarks !== undefined && curSub.internalMarks !== '' && !isNaN(Number(curSub.internalMarks))) {
          intTd.innerHTML = `<strong>${curSub.internalMarks}</strong> / 40`;
        } else {
          intTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
        }
      } else {
        const rawInt = s.internalEnteredCount !== undefined ? Number(s.internalEnteredCount) : 0;
        const intEntered = Math.min(Math.max(0, isNaN(rawInt) ? 0 : rawInt), totalSubs);
        intTd.innerHTML = `<strong>${intEntered}</strong> / ${totalSubs} Entered`;
      }

      // 5. External Marks
      const extTd = document.createElement('td');
      if (curSub) {
        if (curSub.externalMarks !== null && curSub.externalMarks !== undefined && curSub.externalMarks !== '' && !isNaN(Number(curSub.externalMarks))) {
          extTd.innerHTML = `<strong>${curSub.externalMarks}</strong> / 60`;
        } else {
          extTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
        }
      } else {
        const rawExt = s.externalEnteredCount !== undefined ? Number(s.externalEnteredCount) : 0;
        const extEntered = Math.min(Math.max(0, isNaN(rawExt) ? 0 : rawExt), totalSubs);
        extTd.innerHTML = `<strong>${extEntered}</strong> / ${totalSubs} Entered`;
      }

      // 6. Total Score
      const totalTd = document.createElement('td');
      if (curSub) {
        if (curSub.totalMarks !== null && curSub.totalMarks !== undefined && curSub.totalMarks !== '' && !isNaN(Number(curSub.totalMarks))) {
          totalTd.innerHTML = `<strong>${curSub.totalMarks}</strong> / 100`;
        } else {
          totalTd.innerHTML = `<span style="color: var(--color-text-secondary); font-size: 0.8125rem;">Withheld (Incomplete)</span>`;
        }
      } else {
        if (isCompleteOverall && s.totalMarks !== null && s.totalMarks !== undefined) {
          totalTd.innerHTML = `<strong>${s.totalMarks}</strong> / ${totalSubs * 100} <span style="color: var(--color-text-secondary); font-size: 0.75rem;">(${s.percentage}%)</span>`;
        } else {
          totalTd.innerHTML = `<span style="color: var(--color-text-secondary); font-size: 0.8125rem;">Withheld (Incomplete)</span>`;
        }
      }

      // 7. Academic Standing
      const standingTd = document.createElement('td');
      const isSubComplete = curSub ? (curSub.evalStatus === 'Fully Entered') : isCompleteOverall;
      if (isSubComplete) {
        standingTd.innerHTML = `<span class="badge badge-withheld" title="Pass/Fail rules not configured yet">Pass/Fail Rules Not Configured</span>`;
      } else {
        standingTd.innerHTML = `<span class="badge badge-withheld">Marks Pending</span>`;
      }

      // 8. Action Button
      const actionTd = document.createElement('td');
      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.className = 'btn btn-secondary';
      editBtn.style.padding = '5px 12px';
      editBtn.style.fontSize = '0.78125rem';
      editBtn.textContent = 'Enter / Edit Marks';
      editBtn.title = `Select student ${s.studentId} for grading`;
      editBtn.addEventListener('click', () => {
        if (studentSelect) {
          studentSelect.value = s.studentId;
          selectStudent(s.studentId);
          const formCard = document.querySelector('.entry-card');
          if (formCard) formCard.scrollIntoView({ behavior: 'smooth' });
          if (internalMarksInput) internalMarksInput.focus();
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

})();
