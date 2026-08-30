// The API reference, generated rather than written.
//
// `src/js/prelude/docs.js` is the one source of truth for the scripting API:
// `three.getApiDocs()` answers out of it and the `get_api_docs` MCP tool
// answers out of it, so a page built from the same object cannot disagree
// with either. The module is import-free by design — its only live call is
// `globalThis.__three.keyNames()` — which is what lets this script import it
// with no C3 build, no GPU and no binary anywhere in the picture.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..');

// `keyNames` is a host binding over the KEY_NAMES table, so it is the one
// value that does not travel with the module. Parse the names out of the
// table itself rather than keeping a second copy of them here.
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
export async function generate() {
	const keys = await keyNames();

	// The stub stands in for the host binding, and for nothing else — if
	// `docs.js` ever grows a second `H.` call, this throws by name rather
	// than emitting a page with a hole in it.
	globalThis.__three = new Proxy({ keyNames: () => keys }, {
		get(target, prop) {
			if (prop in target) return target[prop];
			throw new Error(`gen-api: docs.js called __three.${String(prop)}, which this stub does not have`);
		},
	});

	const docs = await import(join(repoRoot, 'src/js/prelude/docs.js'));
	const DOCS = docs.DOCS;

	return {
		version: DOCS.version,
		summary: DOCS.summary,
		docs: DOCS,
		sections: sectionList(DOCS),
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

function sectionList(DOCS) {
	return Object.entries(DOCS).map(([key, value]) => ({
		key,
		count: isSection(value) ? Object.keys(value).length : 1,
		leaf: !isSection(value),
	}));
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

// `node site/gen-api.mjs` — the CI check. A docs.js edit that breaks the site
// should fail on the commit that made it, not on the next deploy.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const api = await generate();
	const keyCount = api.docs.keys.length;
	console.log(`api ok: version ${api.version}, ${api.entries.length} entries, ${keyCount} key names`);
	for (const section of api.sections) console.log(`  ${section.key.padEnd(16)} ${section.count}`);
}
