// The build.
//
// There is no page generation here any more: the site is one `index.html` and
// one bundle, and everything the reader sees is rendered by Lit in the browser.
// What is left is the four things a browser cannot do for itself — generate the
// reference out of the engine's docs, turn the tutorial Markdown into something
// fetchable, roll the app up with esbuild, and copy the files.

import { readFile, writeFile, mkdir, readdir, rm, cp } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';
import { build as bundle } from 'esbuild';

import { generate } from './gen-api.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, 'dist');
const assets = join(out, 'assets');

// `classes.Mesh` -> the `Mesh` half of `#/api/classes/Mesh`. Anything outside
// the safe set becomes a dash, because a function entry is keyed by its whole
// call — `load(path)` — and that has to survive being an id and a fragment.
function slug(name) {
	return String(name).replace(/[^A-Za-z0-9_-]+/g, '-').replace(/-+$/g, '');
}

// A duplicate slug is a deep link that silently lands on the wrong entry. It
// only shows after the deploy, so it fails here instead.
function checkSlugs(entries) {
	const taken = new Map();
	for (const entry of entries) {
		const id = `${entry.section}/${slug(entry.name)}`;
		if (taken.has(id)) throw new Error(`api: "${entry.path}" and "${taken.get(id)}" both route to #/api/${id}`);
		taken.set(id, entry.path);
	}
}

// ------------------------------------------------------------- tutorials --

