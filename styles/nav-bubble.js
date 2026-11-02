(() => {
  document.addEventListener('pointerdown', (event) => {
    if (event.button !== 0 || event.pointerType === 'touch') return;

    const ripple = document.createElement('span');
    ripple.className = 'pointer_click_effect';
    ripple.setAttribute('aria-hidden', 'true');
    ripple.style.left = `${event.clientX}px`;
    ripple.style.top = `${event.clientY}px`;
    document.body.appendChild(ripple);
    window.setTimeout(() => ripple.remove(), 680);
  }, { passive: true });

  const menu = document.getElementById('nav_buttons_box_desktop');
  if (!menu) return;

  const underline = document.createElement('span');
  underline.className = 'nav_buttons_bubble';
  underline.setAttribute('aria-hidden', 'true');
  menu.prepend(underline);

  const currentPath = decodeURI(window.location.pathname).replace(/\/+$/, '').toLowerCase();
  const parts = currentPath.split('/').filter(Boolean);
  const file = (parts.length ? parts[parts.length - 1] : 'index.html').toLowerCase();
  const sectionPages = { about: 'about.html', gallery: 'gallery.html', news: 'news.html' };
  const section = [...parts].reverse().find((part) => sectionPages[part]);
  const targetFile = sectionPages[section] || file;
  const desktopLinks = [...menu.querySelectorAll('a[href]')];
  const activeLink = desktopLinks.find((link) => {
    const url = new URL(link.href, window.location.href);
    return url.origin === window.location.origin && url.pathname.split('/').pop().toLowerCase() === targetFile;
  });
  const mobileLinks = [...document.querySelectorAll('#nav_dropdown_content a[href]')];
  const activeUrl = activeLink && new URL(activeLink.href, window.location.href);

  if (activeUrl) {
    menu.classList.add('has-current');
    activeLink.querySelector('.nav_buttons')?.classList.add('is-current');
    activeLink.setAttribute('aria-current', 'page');
    mobileLinks.forEach((link) => {
      const url = new URL(link.href, window.location.href);
      if (url.origin === activeUrl.origin && url.pathname.toLowerCase() === activeUrl.pathname.toLowerCase()) {
        link.setAttribute('aria-current', 'page');
      }
    });
  }

  const moveTo = (link) => {
    menu.querySelectorAll('.nav_buttons-bubble-visible').forEach((item) => item.classList.remove('nav_buttons-bubble-visible'));
    const label = link.querySelector('.nav_buttons') || link;
    const labelRect = label.getBoundingClientRect();
    const menuRect = menu.getBoundingClientRect();
    underline.style.width = `${labelRect.width}px`;
    underline.style.setProperty('--bubble-x', `${labelRect.left - menuRect.left}px`);
    underline.style.setProperty('--underline-y', `${labelRect.bottom - menuRect.top + 5}px`);
    label.classList.add('nav_buttons-bubble-visible');
  };

  const clearHover = () => {
    menu.querySelectorAll('.nav_buttons-bubble-visible').forEach((item) => item.classList.remove('nav_buttons-bubble-visible'));
    if (activeLink) moveTo(activeLink);
    else menu.classList.remove('has-current');
  };
  desktopLinks.forEach((link) => {
    link.addEventListener('pointerenter', () => { menu.classList.add('has-current'); moveTo(link); });
    link.addEventListener('focus', () => { menu.classList.add('has-current'); moveTo(link); });
  });
  menu.addEventListener('pointerleave', clearHover);
  menu.addEventListener('focusout', (event) => { if (!menu.contains(event.relatedTarget)) clearHover(); });

  const syncActive = () => { if (activeLink) requestAnimationFrame(() => requestAnimationFrame(() => moveTo(activeLink))); };
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(syncActive);
  window.addEventListener('load', syncActive, { once: true });
  syncActive();
  window.addEventListener('resize', syncActive);
})();
