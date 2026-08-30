// The screenshot slider: scroll-snap does the moving, this does the buttons.

const slider = document.querySelector('[data-slider]');
if (slider) {
	const track = slider.querySelector('[data-track]');
	const slides = [...track.querySelectorAll('.slide')];
	const dots = [...document.querySelectorAll('[data-dot]')];
	const prev = slider.querySelector('.prev');
	const next = slider.querySelector('.next');

	const at = () => Math.round(track.scrollLeft / track.clientWidth);
	const go = index => track.scrollTo({
		left: Math.max(0, Math.min(slides.length - 1, index)) * track.clientWidth,
		behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
	});

	function sync() {
		const current = at();
		prev.disabled = current === 0;
		next.disabled = current >= slides.length - 1;
		dots.forEach((dot, i) => dot.toggleAttribute('data-current', i === current));
	}

	prev.addEventListener('click', () => go(at() - 1));
	next.addEventListener('click', () => go(at() + 1));
	dots.forEach((dot, i) => dot.addEventListener('click', () => go(i)));
	track.addEventListener('scroll', () => requestAnimationFrame(sync), { passive: true });

	// Arrow keys, but only while the gallery is what the reader is looking at.
	document.addEventListener('keydown', event => {
		if (!slider.contains(document.activeElement) && !inView(slider)) return;
		if (event.key === 'ArrowLeft') { event.preventDefault(); go(at() - 1); }
		if (event.key === 'ArrowRight') { event.preventDefault(); go(at() + 1); }
	});

	function inView(element) {
		const box = element.getBoundingClientRect();
		return box.top < innerHeight * 0.8 && box.bottom > innerHeight * 0.2;
	}

	sync();
}
