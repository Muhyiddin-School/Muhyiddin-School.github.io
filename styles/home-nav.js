(() => {
  const nav = document.getElementById('nav_bar');
  if (!nav || !nav.classList.contains('home_nav')) return;
  const sync = () => nav.classList.toggle('is-scrolled', window.scrollY > 24);
  sync();
  window.addEventListener('scroll', sync, { passive: true });
})();
