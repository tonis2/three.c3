// The API reference, generated rather than written.
//
// `docs/` is the one source of truth for the scripting API, and this reads it:
// `tools/docs.mjs` — the same compiler `c3c build` runs to produce the module
// the engine embeds — turns the folder into `{ data, sections }`, and the two
// walks below turn that into the page. No C3 build, no GPU and no binary
// anywhere in the picture.
//
// It used to go the long way round: compile the folder, write
// `src/js/prelude/docs.data.js`, then import `docs.js` under a stub for its one
// host call and read `DOCS` off it. That bought nothing — the site never used
// the engine's reading side, only the object underneath it — and cost a build
// of the website that wrote into the engine's source tree.
//
// `keys` is the one section not in `docs/`: the key table is the engine's, so
// the names an agent reads are the names the host matches. `docs.js` fills it
// from the host binding; here it is parsed out of the table itself.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { compile } from '../tools/docs.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..');

// Parse the names out of the KEY_NAMES table rather than keeping a second copy
// of them here.
export async function keyNames() {
	const source = await readFile(join(repoRoot, 'src/scene/input.c3'), 'utf8');
	const table = source.match(/const KeyName\[\*\] KEY_NAMES = \{([\s\S]*?)\n\};/);
	if (table === null) throw new Error('gen-api: KEY_NAMES table not found in src/scene/input.c3');

	const names = [];
	for (const row of table[1].matchAll(/\{\s*"((?:[^"\\]|\\.)*)"/g)) names.push(row[1]);

	// A silently empty key section is worse than a red build: the page would
	// look finished and the one list a script has to spell exactly would be
	// missing. So this is fatal rather than a warning.
	if (names.length === 0) throw new Error('gen-api: KEY_NAMES parsed to zero names');
	return names;
}

// `DOCS` and the two walks the site needs over it.
//
// The assembly is `docs.js`'s, in the two lines it is: `version` and `summary`
// first, then one property per section in README order, with `keys` coming from
// the engine instead of the folder.
export async function generate() {
	const [{ data, sections }, keys] = await Promise.all([compile(), keyNames()]);

	const DOCS = { version: data.version, summary: data.summary };
	for (const { key } of sections) {
		if (key !== 'keys' && !(key in data)) throw new Error(`gen-api: README lists "${key}" and the compiler produced nothing for it`);
		DOCS[key] = key === 'keys' ? keys : data[key];
	}

	return {
		version: DOCS.version,
		summary: DOCS.summary,
		docs: DOCS,
		sections: sectionList(DOCS, sections),
		entries: entryList(DOCS),
	};
}

// The same two-deep rule `docsEntries()` uses, and it is the line that
// matters: a top-level plain object is a SECTION and everything one level
// inside one is an entry, nothing deeper. No test on the values finds it —
// a class record's { construct, note, properties, methods } is four halves
// of one answer and has to stay whole, while `differences` is a map of the
// same shape holding fifty separate answers that must not be glued together.
function entryList(DOCS) {
	const out = [];
	for (const [key, value] of Object.entries(DOCS)) {
		if (isSection(value)) {
			for (const [name, entry] of Object.entries(value)) {
				out.push({ path: `${key}.${name}`, section: key, name, value: entry, text: entryText(entry) });
			}
			continue;
		}
		out.push({ path: key, section: key, name: key, value, text: entryText(value) });
	}
	return out;
}

// In README order, each with its blurb; `summary` and `version` — the two
// leaves that are not sections — last.
function sectionList(DOCS, sections) {
	const keys = sections.map(s => s.key);
	for (const key of Object.keys(DOCS)) if (!keys.includes(key)) keys.push(key);
	return keys.map(key => {
		const value = DOCS[key];
		const listed = sections.find(s => s.key === key);
		return {
			key,
			count: isSection(value) ? Object.keys(value).length : 1,
			leaf: !isSection(value),
			blurb: listed ? listed.blurb : '',
		};
	});
}

function isSection(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// What search matches against: the prose of an entry, whatever shape it is.
function entryText(value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return value;
	if (Array.isArray(value)) return value.join('\n');
	if (typeof value !== 'object') return String(value);
	return Object.entries(value).map(([key, field]) => `${key} ${entryText(field)}`).join('\n');
}

// `node site/gen-api.mjs` — the CI check. A docs edit that breaks the site
// should fail on the commit that made it, not on the next deploy.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const api = await generate();
	const keyCount = api.docs.keys.length;
	console.log(`api ok: version ${api.version}, ${api.entries.length} entries, ${keyCount} key names`);
	for (const section of api.sections) console.log(`  ${section.key.padEnd(16)} ${section.count}`);
}
