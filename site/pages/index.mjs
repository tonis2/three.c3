// Home. What it is, what it does, and three places to go next.

const FEATURES = [
	{
		title: 'Instanced by default',
		body: 'Every mesh placed with the same asset reference is one instanced draw call. '
			+ 'There is no batching step to invoke and no way to write an unbatched scene — '
			+ 'a thousand copies in a thousand colours is one call.',
	},
	{
		title: 'One binary',
		body: 'The Slang compiler and the five shader templates are inside the executable. '
			+ 'Nothing to install, nothing to build, no launcher script and no assets folder '
			+ 'behind it — <code>./three --script scene.js</code> from wherever you are.',
	},
	{
		title: 'glTF that moves',
		body: 'Load a file and play its clips: skinning, morph targets, crossfades and '
			+ 'sockets on bones. A hundred rigged characters can still be one draw call, '
			+ 'because the poses are baked once per file and shared by every copy.',
	},
	{
		title: 'Physics, navigation, queries',
		body: 'Rigidbodies and triggers, a voxel nav bake with paths and flow fields, and '
			+ 'a spatial index behind every raycast, sphere, box and capsule sweep — in '
			+ 'single and bulk forms, so a crowd is one crossing rather than two hundred.',
	},
	{
		title: 'Shaders you write in the scene',
		body: 'A <code>ShaderMaterial</code> takes a Slang fragment body, a vertex body, its '
			+ 'own uniforms and up to four samplers of its own. Uniform tables let one '
			+ 'material give many meshes many looks without splitting the draw call.',
	},
	{
		title: 'An agent can drive it',
		body: 'An MCP server is built in: <code>--mcp</code> attaches an agent to a running '
			+ 'scene, and <code>get_api_docs</code> answers out of the same object this '
			+ 'website is generated from.',
	},
];

export async function render(ctx) {
	const { apiData, escapeHtml, codeBlock } = ctx;
	const docs = apiData.docs;

	const features = FEATURES.map(f => `
    <article class="cell">
      <h3>${escapeHtml(f.title)}</h3>
      <p>${f.body}</p>
    </article>`).join('');

	const body = `
<section class="hero">
  <h1>A Three.js-shaped scene API<br>over Vulkan.</h1>
  <p class="lede">${escapeHtml(docs.summary)}</p>
  <p class="cta">
    <a class="button primary" href="download.html">Download</a>
    <a class="button" href="tutorials/index.html">Tutorials</a>
    <a class="button" href="api.html">API reference</a>
  </p>
  <p class="version">Version ${escapeHtml(docs.version)} · macOS · Linux · Windows</p>
</section>

<figure class="shot">
  <a href="screenshots.html">
    <img src="screenshots/village.jpg" alt="A cobbled village street lined with timbered houses and pine trees, villagers walking down it."
         width="1600" height="900" decoding="async">
  </a>
  <figcaption>examples/village.js — a street, a crowd, and nine textures that are arithmetic.
    <a href="screenshots.html">More screenshots</a></figcaption>
</figure>

<section class="sample">
  <h2>A whole scene</h2>
  <p>Two shapes, eighty-two meshes, two draw calls. The grid is one call because
     the same numbers are the same asset; the ball is the second because it has a
     material of its own.</p>
  ${codeBlock(docs.example)}
  <p class="aside">Run it with <code>./three --script scene.js</code>. Add
     <code>--headless --frames 1 --screenshot out.png</code> to get a picture and exit.</p>
</section>

<section class="features">
  <h2>What it does</h2>
  <div class="grid">${features}</div>
</section>

<section class="next">
  <h2>Where to start</h2>
  <div class="grid two">
    <article class="cell">
      <h3><a href="tutorials/index.html">Tutorials</a></h3>
      <p>From an empty window to a lit, animated scene. Every code block in them
         is written out as a runnable file, so each one is a command you can paste.</p>
    </article>
    <article class="cell">
      <h3><a href="api.html">API reference</a></h3>
      <p>${apiData.entries.length} entries across ${apiData.sections.length} sections,
         searchable. Generated from the engine's own docs, so the page, the
         <code>three.getApiDocs()</code> call and the MCP tool cannot drift.</p>
    </article>
  </div>
</section>
`;

	return {
		path: 'index.html',
		title: 'three.c3 — a Three.js-shaped scene API over Vulkan',
		description: docs.summary,
		body,
	};
}
