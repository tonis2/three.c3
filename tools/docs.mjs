// The API docs, compiled from `docs/` into the module the engine embeds.
//
// The scripting API is documented in Markdown under `docs/` — a file per
// section, a heading per entry — because that is what a person edits, what
// GitHub renders and what an agent reads. The engine cannot embed a folder of
// Markdown and answer `three.getApiDocs({ search })` out of it, so this turns
// the folder into `src/js/prelude/docs.data.js`: one object, the shape
// `docs.js` walks. `docs/README.md` is the guide to the format.
//
// This lives under `site/` and the engine does not run it. `c3c build` embeds
// `docs.data.js` and nothing more, which is why that file is committed rather
// than generated on the way past: an engine build that shelled out to a script
// in the website folder would have the dependency backwards, and one that
// silently regenerated an embedded artifact is the trap `runtime.c3` warns
// about. So the flow is: edit `docs/`, run this, commit both. `--check` is what
// stops the two drifting — it fails if the committed module is not what the
// folder compiles to, and CI runs it.
//
//   node site/tools/docs.mjs           write docs.data.js if the docs changed
//   node tools/docs.mjs --check   compile and report, write nothing
//   node tools/docs.mjs --print   the compiled object, as JSON, to stdout
//
// The Markdown it reads is a subset, and it is strict about it: headings,
// paragraphs, fenced code, `- ` lists and <!-- comments -->. Anything else is
// an error naming the file and the line, because an entry that quietly
// compiled to nothing is worse than a build that stopped. No dependencies, on
// purpose: `c3c build` runs this, and it must not need `npm install` first.

import { readFile, readdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '../');
export const source = join(repoRoot, 'docs');
export const output = join(repoRoot, 'src/js/prelude/docs.data.js');

// The one section whose entries are records rather than prose. Named rather
// than detected, so a class written into another file is an error and not a
// differently-shaped entry.
const CLASSES = 'classes';

// The one section that is not written in `docs/`: the key table comes from
// the engine, so the names an agent reads and the names the host matches are
// one list. Listed in README.md for its place and its blurb, and appended
// here if it was not.
const KEYS = 'keys';
const KEYS_BLURB = 'The names `three.input` and `three.onKey` match against, read out of the '
	+ 'engine\'s own key table.';

// ------------------------------------------------------------------ compile --

// The whole folder as `{ data, sections }`.
//
// `data` is what `docs.js` spreads into `DOCS`: `version`, `summary` and then
// one property per section in README order. `sections` is that order with a
// blurb each, `keys` included, for `docs.js` to walk and the site to head its
// panes with.
//
// README says which file each section is written in, so a short section need
// not be a file of its own: two links to the same `.md` with a different
// `#heading` each are two sections out of one file. A file nobody links to is
// still a section, named after itself, which is the common case.
export async function compile() {
	const readme = await guide(join(source, 'README.md'));
	const version = JSON.parse(await readFile(join(repoRoot, 'project.json'), 'utf8')).version;
	if (typeof version !== 'string') throw new Error('project.json has no "version"');

	const files = [];
	for (const entry of (await readdir(source, { withFileTypes: true })).sort(byName)) {
		if (entry.name.startsWith('.') || entry.name === 'README.md') continue;
		if (!entry.isFile() || !entry.name.endsWith('.md')) continue;
		files.push(entry.name);
	}

	// Read once however many sections come out of it.
	const parsed = new Map();
	const blocksOf = async name => {
		if (!parsed.has(name)) {
			const path = join(source, name);
			parsed.set(name, parse(await readFile(path, 'utf8'), path));
		}
		return parsed.get(name);
	};

	// README order first, then any file it did not mention, alphabetically.
	const sections = [];
	const data = { version, summary: readme.summary };
	const linked = new Set();

	for (const { key, file: name, anchor, blurb, line } of readme.sections) {
		if (sections.some(s => s.key === key)) fail('README.md', line, `lists "${key}" twice`);
		sections.push({ key, blurb });
		if (key === KEYS) continue;
		if (name === '') fail('README.md', line, `"${key}" needs a link to the file it is written in`);
		if (!files.includes(name)) fail('README.md', line, `lists "${key}" as docs/${name}, which is not there`);
		linked.add(name);
		data[key] = await read(key, name, anchor, await blocksOf(name));
	}

	for (const name of files) {
		if (linked.has(name)) continue;
		const key = name.slice(0, -3);
		if (sections.some(s => s.key === key)) {
			fail(join(source, name), 1, `no README.md link points here and "${key}" is already a section`);
		}
		sections.push({ key, blurb: '' });
		data[key] = await read(key, name, '', await blocksOf(name));
	}

	if (!sections.some(s => s.key === KEYS)) sections.push({ key: KEYS, blurb: KEYS_BLURB });
	return { data, sections };
}

