window.scrollPolicies = function (direction) {
  const scrollBox = document.getElementById('news_scroll');
  if (!scrollBox) return;
  scrollBox.scrollBy({ left: direction * 380, behavior: 'smooth' });
};

window.openPolicies = function (item) {
  const popup = document.getElementById('news_popup');
  const data = item?.querySelector('.news_popup_data');
  if (!popup || !data) return;

  const title = data.querySelector('h2');
  const image = data.querySelector('img');
  const details = data.querySelector('details');
  if (!title || !image || !details) return;

  document.getElementById('news_popup_title').textContent = title.textContent;
  const popupImage = document.getElementById('news_popup_image');
  popupImage.loading = 'eager';
  popupImage.src = image.src;
  popupImage.alt = image.alt;
  document.getElementById('news_popup_details').innerHTML = details.innerHTML;
  popup.classList.add('show');
  document.body.style.overflow = 'hidden';
};

window.closePolicies = function () {
  const popup = document.getElementById('news_popup');
  if (!popup) return;
  popup.classList.remove('show');
  document.body.style.overflow = '';
};

const newsPopup = document.getElementById('news_popup');
newsPopup?.addEventListener('click', (event) => {
  if (event.target === newsPopup) window.closePolicies();
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') window.closePolicies();
});

const homeBackground = document.getElementById('home_background');
homeBackground?.addEventListener('mousemove', (event) => {
  const rect = homeBackground.getBoundingClientRect();
  homeBackground.style.setProperty('--mouse-x', `${event.clientX - rect.left}px`);
  homeBackground.style.setProperty('--mouse-y', `${event.clientY - rect.top}px`);
});
homeBackground?.addEventListener('mouseleave', () => {
  homeBackground.style.setProperty('--mouse-x', '50%');
  homeBackground.style.setProperty('--mouse-y', '50%');
});
