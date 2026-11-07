(() => {
  const sourceKey = (image) => `${image.getAttribute('src') || ''}\n${image.getAttribute('srcset') || ''}`;

  function prepareImage(image) {
    if (!(image instanceof HTMLImageElement)) return;

    const key = sourceKey(image);
    if (!key.trim()) return;
    if (image.dataset.imageLoadingSource === key) return;
    image.dataset.imageLoadingSource = key;

    image.classList.remove('image-loaded');
    image.classList.add('image-loading');

    if (image.complete) {
      if (image.naturalWidth > 0) markLoaded(image);
      else markFailed(image);
    }
  }

  function markLoaded(image) {
    image.classList.remove('image-loading');
    image.classList.add('image-loaded');
  }

  function markFailed(image) {
    image.classList.remove('image-loading', 'image-loaded');
  }

  function scan(node) {
    if (node instanceof HTMLImageElement) prepareImage(node);
    node.querySelectorAll?.('img').forEach(prepareImage);
  }

  document.querySelectorAll('img').forEach(prepareImage);
  document.addEventListener('load', (event) => {
    if (event.target instanceof HTMLImageElement) markLoaded(event.target);
  }, true);
  document.addEventListener('error', (event) => {
    if (event.target instanceof HTMLImageElement) markFailed(event.target);
  }, true);

  new MutationObserver((changes) => {
    for (const change of changes) {
      if (change.type === 'attributes') prepareImage(change.target);
      else change.addedNodes.forEach(scan);
    }
  }).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['src', 'srcset']
  });
})();