// One section out of one file: the whole of it, or the part under the
// `# heading` the README link named.
async function read(key, name, anchor, blocks) {
	const path = join(source, name);
	const body = anchor === '' ? blocks : part(blocks, anchor, path);
	return key === CLASSES ? classes(body, path) : file(body, path);
}

// The blocks under `# heading`, for a file holding more than one section. The
// same `#` headings that are dividers for the reader everywhere else, so a
// file reads the same whether or not a link picks it apart.
function part(blocks, anchor, path) {
	const at = blocks.findIndex(block => isTitle(block) && slug(block.text) === anchor);
	if (at === -1) fail(path, 1, `no "# heading" in here is #${anchor}`);
	const next = blocks.findIndex((block, i) => i > at && isTitle(block));
	return blocks.slice(at + 1, next === -1 ? blocks.length : next);
}

// A heading as GitHub anchors it, so the link a reader clicks and the link the
// compiler follows are the same one.
function slug(text) {
	return text.toLowerCase().replace(/[^\w]+/g, '-').replace(/^-+|-+$/g, '');
}

// A section holding entries: one per `## heading`, or one per
// `- `name` — text` list item — or, with neither, one value: the code of its
// single fenced block, or its prose as Markdown. A `# heading` anywhere is a
// title or a divider for the reader and compiles to nothing, which is how
// functions.md groups its entries by area without that changing their keys.
function file(blocks, path) {
	const body = blocks.filter(block => !isTitle(block));

	const hasEntries = body.some(b => (b.type === 'heading' && b.level === 2) || b.type === 'list');
	if (!hasEntries) {
		if (body.length === 0) fail(path, 1, 'nothing in it');
		return body.length === 1 && body[0].type === 'code' ? body[0].text : markdown(body);
	}

	const value = {};
	let i = 0;
	while (i < body.length) {
		const block = body[i];
		if (block.type === 'heading' && block.level === 2) {
			const name = block.text;
			i++;
			const own = [];
			while (i < body.length && !(body[i].type === 'heading' && body[i].level === 2)) own.push(body[i++]);
			if (own.length === 0) fail(path, block.line, `## ${name} has nothing under it`);
			add(value, name, markdown(own), path, block.line);
			continue;
		}
		if (block.type === 'list') {
			for (const item of block.items) {
				const m = item.match(/^`([^`]+)` — (.+)$/);
				if (!m) fail(path, block.line, 'an entry in a list is `- `name` — what it is`');
				add(value, m[1], m[2], path, block.line);
			}
			i++;
			continue;
		}
		fail(path, block.line, 'a section file holds `## name` entries or `- `name` — text` items; '
			+ 'a paragraph about the section itself belongs in README.md');
	}
	return value;
}

function add(into, name, value, path, line) {
	if (name in into) fail(path, line, `"${name}" is documented twice`);
	into[name] = value;
}

function isTitle(block) {
	return block.type === 'heading' && block.level === 1;
}

// `docs/classes.md`: one class per `## Name` —
//
//   ## Name
//   ```js
//   new three.Name(args)
//   ```
//   What it is.
//   ### Properties         - `name`  or  - `name` — what it is
//   ### Methods            - `call(args)`
//   ### Details            #### member, then its paragraphs
//
// each into { construct, note, properties, methods, details }, the record the
// site and `docsMarkdown()` both know how to lay out.
function classes(all, path) {
	const blocks = all.filter(block => !isTitle(block));
	const into = {};
	let i = 0;
	while (i < blocks.length) {
		const head = blocks[i];
		if (head.type !== 'heading' || head.level !== 2) {
			fail(path, head.line, 'a class starts with `## Name`, and nothing stands between one class and the next');
		}
		i++;
		const own = [];
		while (i < blocks.length && !(blocks[i].type === 'heading' && blocks[i].level === 2)) own.push(blocks[i++]);
		if (head.text in into) fail(path, head.line, `## ${head.text} twice`);
		into[head.text] = classRecord(own, path, head);
	}
	if (Object.keys(into).length === 0) fail(path, 1, 'no classes in it');
	return into;
}

