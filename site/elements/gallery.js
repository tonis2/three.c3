// <three-gallery> — the screenshot slider.
//
// It plays from the first frame, because the gallery is the argument the home
// page is making and a reader who has to press an arrow to see the second
// picture never sees it. Everything that says "I am reading this" stops it —
// hovering, focusing, dragging, an arrow, a dot, a key — and nothing starts it
// again, because a carousel that resumes under your cursor is the reason people
// hate carousels. `prefers-reduced-motion` never starts it at all.
//
// Scroll-snap does the moving. What this owns is which dot is lit, and when.

import { LightElement } from './base.js';
import { galleryFrame } from '../components/gallery.mjs';

class Gallery extends LightElement {
	static properties = {
		shots: { attribute: false },
		autoplay: { type: Number },
		current: { type: Number, state: true },
	};

	constructor() {
		super();
		this.shots = [];
		this.autoplay = 0;
		this.current = 0;
		this.timer = null;
		this.stopped = false;
		this.still = matchMedia('(prefers-reduced-motion: reduce)');
		this.dots = new Map();
	}

	connectedCallback() {
		super.connectedCallback();
		document.addEventListener('visibilitychange', this.visibility);
		document.addEventListener('keydown', this.key);
	}

	disconnectedCallback() {
		super.disconnectedCallback();
		document.removeEventListener('visibilitychange', this.visibility);
		document.removeEventListener('keydown', this.key);
		this.rest();
	}

	firstUpdated() {
		this.play();
	}

	render() {
		return galleryFrame({
			shots: this.shots,
			current: this.current,
			on: {
				prev: this.prev, next: this.next, dot: this.dot,
				rest: this.rest, resume: this.play, take: this.take,
				scroll: this.scroll,
			},
		});
	}

	get track() { return this.querySelector('.track'); }

	get at() {
		const track = this.track;
		return track && track.clientWidth ? Math.round(track.scrollLeft / track.clientWidth) : 0;
	}

	// Wrapping, because autoplay has to come back round and an arrow that
	// stopped at the end while the timer wrapped would be two different
	// galleries.
	go(index) {
		const track = this.track;
		if (!track || this.shots.length === 0) return;
		const wrapped = ((index % this.shots.length) + this.shots.length) % this.shots.length;
		track.scrollTo({
			left: wrapped * track.clientWidth,
			behavior: this.still.matches ? 'auto' : 'smooth',
		});
	}

	// ------------------------------------------------------------ autoplay --

	play = () => {
		if (this.stopped || this.timer !== null) return;
		if (!this.autoplay || this.shots.length < 2 || this.still.matches) return;
		this.timer = setInterval(this.tick, this.autoplay);
	};

	rest = () => {
		if (this.timer === null) return;
		clearInterval(this.timer);
		this.timer = null;
	};

	// Told, rather than rested: the reader has taken over.
	take = () => {
		this.stopped = true;
		this.rest();
	};

	tick = () => {
		// A hidden tab does not animate, so a timer that kept firing would land
		// the reader eight slides along from where they left.
		if (!document.hidden) this.go(this.at + 1);
	};

	visibility = () => (document.hidden ? this.rest() : this.play());

	// ------------------------------------------------------------- driving --

	prev = () => { this.take(); this.go(this.at - 1); };
	next = () => { this.take(); this.go(this.at + 1); };

	// One listener per dot, made once — see `choose` in download.js.
	dot = index => {
		if (!this.dots.has(index)) {
			this.dots.set(index, () => { this.take(); this.go(index); });
		}
		return this.dots.get(index);
	};

	scroll = {
		handleEvent: () => requestAnimationFrame(() => { this.current = this.at; }),
		passive: true,
	};

	// Arrow keys, but only while the gallery is what the reader is looking at.
	key = event => {
		if (!this.contains(document.activeElement) && !this.inView) return;
		if (event.key === 'ArrowLeft') { event.preventDefault(); this.prev(); }
		if (event.key === 'ArrowRight') { event.preventDefault(); this.next(); }
	};

	get inView() {
		const box = this.getBoundingClientRect();
		return box.top < innerHeight * 0.8 && box.bottom > innerHeight * 0.2;
	}
}

customElements.define('three-gallery', Gallery);
