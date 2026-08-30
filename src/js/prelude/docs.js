// three.c3 — the machine-readable docs, `three.getApiDocs()`'s answer.
//
// The prose lives in `docs/` as Markdown — one file per class, one heading
// per entry — and `tools/docs.mjs` compiles it into `docs.data.js` before
// every build. This module is the reading side: it adds the one value that
// cannot be written down, the key table (`H.keyNames()`, so the names an agent
// reads and the names the host matches are one list), and answers the four
// questions below out of the result.

import { DATA, SECTIONS } from './docs.data.js';

const H = globalThis.__three;

// -----------------------------------------------------------------------
// The docs
//
// `version` and `summary` first, then the sections in the order README.md
// lists them — `differences` before anything, because it is the section that
// stops scripts failing. `keys` is the whole key table, from the host.
// Aliases included: ctrl, cmd, esc. No numpad and no mouse buttons —
// mesh.pick and the mouse are the camera's, and a latched mouse button is a
// trap the window has already been caught by once.

export const DOCS = { version: DATA.version, summary: DATA.summary };
for (const { key } of SECTIONS) DOCS[key] = key === 'keys' ? H.keyNames() : DATA[key];

export { SECTIONS };

// -----------------------------------------------------------------------
// Reading the docs rather than swallowing them
//
// `DOCS` is about 113 KB of JSON — thirty thousand tokens an agent pays
// before it has written a line — and from anywhere but this repository it
// is ungreppable: these strings are embedded in the binary, so there is no
// file for the usual tools to search. An agent that wanted one fact had to
// take all of them or none.
//
// So the docs answer four questions instead of one. `docsIndex()` is what a
// bare ask gets: everything short in full, and the NAMES of everything long.
// `docsSearch(term)` is the grep — every entry whose path or prose mentions
// a word, with its text. `findSection(path)` is the drill-down after either.
// `docsMarkdown()` is the whole surface as a file, one heading per entry,
// for the agent that would rather grep it with its own tools and never call
// this again. The full dump is still there behind `{ all: true }`, because
// an agent with the room for it should be able to say so.

// Dumped whole in the index. Each is short, and each is read on nearly every
// task: `differences` is the section that stops scripts failing, and `stats`
// is the block that comes back from every `run_script` whether asked for or
// not. `classes` and `functions` are the 83 KB that becomes a name list.
const INDEX_WHOLE = [
	'version', 'summary', 'differences', 'keys', 'stats', 'intersection',
	'example', 'exampleFromFile',
];

const HOW =
	'This is the INDEX, not the whole documentation: `classes` and `functions` are name lists '
	+ 'here and the prose behind a name is one call away. { search: "shadow" } is the grep — every '
	+ 'entry whose name or text mentions a word, in full. { section: "classes.ShaderMaterial" } is '
	+ 'one entry or one whole section, and a bare name like "ShaderMaterial" is found too. '
	+ '{ path: "api.md" } also writes the whole surface to a file, which is how you grep it with '
	+ 'ordinary tools instead of calling this again. { all: true } is everything at once, the way '
	+ 'this used to answer. From a script the same four are three.getApiDocs({ ... }).';

// One answer is capped at roughly this many characters of prose. A search for
// a common word matches half the API, and an answer that quietly became the
// whole dump again would defeat the point of asking narrowly.
const SEARCH_BUDGET = 20000;

// The compact answer: everything short, and the names of everything long.
export function docsIndex() {
	const index = { how: HOW };
	for (const [key, value] of Object.entries(DOCS)) {
		index[key] = INDEX_WHOLE.includes(key) ? value : Object.keys(value);
	}
	return index;
}

// Every entry whose path or prose mentions `term`, case-insensitively.
//
// Entries come back whole and keyed by the path `section` takes, so a hit is
// both the answer and the way to ask for its neighbours.
export function docsSearch(term) {
	const query = String(term == null ? '' : term).trim();
	if (query.length === 0) return { query, matches: 0, entries: {} };

	const wanted = query.toLowerCase();
	const hits = [];
	for (const [path, value] of docsEntries()) {
		if (path.toLowerCase().includes(wanted) || entryText(value).toLowerCase().includes(wanted)) {
			hits.push([path, value]);
		}
	}

	const answer = { query, matches: hits.length, entries: {} };
	const notShown = [];
	let spent = 0;
	for (const [path, value] of hits) {
		const cost = path.length + entryText(value).length;
		// `spent > 0` so the first hit is always answered with, however long it
		// is: an answer that dropped everything would be worse than a long one.
		if (spent > 0 && spent + cost > SEARCH_BUDGET) { notShown.push(path); continue; }
		answer.entries[path] = value;
		spent += cost;
	}
	if (notShown.length > 0) {
		answer.notShown = notShown;
		answer.note = `${notShown.length} more entries matched than fit in one answer. They are named `
			+ 'in notShown — ask for one with { section } — or search for something narrower.';
	}
	return answer;
}

// One entry or one whole section, by the path `docsSearch` keys its hits with.
//
// Answers { path, value } for what was found, or null.
export function findSection(path) {
	let node = DOCS;
	let rest = String(path == null ? '' : path).trim();
	const walked = [];

	while (rest.length > 0) {
		if (node === null || typeof node !== 'object') return null;
		const key = longestKey(node, rest);
		if (key === null) return bareName(String(path).trim());
		walked.push(key);
		node = node[key];
		rest = rest.slice(key.length + 1);
	}
	if (walked.length === 0) return null;
	return { path: walked.join('.'), value: node };
}

