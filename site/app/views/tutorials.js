// <three-tutorials> — the list, and one tutorial.
//
// The tutorials are Markdown files in `site/tutorials/`, and they stay readable
// on their own: headings, prose and fenced code, so GitHub renders them and so
// does any editor. What this adds is the sidebar, the prev/next, the copy
// buttons and the runnable script. `lib/markup.js` rewrites the links between
// them, which is how one file serves both readers.

import { LitElement, html, nothing } from 'lit';
import { markdown } from '../../lib/markup.js';
import { setHead } from '../../lib/head.js';
import { highlight } from '../../lib/highlight.js';
import { tutorialData } from '../../lib/data.js';
import { tutorialList, sidebar, prevNext, runIt } from '../../components/tutorial.mjs';

const INDEX = {
	title: 'Tutorials — three.c3',
	description: 'From an empty window to a lit, animated scene, one file at a time.',
};

class Tutorials extends LitElement {
	static properties = {
		slug: { type: String },
		entries: { state: true },
		failed: { state: true },
	};

	createRenderRoot() { this.replaceChildren(); return this; }

	constructor() {
		super();
		this.slug = '';
		this.entries = null;
		this.failed = '';
	}

	connectedCallback() {
		super.connectedCallback();
		tutorialData().then(entries => { this.entries = entries; }, error => { this.failed = error.message; });
	}

	// A tutorial link scrolls nowhere on its own — the fragment is the route,
	// not an anchor — so arriving at one starts it at the top the way following
	// a link between pages used to.
	updated(changed) {
		highlight(this);
		if (!this.entries) return;
		const found = this.found;
		if (changed.has('slug')) scrollTo({ top: 0, behavior: 'auto' });
		setHead(found ? `${found.title} — three.c3` : INDEX.title,
			found ? found.summary : INDEX.description);
	}

	get found() {
		return (this.entries || []).find(entry => entry.slug === this.slug) || null;
	}

	render() {
		if (this.failed) {
			return html`<section class="page-head narrow">
        <h1>The tutorials did not load</h1>
        <p class="lede">${this.failed}. They are Markdown files either way —
           <a href="https://github.com/tonis2/three.c3/tree/main/site/tutorials">read
           them in the repository</a>.</p>
      </section>`;
		}
		if (!this.entries) return html`<p class="empty">Loading…</p>`;
		return this.slug ? this.one() : this.index();
	}

	index() {
		return html`
<section class="page-head">
  <h1>Tutorials</h1>
  <p class="lede">Each one is a scene you can run. Every code block is written out
     as a file beside the page, so the command under it is the command — nothing
     in here is a snippet that has never been run.</p>
</section>
${tutorialList(this.entries)}
<section class="after">
  <p class="aside">Looking for a reference rather than a walkthrough?
     <a href="#/api">The API</a> is searchable, and <code>SKILL.md</code> in
     the release zip is the long-form guide.</p>
</section>`;
	}

	one() {
		const entry = this.found;
		if (!entry) {
			return html`<section class="page-head narrow">
        <h1>No such tutorial</h1>
        <p class="lede">There is no <code>${this.slug}</code>.
           <a href="#/tutorials">The list</a> has the five that exist.</p>
      </section>`;
		}

		const at = this.entries.indexOf(entry);
		return html`
<div class="tutorial">
  ${sidebar(this.entries, entry)}
  <article class="prose">
    ${markdown(entry.content)}
    ${entry.script ? runIt(entry.slug) : nothing}
    ${prevNext(this.entries[at - 1], this.entries[at + 1])}
  </article>
</div>`;
	}
}

customElements.define('three-tutorials', Tutorials);
