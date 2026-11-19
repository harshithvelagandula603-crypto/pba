/**
 * Academic Result Input Validator - Authentication Form Controller
 * Manages role switching (Student vs Faculty), passwordless Student ID access,
 * registered email faculty authentication, and strict fresh input enforcement
 * without browser autocomplete or cached suggestion leakage.
 */

document.addEventListener('DOMContentLoaded', () => {
  const roleTabStudent = document.getElementById('roleTabStudent');
  const roleTabFaculty = document.getElementById('roleTabFaculty');
  const roleInput = document.getElementById('roleInput');
  const identifierLabel = document.getElementById('identifierLabel');
  const identifierInput = document.getElementById('identifierInput');
  const identifierError = document.getElementById('identifierError');
  const emailGroup = document.getElementById('emailGroup');
  const emailInput = document.getElementById('emailInput');
  const emailError = document.getElementById('emailError');
  const loginForm = document.getElementById('loginForm');
  const submitBtn = document.getElementById('submitBtn');
  const submitBtnText = document.getElementById('submitBtnText');
  const authFeedback = document.getElementById('authFeedback');
  const authFeedbackText = document.getElementById('authFeedbackText');
  const securityNotice = document.getElementById('securityNotice');

  // Role Configuration Dictionary
  const roles = {
    student: {
      name: 'Student',
      label: 'Student ID',
      placeholder: '',
      buttonText: 'Access Student Dashboard',
      emptyIdentifierMsg: 'Please enter your valid Student ID.'
    },
    faculty: {
      name: 'Faculty',
      label: 'Faculty ID',
      placeholder: '',
      buttonText: 'Sign In as Faculty',
      emptyIdentifierMsg: 'Please enter your registered Faculty ID.'
    }
  };

  let currentRole = 'student';

  // Helper to ensure input fields are always blank and free of suggestions
  function clearAllInputs() {
    if (loginForm) {
      try { loginForm.reset(); } catch (e) {}
    }
    if (identifierInput) {
      identifierInput.value = '';
      identifierInput.defaultValue = '';
      identifierInput.setAttribute('autocomplete', 'off');
    }
    if (emailInput) {
      emailInput.value = '';
      emailInput.defaultValue = '';
      emailInput.setAttribute('autocomplete', 'off');
    }
  }

  // Clear validation error visual states
  function clearErrors() {
    if (identifierInput) identifierInput.classList.remove('has-error');
    if (emailInput) emailInput.classList.remove('has-error');
    if (identifierError) {
      identifierError.classList.remove('visible');
      identifierError.textContent = '';
    }
    if (emailError) {
      emailError.classList.remove('visible');
      emailError.textContent = '';
    }
  }

  // Clear feedback banner
  function clearFeedback() {
    if (authFeedback) {
      authFeedback.className = 'auth-feedback-box';
      authFeedback.style.display = 'none';
      if (authFeedbackText) authFeedbackText.textContent = '';
    }
  }

  // Display feedback message
  function showFeedback(type, message) {
    if (!authFeedback || !authFeedbackText) return;
    authFeedback.className = `auth-feedback-box ${type}`;
    authFeedbackText.textContent = message;
    authFeedback.style.display = 'flex';
  }

  // Switch role between Student and Faculty
  function setRole(roleName) {
    if (!roles[roleName]) roleName = 'student';
    currentRole = roleName;
    if (roleInput) roleInput.value = roleName;

    // Requirement: Fields must be empty each time user opens or switches login mode
    clearAllInputs();
    clearErrors();
    clearFeedback();

    if (roleName === 'student') {
      if (roleTabStudent) {
        roleTabStudent.classList.add('active');
        roleTabStudent.setAttribute('aria-selected', 'true');
      }
      if (roleTabFaculty) {
        roleTabFaculty.classList.remove('active');
        roleTabFaculty.setAttribute('aria-selected', 'false');
      }

      // Requirement: Remove email field for students (Student ID only)
      if (emailGroup) {
        emailGroup.style.display = 'none';
      }
      if (emailInput) {
        emailInput.value = '';
        emailInput.required = false;
      }
      if (securityNotice) {
        securityNotice.textContent = 'Demonstration Mode: Student ID-only access is configured for demonstration purposes. In a real college deployment, secure credential authentication is required.';
      }
    } else {
      if (roleTabFaculty) {
        roleTabFaculty.classList.add('active');
        roleTabFaculty.setAttribute('aria-selected', 'true');
      }
      if (roleTabStudent) {
        roleTabStudent.classList.remove('active');
        roleTabStudent.setAttribute('aria-selected', 'false');
      }

      // Requirement: Faculty authentication requires registered email address
      if (emailGroup) {
        emailGroup.style.display = 'block';
      }
      if (emailInput) {
        emailInput.value = '';
        emailInput.required = true;
      }
      if (securityNotice) {
        securityNotice.textContent = 'Faculty access is verified against institutional records using your registered Faculty ID and institutional email address.';
      }
    }

    if (identifierLabel) identifierLabel.textContent = roles[roleName].label;
    if (identifierInput) identifierInput.placeholder = roles[roleName].placeholder;
    if (submitBtnText) submitBtnText.textContent = roles[roleName].buttonText;
  }

  // Parse URL search parameters for pre-selected role
  const urlParams = new URLSearchParams(window.location.search);
  const initialRole = urlParams.get('role');
  if (initialRole === 'faculty') {
    setRole('faculty');
  } else {
    setRole('student');
  }

  // Role Switch Event Listeners
  if (roleTabStudent) {
    roleTabStudent.addEventListener('click', () => setRole('student'));
  }
  if (roleTabFaculty) {
    roleTabFaculty.addEventListener('click', () => setRole('faculty'));
  }

  // Clear stale session & wipe any browser-suggested values on page load
  sessionStorage.removeItem('academic_session');
  clearAllInputs();
  clearErrors();
  clearFeedback();

  // Neutralize delayed browser autofill attempts
  setTimeout(clearAllInputs, 50);
  setTimeout(clearAllInputs, 200);

  // Input listeners to clear error visual indicators as user types
  if (identifierInput) {
    identifierInput.addEventListener('input', () => {
      identifierInput.classList.remove('has-error');
      if (identifierError) identifierError.classList.remove('visible');
    });
  }

  if (emailInput) {
    emailInput.addEventListener('input', () => {
      emailInput.classList.remove('has-error');
      if (emailError) emailError.classList.remove('visible');
    });
  }

  // Form Submission Handler
  if (loginForm) {
    loginForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      clearErrors();
      clearFeedback();

      const rawIdentifier = identifierInput ? identifierInput.value.trim() : '';
      let hasError = false;

      // Validate Identifier
      if (!rawIdentifier) {
        if (identifierInput) identifierInput.classList.add('has-error');
        if (identifierError) {
          identifierError.textContent = roles[currentRole].emptyIdentifierMsg;
          identifierError.classList.add('visible');
        }
        hasError = true;
      }

      // Validate Email when role is FACULTY
      let rawEmail = '';
      if (currentRole === 'faculty') {
        rawEmail = emailInput ? emailInput.value.trim() : '';
        if (!rawEmail) {
          if (emailInput) emailInput.classList.add('has-error');
          if (emailError) {
            emailError.textContent = 'Please enter your registered institutional email address.';
            emailError.classList.add('visible');
          }
          hasError = true;
        }
      }

      if (hasError) return;

      // Disable button while verifying
      submitBtn.disabled = true;
      const originalText = submitBtnText.textContent;
      submitBtnText.textContent = 'Verifying with Server...';

      try {
        if (currentRole === 'student') {
          // Requirement: Check Student ID against database via server API
          const response = await fetch('/api/auth/student', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ studentId: rawIdentifier })
          });

          const data = await response.json().catch(() => ({}));

          if (response.ok && data.success) {
            // Store session token in sessionStorage
            sessionStorage.setItem('academic_session', JSON.stringify(data.session));
            showFeedback('info', `Verified Student ID: ${data.session.studentName} (${data.session.studentId}). Redirecting to dashboard...`);
            setTimeout(() => {
              window.location.href = 'student-dashboard.html';
            }, 400);
          } else {
            submitBtn.disabled = false;
            submitBtnText.textContent = originalText;
            if (identifierInput) identifierInput.classList.add('has-error');
            const err = data.error || `Invalid Student ID '${rawIdentifier}'. No matching student record found in institutional records.`;
            showFeedback('error', err);
          }
        } else {
          // Faculty Authentication using authenticated Faculty ID & Registered Email Address
          const response = await fetch('/api/auth/faculty', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ facultyId: rawIdentifier, email: rawEmail })
          });

          const data = await response.json().catch(() => ({}));

          if (response.ok && data.success) {
            sessionStorage.setItem('academic_session', JSON.stringify(data.session));
            showFeedback('info', `Authentication successful for Faculty ID: ${data.session.facultyId || data.session.username}. Redirecting to dashboard...`);
            setTimeout(() => {
              window.location.href = 'faculty-dashboard.html';
            }, 400);
          } else {
            submitBtn.disabled = false;
            submitBtnText.textContent = originalText;
            if (response.status === 401 && data.error && data.error.includes('email address')) {
              if (emailInput) emailInput.classList.add('has-error');
            } else {
              if (identifierInput) identifierInput.classList.add('has-error');
            }
            const err = data.error || 'Authentication failed. Please verify your faculty ID and registered email address.';
            showFeedback('error', err);
          }
        }
      } catch (err) {
        submitBtn.disabled = false;
        submitBtnText.textContent = originalText;
        showFeedback('error', 'Unable to reach the server. Please verify that server.ps1 is running.');
      }
    });
  }
});

// Enforce blank inputs and fresh state on pageshow (e.g. Browser Back Button / bfcache / Logout return)
window.addEventListener('pageshow', () => {
  const loginForm = document.getElementById('loginForm');
  const identifierInput = document.getElementById('identifierInput');
  const emailInput = document.getElementById('emailInput');
  const authFeedback = document.getElementById('authFeedback');
  const authFeedbackText = document.getElementById('authFeedbackText');

  sessionStorage.removeItem('academic_session');

  if (loginForm) {
    try { loginForm.reset(); } catch (e) {}
  }
  if (identifierInput) {
    identifierInput.value = '';
    identifierInput.defaultValue = '';
    identifierInput.setAttribute('autocomplete', 'off');
    identifierInput.classList.remove('has-error');
  }
  if (emailInput) {
    emailInput.value = '';
    emailInput.defaultValue = '';
    emailInput.setAttribute('autocomplete', 'off');
    emailInput.classList.remove('has-error');
  }
  if (authFeedback) {
    authFeedback.className = 'auth-feedback-box';
    authFeedback.style.display = 'none';
    if (authFeedbackText) authFeedbackText.textContent = '';
  }
});
