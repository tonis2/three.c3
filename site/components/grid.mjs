// A row of cards. Two sections use it and they differ only in how many across.

import { html, nothing } from 'lit';

export function cell({ title, href, body }) {
	return html`<article class="cell">
      <h3>${href ? html`<a href="${href}">${title}</a>` : title}</h3>
      <p>${body}</p>
    </article>`;
}

export function grid(items, modifier) {
	return html`<div class="${modifier ? `grid ${modifier}` : 'grid'}">${items.map(cell)}</div>`;
}