// The whole surface as Markdown, one heading per entry.
//
// A file rather than an answer: the headings are the paths `section` takes, so
// a grep hit names the thing to ask about next as well as answering.
export function docsMarkdown() {
	const out = [
		'# three.c3 — the scripting API',
		'',
		`Version ${DOCS.version}. ${DOCS.summary}`,
		'',
		'Written out of the docs embedded in the binary; `get_api_docs` answers out of the same '
		+ 'object, so this file and the tool cannot disagree. Every heading below is a path that '
		+ '`three.getApiDocs({ section: "..." })` accepts.',
		'',
	];

	let section = null;
	for (const [path, value] of docsEntries()) {
		const head = path.split('.')[0];
		if (head !== section) { section = head; out.push(`## ${head}`, ''); }
		if (path !== head) out.push(`### ${path}`, '');
		out.push(entryMarkdown(path, value), '');
	}
	return out.join('\n');
}

// The one entry the host calls, and what `three.getApiDocs(options)` is.
//
// `options` is a search string, or { search, section, all, markdown }, or
// nothing at all — which is the index.
export function docsQuery(options) {
	if (options === null || options === undefined) return docsIndex();
	if (typeof options === 'string') return docsSearch(options);
	if (options.all === true) return DOCS;
	if (options.markdown === true) return docsMarkdown();

	const search = typeof options.search === 'string' ? options.search.trim() : '';
	if (search.length > 0) return docsSearch(search);

	const section = typeof options.section === 'string' ? options.section.trim() : '';
	if (section.length > 0) {
		const found = findSection(section);
		if (found === null) {
			return {
				section,
				found: false,
				sections: Object.keys(DOCS),
				note: 'No entry by that name. The top-level sections are in `sections`, and '
					+ '{ search } finds an entry whose name you only half remember.',
			};
		}
		return { section: found.path, entry: found.value };
	}
	return docsIndex();
}

// The longest key of `node` that `rest` begins with, on a '.' boundary and
// case-insensitively. Longest rather than first because a function is keyed by
// its whole call — `three.load(path)` — so not every dot in a path is a
// separator, and the greedy match is the only one that tells the two apart.
function longestKey(node, rest) {
	const wanted = rest.toLowerCase();
	let best = null;
	for (const key of Object.keys(node)) {
		const lower = key.toLowerCase();
		if (wanted === lower || (wanted.startsWith(lower) && wanted[lower.length] === '.')) {
			if (best === null || key.length > best.length) best = key;
		}
	}
	return best;
}

// `section: "ShaderMaterial"` rather than `"classes.ShaderMaterial"`. An agent
// that read a class name out of the index and asked for it by that name asked
// a reasonable question, and one level of looking is the whole answer.
function bareName(name) {
	const wanted = name.toLowerCase();
	for (const [group, value] of Object.entries(DOCS)) {
		if (value === null || typeof value !== 'object' || Array.isArray(value)) continue;
		for (const key of Object.keys(value)) {
			if (key.toLowerCase() === wanted) return { path: `${group}.${key}`, value: value[key] };
		}
	}
	return null;
}

// Every entry of the docs as [path, value].
//
// The shape is two deep and this walk knows it: a top-level plain object is a
// SECTION, everything one level inside one is an entry, and nothing deeper is.
// That is the line that matters, and no test on the values finds it — a class
// record's { construct, note, properties, methods } is four halves of one
// answer and has to stay whole, while `differences` is a map of the same shape
// holding fifty separate answers that must not be glued into one.
function docsEntries() {
	const out = [];
	for (const [key, value] of Object.entries(DOCS)) {
		if (isSection(value)) {
			for (const [name, entry] of Object.entries(value)) out.push([`${key}.${name}`, entry]);
			continue;
		}
		out.push([key, value]);
	}
	return out;
}

function isSection(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function entryText(value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return value;
	if (Array.isArray(value)) return value.join('\n');
	if (typeof value !== 'object') return String(value);
	return Object.entries(value).map(([key, field]) => `${key} ${entryText(field)}`).join('\n');
}

// The two leaves whose value is code rather than prose. Everything else was
// written as Markdown and goes in as it is.
const CODE = ['example', 'exampleFromFile'];

function entryMarkdown(path, value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return CODE.includes(path) ? fence(value) : value;
	if (Array.isArray(value)) return bullets(value);
	if (typeof value !== 'object') return String(value);

	// A class record, laid out the way its Markdown file is.
	const out = [];
	if (value.construct) out.push(fence(value.construct));
	if (value.note) out.push(value.note);
	if (value.properties) out.push(`**Properties**\n\n${bullets(value.properties)}`);
	if (value.methods) out.push(`**Methods**\n\n${bullets(value.methods)}`);
	for (const [member, text] of Object.entries(value.details || {})) out.push(`**${member}** — ${text}`);
	return out.join('\n\n');
}

function fence(code) {
	return '```js\n' + code + '\n```';
}

function bullets(items) {
	return items.map(item => `- ${item}`).join('\n');
}