function classRecord(blocks, path, head) {
	const construct = blocks[0];
	if (!construct || construct.type !== 'code') {
		fail(path, head.line, `after ## ${head.text} comes a fenced code block showing how it is constructed`);
	}

	let i = 1;
	const note = [];
	while (i < blocks.length && !isPart(blocks[i])) note.push(blocks[i++]);
	if (note.length === 0) fail(path, construct.line, `${head.text} needs a note: a paragraph saying what it is`);

	const record = { construct: construct.text, note: markdown(note) };
	while (i < blocks.length) {
		const part = blocks[i];
		i++;
		const body = [];
		while (i < blocks.length && !isPart(blocks[i])) body.push(blocks[i++]);
		switch (part.text) {
			case 'Properties': record.properties = members(body, path, part); break;
			case 'Methods': record.methods = members(body, path, part); break;
			case 'Details': record.details = details(body, path, part); break;
			default: fail(path, part.line, `"${part.text}" is not a part of a class — Properties, Methods or Details`);
		}
	}

	if (record.details) {
		const listed = [...(record.properties || []), ...(record.methods || [])].map(memberName);
		for (const member of Object.keys(record.details)) {
			if (!listed.includes(member)) fail(path, head.line, `#### ${member} under ${head.text}'s Details explains a member that is not listed`);
		}
	}

	// A fixed key order whatever order the file wrote its parts in.
	const ordered = {};
	for (const key of ['construct', 'note', 'properties', 'methods', 'details']) {
		if (key in record) ordered[key] = record[key];
	}
	return ordered;
}

function isPart(block) {
	return block.type === 'heading' && block.level === 3;
}

// `- `position``, or `- `isActive` — whether this is the one being rendered`.
// The second form compiles to `isActive (whether this is ...)`, the string the
// renderers already split on.
function members(body, path, part) {
	const out = [];
	for (const block of body) {
		if (block.type !== 'list') fail(path, block.line, `${part.text} holds a list of members and nothing else`);
		for (const item of block.items) {
			const m = item.match(/^`([^`]+)`(?: — (.+))?$/);
			if (!m) fail(path, block.line, 'a member is `- `name`` or `- `name` — what it is`');
			out.push(m[2] ? `${m[1]} (${m[2]})` : m[1]);
		}
	}
	if (out.length === 0) fail(path, part.line, `${part.text} lists nothing`);
	return out;
}

// `#### member` followed by its paragraphs, for the members whose one line in
// the list was not enough.
function details(body, path, part) {
	const out = {};
	let i = 0;
	while (i < body.length) {
		const sub = body[i];
		if (sub.type !== 'heading' || sub.level !== 4) fail(path, sub.line, 'Details holds `#### member` headings, each with its paragraphs');
		i++;
		const own = [];
		while (i < body.length && body[i].type !== 'heading') own.push(body[i++]);
		if (own.length === 0) fail(path, sub.line, `#### ${sub.text} has nothing under it`);
		if (sub.text in out) fail(path, sub.line, `#### ${sub.text} twice`);
		out[sub.text] = markdown(own);
	}
	if (Object.keys(out).length === 0) fail(path, part.line, 'Details is empty');
	return out;
}

function memberName(member) {
	const found = member.match(/^[A-Za-z_$][\w$]*/);
	return found ? found[0] : member;
}

// README.md: the summary is its first paragraph and the section order is its
// first list — `- [name](name.md) — blurb`, where the link says which file the
// section is written in and a `#heading` on the end says which part of it.
async function guide(path) {
	const blocks = parse(await readFile(path, 'utf8'), path);
	const summary = blocks.find(b => b.type === 'para');
	if (!summary) fail(path, 1, 'README.md opens with a paragraph, which becomes the summary');
	const list = blocks.find(b => b.type === 'list');
	if (!list) fail(path, 1, 'README.md lists the sections — `- [name](name.md) — blurb`');

	const sections = [];
	for (const item of list.items) {
		const m = item.match(/^(?:\[([^\]]+)\]\(([^)]*)\)|`([^`]+)`|([\w-]+)) — (.+)$/);
		if (!m) fail(path, list.line, `not a section line: "${item}" — wanted \`- [name](name.md) — blurb\``);
		const [file, anchor = ''] = (m[2] || '').split('#');
		sections.push({ key: m[1] || m[3] || m[4], file, anchor, blurb: m[5], line: list.line });
	}
	return { summary: summary.text, sections };
}

// -------------------------------------------------------------------- parse --

