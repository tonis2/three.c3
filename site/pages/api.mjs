// The API reference.
//
// Every entry is rendered into the page at build time rather than fetched:
// deep links work with no round trip, the page opens from a file:// URL, and
// search is a scan over nodes that are already in the DOM. With JavaScript off
// the whole reference is still there — long, but complete and linkable.
//
// The fragment is the path `getApiDocs` takes: `#/classes/ShaderMaterial` here
// is `{ section: 'classes.ShaderMaterial' }` in the tool, so a link somebody
// pastes into a chat is a link an agent can act on.

// `differences` first, and it is what the page opens on. It is the section
// that stops scripts failing, and `docsIndex()` already says so by dumping it
// whole in the index while `classes` and `functions` become name lists.
const ORDER = ['differences', 'classes', 'functions', 'stats', 'intersection', 'keys',
	'example', 'exampleFromFile', 'summary', 'version'];

const BLURB = {
	differences: 'Where this is not Three.js. Read this section first — nearly every '
		+ 'script that fails does so against one of these.',
	classes: 'The constructors, their properties and their methods.',
	functions: 'Everything on `three` itself, keyed by its whole call.',
	stats: 'What each number from `scene.stats()` counts.',
	intersection: 'The record a raycast or a pick answers with.',
	keys: 'The names `three.input` and `three.onKey` match against. This list is read '
		+ 'out of the engine\'s own key table, so it is the list that actually matches.',
	example: 'A complete scene, with the draw-call count it ends on.',
	exampleFromFile: 'The same, from a glTF file.',
	summary: 'What the engine is, in a sentence.',
	version: 'The documented API version.',
};

export async function render(ctx) {
	const { apiData, escapeHtml, prose, codeBlock } = ctx;

	const bySection = new Map();
	const slugs = new Map();
	for (const entry of apiData.entries) {
		if (!bySection.has(entry.section)) bySection.set(entry.section, []);
		bySection.get(entry.section).push(entry);

		// A function is keyed by its whole call, so two of them can flatten to
		// one id — and a duplicate id is a deep link that silently lands on
		// the wrong entry. Fail here instead.
		const id = slug(entry.path);
		if (slugs.has(id)) throw new Error(`api: "${entry.path}" and "${slugs.get(id)}" both slug to #/${id}`);
		slugs.set(id, entry.path);
	}

	const sections = [...bySection.keys()]
		.sort((a, b) => order(a) - order(b));

	const nav = sections.map(key => {
		const entries = bySection.get(key);
		const leaf = entries.length === 1 && entries[0].path === key;
		const items = leaf ? '' : `<ul>${entries.map(e =>
			`<li><a href="#/${slug(e.path)}" data-nav="${escapeHtml(e.path)}">${escapeHtml(e.name)}</a></li>`
		).join('')}</ul>`;
		const self = leaf
			? `<a class="section-link" href="#/${slug(key)}" data-nav="${escapeHtml(key)}">${escapeHtml(key)}</a>`
			: `<a class="section-link" href="#/${slug(key)}">${escapeHtml(key)} <span class="count">${entries.length}</span></a>`;
		return `<div class="nav-section" data-section="${escapeHtml(key)}">${self}${items}</div>`;
	}).join('');

	const panes = sections.map(key => {
		const entries = bySection.get(key);
		const blurb = BLURB[key] ? `<p class="section-blurb">${prose(BLURB[key])}</p>` : '';
		const rendered = entries.map(e => `
    <article class="entry" id="${slug(e.path)}" data-path="${escapeHtml(e.path)}">
      <h2><a class="anchor" href="#/${slug(e.path)}">${escapeHtml(e.name)}</a>
          <span class="path">${escapeHtml(e.path)}</span></h2>
      ${renderValue(e.value, { escapeHtml, prose, codeBlock })}
    </article>`).join('');
		return `<section class="pane" data-section="${escapeHtml(key)}">
      <h1 class="section-title">${escapeHtml(key)}</h1>${blurb}${rendered}
    </section>`;
	}).join('');

	const body = `
<div class="api">
  <aside class="sidebar">
    <form class="search" role="search" onsubmit="return false">
      <input type="search" id="q" placeholder="Search the API" autocomplete="off"
             aria-label="Search the API" spellcheck="false">
      <p class="hits" data-hits></p>
    </form>
    <nav class="toc">${nav}</nav>
  </aside>
  <div class="reference">
    <p class="reference-head">Version ${escapeHtml(apiData.version)} ·
       ${apiData.entries.length} entries · generated from the engine's own docs, so this
       page and <code>three.getApiDocs()</code> cannot disagree ·
       <a href="assets/api.json">api.json</a></p>
    <p class="empty" data-empty hidden>Nothing matched.</p>
    ${panes}
  </div>
</div>
`;

	return {
		path: 'api.html',
		title: 'API reference — three.c3',
		description: `The three.c3 scripting API: ${apiData.entries.length} entries across `
			+ `${sections.length} sections, searchable.`,
		body,
		wide: true,
		scripts: ['api.js'],
	};
}

