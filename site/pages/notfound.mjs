// 404. Pages serves this for anything it cannot find under /three.c3/.
//
// Its links are relative like every other page's, which works because Pages
// serves this file from the site root whatever path was asked for.

export async function render() {
	return {
		path: '404.html',
		title: 'Not found — three.c3',
		description: 'That page is not here.',
		body: `
<section class="page-head notfound">
  <h1>404</h1>
  <p class="lede">That page is not here. These four are.</p>
  <p class="cta">
    <a class="button primary" href="index.html">Home</a>
    <a class="button" href="download.html">Download</a>
    <a class="button" href="api.html">API</a>
    <a class="button" href="tutorials/index.html">Tutorials</a>
  </p>
</section>
`,
	};
}
