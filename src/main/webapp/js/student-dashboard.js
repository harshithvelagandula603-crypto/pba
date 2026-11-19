/**
 * Academic Result Input Validator - Student Dashboard Controller
 *
 * Rendering Rules:
 * - Each subject has TWO mark components: Internal (max 40) and External (max 60).
 * - NULL is displayed as "Not Updated" and is NEVER treated as 0.
 * - If EITHER component is NULL, subject status = "Marks Pending"; total is withheld.
 * - Aggregate (Total, Percentage) withheld until ALL subjects are FULLY entered (both components).
 * - PASS/FAIL: 35 or above = PASS; below 35 = FAIL.
 * - AI Analysis: Personalized per-student suggestions based on that student's own validated records.
 */

// Utility: HTML entity escaping to prevent XSS
function escapeHtml(text) {
  if (!text) return '';
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

document.addEventListener('DOMContentLoaded', async () => {
  const studentPillText      = document.getElementById('studentPillText');
  const studentNameDisplay   = document.getElementById('studentNameDisplay');
  const studentIdDisplay     = document.getElementById('studentIdDisplay');
  const subjectCountDisplay  = document.getElementById('subjectCountDisplay');
  const progressDisplay      = document.getElementById('progressDisplay');
  const subjectsTableBody    = document.getElementById('subjectsTableBody');
  const totalMarksDisplay    = document.getElementById('totalMarksDisplay');
  const percentageDisplay    = document.getElementById('percentageDisplay');
  const resultStatusDisplay  = document.getElementById('resultStatusDisplay');
  const resultStatusNote     = document.getElementById('resultStatusNote');
  const logoutBtn            = document.getElementById('logoutBtn');

  // 1. Session Verification
  const rawSession = sessionStorage.getItem('academic_session');
  if (!rawSession) {
    window.location.replace('login.html?role=student');
    return;
  }

  let session;
  try {
    session = JSON.parse(rawSession);
  } catch (e) {
    sessionStorage.removeItem('academic_session');
    window.location.replace('login.html?role=student');
    return;
  }

  if (session.role !== 'student') {
    window.location.replace('login.html?role=student');
    return;
  }

  // Handle Logout
  if (logoutBtn) {
    logoutBtn.addEventListener('click', async () => {
      try {
        await fetch('/api/auth/logout', {
          method: 'POST',
          headers: { 'X-Session-Id': session.sessionId }
        });
      } catch (ignored) {}
      sessionStorage.removeItem('academic_session');
      window.location.replace('login.html?role=student');
    });
  }

  // 2. Retrieve Student Records via Server Session
  // Security Rule: Client never requests another student's ID via query param.
  // Server strictly uses the session token to retrieve only the authenticated student's data.
  try {
    const response = await fetch('/api/student/records', {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Session-Id': session.sessionId
      }
    });

    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        sessionStorage.removeItem('academic_session');
        window.location.replace('login.html?role=student');
        return;
      }
      throw new Error(`Failed to load records. HTTP Status: ${response.status}`);
    }

    const data = await response.json();
    renderStudentDashboard(data);

  } catch (err) {
    if (subjectsTableBody) {
      subjectsTableBody.innerHTML = `
        <tr>
          <td colspan="6" style="text-align: center; color: var(--color-error); padding: 24px;">
            Unable to retrieve student records. ${err.message}
          </td>
        </tr>
      `;
    }
  }

  /**
   * Renders student profile, subject-wise marks table (Internal / External / Total / Status),
   * and aggregate result cards with PASS/FAIL rules not configured state.
   */
  function renderStudentDashboard(data) {
    const student  = data.student  || {};
    const subjects = data.subjects || [];

    // PASS/FAIL configuration flag from server response
    const passfailConfigured = data.passfailConfigured === true;
    const passfailNote = data.passfailNote || 'Pass/Fail Rules Not Configured. Exact institutional rules must be provided before results can be declared.';

    // Header & Profile Information
    if (studentPillText) {
      studentPillText.textContent = `${student.studentName || 'Student'} (${student.studentId || session.studentId})`;
    }
    if (studentNameDisplay) studentNameDisplay.textContent = student.studentName || '---';
    if (studentIdDisplay)   studentIdDisplay.textContent   = student.studentId   || session.studentId;
    if (subjectCountDisplay) subjectCountDisplay.textContent = `${subjects.length} Curricular Subjects`;

    // Process Subjects
    let totalObtained       = 0;
    let totalMaxMarks       = 0;
    let fullyEnteredCount   = 0;
    let anySubjectFailed    = false;
    let allSubjectsFullyEntered = subjects.length > 0;

    if (subjectsTableBody) {
      subjectsTableBody.innerHTML = '';

      if (subjects.length === 0) {
        subjectsTableBody.innerHTML = `
          <tr>
            <td colspan="6" style="text-align: center; color: var(--color-text-secondary); padding: 24px;">
              No curricular subjects assigned yet.
            </td>
          </tr>
        `;
      } else {
        subjects.forEach(sub => {
          totalMaxMarks += 100; // Each subject is out of 100

          const row = document.createElement('tr');

          // Subject Code (Abbreviation)
          const codeTd = document.createElement('td');
          codeTd.style.fontWeight = '600';
          codeTd.textContent = sub.subjectCode || sub.subjectId;

          // Subject Name (Full Form)
          const nameTd = document.createElement('td');
          nameTd.textContent = sub.subjectName;

          // Internal Marks Cell (0-40, or null if missing)
          const internalTd = document.createElement('td');
          const hasInternal = (sub.internalMarks !== null && sub.internalMarks !== undefined && sub.internalMarks !== '');
          const internalVal = hasInternal ? Number(sub.internalMarks) : null;

          // External Marks Cell (0-60, or null if missing)
          const externalTd = document.createElement('td');
          const hasExternal = (sub.externalMarks !== null && sub.externalMarks !== undefined && sub.externalMarks !== '');
          const externalVal = hasExternal ? Number(sub.externalMarks) : null;

          // Total & Result Status Cells
          const totalTd  = document.createElement('td');
          const statusTd = document.createElement('td');

          if (internalVal === null && externalVal === null) {
            // Neither component entered — missing marks preserved as NULL
            allSubjectsFullyEntered = false;
            internalTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
            externalTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
            totalTd.innerHTML    = `<span class="badge badge-withheld">Not Available</span>`;
            statusTd.innerHTML   = `<span class="badge badge-withheld">Result Pending</span>`;

          } else if (internalVal === null || externalVal === null) {
            // Either component missing — never treat missing marks as zero
            allSubjectsFullyEntered = false;
            if (internalVal === null) {
              internalTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
            } else {
              internalTd.innerHTML = `<strong>${internalVal}</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">/ 40</span>`;
            }
            if (externalVal === null) {
              externalTd.innerHTML = `<span class="badge badge-not-updated">Not Updated</span>`;
            } else {
              externalTd.innerHTML = `<strong>${externalVal}</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">/ 60</span>`;
            }
            totalTd.innerHTML  = `<span class="badge badge-withheld">Not Available</span>`;
            statusTd.innerHTML = `<span class="badge badge-withheld">Result Pending</span>`;

          } else {
            // Both components entered and valid — calculate total out of 100
            fullyEnteredCount++;
            const subjectTotal = internalVal + externalVal;
            totalObtained += subjectTotal;

            internalTd.innerHTML = `<strong>${internalVal}</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">/ 40</span>`;
            externalTd.innerHTML = `<strong>${externalVal}</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">/ 60</span>`;
            totalTd.innerHTML    = `<strong>${subjectTotal}</strong> <span style="color: var(--color-text-secondary); font-size: 0.75rem;">/ 100</span>`;

            // Pass-mark rule: 35 marks or above out of 100 = PASS; below 35 marks = FAIL
            if (subjectTotal >= 35) {
              statusTd.innerHTML = `<span class="badge badge-pass">PASS</span>`;
            } else {
              statusTd.innerHTML = `<span class="badge badge-fail">FAIL</span>`;
              anySubjectFailed = true;
            }
          }

          row.appendChild(codeTd);
          row.appendChild(nameTd);
          row.appendChild(internalTd);
          row.appendChild(externalTd);
          row.appendChild(totalTd);
          row.appendChild(statusTd);
          subjectsTableBody.appendChild(row);
        });

        // Sync flag: only fully entered if all subjects have both components
        if (fullyEnteredCount < subjects.length) {
          allSubjectsFullyEntered = false;
        }
      }
    }

    // Progress Display
    if (progressDisplay) {
      if (allSubjectsFullyEntered && subjects.length > 0) {
        progressDisplay.textContent = `Fully Entered (${subjects.length}/${subjects.length})`;
      } else {
        progressDisplay.textContent = `${fullyEnteredCount} of ${subjects.length} Fully Entered`;
      }
    }

    // Aggregate Result Section
    // Core Rule: Compute Total & Percentage ONLY when ALL subjects have BOTH components.
    if (allSubjectsFullyEntered && subjects.length > 0) {
      const percentage = (totalObtained / totalMaxMarks) * 100;

      if (totalMarksDisplay) {
        totalMarksDisplay.className = 'aggregate-value';
        totalMarksDisplay.textContent = `${totalObtained} / ${totalMaxMarks}`;
      }

      if (percentageDisplay) {
        percentageDisplay.className = 'aggregate-value';
        percentageDisplay.textContent = `${percentage.toFixed(2)}%`;
      }

      if (resultStatusDisplay) {
        resultStatusDisplay.className = 'aggregate-value';
        if (anySubjectFailed) {
          resultStatusDisplay.innerHTML = `<span class="badge badge-fail" style="font-size: 0.9375rem; padding: 6px 12px;">FAIL</span>`;
        } else {
          resultStatusDisplay.innerHTML = `<span class="badge badge-pass" style="font-size: 0.9375rem; padding: 6px 12px;">PASS</span>`;
        }
      }

      if (resultStatusNote) {
        if (anySubjectFailed) {
          resultStatusNote.textContent = 'Result: FAIL (One or more subjects scored below the required passing mark of 35/100).';
        } else {
          resultStatusNote.textContent = 'Result: PASS (All subjects cleared with 35 or more marks out of 100).';
        }
      }

    } else {
      // Incomplete mark entry — Result Pending
      const pendingSubjects = subjects.length - fullyEnteredCount;
      if (totalMarksDisplay) {
        totalMarksDisplay.className = 'aggregate-value withheld';
        totalMarksDisplay.textContent = `Result Pending (${fullyEnteredCount}/${subjects.length} subjects complete)`;
      }

      if (percentageDisplay) {
        percentageDisplay.className = 'aggregate-value withheld';
        percentageDisplay.textContent = 'Result Pending';
      }

      if (resultStatusDisplay) {
        resultStatusDisplay.className = 'aggregate-value withheld';
        resultStatusDisplay.innerHTML = `<span class="badge badge-withheld" style="font-size: 0.9375rem; padding: 6px 12px;">Result Pending</span>`;
      }

      if (resultStatusNote) {
        resultStatusNote.textContent =
          `Result Pending: Aggregate marks and Academic Standing are pending completion of all curricular subject evaluations (${fullyEnteredCount} of ${subjects.length} complete, ${pendingSubjects} pending). ` +
          'Unentered marks are strictly preserved as NULL ("Not Updated") and never treated as zero. ' +
          'Pass-mark rule: 35 marks or above out of 100 = PASS; below 35 = FAIL.';
      }
    }

    // Render AI Analysis for this individual student
    renderAiAnalysis(data.aiSuggestions, subjects);
  }

  /**
   * Renders the AI Analysis section for the student dashboard.
   * Shows individual student performance: subject-wise marks, strong/weak subjects,
   * personalized improvement suggestions, relevant topics, practical recommendations,
   * and overall individual performance summary.
   * Each student sees ONLY their own data — no class-wide details.
   */
  function renderAiAnalysis(suggestions, subjects) {
    const container = document.getElementById('improvementSuggestionsContainer');
    if (!container) return;

    if (!suggestions) {
      container.innerHTML = `
        <div style="padding: 16px; background: #F8F9FA; color: #6C757D; border-radius: 6px; font-size: 0.875rem;">
          No subject marks have been recorded yet. Your individual AI Analysis will appear once your subject marks are entered and validated.
        </div>
      `;
      return;
    }

    const strong = suggestions.strongSubjects || [];
    const weak = suggestions.subjectsNeedingImprovement || [];
    const recs = suggestions.studyRecommendations || [];
    const practical = suggestions.practicalSuggestions || [];

    // --- Individual Performance Summary ---
    let summaryHtml = '';
    if (subjects && subjects.length > 0) {
      let enteredCount = 0;
      let totalScore = 0;
      let passCount = 0;
      let failCount = 0;
      subjects.forEach(sub => {
        const hasI = sub.internalMarks !== null && sub.internalMarks !== undefined && sub.internalMarks !== '';
        const hasE = sub.externalMarks !== null && sub.externalMarks !== undefined && sub.externalMarks !== '';
        if (hasI && hasE) {
          enteredCount++;
          const t = Number(sub.internalMarks) + Number(sub.externalMarks);
          totalScore += t;
          if (t >= 35) passCount++; else failCount++;
        }
      });
      const avgScore = enteredCount > 0 ? (totalScore / enteredCount).toFixed(1) : '—';
      const pct = enteredCount > 0 ? ((totalScore / (enteredCount * 100)) * 100).toFixed(1) : '—';

      summaryHtml = `
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 20px;">
          <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 12px; text-align: center;">
            <div style="font-size: 0.7rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Subjects Evaluated</div>
            <div style="font-size: 1.25rem; font-weight: 800; color: #1E3A5F;">${enteredCount} / ${subjects.length}</div>
          </div>
          <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 12px; text-align: center;">
            <div style="font-size: 0.7rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Average Score</div>
            <div style="font-size: 1.25rem; font-weight: 800; color: #1E3A5F;">${avgScore} <span style="font-size: 0.75rem; color: #6C757D;">/ 100</span></div>
          </div>
          <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 12px; text-align: center;">
            <div style="font-size: 0.7rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Overall Percentage</div>
            <div style="font-size: 1.25rem; font-weight: 800; color: ${Number(pct) >= 60 ? '#2E7D32' : '#C62828'};">${pct}%</div>
          </div>
          <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 8px; padding: 12px; text-align: center;">
            <div style="font-size: 0.7rem; color: #6C757D; text-transform: uppercase; font-weight: 600;">Pass / Fail</div>
            <div style="font-size: 1.125rem; font-weight: 700;">
              <span style="color: #2E7D32;">${passCount} Pass</span> / <span style="color: #C62828;">${failCount} Fail</span>
            </div>
          </div>
        </div>
      `;
    }

    // --- Strong Subjects ---
    let strongHtml = '';
    if (strong.length > 0) {
      strongHtml = `
        <div style="margin-bottom: 20px;">
          <h3 style="font-size: 0.9375rem; font-weight: 700; color: #155724; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#155724" stroke-width="2"><polyline points="20 6 9 17 4 12"></polyline></svg>
            Strong Subjects (${strong.length})
          </h3>
          <div style="display: flex; flex-wrap: wrap; gap: 10px;">
            ${strong.map(s => `
              <div style="background: #E8F5E9; border: 1px solid #C8E6C9; border-radius: 6px; padding: 8px 14px; font-size: 0.8125rem;">
                <strong style="color: #1B5E20;">${escapeHtml(s.subjectCode)} - ${escapeHtml(s.subjectName)}</strong>:
                <span class="badge badge-pass" style="margin-left: 6px;">${s.totalMarks}/100</span>
                <span style="color: #2E7D32; font-size: 0.75rem; display: block; margin-top: 2px;">${escapeHtml(s.note)}</span>
              </div>
            `).join('')}
          </div>
        </div>
      `;
    }

    // --- Weak Subjects Needing Improvement ---
    let weakHtml = '';
    if (weak.length > 0) {
      weakHtml = `
        <div style="margin-bottom: 20px;">
          <h3 style="font-size: 0.9375rem; font-weight: 700; color: #721C24; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#721C24" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line></svg>
            Subjects Needing Improvement (${weak.length})
          </h3>
          <div style="display: flex; flex-direction: column; gap: 12px;">
            ${weak.map(w => `
              <div style="background: #FFF5F5; border: 1px solid #F5C6CB; border-left: 4px solid #DC3545; border-radius: 6px; padding: 12px 16px;">
                <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; margin-bottom: 6px;">
                  <strong style="color: #721C24; font-size: 0.9375rem;">${escapeHtml(w.subjectCode)}: ${escapeHtml(w.subjectName)}</strong>
                  <span class="badge badge-fail">${w.totalMarks !== null ? w.totalMarks + '/100 (FAIL)' : 'Internal: ' + w.internalMarks + '/40'}</span>
                </div>
                <div style="font-size: 0.8125rem; color: #495057; margin-bottom: 6px;">
                  <strong>Identified Issue:</strong> ${escapeHtml(w.reason)}
                </div>
                <div style="font-size: 0.8125rem; color: #1E3A5F; background: #EEF4FB; padding: 8px 12px; border-radius: 4px; margin-bottom: 6px;">
                  <strong>Relevant Topics to Study:</strong> ${escapeHtml(w.relevantTopics)}
                </div>
                <div style="font-size: 0.8125rem; color: #2E7D32;">
                  <strong>Personalized Improvement Suggestion:</strong> ${escapeHtml(w.studyRecommendation)}
                </div>
                <div style="font-size: 0.75rem; color: #6C757D; margin-top: 4px;">
                  <strong>Practical Recommendation:</strong> ${escapeHtml(w.practicalSuggestion)}
                </div>
              </div>
            `).join('')}
          </div>
        </div>
      `;
    } else if (strong.length > 0) {
      weakHtml = `
        <div style="margin-bottom: 18px; padding: 12px 16px; background: #E8F5E9; border-left: 4px solid #2E7D32; border-radius: 6px; font-size: 0.875rem; color: #1B5E20;">
          🎉 <strong>Excellent standing!</strong> You have no subjects currently flagged for academic risk. Keep up your continuous learning!
        </div>
      `;
    }

    // --- General Recommendations & Practical Action Steps ---
    let recsHtml = '';
    if (recs.length > 0 || practical.length > 0) {
      recsHtml = `
        <div style="background: #F8F9FA; border: 1px solid #DEE2E6; border-radius: 6px; padding: 14px 18px;">
          <h4 style="font-size: 0.875rem; font-weight: 700; color: #1E3A5F; margin-bottom: 8px;">
            Personalized Study Recommendations &amp; Practical Action Steps
          </h4>
          <ul style="margin: 0; padding-left: 20px; font-size: 0.8125rem; color: #333; line-height: 1.6;">
            ${recs.map(r => `<li>${escapeHtml(r)}</li>`).join('')}
            ${practical.map(p => `<li>${escapeHtml(p)}</li>`).join('')}
          </ul>
          <div style="margin-top: 8px; font-size: 0.75rem; color: #6C757D;">
            Intelligence Engine: <strong>${escapeHtml(suggestions.aiSource || 'Institutional Academic Advisor')}</strong>
          </div>
        </div>
      `;
    }

    container.innerHTML = `
      ${summaryHtml}
      ${strongHtml}
      ${weakHtml}
      ${recsHtml}
    `;
  }
});