function order(key) {
	const at = ORDER.indexOf(key);
	return at === -1 ? ORDER.length : at;
}

// `classes.ShaderMaterial` -> `/classes/ShaderMaterial`, and a function's whole
// call — `three.load(path)` — has to survive being an id and a fragment, so
// anything outside the safe set becomes a dash.
export function slug(path) {
	return path.replace(/\./g, '/').replace(/[^A-Za-z0-9/_-]+/g, '-').replace(/-+$/g, '');
}

// ------------------------------------------------------------ the shapes --

const CLASS_KEYS = ['construct', 'note', 'note2', 'properties', 'methods', 'details'];

function renderValue(value, h) {
	if (typeof value === 'string') return renderString(value, h);
	if (Array.isArray(value)) return renderArray(value, h);
	return renderRecord(value, h);
}

function renderString(text, h) {
	// A multi-line string in the docs is a code listing; a one-line one is prose.
	if (text.includes('\n')) return h.codeBlock(text);
	return `<p>${h.prose(text)}</p>`;
}

function renderArray(items, h) {
	// The key table is a hundred short names — a list of chips reads as the
	// lookup table it is, where a bullet list would be a column of noise.
	const short = items.every(item => typeof item === 'string' && item.length <= 16);
	if (short) return `<ul class="chips">${items.map(i => `<li><code>${h.escapeHtml(i)}</code></li>`).join('')}</ul>`;
	return `<ul>${items.map(i => `<li>${h.prose(i)}</li>`).join('')}</ul>`;
}

function renderRecord(record, h) {
	const out = [];
	if (record.construct) out.push(h.codeBlock(record.construct));
	if (record.note) out.push(`<p>${h.prose(record.note)}</p>`);
	if (record.note2) out.push(`<p>${h.prose(record.note2)}</p>`);

	const details = record.details || {};
	if (record.properties) out.push(memberList('Properties', record.properties, details, h));
	if (record.methods) out.push(memberList('Methods', record.methods, details, h));

	// Anything a class record grows that this does not know about is still
	// shown, labelled, rather than silently dropped.
	for (const [key, value] of Object.entries(record)) {
		if (CLASS_KEYS.includes(key)) continue;
		out.push(`<h3>${h.escapeHtml(key)}</h3>${renderValue(value, h)}`);
	}

	// A detail whose member is not in either list would otherwise vanish.
	const used = new Set([...(record.properties || []), ...(record.methods || [])].map(member));
	const orphans = Object.entries(details).filter(([key]) => !used.has(key));
	if (orphans.length > 0) {
		out.push(`<h3>Details</h3><dl class="members">${orphans.map(([key, text]) =>
			`<dt><code>${h.escapeHtml(key)}</code></dt><dd>${h.prose(text)}</dd>`).join('')}</dl>`);
	}
	return out.join('');
}

// `details` hangs under the property or method it explains rather than as a
// fourth list — it is an explanation OF a member, and two lists away from the
// name it belongs to is where a reader stops following it.
function memberList(title, members, details, h) {
	const rows = members.map(entry => {
		const { signature, inline } = split(entry);
		const detail = details[member(entry)];
		return `<dt><code>${h.escapeHtml(signature)}</code></dt>`
			+ `<dd>${inline ? `<p>${h.prose(inline)}</p>` : ''}`
			+ `${detail ? `<p class="detail">${h.prose(detail)}</p>` : ''}</dd>`;
	}).join('');
	return `<h3>${title}</h3><dl class="members">${rows}</dl>`;
}

// A member is either a signature — `play(name, { loop, speed })` — or a name
// with its explanation in brackets after it: `isActive (whether this is ...)`.
// The difference is whether the parenthesis opens straight off the identifier,
// and the second form is a name and a paragraph rather than one long code span.
function split(entry) {
	const text = String(entry);
	if (looksLikeCall(text)) return { signature: text, inline: '' };
	const open = text.indexOf(' (');
	if (open === -1 || !text.endsWith(')')) return { signature: text, inline: '' };
	return { signature: text.slice(0, open), inline: text.slice(open + 2, -1) };
}

function member(entry) {
	const found = String(entry).match(/^[A-Za-z_$][\w$]*/);
	return found ? found[0] : String(entry);
}

function looksLikeCall(entry) {
	return /^[A-Za-z_$][\w$]*\(/.test(String(entry));
}