// The Markdown subset, as a flat list of blocks:
//
//   { type: 'heading', level, text }
//   { type: 'para', text }          lines joined by one space
//   { type: 'code', lang, text }    a ``` fence
//   { type: 'list', items }         `- ` items; a following unindented or
//                                   indented line continues the item
//
// each with the `line` it started on. Comments are gone before any of this
// looks, so a commented-out item does not end a list.
export function parse(text, path) {
	const lines = text.replace(/<!--[\s\S]*?-->/g, '').split(/\r?\n/);
	const blocks = [];
	let i = 0;

	while (i < lines.length) {
		const line = lines[i];
		if (line.trim() === '') { i++; continue; }

		// A fence closes on a run of backticks at least as long as the one that
		// opened it, so a four-backtick fence can quote a three-backtick one.
		const fence = line.match(/^(`{3,})(\S*)\s*$/);
		if (fence) {
			const start = i;
			const body = [];
			const closer = new RegExp(`^\`{${fence[1].length},}\\s*$`);
			i++;
			while (i < lines.length && !closer.test(lines[i])) body.push(lines[i++]);
			if (i >= lines.length) fail(path, start + 1, 'a code fence that never closes');
			i++;
			blocks.push({ type: 'code', lang: fence[2], text: body.join('\n'), line: start + 1 });
			continue;
		}

		const heading = line.match(/^(#{1,6}) +(.*?)\s*$/);
		if (heading) {
			blocks.push({ type: 'heading', level: heading[1].length, text: heading[2], line: i + 1 });
			i++;
			continue;
		}

		if (/^- /.test(line)) {
			const start = i;
			const items = [];
			while (i < lines.length && /^- /.test(lines[i])) {
				let item = lines[i].slice(2).trim();
				i++;
				while (i < lines.length && continues(lines[i])) item += ' ' + lines[i++].trim();
				items.push(item);
			}
			blocks.push({ type: 'list', items, line: start + 1 });
			continue;
		}

		const start = i;
		const para = [];
		while (i < lines.length && continues(lines[i])) para.push(lines[i++].trim());
		blocks.push({ type: 'para', text: para.join(' '), line: start + 1 });
	}
	return blocks;
}

// A line that carries on the paragraph or list item before it.
function continues(line) {
	return line.trim() !== '' && !/^(```|#{1,6} |- )/.test(line);
}

// Blocks back to Markdown, normalised: one paragraph per line, fences kept,
// lists re-bulleted. This is the string an entry compiles to, so what an
// agent reads is Markdown too.
function markdown(blocks) {
	return blocks.map(block => {
		switch (block.type) {
			case 'para': return block.text;
			case 'code': return '```' + block.lang + '\n' + block.text + '\n```';
			case 'list': return block.items.map(item => `- ${item}`).join('\n');
			case 'heading': return '#'.repeat(block.level) + ' ' + block.text;
			default: throw new Error(`unknown block ${block.type}`);
		}
	}).join('\n\n');
}

function fail(path, line, message) {
	throw new Error(`${relative(repoRoot, path)}:${line}: ${message}`);
}

function byName(a, b) {
	return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

// -------------------------------------------------------------------- write --

// The module. JSON is JavaScript, so the object is written as it is; the two
// line separators JSON allows raw and older parsers do not are escaped.
export function moduleSource({ data, sections }) {
	const literal = value => JSON.stringify(value, null, '\t').replace(/[\u2028\u2029]/g, c => `\\u${c.charCodeAt(0).toString(16)}`);
	return '// Generated from docs/ by site/tools/docs.mjs — edit the Markdown, not this file.\n'
		+ '// `c3c build` regenerates it; `docs.js` reads it.\n\n'
		+ `export const DATA = ${literal(data)};\n\n`
		+ `export const SECTIONS = ${literal(sections)};\n`;
}

// Throws unless the committed module is what the folder compiles to. This is
// the whole of what keeps a `docs/` edit from shipping as a stale embedded
// answer, now that no build step rewrites the file behind you.
export async function current(compiled) {
	const want = moduleSource(compiled);
	let have = null;
	try { have = await readFile(output, 'utf8'); } catch { have = null; }
	if (have === want) return;

	const where = relative(repoRoot, output);
	throw new Error(have === null
		? `${where} is missing — run \`node site/tools/docs.mjs\` and commit it`
		: `${where} is not what docs/ compiles to — run \`node site/tools/docs.mjs\` and commit the result`);
}

// Writes `docs.data.js`, and only if it changed, so an untouched docs folder
// leaves the file's mtime alone. Answers whether it wrote.
export async function write(compiled) {
	const next = moduleSource(compiled);
	let current = null;
	try { current = await readFile(output, 'utf8'); } catch { current = null; }
	if (current === next) return false;
	await writeFile(output, next);
	return true;
}

export function count(data) {
	let n = 0;
	for (const value of Object.values(data)) {
		n += value !== null && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).length : 1;
	}
	return n;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const mode = process.argv[2] || '--write';
	try {
		const compiled = await compile();
		const entries = count(compiled.data);
		if (mode === '--print') {
			process.stdout.write(JSON.stringify(compiled, null, 2) + '\n');
		} else if (mode === '--check') {
			await current(compiled);
			console.log(`docs ok: ${entries} entries in ${compiled.sections.length} sections`);
			for (const { key } of compiled.sections) {
				const value = compiled.data[key];
				const n = value === undefined ? '(from the engine)' : typeof value === 'string' ? '1' : Object.keys(value).length;
				console.log(`  ${key.padEnd(16)} ${n}`);
			}
		} else if (mode === '--write') {
			if (await write(compiled)) console.log(`docs: wrote ${relative(repoRoot, output)} — ${entries} entries`);
		} else {
			throw new Error(`unknown option ${mode} — --write, --check or --print`);
		}
	} catch (error) {
		console.error(`docs: ${error.message}`);
		process.exit(1);
	}
}
