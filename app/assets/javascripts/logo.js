export default function initLogoAnimation() {
  window.addEventListener('beforeunload', () => {
    document.querySelector('.tanuki-logo')?.classList.add('animate');
  });
}

export function initPortraitLogoDetection() {
  const image = document.querySelector('.js-portrait-logo-detection');

  image?.addEventListener(
    'load',
    ({ currentTarget: img }) => {
      const isPortrait = img.height > img.width;
      if (isPortrait) {
        // Limit the width when the logo has portrait format
        img.classList.replace('gl-h-9', 'gl-w-10');
      }
      img.classList.remove('gl-visibility-hidden');
    },
    { once: true },
  );
}
