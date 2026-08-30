// <three-api> — the reference.
//
// 287 entries. The static site rendered all of them into one 390 KB document
// and let CSS show a section at a time; this renders the section that is being
// looked at, which is why the route carries it: `#/api/classes/Mesh` is a
// section, an entry and a scroll position, and it survives a reload and a paste
// into a chat. It is also the path `getApiDocs` takes — `classes.Mesh` in the
// tool — so a link a reader sends is a link an agent can act on.
//
// The data is fetched, not bundled: 250 KB of JSON has no business on the home
// page. Until it arrives this says so, and if it never arrives it says that
// instead of showing an empty reference.

import { LitElement, html, nothing } from 'lit';
import { prose } from '../../lib/markup.js';
import { setHead } from '../../lib/head.js';
import { highlight } from '../../lib/highlight.js';
import { apiData } from '../../lib/data.js';
import { value } from '../../components/reference.mjs';

// What search matches against, flattened out of the entry once on the way in.
// The prose is already in `value`, so sending a second copy of it in `api.json`
// would be 100 KB spent on words the browser was handed anyway.
function text(value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return value;
	if (Array.isArray(value)) return value.join('\n');
	if (typeof value !== 'object') return String(value);
	return Object.entries(value).map(([key, field]) => `${key} ${text(field)}`).join('\n');
}

export function slug(name) {
	return String(name).replace(/[^A-Za-z0-9_-]+/g, '-').replace(/-+$/g, '');
}

class Api extends LitElement {
	static properties = {
		section: { type: String },
		entry: { type: String },
		data: { state: true },
		failed: { state: true },
		q: { state: true },
	};

	createRenderRoot() { this.replaceChildren(); return this; }

	constructor() {
		super();
		this.section = '';
		this.entry = '';
		this.data = null;
		this.failed = '';
		this.q = '';
		this.index = new Map();
	}

	connectedCallback() {
		super.connectedCallback();
		apiData().then(data => {
			this.index = new Map(data.entries.map(e => [e, `${e.path} ${text(e.value)}`.toLowerCase()]));
			this.data = data;
		}, error => { this.failed = error.message; });
	}

	// The route can change while this element stays mounted — every link in the
	// table of contents does exactly that — so the scroll is driven by the
	// property landing, not by the element being created.
	updated(changed) {
		highlight(this);
		if (this.data && (changed.has('entry') || changed.has('data'))) this.reveal();
		if (this.data && (changed.has('data') || changed.has('section'))) {
			setHead(`${this.section || 'API'} — three.c3`,
				`The three.c3 scripting API: ${this.data.entries.length} entries, searchable.`);
		}
	}

	reveal() {
		if (!this.entry) return;
		// After the render that put it there.
		requestAnimationFrame(() => {
			const found = this.querySelector(`#${CSS.escape(this.entry)}`);
			if (found) found.scrollIntoView({ block: 'start', behavior: 'auto' });
		});
	}

	get sections() {
		return (this.data?.sections || []).filter(s => this.entries(s.key).length > 0);
	}

	entries(key) {
		return (this.data?.entries || []).filter(e => e.section === key);
	}

	// The same rule `docsSearch()` uses: a hit is any entry whose path or prose
	// contains the term. There is no cap on it — the one in the engine exists
	// because an agent pays tokens for an answer, and a reader scrolling does not.
	get hits() {
		const term = this.q.trim().toLowerCase();
		if (!term) return null;
		return (this.data?.entries || []).filter(e => this.index.get(e).includes(term));
	}

	render() {
		if (this.failed) {
			return html`<section class="page-head narrow">
        <h1>The reference did not load</h1>
        <p class="lede">${this.failed}. It is a plain file either way:
           <a href="assets/api.json">api.json</a>, the same object
           <code>three.getApiDocs()</code> answers with.</p>
      </section>`;
		}
		if (!this.data) return html`<p class="empty">Loading the reference…</p>`;

		const hits = this.hits;
		const shown = hits
			? this.sections.map(s => [s, hits.filter(e => e.section === s.key)]).filter(([, list]) => list.length)
			: this.sections.filter(s => s.key === this.here).map(s => [s, this.entries(s.key)]);

		return html`
<div class="api">
  <aside class="sidebar">
    <form class="search" role="search" @submit=${this.stop}>
      <input type="search" id="q" placeholder="Search the API" autocomplete="off"
             aria-label="Search the API" spellcheck="false"
             .value=${this.q} @input=${this.type}>
      <p class="hits">${hits ? `${hits.length} match${hits.length === 1 ? '' : 'es'}` : ''}</p>
    </form>
    <nav class="toc">${this.sections.map(s => this.tocSection(s, hits))}</nav>
  </aside>
  <div class="reference">
    <p class="reference-head">Version ${this.data.version} ·
       ${this.data.entries.length} entries · generated from the engine's own docs, so this
       page and <code>three.getApiDocs()</code> cannot disagree ·
       <a href="assets/api.json">api.json</a></p>
    ${shown.length === 0 ? html`<p class="empty">Nothing matched.</p>` : nothing}
    ${shown.map(([section, list]) => this.pane(section, list))}
  </div>
</div>`;
	}

	// Which section is on screen: the route's, or the first one that exists.
	get here() {
		const keys = this.sections.map(s => s.key);
		return keys.includes(this.section) ? this.section : keys[0];
	}

	stop = event => event.preventDefault();
	type = event => { this.q = event.target.value; };

	// A section whose only entry IS the section — `summary`, `version` — is a
	// link to that entry rather than a heading over a list of one.
	tocSection(section, hits) {
		const all = this.entries(section.key);
		const list = hits ? all.filter(e => hits.includes(e)) : all;
		if (list.length === 0) return nothing;

		const leaf = all.length === 1 && all[0].path === section.key;
		const open = section.key === this.here;

		return html`<div class="nav-section">${leaf
			? html`<a class="section-link" href="#/api/${section.key}">${section.key}</a>`
			: html`<a class="section-link" href="#/api/${section.key}">${section.key}
			  <span class="count">${list.length}</span></a>
			${open || hits ? html`<ul>${list.map(e => html`<li><a
				href="#/api/${e.section}/${slug(e.name)}">${e.name}</a></li>`)}</ul>` : nothing}`
		}</div>`;
	}

	pane(section, entries) {
		return html`<section class="pane active">
      <h1 class="section-title">${section.key}</h1>
      ${section.blurb ? html`<p class="section-blurb">${prose(section.blurb)}</p>` : nothing}
      ${entries.map(e => html`
    <article class="entry" id="${slug(e.name)}">
      <h2><a class="anchor" href="#/api/${e.section}/${slug(e.name)}">${e.name}</a>
          <span class="path">${e.path}</span></h2>
      ${value(e.value, e.path)}
    </article>`)}
    </section>`;
	}
}

customElements.define('three-api', Api);
