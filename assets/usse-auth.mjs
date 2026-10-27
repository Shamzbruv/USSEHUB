// Authentication actions stay separate from directory and advertising records.
export const PASSWORD_MIN_LENGTH = 8;
export function passwordProblem(password) {
  if (password.length < PASSWORD_MIN_LENGTH) return `Use at least ${PASSWORD_MIN_LENGTH} characters for your password.`;
  if (!/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/[0-9]/.test(password) || !/[!@#$%^&*()_+\-=\[\]{};\\':"|<>?,./`~]/.test(password)) {
    return 'Include an uppercase letter, a lowercase letter, a number and a symbol.';
  }
  return '';
}
export function authErrorMessage(error, fallback = 'We could not complete that request. Please try again.') {
  const code = String(error?.code || '');
  const message = String(error?.message || '');
  if (/email_not_confirmed/.test(code) || /email not confirmed/i.test(message)) return 'Confirm your email address before signing in. You can request another confirmation email below.';
  if (/over_email_send_rate_limit|over_request_rate_limit/.test(code) || /rate limit|too many requests/i.test(message)) return 'Please wait a minute before trying again. Too many requests were made recently.';
  if (/smtp|sending.*(?:confirmation|recovery|email)|email.*(?:delivery|send)|authentication credentials invalid/i.test(message)) return 'We could not send the account email. Please try again shortly or contact USSE at info@ussehub.com. Your password has not been changed.';
  if (/invalid_credentials/.test(code)) return 'The email or password is incorrect. Check your details or use Forgot Password.';
  if (/otp_expired|flow_state_expired|flow_state_not_found/.test(code)) return 'This account link has expired or was already used. Request a new email and open its latest link.';
  if (/weak_password/.test(code)) return 'Use a stronger password with uppercase and lowercase letters, a number and a symbol.';
  if (/fetch|network|timeout/i.test(message)) return 'The connection was interrupted. Check your connection and try again.';
  return fallback;
}
export function authRedirectURL(origin, action) {
  const url = new URL('/ajm-advertising-hub', origin);
  url.searchParams.set('auth', action === 'recovery' ? 'recovery' : 'confirmed');
  return url.href;
}
// Auth callbacks must return immediately: awaiting a Supabase request inside one
// can hold the auth lock and stop all later database requests on that client.
export function deferAuthChanges(client, callback, onError, defer = fn => setTimeout(fn, 0)) {
  return client.auth.onAuthStateChange((event, session) => {
    defer(() => Promise.resolve().then(() => callback(event, session)).catch(onError));
  });
}
export function createAuthUI({client, onSignedIn, onSignedOut, showToast, openModal, closeModal, document: doc = document, location: loc = location, history: hist = history}) {
  const el = id => doc.getElementById(id);
  const initialLinkError = new URLSearchParams(loc.hash.slice(1)).get('error_code') || new URL(loc.href).searchParams.get('error_code');
  let recoveryActive = false;
  let recoveryRequested = new URL(loc.href).searchParams.get('auth') === 'recovery' || new URLSearchParams(loc.hash.slice(1)).get('type') === 'recovery';
  let hydratedUserId = null, hydratingId = null, hydration = null, generation = 0, resendAfter = 0;
  function show(box, message) { box.textContent = message; box.classList.add('show'); }
  function clear(...ids) { ids.forEach(id => { el(id).textContent = ''; el(id).classList.remove('show'); }); }
  function cleanLink() {
    const url = new URL(loc.href);
    for (const key of ['auth','code','token_hash','type','error','error_code','error_description']) url.searchParams.delete(key);
    url.hash = '';
    hist.replaceState(null, '', url.pathname + url.search);
  }
  function confirmationFor(email) {
    el('auth-confirmation-tools').hidden = false;
    el('confirmation-email').value = email;
  }
  function emailValue(id) {
    const input = el(id), email = input.value.trim();
    if (!email || !input.checkValidity()) throw new Error('Enter a valid email address.');
    return email;
  }
  const statuses = {
    'modal-login': {error:'login-error',spinner:'login-spinner'},
    'modal-reg': {error:'register-error',spinner:'reg-spinner'},
    'modal-forgot': {error:'forgot-error',spinner:'forgot-spinner'}
  };
  async function action(prefix, callback) {
    const button = el(prefix + '-btn');
    if (button.disabled) return;
    const status = statuses[prefix] || {error:prefix + '-error',spinner:prefix + '-spinner'};
    const error = el(status.error);
    if (error) { error.textContent = ''; error.classList.remove('show'); }
    button.disabled = true; button.setAttribute('aria-busy','true');
    el(status.spinner)?.classList.add('show');
    try { await callback(); }
    catch (err) { show(error, err.uiMessage || authErrorMessage(err)); }
    finally { button.disabled = false; button.removeAttribute('aria-busy'); el(status.spinner)?.classList.remove('show'); }
  }
  function validation(message) { return Object.assign(new Error(message), {uiMessage:message}); }
  function getEmail(id) { try { return emailValue(id); } catch (error) { throw validation(error.message); } }
  async function hydrate(user) {
    if (hydratedUserId === user.id) return;
    if (hydratingId === user.id && hydration) return hydration;
    const expected = generation;
    hydratingId = user.id;
    hydration = Promise.resolve(onSignedIn(user, () => generation === expected)).then(() => { if (generation === expected) hydratedUserId = user.id; }).finally(() => { if (generation === expected) { hydration = null; hydratingId = null; } });
    return hydration;
  }
  async function sessionChanged(event, session) {
    if (!session?.user) {
      generation++; hydratedUserId = null; hydration = null; hydratingId = null;
      recoveryActive = false;
      await onSignedOut();
      return;
    }
    await hydrate(session.user);
    if (event === 'PASSWORD_RECOVERY' || recoveryRequested) {
      recoveryRequested = false; recoveryActive = true;
      doc.querySelector('.auth-tabs').hidden = true;
      for (const tab of ['login','register','forgot']) el('auth-panel-' + tab).style.display = 'none';
      el('auth-panel-reset').style.display = 'block';
      el('auth-confirmation-tools').hidden = true;
      openModal('auth-modal'); el('modal-reset-password').focus(); cleanLink();
    } else if (new URL(loc.href).searchParams.get('auth') === 'confirmed') cleanLink();
  }
  const ui = {
    login: () => action('modal-login', async () => {
      const email = getEmail('modal-login-email'), password = el('modal-login-password').value;
      if (!password) throw validation('Enter your password.');
      const {error} = await client.auth.signInWithPassword({email,password});
      if (error) { if (error.code === 'email_not_confirmed' || /email not confirmed/i.test(error.message)) confirmationFor(email); throw error; }
      el('modal-login-password').value = '';
      showToast('Welcome back! You are now signed in.','success');
    }),
    sidebarLogin: () => action('sidebar-login', async () => {
      const email = getEmail('sidebar-email'), password = el('sidebar-password').value;
      if (!password) throw validation('Enter your password.');
      const {error} = await client.auth.signInWithPassword({email,password});
      if (error) throw error;
      el('sidebar-password').value = ''; showToast('Welcome back! You are now signed in.','success');
    }),
    register: () => action('modal-reg', async () => {
      clear('register-error','register-success');
      const name = el('modal-reg-name').value.trim(), email = getEmail('modal-reg-email');
      const password = el('modal-reg-password').value, confirm = el('modal-reg-password-confirm').value;
      if (!name) throw validation('Enter your full name.');
      if (password !== confirm) throw validation('Passwords do not match.');
      const problem = passwordProblem(password); if (problem) throw validation(problem);
      const {data,error} = await client.auth.signUp({email,password,options:{data:{full_name:name},emailRedirectTo:authRedirectURL(loc.origin,'confirmed')}});
      if (error) throw error;
      if (!data?.user) throw validation('The account was not confirmed as created. Please try again.');
      el('modal-reg-password').value = ''; el('modal-reg-password-confirm').value = '';
      if (data.session) showToast('Your account is ready. You are now signed in.','success');
      else { show(el('register-success'),'Check your inbox and spam folder for the confirmation email, then open its link to finish registration. If you already have an account, sign in or reset your password.'); confirmationFor(email); }
    }),
    forgot: () => action('modal-forgot', async () => {
      clear('forgot-error','forgot-success');
      const email = getEmail('modal-forgot-email');
      const {error} = await client.auth.resetPasswordForEmail(email,{redirectTo:authRedirectURL(loc.origin,'recovery')});
      if (error) throw error;
      show(el('forgot-success'),'If an account uses this address, a reset link will arrive shortly. Check your inbox and spam folder and open the latest email.');
    }),
    resend: () => action('confirmation', async () => {
      clear('confirmation-error','confirmation-success');
      if (Date.now() < resendAfter) throw validation('Please wait a minute before requesting another confirmation email.');
      const email = getEmail('confirmation-email');
      const {error} = await client.auth.resend({type:'signup',email,options:{emailRedirectTo:authRedirectURL(loc.origin,'confirmed')}});
      if (error) throw error;
      resendAfter = Date.now() + 60_000;
      show(el('confirmation-success'),'If confirmation is still needed, a new email will arrive shortly. Check your inbox and spam folder.');
    }),
    reset: () => action('reset', async () => {
      clear('reset-error','reset-success');
      if (!recoveryActive) throw validation('Open the latest password-reset email before choosing a new password.');
      const password = el('modal-reset-password').value, confirm = el('modal-reset-confirm').value;
      if (password !== confirm) throw validation('Passwords do not match.');
      const problem = passwordProblem(password); if (problem) throw validation(problem);
      const {error} = await client.auth.updateUser({password}); if (error) throw error;
      recoveryActive = false; el('modal-reset-password').value = ''; el('modal-reset-confirm').value = '';
      el('auth-panel-reset').style.display = 'none'; doc.querySelector('.auth-tabs').hidden = false;
      el('auth-panel-login').style.display = 'block'; closeModal('auth-modal'); cleanLink();
      showToast('Your password has been updated.','success');
    }),
    logout: async () => {
      try { const {error} = await client.auth.signOut(); if (error) throw error; showToast('You have been signed out.','info'); }
      catch (error) { showToast(authErrorMessage(error,'Sign out could not be completed. Please try again.'),'error'); }
    },
    init: async () => {
      // Prefixes differ from legacy spinner IDs; keep one action status source.
      deferAuthChanges(client, sessionChanged, error => showToast(authErrorMessage(error,'Your account details could not be loaded. Please refresh and sign in again.'),'error'));
      for (const [panel,handler] of [['login',ui.login],['register',ui.register],['forgot',ui.forgot],['reset',ui.reset]]) {
        el('auth-panel-' + panel).addEventListener('keydown', event => { if (event.key === 'Enter' && event.target.matches('input')) { event.preventDefault(); handler(); } });
      }
      try {
        const {data,error} = await client.auth.getSession(); if (error) throw error;
        if (data?.session?.user) await sessionChanged('INITIAL_SESSION',data.session);
        const linkError = initialLinkError || new URLSearchParams(loc.hash.slice(1)).get('error_code') || new URL(loc.href).searchParams.get('error_code');
        if (linkError || recoveryRequested && !data?.session) {
          doc.querySelector('.auth-tabs').hidden = false; el('auth-panel-forgot').style.display = 'block'; el('auth-panel-login').style.display = 'none';
          show(el('forgot-error'),'This account link is invalid or has expired. Request a new email and open its latest link.'); openModal('auth-modal'); cleanLink();
        }
      } catch (error) { showToast(authErrorMessage(error,'Your session could not be restored. Please sign in again.'),'error'); }
    }
  };
  return ui;
}
