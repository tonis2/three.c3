// The top of the home page: what it is, how to get it, and what it looks like
// to use.

import { html } from 'lit';
import { codeWindow } from './window.mjs';

// The summary's first sentence IS the headline and the rest is the claim under
// it, so the two are split from one string rather than written twice — printing
// the whole summary under a heading that repeats its opening line is how the
// old hero read.
function split(summary) {
	const [headline, ...rest] = summary.split(/(?<=\.)\s+/);
	return { headline, lede: rest.join(' ') };
}

export function hero(docs) {
	const { headline, lede } = split(docs.summary);

	return html`<section class="hero">
  <div class="hero-copy">
    <h1>${headline}</h1>
    <p class="lede">${lede}</p>

    <three-download version="${docs.version}"></three-download>

    <p class="cta">
      <a class="button" href="#/tutorials">Read the tutorials</a>
      <a class="button" href="#/api">API reference</a>
    </p>
  </div>

  <div class="hero-code">
    ${codeWindow('scene.js', docs.example)}
    <p class="aside">Two shapes, eighty-two meshes, two draw calls. The grid is one
       call because the same numbers are the same asset; the ball is the second
       because it has a material of its own.</p>
  </div>
</section>`;
}