// `title`, `order`, `summary` — three scalar keys, and no reason to carry a
// YAML parser for them.
function frontmatter(raw) {
	const found = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
	if (!found) return { meta: {}, content: raw };
	const meta = {};
	for (const line of found[1].split(/\r?\n/)) {
		const pair = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
		if (pair) meta[pair[1]] = pair[2].trim().replace(/^["'](.*)["']$/, '$1');
	}
	return { meta, content: raw.slice(found[0].length) };
}

// The fenced JavaScript, concatenated in the order it appears. A block marked
// ```js ignore is prose about code — a counter-example, a line to compare
// against — and is left out of the file that has to run.
function scriptFrom(source) {
	const blocks = [];
	for (const block of source.matchAll(/^```(js|javascript)([^\n]*)\n([\s\S]*?)^```/gm)) {
		if (/\bignore\b/.test(block[2])) continue;
		blocks.push(block[3].trimEnd());
	}
	return blocks.length === 0 ? null : blocks.join('\n\n') + '\n';
}

async function tutorials() {
	const dir = join(here, 'tutorials');
	const files = existsSync(dir)
		? (await readdir(dir)).filter(file => file.endsWith('.md')).sort()
		: [];

	const entries = [];
	for (const file of files) {
		const { meta, content } = frontmatter(await readFile(join(dir, file), 'utf8'));
		const slugged = file.replace(/\.md$/, '');
		entries.push({
			slug: slugged, content,
			title: meta.title || slugged,
			summary: meta.summary || '',
			order: Number(meta.order ?? 999),
			script: scriptFrom(content),
		});
	}
	entries.sort((a, b) => a.order - b.order || a.slug.localeCompare(b.slug));

	// The tutorials link to each other as files, so that the Markdown reads on
	// GitHub too. `lib/markup.js` turns those into routes — and a link to a file
	// that was renamed resolves nowhere in either place, which is worth a red
	// build rather than a dead link on the deploy.
	const known = new Set(entries.map(entry => entry.slug));
	for (const entry of entries) {
		for (const [, href] of entry.content.matchAll(/\]\((\d\d-[a-z0-9-]+)\.html\)/g)) {
			if (!known.has(href)) throw new Error(`${entry.slug}.md links to ${href}.html, which is not a tutorial`);
		}
	}
	return entries;
}

// ----------------------------------------------------------------- build --

async function build() {
	const started = process.hrtime.bigint();
	await rm(out, { recursive: true, force: true });
	await mkdir(assets, { recursive: true });

	const api = await generate();
	checkSlugs(api.entries);
	const steps = await tutorials();

	// The two values the home page needs, compiled into the bundle rather than
	// fetched: a couple of kilobytes, against a request the first route a
	// visitor lands on would otherwise have to wait for.
	const shots = await screenshots();
	await mkdir(join(here, '.generated'), { recursive: true });
	await writeFile(join(here, '.generated/data.js'),
		'// Written by build.mjs. Not checked in.\n'
		+ `export const META = ${JSON.stringify({
			version: api.version,
			summary: api.summary,
			example: api.docs.example,
			entryCount: api.entries.length,
			sectionCount: api.sections.length,
		}, null, '\t')};\n\n`
		+ `export const SHOTS = ${JSON.stringify(shots, null, '\t')};\n`);

	// `text` is left out: it is the prose of an entry concatenated, and the
	// prose is already in `value`. The reference builds its search index from
	// that on the way in rather than being sent the same words twice.
	await writeFile(join(assets, 'api.json'), JSON.stringify({
		version: api.version,
		sections: api.sections,
		entries: api.entries.map(e => ({ path: e.path, section: e.section, name: e.name, value: e.value })),
	}));

	await writeFile(join(assets, 'tutorials.json'), JSON.stringify(
		steps.map(({ slug: id, title, summary, content, script }) =>
			({ slug: id, title, summary, content, script: Boolean(script) }))));

	// The runnable file beside each tutorial is a real file, because `--script`
	// takes a path and a blob the page assembled is not something to keep.
	await mkdir(join(assets, 'scripts'), { recursive: true });
	for (const step of steps) {
		if (step.script) await writeFile(join(assets, 'scripts', `${step.slug}.js`), step.script);
	}

	const bundled = await app();

	await cp(join(here, 'assets'), assets, { recursive: true });
	await cp(join(here, 'index.html'), join(out, 'index.html'));
	if (existsSync(join(here, 'screenshots'))) {
		await cp(join(here, 'screenshots'), join(out, 'screenshots'), { recursive: true });
	}

	await writeFile(join(out, '404.html'), notFound());
	// Pages serves what it is given and adds nothing; this stops Jekyll from
	// eating anything if the source is ever pointed at a branch instead.
	await writeFile(join(out, '.nojekyll'), '');

	await checkShell();

	const ms = Number(process.hrtime.bigint() - started) / 1e6;
	console.log(`built in ${ms.toFixed(0)} ms`);
	console.log(`  bundle.js        ${(bundled / 1024).toFixed(1)} KB`);
	console.log(`  api.json         ${(Buffer.byteLength(await readFile(join(assets, 'api.json'))) / 1024).toFixed(1)} KB  ${api.entries.length} entries`);
	console.log(`  tutorials.json   ${(Buffer.byteLength(await readFile(join(assets, 'tutorials.json'))) / 1024).toFixed(1)} KB  ${steps.length} tutorials`);
}

// Lit, the router, the views and the two live widgets, in one ES module. A
// module rather than an IIFE because that is what a browser loads without a
// build step of its own, and bundled rather than import-mapped because Lit's
// own imports are bare specifiers no browser resolves.
async function app() {
	const result = await bundle({
		entryPoints: [join(here, 'app/main.js')],
		outfile: join(assets, 'bundle.js'),
		bundle: true,
		format: 'esm',
		minify: true,
		target: 'es2022',
		legalComments: 'none',
		metafile: true,
	});
	return Object.values(result.metafile.outputs)[0].bytes;
}

// A shot missing from disk is dropped rather than rendered as a broken image.
async function screenshots() {
	const dir = join(here, 'screenshots');
	const manifest = join(dir, 'captions.json');
	if (!existsSync(manifest)) return [];
	return JSON.parse(await readFile(manifest, 'utf8'))
		.filter(shot => existsSync(join(dir, shot.file)));
}

// Every URL the old site got wrong, it got wrong the same way: an absolute path
// resolves locally and 404s under /three.c3/. There is one document now, so the
// check is one document long — and it also makes sure the files it names were
// actually written.
async function checkShell() {
	const html = await readFile(join(out, 'index.html'), 'utf8');

	const absolute = [...html.matchAll(/(?:href|src)="(\/[^/][^"]*)"/g)].map(m => m[1]);
	if (absolute.length > 0) {
		throw new Error(`index.html: absolute paths break the /three.c3/ base — ${absolute.join(', ')}`);
	}

	for (const [, href] of html.matchAll(/(?:href|src)="([^":#]+)"/g)) {
		if (/^(https?:|mailto:|data:)/.test(href)) continue;
		if (!existsSync(join(out, href))) throw new Error(`index.html: references ${href}, which was not built`);
	}
}

// Pages has no rewrite rules, so `/three.c3/api.html` — a URL from when this
// site was nine documents — is a 404 it serves this file for. The path it was
// asked for is still in the address bar, so the route is recoverable: work out
// where the site root is by stripping the tail, and send the reader there.
function notFound() {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Redirecting — three.c3</title>
<script>
(function () {
	var path = location.pathname;
	var tutorial = path.match(/^(.*\\/)tutorials\\/(\\d\\d-[a-z0-9-]+)\\.html$/);
	var api = path.match(/^(.*\\/)api\\.html$/);
	var list = path.match(/^(.*\\/)tutorials\\/(index\\.html)?$/);

	var base = (tutorial || api || list || [, path.replace(/[^/]*$/, '')])[1];
	var route = tutorial ? '#/tutorials/' + tutorial[2] : api ? '#/api' : list ? '#/tutorials' : '#/404';

	location.replace(base + 'index.html' + route);
}());
</script>
</head>
<body><p>Redirecting to <a href="index.html">three.c3</a>.</p></body>
</html>
`;
}

await build();
