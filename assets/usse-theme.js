/* Display preferences only. Authentication and business actions stay in page modules. */
(() => {
  'use strict';
  const root = document.documentElement;
  const key = 'ussehub-display-mode';
  const valid = value => value === 'day' || value === 'night';
  const fallback = root.dataset.hubDefaultTheme === 'night' ? 'night' : 'day';
  let saved;
  try { saved = localStorage.getItem(key); } catch { /* Storage can be blocked. */ }
  root.dataset.hubTheme = valid(saved) ? saved : fallback;
  // Chart labels are canvas text, so update their colours when the display changes.
  window.usseThemeColour = name => getComputedStyle(root).getPropertyValue(name).trim();
  const refreshCharts = () => {
    const ink = window.usseThemeColour('--hub-muted');
    for (const chart of Object.values(window.Chart?.instances || {})) {
      chart.options.color = ink;
      const plugins = chart.options.plugins;
      if (plugins?.legend?.labels) plugins.legend.labels.color = ink;
      if (plugins?.title) plugins.title.color = ink;
      for (const scale of Object.values(chart.options.scales || {})) {
        if (scale.ticks) scale.ticks.color = ink;
        if (scale.title) scale.title.color = ink;
      }
      chart.update('none');
    }
  };
  window.addEventListener('usse-theme-change', refreshCharts);
  let button;
  const sync = () => {
    if (!button) return;
    const night = root.dataset.hubTheme === 'night';
    button.setAttribute('aria-pressed', String(night));
    button.setAttribute('aria-label', `Night mode. Switch to ${night ? 'day' : 'night'} mode`);
    button.title = `Switch to ${night ? 'day' : 'night'} mode`;
    button.querySelector('span').textContent = night ? 'Night' : 'Day';
    button.querySelector('svg').innerHTML = night
      ? '<path d="M20 14.1A8.4 8.4 0 0 1 9.9 4 8.4 8.4 0 1 0 20 14.1Z"/>'
      : '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.4 1.4m11.2 11.2L19 19M5 19l1.4-1.4M17.6 6.4 19 5"/>';
  };
  const mount = () => {
    button = document.createElement('button');
    button.type = 'button'; button.className = 'hub-theme-toggle';
    button.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"></svg><span></span>';
    button.addEventListener('click', () => {
      root.dataset.hubTheme = root.dataset.hubTheme === 'night' ? 'day' : 'night';
      try { localStorage.setItem(key, root.dataset.hubTheme); } catch { /* Keep this tab usable. */ }
      sync();
      window.dispatchEvent(new CustomEvent('usse-theme-change', {detail: {theme: root.dataset.hubTheme}}));
    });
    const nav = document.querySelector('.topbar .nav');
    if (nav) nav.insertBefore(button, nav.querySelector('.mobile-toggle'));
    else {
      const header = document.querySelector('body > header');
      if (header) { header.append(button); header.classList.add('hub-theme-header'); }
      else { button.classList.add('hub-theme-floating'); document.body.append(button); }
    }
    sync();
  };
  window.addEventListener('storage', event => {
    if (event.key !== key) return;
    root.dataset.hubTheme = valid(event.newValue) ? event.newValue : fallback;
    sync();
    window.dispatchEvent(new CustomEvent('usse-theme-change', {detail: {theme: root.dataset.hubTheme}}));
  });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount, {once:true});
  else mount();
})();
