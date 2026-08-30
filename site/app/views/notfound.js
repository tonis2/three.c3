// Anything the router did not recognise.

import { html } from 'lit';

export const notFound = {
	title: 'Not found — three.c3',
	description: 'That page is not here.',
	body: html`
<section class="page-head notfound">
  <h1>404</h1>
  <p class="lede">That page is not here. These three are — and the download and the
     screenshots are on the home page.</p>
  <p class="cta">
    <a class="button primary" href="#/">Home</a>
    <a class="button" href="#/api">API</a>
    <a class="button" href="#/tutorials">Tutorials</a>
  </p>
</section>
`,
};
