// Download.
//
// The release assets are version-suffixed — `three-macos-arm64-0.1.0.zip` —
// so the usual `/releases/latest/download/<name>` trick cannot work: the name
// is not knowable without the version. The links are resolved at run time from
// the GitHub API by assets/download.js, and every card ships with a working
// link to the releases page underneath, so a rate-limited fetch degrades
// rather than leaving the page empty.

const PLATFORMS = [
	{
		id: 'macos-arm64',
		prefix: 'three-macos-arm64',
		name: 'macOS',
		detail: 'Apple Silicon · macOS 26 or newer',
		match: 'mac',
		notes: [
			{ p: 'The download is quarantined and the binary is not notarised, so clear that once:' },
			{ code: 'xattr -dr com.apple.quarantine .\n./three --help' },
			{ p: 'The GPU driver travels in the folder, so move the whole folder rather than the '
				+ 'binary alone. macOS 15 and earlier cannot load it at all — the driver is built '
				+ 'on Metal 4 — and report <code>E_ERROR_INCOMPATIBLE_DRIVER</code>.' },
		],
	},
	{
		id: 'linux-x64',
		prefix: 'three-linux-x64',
		name: 'Linux',
		detail: 'x86-64 · experimental',
		match: 'linux',
		notes: [
			{ p: 'Nothing to install on a machine that can already run 3D applications — the '
				+ 'loader and your GPU\'s driver come with the graphics stack.' },
			{ code: './three --help' },
			{ p: 'On a machine with no graphics stack at all (a minimal container, a headless '
				+ 'server) install <code>libvulkan1</code>, and <code>mesa-vulkan-drivers</code> '
				+ 'if there is no GPU to use.' },
		],
	},
	{
		id: 'windows-x64',
		prefix: 'three-windows-x64',
		name: 'Windows',
		detail: 'x86-64',
		match: 'win',
		notes: [
			{ p: '<code>vulkan-1.dll</code> is a system library current GPU drivers put there, so '
				+ 'there is nothing to install for Vulkan itself.' },
			{ code: 'three.exe --help' },
			{ p: 'A bare machine that exits with <code>0xC0000135</code> and no message is missing '
				+ 'the Visual C++ runtime: <code>winget install Microsoft.VCRedist.2015+.x64</code>.' },
		],
	},
];

export async function render(ctx) {
	const { SITE, escapeHtml, codeBlock, apiData } = ctx;

	const cards = PLATFORMS.map(p => {
		const notes = p.notes
			.map(note => (note.code ? codeBlock(note.code, 'bash') : `<p>${note.p}</p>`))
			.join('');

		return `
    <article class="card platform" data-platform="${p.id}" data-prefix="${p.prefix}" data-match="${p.match}">
      <h2>${escapeHtml(p.name)} <span class="badge" hidden>Your system</span></h2>
      <p class="detail">${escapeHtml(p.detail)}</p>
      <p class="get">
        <a class="button primary" href="${SITE.repo}/releases/latest" data-download>Download</a>
        <span class="asset" data-asset></span>
      </p>
      <details>
        <summary>First run</summary>
        ${notes}
      </details>
    </article>`;
	}).join('');

	const body = `
<section class="page-head">
  <h1>Download</h1>
  <p class="lede">One zip per platform. Inside it: the engine, the guide, five example
     scenes and — on macOS — the GPU driver. There is nothing to install and nothing
     to build.</p>
  <p class="status" data-status>Resolving the latest release&hellip;</p>
</section>

<section class="platforms">${cards}</section>

<section class="after">
  <h2>Then what</h2>
  <p>Unzip it, open a terminal in the folder and run the first scene:</p>
  ${codeBlock(`./three --script examples/village.js\n\n# or, with no window:\n./three --headless --script examples/village.js --frames 120 --screenshot village.jpg`, 'bash')}
  <p><code>--script</code> keeps running after the script returns, so a non-interactive
     run needs <code>--frames</code> or <code>--screenshot</code> to bound it.
     <code>SKILL.md</code> in the zip is the guide, and
     <a href="api.html">the API reference</a> here is the same
     ${apiData.entries.length} entries <code>three.getApiDocs()</code> answers with.</p>
  <p class="aside">Building from source instead? The repository is
     <a href="${SITE.repo}">${SITE.owner}/${SITE.project}</a>;
     <code>setup.sh</code> fetches the dependencies and
     <code>c3c build --trust=full --safe=no -O3</code> is the fast build.</p>
</section>
`;

	return {
		path: 'download.html',
		title: 'Download — three.c3',
		description: 'Prebuilt three.c3 binaries for macOS, Linux and Windows. Nothing to install.',
		body,
		scripts: ['download.js'],
	};
}
