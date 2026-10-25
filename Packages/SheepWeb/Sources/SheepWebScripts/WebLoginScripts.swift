import Foundation

/// The login-field rules both apps run in a page (5.0 (53)): which field is the user name, which
/// is the password, when a login was really sent, and how a saved login goes in. SheepTerm's
/// hardening (the user's own events only, autofill bait off the page, the "show password" eye)
/// with the browser-style field rules (a field that SAYS it is the user name, form scope, the first
/// step of a two-step sign-in, sign-up / change-password forms).
///
/// Foundation only, no localisation: SheepTerm's `WebTabs.swift` (compiled on Windows too, where
/// this file is added to the shared list) re-exports these as `WebLoginKey.script` /
/// `WebFillLogin.script`.
///
/// Both scripts run in the APP's own `WKContentWorld` — never the page world — so the page's
/// scripts can neither see their globals nor post to the handler.
public nonisolated enum WebLoginScripts {
    /// The page script (document end, main frame), posting to `handler`:
    /// - `{k:'fields', boxes:[{x,y,w,h}]}` — the field a key belongs in (CSS px from the page's
    ///   top-left; [] = no login form), again whenever it moves (SheepTerm's key).
    /// - `{k:'focus', rect:[x,y,w,h], newPassword}` / `{k:'blur'}` — the user put the caret in a login
    ///   field / left it (a list-style app). Only for the user's own focus.
    /// - `{k:'user', user}` — the first step of a two-step sign-in was sent with this user name.
    /// - `{k:'submit', user, pass}` — a login form the user TYPED into was sent.
    /// Globals in that world: `__sheepLoginCheck()` (a visible password field is on the page),
    /// `__sheepLoginReport()` (report the field again).
    public static func pageScript(handler: String) -> String {
        pageTemplate.replacingOccurrences(of: "__HANDLER__", with: handler)
    }

    private static let pageTemplate = """
    (() => {
      if (window.__sheepLogin) return;
      window.__sheepLogin = true;
      const post = (m) => { try { window.webkit.messageHandlers.__HANDLER__.postMessage(m); } catch (e) {} };
      // Visible = laid out, not hidden, not transparent, and not parked off
      // the page (the "left:-9999px" autofill bait many login pages carry).
      const visible = (el) => {
        if (!el || el.disabled || el.readOnly) return false;
        const r = el.getBoundingClientRect(), s = window.getComputedStyle(el);
        if (r.width <= 0 || r.height <= 0 || s.visibility === 'hidden' || s.display === 'none' || s.opacity === '0') return false;
        return r.right + window.scrollX > 0 && r.bottom + window.scrollY > 0;
      };
      const userType = (el) => ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase());
      // A field that says it is the user name / e-mail (autocomplete, type, name/id/placeholder/label).
      // Never a search box.
      const userish = (el) => {
        if (!(el instanceof HTMLInputElement) || !userType(el) || !visible(el)) return false;
        if (el.closest('[role=search], search')) return false;
        const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (ac.includes('username') || ac === 'email' || (el.getAttribute('type') || '').toLowerCase() === 'email') return true;
        const hint = [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label')].join(' ');
        return /user|login|logon|e-?mail|account|identifier|signin/i.test(hint) && !/search|query/i.test(hint);
      };
      // The user's own events only. The harness cannot make trusted events,
      // so it sets __sheepLoginTestTrust — a global of THIS world, which the
      // page cannot reach.
      const trusted = (e) => e.isTrusted || window.__sheepLoginTestTrust === true;
      // Password fields — including one the page's "show password" eye has
      // turned into type=text for a moment: it is still the login's field.
      const seenPassword = new Set();
      const passwordFields = () => {
        for (const el of document.querySelectorAll('input[type=password]')) seenPassword.add(el);
        for (const el of Array.from(seenPassword)) if (!el.isConnected) seenPassword.delete(el);
        return Array.from(document.querySelectorAll('input')).filter((el) => seenPassword.has(el) && visible(el));
      };
      const pageHasPassword = () => passwordFields().length > 0;
      // Same form, or — no form — neither in one.
      const together = (a, b) => (b.form ? a.form === b.form : !a.form);
      // The first step of a two-step sign-in (no password field yet) is stricter than `userish`: the
      // field must say it is a LOGIN name (autocomplete=username, or user/login/identifier/account in
      // its name or id) — a newsletter "Email" box is not one (review 5.0 (53) #7).
      const stepUserish = (el) => {
        if (!userish(el)) return false;
        if ((el.getAttribute('autocomplete') || '').toLowerCase().includes('username')) return true;
        return /user|login|logon|identifier|signin|account/i.test([el.name, el.id].join(' '));
      };
      // That field — in `form` when one is given and has it.
      const stepUser = (form) => {
        const all = Array.from(document.querySelectorAll('input')).filter(stepUserish);
        return (form && all.find((el) => el.form === form)) || all[0] || null;
      };
      // The login form: the first visible password field (in `form` when one is given and has
      // one — the form the user is sending, review 5.0 (53) #3), and the user field before it
      // that belongs with it — the last one that says it is the user name, else the last visible
      // text/email field: never a search box elsewhere on the page. No password field: the
      // first step's user field.
      const loginFields = (form) => {
        const all = passwordFields();
        const pw = (form && all.find((el) => el.form === form)) || all[0];
        if (!pw) { const u = stepUser(form); return u ? [u] : []; }
        let named = null, plain = null;
        for (const el of Array.from(document.querySelectorAll('input'))) {
          if (el === pw) break;
          if (!userType(el) || !visible(el) || !together(el, pw)) continue;
          plain = el;
          if (userish(el)) named = el;
        }
        const user = named || plain;
        return user ? [user, pw] : [pw];
      };
      // A sign-up or change-password form: "new-password", or two password fields in one form.
      const isNewPassword = (el) => {
        if (!seenPassword.has(el)) return false;
        if ((el.getAttribute('autocomplete') || '').includes('new-password')) return true;
        return passwordFields().filter((p) => together(p, el)).length >= 2;
      };
      // The key goes where Safari puts it: the user field, else the
      // password field when the form has no user field.
      let last = '', timer = 0;
      const report = () => {
        timer = 0;
        const field = loginFields()[0];
        const boxes = field ? [field].map((el) => { const r = el.getBoundingClientRect(); return {x: r.left, y: r.top, w: r.width, h: r.height}; }) : [];
        const key = JSON.stringify(boxes);
        if (key === last) return;
        last = key;
        post({k: 'fields', boxes: boxes});
      };
      // A short timer, not requestAnimationFrame: rAF stops in a page that
      // is not on screen, and the key must be right when it comes back.
      const again = () => { if (!timer) timer = setTimeout(report, 50); };
      window.addEventListener('scroll', again, true);
      window.addEventListener('resize', again);
      document.addEventListener('focusin', again, true);
      // Back/forward cache: the scripts do not run again, the page does.
      window.addEventListener('pageshow', () => { last = ''; again(); });
      new MutationObserver(again).observe(document.documentElement, {childList: true, subtree: true, attributes: true});
      window.__sheepLoginReport = () => { last = ''; report(); };
      report();
      // The caret in a login field (a list-style app): only the user's own focus — a
      // click or Tab — and never while a saved login is being put in (`__sheepFilling`).
      const qualifies = (el) => el instanceof HTMLInputElement && (seenPassword.has(el) || userish(el) || loginFields().includes(el));
      const byUser = () => !navigator.userActivation || navigator.userActivation.isActive;
      let focused = null;
      const focusReport = (el) => {
        const r = el.getBoundingClientRect();
        post({k: 'focus', rect: [r.left, r.top, r.width, r.height], newPassword: isNewPassword(el)});
      };
      document.addEventListener('focusin', (e) => {
        if (window.__sheepFilling || !qualifies(e.target)) return;
        focused = e.target;
        if (byUser() || window.__sheepLoginTestTrust === true) focusReport(e.target);
      }, true);
      // A field the page focused itself (autofocus) shows the list when the user clicks it.
      document.addEventListener('pointerdown', (e) => {
        if (trusted(e) && e.target === focused && qualifies(e.target)) focusReport(e.target);
      }, true);
      document.addEventListener('focusout', () => {
        if (window.__sheepFilling || !focused) return;
        focused = null;
        post({k: 'blur'});
      }, true);
      window.addEventListener('scroll', () => { if (focused) post({k: 'blur'}); }, true);
      // What the USER typed, per field (trusted input only): a value the page
      // set itself — or our own fill — is never "typed".
      const typed = new WeakMap();
      // The user name last typed, per form (a newsletter box never names another form's login).
      const typedUsers = new Map();
      const formKey = (el) => (el && el.form) || document;
      document.addEventListener('input', (e) => {
        if (!trusted(e) || !(e.target instanceof HTMLInputElement)) return;
        if (e.target.type === 'password') seenPassword.add(e.target);
        if (seenPassword.has(e.target) || userType(e.target)) typed.set(e.target, e.target.value);
        if (userish(e.target) && e.target.value) typedUsers.set(formKey(e.target), e.target.value);
      }, true);
      // A user name the app put in from a saved login (`fillScript`, this world only): it may name the
      // login — never stand for a typed password (review 5.0 (53) #4).
      const filledUser = (value) => !!value && window.__sheepFilledUser === value;
      let sent = null;
      // The first step of a two-step sign-in was sent: its user name, so the password
      // step (which often shows none) can be saved with it.
      let sentUser = '';
      const captureUser = (form) => {
        if (pageHasPassword()) return;
        const u = stepUser(form);
        if (!u || !u.value || (typed.get(u) !== u.value && !filledUser(u.value)) || u.value === sentUser) return;
        sentUser = u.value;
        post({k: 'user', user: u.value});
      };
      const capture = (form) => {
        captureUser(form);
        const fields = loginFields(form);
        const pw = fields[fields.length - 1];
        // On the user step loginFields() is that one user field: never sent as a password.
        if (!pw || !seenPassword.has(pw) || !pw.value || typed.get(pw) !== pw.value) return;
        // The user field — or, on a two-step login, the read-only one that
        // shows the user chosen on the step before — or the user name typed
        // earlier on this page.
        let user = fields.length > 1 ? fields[0].value : '';
        if (!user) {
          for (const el of Array.from(document.querySelectorAll('input'))) {
            if (el === pw) break;
            if (userType(el) && el.readOnly && el.value && together(el, pw)) user = el.value;
          }
        }
        if (!user) user = typedUsers.get(formKey(pw)) || window.__sheepFilledUser || '';
        // A click on Submit and the form's own submit event are one login.
        if (sent && sent.user === user && sent.pass === pw.value && Date.now() - sent.at < 1000) return;
        sent = {user: user, pass: pw.value, at: Date.now()};
        post({k: 'submit', user: user, pass: pw.value});
      };
      // Only the user's own actions, and only on THIS login form.
      document.addEventListener('submit', (e) => {
        const pw = loginFields(e.target).slice(-1)[0];
        if (trusted(e) && pw && e.target === pw.form) capture(e.target);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (!trusted(e) || e.key !== 'Enter' || !(e.target instanceof HTMLInputElement)) return;
        const form = e.target.form || null;
        if (loginFields(form).includes(e.target)) capture(form);
      }, true);
      document.addEventListener('click', (e) => {
        if (!trusted(e) || !e.target || !e.target.closest) return;
        const b = e.target.closest('button, input[type=submit], input[type=image], [role=button]');
        if (!b) return;
        const form = b.form || b.closest('form') || null;
        const pw = loginFields(form).slice(-1)[0];
        if (!pw) return;
        // Any button of this login form (an AJAX login is often type=button);
        // formless: a button after the password field. A "show password" eye
        // may post too — harmless: the field it reveals still counts as the
        // login form, so nothing is offered unless the form really goes.
        const ofForm = pw.form ? (b.form === pw.form || pw.form.contains(b)) : (pw.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
        if (ofForm) capture(form);
      }, true);
      window.__sheepLoginCheck = () => pageHasPassword();
      // For `newPasswordFillScript` (same world only): a password the app generated for the user
      // counts as typed, so the form's submit still reports the login with its user name.
      window.__sheepMarkTyped = (el) => { if (el instanceof HTMLInputElement) { seenPassword.add(el); typed.set(el, el.value); } };
    })();
    """

    /// Puts a saved login in — never submits. Run with `callAsyncJavaScript` in the app's own
    /// world (the page script's: its focus report stays quiet meanwhile); `user`, `pass` and
    /// `expected` ({protocol, hostname, port} — `expectedOrigin`) arrive as arguments, never
    /// spliced into the source. The document's own `location` must be `expected` ("other-origin").
    /// The password field: the first visible one in the focused field's form, else on the page;
    /// the user field: the one before it that says it is the user name, else the last visible
    /// text/email field before it — or, with no password field (a two-step sign-in's first step),
    /// the focused field if it is a user name, else the first field that says it is one.
    /// Values go in with the native setter (frameworks that track `value` see a change) plus
    /// input + change. Returns "filled", "user-only" or "none".
    public static let fillScript = """
    const here = (() => {
      let h = location.hostname.toLowerCase();
      if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
      if (h.endsWith('.')) h = h.slice(0, -1);
      const p = location.port || (location.protocol === 'https:' ? '443' : location.protocol === 'http:' ? '80' : '');
      return { protocol: location.protocol, hostname: h, port: p };
    })();
    if (here.protocol !== expected.protocol || here.hostname !== expected.hostname || here.port !== expected.port) {
      return 'other-origin';
    }
    const visible = (el) => {
      if (el.disabled || el.readOnly) return false;
      const r = el.getBoundingClientRect();
      const s = window.getComputedStyle(el);
      // Not the off-page autofill bait ("left:-9999px").
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'
        && r.right + window.scrollX > 0 && r.bottom + window.scrollY > 0;
    };
    const isUserField = (el) => ['text', 'email', 'tel', ''].includes((el.getAttribute('type') || '').toLowerCase()) && visible(el);
    const userish = (el) => {
      if (!isUserField(el) || el.closest('[role=search], search')) return false;
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      if (ac.includes('username') || ac === 'email' || (el.getAttribute('type') || '').toLowerCase() === 'email') return true;
      const hint = [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label')].join(' ');
      return /user|login|logon|e-?mail|account|identifier|signin/i.test(hint) && !/search|query/i.test(hint);
    };
    const stepUserish = (el) => userish(el) && ((el.getAttribute('autocomplete') || '').toLowerCase().includes('username')
      || /user|login|logon|identifier|signin|account/i.test([el.name, el.id].join(' ')));
    const inputs = Array.from(document.querySelectorAll('input'));
    const anchor = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
    const passwords = inputs.filter((el) => el.type === 'password' && visible(el));
    const pwField = (anchor && anchor.form && passwords.find((el) => el.form === anchor.form)) || passwords[0] || null;
    let userField = null;
    if (pwField) {
      let named = null, plain = null;
      for (const el of inputs) {
        if (el === pwField) break;
        if (!isUserField(el) || (pwField.form ? el.form !== pwField.form : !!el.form)) continue;
        plain = el;
        if (userish(el)) named = el;
      }
      userField = named || plain;
    } else {
      userField = (anchor && userish(anchor)) ? anchor : (inputs.find(stepUserish) || null);
    }
    const setValue = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    window.__sheepFilling = true;
    try {
      if (userField && user.length > 0) { setValue(userField, user); window.__sheepFilledUser = user; }
      if (pwField && pass.length > 0) { setValue(pwField, pass); return 'filled'; }
    } finally { window.__sheepFilling = false; }
    if (userField && user.length > 0) return 'user-only';
    return 'none';
    """

    /// A new account ("Use Strong Password"): `pass` goes in every visible password
    /// box of the focused field's form (password + confirm), origin-checked like `fillScript`, and
    /// counts as typed (`__sheepMarkTyped`). Returns how many boxes were filled (0 = other origin / none).
    public static let newPasswordFillScript = """
    const p = location.port || (location.protocol === 'https:' ? '443' : location.protocol === 'http:' ? '80' : '');
    let h = location.hostname.toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
    if (h.endsWith('.')) h = h.slice(0, -1);
    if (location.protocol !== expected.protocol || h !== expected.hostname || p !== expected.port) return 0;
    const visible = (el) => {
      if (el.disabled || el.readOnly) return false;
      const r = el.getBoundingClientRect(), s = window.getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'
        && r.right + window.scrollX > 0 && r.bottom + window.scrollY > 0;
    };
    const anchor = document.activeElement instanceof HTMLInputElement ? document.activeElement : null;
    const root = (anchor && anchor.form) || document;
    const boxes = Array.from(root.querySelectorAll('input[type=password]')).filter(visible);
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    window.__sheepFilling = true;
    try {
      for (const b of boxes) {
        b.focus();
        setter.call(b, pass);
        b.dispatchEvent(new Event('input', { bubbles: true }));
        b.dispatchEvent(new Event('change', { bubbles: true }));
        if (window.__sheepMarkTyped) window.__sheepMarkTyped(b);
      }
    } finally { window.__sheepFilling = false; }
    return boxes.length;
    """

    /// `fillScript`'s `expected` argument for a page address: protocol with its colon, bare
    /// lower-case host (no brackets, no trailing dot), port string (80/443 filled in).
    public static func expectedOrigin(_ url: URL) -> [String: String]? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return ["protocol": scheme + ":", "hostname": host, "port": String(port)]
    }
}
