// The furniture around a tutorial: the index list, the sidebar, the runnable
// file and the step either side of this one.

import { html } from 'lit';
import { code } from '../lib/markup.js';

export function tutorialList(entries) {
	if (entries.length === 0) return html`<p class="empty-state">No tutorials yet.</p>`;

	return html`<ol class="tutorial-list">${entries.map((entry, i) => html`
      <li>
        <a href="#/tutorials/${entry.slug}">
          <span class="num">${String(i + 1).padStart(2, '0')}</span>
          <span class="text"><strong>${entry.title}</strong>
          <span class="summary">${entry.summary}</span></span>
        </a>
      </li>`)}</ol>`;
}

export function sidebar(entries, current) {
	return html`<nav class="tutorial-nav">
      <p class="label">Tutorials</p>
      <ol>${entries.map(entry => entry.slug === current.slug
		? html`<li class="current"><a href="#/tutorials/${entry.slug}">${entry.title}</a></li>`
		: html`<li><a href="#/tutorials/${entry.slug}">${entry.title}</a></li>`)}</ol>
    </nav>`;
}

export function prevNext(prev, next) {
	return html`<p class="prevnext">
      ${prev ? html`<a class="prev" href="#/tutorials/${prev.slug}">&larr; ${prev.title}</a>` : html`<span></span>`}
      ${next ? html`<a class="next" href="#/tutorials/${next.slug}">${next.title} &rarr;</a>` : html`<span></span>`}
    </p>`;
}

// Every JavaScript block on the page, in order, written out beside it — so the
// command under this section is the command, not a paraphrase of one. The build
// writes the file; this links to it, because a real file is what `--script`
// takes and a blob the page assembled is not something a reader can keep.
export function runIt(slug) {
	return html`<section class="run">
  <h2>Run it</h2>
  <p>Every JavaScript block on this page, in order, as one file:
     <a href="assets/scripts/${slug}.js" download>${slug}.js</a></p>
  ${code(`./three --script ${slug}.js`, 'bash')}
</section>`;
}
