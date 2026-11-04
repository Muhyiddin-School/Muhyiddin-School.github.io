(() => {
  const year = new Date().getFullYear();
  document.querySelectorAll('[data-footer-year]').forEach((element) => {
    element.textContent = year;
  });
})();
