(() => {
  const stats = [...document.querySelectorAll('.home_stat_number')];
  if (!stats.length) return;

  const targetFor = (element) => {
    if (element.dataset.since) {
      const [year, month, day] = element.dataset.since.split('-').map(Number);
      const today = new Date();
      let years = today.getFullYear() - year;
      if (today.getMonth() + 1 < month || (today.getMonth() + 1 === month && today.getDate() < day)) years--;
      return years;
    }
    return Number(element.dataset.count || 0);
  };
  const format = (number, element) => `${new Intl.NumberFormat().format(number)}${element.dataset.suffix || ''}`;
  const showFinal = (element) => { element.textContent = format(targetFor(element), element); };
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!reduceMotion) stats.forEach((element) => { element.textContent = format(0, element); });
  const animate = (element) => {
    const target = targetFor(element);
    if (reduceMotion) { showFinal(element); return; }
    const start = performance.now();
    const duration = 1200;
    const frame = (now) => {
      const progress = Math.min((now - start) / duration, 1);
      const eased = 1 - Math.pow(1 - progress, 4);
      element.textContent = format(Math.round(target * eased), element);
      if (progress < 1) requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  };

  if (!('IntersectionObserver' in window)) { stats.forEach(animate); return; }
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        animate(entry.target);
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: .35 });
  stats.forEach((element) => observer.observe(element));
})();

