// <three-app> — the page.
//
// It owns the frame (skip link, header, main, footer) and decides what is
// inside `<main>`; the routes that need to fetch something or hold state of
// their own are elements and do it themselves, so nothing here is async.
//
// It renders into the light DOM. The site has one stylesheet and every one of
// these components is made of its classes, so an element hiding inside a shadow
// root would need a copy of the CSS to look like the page it is sitting in. Lit
// appends to its render root rather than replacing what is in it, which is why
// the first thing this does is take the shell in `index.html` down — without
// that the header would be there twice.

import { LitElement, html } from 'lit';
import { NAV, SITE } from '../lib/site.mjs';
import { setHead } from '../lib/head.js';
import { highlight } from '../lib/highlight.js';
import { parse } from './router.js';
import { home } from './views/home.js';
import { notFound } from './views/notfound.js';
import './views/api.js';
import './views/tutorials.js';

// `#/api/classes` is a route; `#first-run` is an anchor in the page the reader
// is already on. Only the first shape is one of ours, and treating the second
// as a route is how a "jump to that section" link turns into a 404.
function routeOf(hash) {
	return hash === '' || hash === '#' || hash.startsWith('#/') ? parse(hash) : null;
}

class App extends LitElement {
	static properties = { route: { state: true } };

	createRenderRoot() { this.replaceChildren(); return this; }

	constructor() {
		super();
		this.route = routeOf(location.hash) || { name: 'home', parts: [] };
	}

	connectedCallback() {
		super.connectedCallback();
		addEventListener('hashchange', this.navigate);
	}

	disconnectedCallback() {
		super.disconnectedCallback();
		removeEventListener('hashchange', this.navigate);
	}

	firstUpdated() {
		this.anchor();
	}

	// The home route's code blocks. The two routes that fetch before they can
	// render do their own, because their content lands after this.
	updated() {
		highlight(this);
	}

	navigate = () => {
		const route = routeOf(location.hash);
		if (!route) return this.anchor();
		this.route = route;
		// A route change is a new page as far as the reader is concerned, and a
		// new page starts at the top. The views that scroll somewhere of their
		// own — the reference, to an entry — do it after this.
		if (route.name !== 'api') scrollTo({ top: 0, behavior: 'auto' });
	};

	// The browser scrolls to a fragment when the document already contains it.
	// On a cold load it does not: nothing is rendered yet.
	anchor() {
		const id = location.hash.startsWith('#/') ? '' : location.hash.slice(1);
		if (!id) return;
		requestAnimationFrame(() => document.getElementById(id)?.scrollIntoView());
	}

	get wide() {
		return this.route.name === 'home' || this.route.name === 'api';
	}

	render() {
		return html`<a class="skip" href="#main">Skip to content</a>
${this.topbar()}
<main id="main" class="${this.wide ? 'wide' : ''}">
${this.view()}
</main>
${this.footer()}`;
	}

	view() {
		const [first = '', second = ''] = this.route.parts;
		switch (this.route.name) {
			case 'home':
				setHead(home.title, home.description);
				return home.body;
			case 'api':
				return html`<three-api section="${first}" entry="${second}"></three-api>`;
			case 'tutorials':
				return html`<three-tutorials slug="${first}"></three-tutorials>`;
			default:
				setHead(notFound.title, notFound.description);
				return notFound.body;
		}
	}

	topbar() {
		return html`<header class="topbar">
  <a class="brand" href="#/"><span class="mark"></span>three.c3</a>
  <nav>${NAV.map(item => item.match === this.route.name
			? html`<a href="${item.href}" aria-current="page">${item.label}</a>`
			: html`<a href="${item.href}">${item.label}</a>`)}</nav>
  <a class="source" href="${SITE.repo}">GitHub</a>
</header>`;
	}

	footer() {
		return html`<footer>
  <p>${SITE.name} — a Three.js-shaped scene API over Vulkan.
     <a href="${SITE.repo}">Source</a> ·
     <a href="${SITE.repo}/releases">Releases</a> ·
     <a href="${SITE.repo}/blob/main/LICENSE">MIT</a></p>
</footer>`;
	}
}

customElements.define('three-app', App);
