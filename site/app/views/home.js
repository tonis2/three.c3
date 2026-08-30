// The whole site, minus the reference and the tutorials.
//
// Home, Download and Screenshots used to be three pages, and the split cost
// more than it bought: a visitor who came to look at pictures had to go and
// find the download, and the download page had nothing to look at. They are one
// view now, and the nav is Home, API, Tutorials — two routes that are genuinely
// somewhere else, because one is a reference you search and the other is a
// sequence you read.
//
// Everything this needs travels in the bundle: the summary, the example and the
// captions are a couple of kilobytes between them, so the first route a visitor
// lands on asks for nothing but its images.

import { html } from 'lit';
import { code } from '../../lib/markup.js';
import { SITE } from '../../lib/site.mjs';
import { META, SHOTS } from '../../.generated/data.js';
import { hero } from '../../components/hero.mjs';
import { gallerySection } from '../../components/gallery.mjs';
import { grid } from '../../components/grid.mjs';

const FEATURES = [
	{
		title: 'Instanced by default',
		body: html`Every mesh placed with the same asset reference is one instanced draw
			call. There is no batching step to invoke and no way to write an unbatched
			scene — a thousand copies in a thousand colours is one call.`,
	},
	{
		title: 'One binary',
		body: html`The Slang compiler and the five shader templates are inside the
			executable. Nothing to install, nothing to build, no launcher script and no
			assets folder behind it — <code>./three --script scene.js</code> from
			wherever you are.`,
	},
	{
		title: 'glTF that moves',
		body: html`Load a file and play its clips: skinning, morph targets, crossfades
			and sockets on bones. A hundred rigged characters can still be one draw call,
			because the poses are baked once per file and shared by every copy.`,
	},
	{
		title: 'Physics, navigation, queries',
		body: html`Rigidbodies and triggers, a voxel nav bake with paths and flow fields,
			and a spatial index behind every raycast, sphere, box and capsule sweep — in
			single and bulk forms, so a crowd is one crossing rather than two hundred.`,
	},
	{
		title: 'Shaders you write in the scene',
		body: html`A <code>ShaderMaterial</code> takes a Slang fragment body, a vertex
			body, its own uniforms and up to four samplers of its own. Uniform tables let
			one material give many meshes many looks without splitting the draw call.`,
	},
	{
		title: 'An agent can drive it',
		body: html`An MCP server is built in: <code>--mcp</code> attaches an agent to a
			running scene, and <code>get_api_docs</code> answers out of the same object
			this website is generated from.`,
	},
];

export const home = {
	title: 'three.c3 — a Three.js-shaped scene API over Vulkan',
	description: META.summary,
	wide: true,
	body: html`
${hero(META)}

${gallerySection(SHOTS)}

<section class="features">
  <h2>What it does</h2>
  ${grid(FEATURES)}
</section>

<section class="after narrow" id="first-run">
  <h2>How to run</h2>
  <p>Unzip it, open a terminal in the folder and run the first scene:</p>

  <div class="code">
    <button class="copy" type="button" aria-label="Copy">Copy</button>
    <pre class="language-bash"><code class="language-bash">./three --script examples/village.js

# or
./three --assets ./game

# --assets seeks main.js in the folder and boots that

# or, with no window:
./three --headless --script examples/village.js --frames 120 --screenshot village.jpg</code></pre>
  </div>

  <p>
	Use debug parameter while developing, to get hot-reload, quit by ESC and debugging info while the game runs.
	Hot-reload works work SHIFT+R
  </p>

  <div class="code">
	<pre class="language-bash"><code class="language-bash">./three --debug --script examples/village.js</pre>
  </code>
</section>

<section class="next">
  <h2>Where to start</h2>
  ${grid([
		{
			title: 'Tutorials',
			href: '#/tutorials',
			body: html`From an empty window to a lit, animated scene. Every code block in
				them is written out as a runnable file, so each one is a command you can
				paste.`,
		},
		{
			title: 'API reference',
			href: '#/api',
			body: html`${META.entryCount} entries across ${META.sectionCount}
				sections, searchable. Generated from the engine's own docs, so the page, the
				<code>three.getApiDocs()</code> call and the MCP tool cannot drift.`,
		},
	], 'two')}
</section>
`,
};
