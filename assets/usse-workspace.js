/* Shared navigation is presentation only; existing authenticated page modules
   remain responsible for loading records, permissions and every mutation. */
(() => {
  const body = document.body;
  const isAdmin = body.classList.contains('hub-admin');
  const target = document.querySelector('main, #admin-content, #services, #sign-page');
  if (target) {
    if (!target.id) target.id = 'hub-main';
    const skip = document.createElement('a');
    skip.className = 'hub-skip'; skip.href = `#${target.id}`;
    skip.textContent = 'Skip to content'; body.prepend(skip);
  }
  if (!isAdmin) return;

  const page = body.dataset.hubPage;
  const config = {
    'master-admin': ['Enterprise overview', 'See the whole picture.', 'Review consultations, members, subscriptions and listing activity across USSEHub.', 'Begin with the overview, then use Consultations to follow up enquiries. Review pending listings before approval and use Members to manage existing accounts.'],
    'ajm-admin-panel': ['Directory & reporting', 'Keep your network moving.', 'Manage business listings, review members and turn directory activity into useful reports.', 'Review the pending queue, open a listing to check its details, then approve or return it for correction. Reports contains the directory, registration register, call list, performance, invoices and statements.'],
    'ajm-ad-management': ['Advertising & accounts', 'Make every placement count.', 'Follow orders from payment review to active advertising, with packages and performance in one workspace.', 'Set payment destinations and package prices first. Review the payment queue before confirming receipts. Active ads and Overview show delivery and commercial performance.'],
    'referral-agreements': ['Partners & commissions', 'Build stronger connections.', 'Manage partner agreements, signatures, introductions and commissions across every USSE subsidiary.', 'Set the company identity and authorized signature, create an agreement, then share its signing link with the partner. Record introductions and update commission records in the referral register.'],
    'ajm-webpage-builder': ['Business webpage studio', 'Build your business presence.', 'Move from business details to an engaging webpage with the tools included in your package.', 'Start with Package and market, complete the Silver foundation, then add the engagement tools available in your plan. Review your details before publishing.']
  }[page];
  if (!config) return;
  const icon = (kind = 'grid') => {
    const paths = {
      grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
      list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
      chart: '<path d="M4 4v16h17M9 15v-4M14 15V7M19 15V3"/>',
      people: '<circle cx="9" cy="7" r="3"/><path d="M3 21v-4a6 6 0 0 1 12 0v4M16 4a3 3 0 0 1 0 6M21 21v-4a6 6 0 0 0-4-5"/>',
      globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
      arrow: '<path d="M5 12h14M14 7l5 5-5 5"/>'
    };
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[kind] || paths.list}</svg>`;
  };
  const rail = document.createElement('aside');
  rail.className = 'hub-rail'; rail.id = 'hub-workspace-navigation'; rail.setAttribute('aria-label', 'USSE workspace');
  rail.innerHTML = `<a class="hub-rail-brand" href="index.html"><img src="usse.png" alt=""><span><strong>USSEHub</strong><small>Operations suite</small></span></a><div class="hub-rail-label">Workspace</div><nav aria-label="Operations modules"></nav><div class="hub-rail-local"><div class="hub-rail-label">In this workspace</div><nav aria-label="Current workspace sections"></nav></div><div class="hub-rail-label">Explore</div><nav class="hub-rail-public" aria-label="Public pages"></nav><div class="hub-rail-note"><strong>One enterprise.<br>Connected possibilities.</strong>Strategy, creativity and execution.<br>Working together, across Jamaica.</div>`;
  const isBuilder = page === 'ajm-webpage-builder';
  if (isBuilder) rail.querySelector('.hub-rail-brand small').textContent = 'Business studio';
  const links = isBuilder ? [
    ['ajm-advertising-hub', 'Business directory', 'globe'],
    ['ajm-webpage-builder', 'Your webpage studio', 'grid'],
    ['ajm-advertising-hub?advertise=1&product=webpage', 'Webpage packages', 'list']
  ] : [
    ['master-admin', 'Enterprise overview', 'grid'],
    ['ajm-admin-panel', 'Directory & reports', 'list'],
    ['ajm-ad-management', 'Advertising & accounts', 'chart'],
    ['referral-agreements', 'Partners & referrals', 'people']
  ];
  const moduleNav = rail.querySelector('nav');
  for (const [path, label, glyph] of links) {
    const a = document.createElement('a'); a.className = 'hub-rail-link'; a.href = path === 'ajm-webpage-builder' ? path + location.search : path;
    a.innerHTML = icon(glyph); a.append(document.createTextNode(label));
    if (page === path) a.setAttribute('aria-current', 'page'); moduleNav.append(a);
  }
  const publicNav = rail.querySelector('.hub-rail-public');
  for (const [path, label, glyph] of [['index.html','Public website','globe'], ['ajm-advertising-hub','Business directory','arrow']]) {
    const a = document.createElement('a'); a.className = 'hub-rail-link'; a.href = path;
    a.innerHTML = icon(glyph); a.append(document.createTextNode(label)); publicNav.append(a);
  }
  body.prepend(rail);
  const toggle = document.createElement('button'); toggle.className = 'hub-menu-toggle';
  toggle.type = 'button'; toggle.textContent = '☰   USSEHub · Workspace navigation';
  toggle.setAttribute('aria-controls', rail.id); toggle.setAttribute('aria-expanded', 'false'); body.prepend(toggle);
  const mobile = window.matchMedia('(max-width: 760px)');
  const updateRail = () => {
    const concealed = mobile.matches && !body.classList.contains('hub-menu-open');
    rail.inert = concealed;
    if (concealed) rail.setAttribute('aria-hidden', 'true'); else rail.removeAttribute('aria-hidden');
  };
  const closeMenu = () => { body.classList.remove('hub-menu-open'); toggle.setAttribute('aria-expanded','false'); updateRail(); };
  toggle.addEventListener('click', () => { const open = body.classList.toggle('hub-menu-open'); toggle.setAttribute('aria-expanded', String(open)); updateRail(); });
  mobile.addEventListener('change', updateRail); updateRail();
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && body.classList.contains('hub-menu-open')) { closeMenu(); toggle.focus(); } });
  document.addEventListener('click', e => { if (!rail.contains(e.target) && !toggle.contains(e.target)) closeMenu(); });
  rail.addEventListener('click', e => { if (e.target.closest('a')) closeMenu(); });

  const sources = [...document.querySelectorAll('.tab-bar .tab-btn, #app > .tabs .tab, #workspace > .tabs button, .step-nav a')];
  const localNav = rail.querySelector('.hub-rail-local nav');
  const proxies = sources.map((source) => {
    source.parentElement.classList.add('hub-source-tabs');
    const button = document.createElement('button'); button.type = 'button';
    button.textContent = source.textContent.replace(/[📊💬💳⏳✅👥❌🕰️📋📄💰↗]/gu,'').replace(/\s+/g,' ').trim();
    if (source.id === 'tab-subscriptions') button.textContent = 'Subscriptions';
    const sync = () => {
      const available = source.closest('#admin-content, #app, #workspace');
      button.disabled = source.disabled || !!available && (available.hidden || getComputedStyle(available).display === 'none');
      button.setAttribute('aria-current', String(source.classList.contains('active') || source.getAttribute('aria-selected') === 'true' || !!source.hash && source.hash === location.hash));
    };
    button.addEventListener('click', () => {
      if (button.disabled) return;
      source.click(); closeMenu(); syncAll();
      if (mobile.matches) {
        const heading = document.querySelector('.hub-work-intro h1');
        if (heading) { heading.tabIndex = -1; heading.focus({preventScroll:true}); }
      }
    });
    localNav.append(button); return { source, sync };
  });
  function syncAll() { proxies.forEach(p => p.sync()); }
  if (!sources.length) rail.querySelector('.hub-rail-local').hidden = true;
  syncAll();
  window.addEventListener('hashchange', syncAll);
  const observer = new MutationObserver(syncAll);
  for (const {source} of proxies) observer.observe(source, {attributes: true, attributeFilter:['class','aria-selected','disabled']});
  for (const container of document.querySelectorAll('#admin-content,#app,#workspace')) observer.observe(container, {attributes:true,attributeFilter:['style','hidden','class']});
  body.classList.add('hub-enhanced');

  const host = document.querySelector('#admin-content, #app, body > main');
  if (host) {
    const intro = document.createElement('div'); intro.className = 'hub-work-intro';
    const copy = document.createElement('div');
    const eyebrow = document.createElement('small'); eyebrow.textContent = config[0];
    const title = document.createElement('h1'); title.textContent = config[1];
    const p = document.createElement('p'); p.textContent = config[2]; copy.append(eyebrow,title,p);
    const help = document.createElement('button'); help.type = 'button'; help.className = 'hub-help'; help.textContent = 'How this workspace works';
    const guide = document.createElement('div'); guide.id = 'hub-workspace-guide'; guide.className = 'hub-guide'; guide.hidden = true;
    const guideText = document.createElement('p'); guideText.textContent = config[3]; guide.append(guideText);
    help.setAttribute('aria-controls',guide.id); help.setAttribute('aria-expanded','false');
    help.addEventListener('click',()=>{guide.hidden = !guide.hidden; help.setAttribute('aria-expanded',String(!guide.hidden));});
    const heading = host.querySelector('.page-header, .page-head, .head');
    if (heading) {
      const previousCopy = heading.querySelector('div:first-child');
      const previousTitle = previousCopy?.querySelector('h1');
      if (previousTitle?.id) title.id = previousTitle.id;
      previousCopy?.replaceChildren(eyebrow,title,p);
      heading.classList.add('hub-work-intro'); heading.append(help); heading.after(guide);
    } else if (isBuilder) {
      const workflow = host.querySelector('.workflow-card');
      if (workflow) { workflow.append(help); workflow.after(guide); }
    } else { intro.append(copy,help); host.prepend(intro,guide); }
  }
})();
