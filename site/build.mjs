// The whole build: markdown to HTML, the page templates, the asset copy.
//
// Plain HTML, CSS and JavaScript out the other end. No framework and no CDN —
// `marked` and `highlight.js` run here and nothing they produce is shipped as
// a library, so every page loads with no dependency and opens from a file://
// URL as readily as from Pages.

import { readFile, writeFile, mkdir, rm, cp, readdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';
import { existsSync } from 'node:fs';
import { marked } from 'marked';
import hljs from 'highlight.js';

import { generate } from './gen-api.mjs';
import * as home from './pages/index.mjs';
import * as download from './pages/download.mjs';
import * as api from './pages/api.mjs';
import * as tutorials from './pages/tutorials.mjs';
import * as screenshots from './pages/screenshots.mjs';
import * as notfound from './pages/notfound.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const out = join(here, 'dist');

export const SITE = {
	name: 'three.c3',
	// A project Pages site is served from a subdirectory. Nothing in the
	// build uses this as a prefix — every href is relative — but the meta
	// tags need one absolute origin and this is it.
	origin: 'https://tonis2.github.io/three.c3/',
	repo: 'https://github.com/tonis2/three.c3',
	owner: 'tonis2',
	project: 'three.c3',
};

const NAV = [
	{ href: 'index.html', label: 'Home' },
	{ href: 'download.html', label: 'Download' },
	{ href: 'api.html', label: 'API' },
	{ href: 'tutorials/index.html', label: 'Tutorials' },
	{ href: 'screenshots.html', label: 'Screenshots' },
];

// ---------------------------------------------------------------- helpers --

export function escapeHtml(text) {
	return String(text)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// A fenced block, highlighted here so the browser ships no highlighter.
export function codeBlock(source, language = 'javascript') {
	const known = hljs.getLanguage(language) ? language : 'plaintext';
	const html = hljs.highlight(String(source), { language: known }).value;
	return `<div class="code"><button class="copy" type="button" aria-label="Copy">Copy</button>`
		+ `<pre><code class="hljs language-${known}">${html}</code></pre></div>`;
}

// Inline markdown-ish prose: the docs strings use `code` spans and nothing
// else, so this is the whole of the markup they need.
export function prose(text) {
	return escapeHtml(text).replace(/`([^`]+)`/g, (_, code) => `<code>${code}</code>`);
}

marked.use({
	renderer: {
		code({ text, lang }) { return codeBlock(text, lang || 'plaintext'); },
	},
});

export function markdown(source) {
	return marked.parse(source);
}

// -------------------------------------------------------------- the shell --

// `depth` is how many directories down the page sits, which is what every
// href is written relative to. A page at the root gets '', a tutorial gets
// '../'. Absolute paths are the standard way a project Pages site breaks —
// they work locally and 404 on the deploy — so the build refuses them below.
function layout(page, depth = 0) {
	const base = '../'.repeat(depth);
	const nav = NAV.map(item => {
		const current = item.href === page.path || (page.nav && page.nav === item.label);
		return `<a href="${base}${item.href}"${current ? ' aria-current="page"' : ''}>${item.label}</a>`;
	}).join('');

	const scripts = (page.scripts || [])
		.map(src => `<script src="${base}assets/${src}" defer></script>`).join('');

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<script>document.documentElement.className = 'js';</script>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(page.title)}</title>
<meta name="description" content="${escapeHtml(page.description)}">
<meta property="og:title" content="${escapeHtml(page.title)}">
<meta property="og:description" content="${escapeHtml(page.description)}">
<meta property="og:type" content="website">
<meta property="og:url" content="${SITE.origin}${page.path}">
<meta property="og:image" content="${SITE.origin}screenshots/village.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="${base}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="${base}assets/style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar">
  <a class="brand" href="${base}index.html"><span class="mark"></span>three.c3</a>
  <nav>${nav}</nav>
  <a class="source" href="${SITE.repo}">GitHub</a>
</header>
<main id="main"${page.wide ? ' class="wide"' : ''}>
${page.body}
</main>
<footer>
  <p>${SITE.name} — a Three.js-shaped scene API over Vulkan.
     <a href="${SITE.repo}">Source</a> ·
     <a href="${SITE.repo}/releases">Releases</a> ·
     <a href="${SITE.repo}/blob/main/LICENSE">MIT</a></p>
</footer>
<script src="${base}assets/copy.js" defer></script>
${scripts}
</body>
</html>
`;
}

// ---------------------------------------------------------------- writing --

const written = [];

async function emit(path, html) {
	const target = join(out, path);
	await mkdir(dirname(target), { recursive: true });
	await writeFile(target, html);
	written.push({ path, bytes: Buffer.byteLength(html) });
}

async function page(module, ctx) {
	const pages = await module.render(ctx);
	for (const p of Array.isArray(pages) ? pages : [pages]) {
		await emit(p.path, layout(p, p.path.split('/').length - 1));
	}
}

// Two build-time checks rather than review ones, because both fail only after
// the deploy. `href="/assets/style.css"` resolves locally and 404s under
// /three.c3/; a relative link to a page that was renamed resolves nowhere at
// all, and neither shows up in a build that otherwise succeeded.
function checkLinks(html, path, present) {
	const bad = [...html.matchAll(/(href|src)="(\/[^/][^"]*)"/g)].map(m => m[2]);
	if (bad.length > 0) {
		throw new Error(`${path}: absolute paths break the /three.c3/ base — ${bad.join(', ')}`);
	}

	const from = dirname(path);
	const broken = [];
	for (const [, , href] of html.matchAll(/(href|src)="([^"]+)"/g)) {
		if (/^(https?:|mailto:|data:|#)/.test(href)) continue;
		const target = join(from, href.split('#')[0].split('?')[0]);
		if (target !== '' && !present.has(target)) broken.push(href);
	}
	if (broken.length > 0) throw new Error(`${path}: links to nothing — ${broken.join(', ')}`);
}

// ------------------------------------------------------------------ build --

async function build() {
	const started = process.hrtime.bigint();
	await rm(out, { recursive: true, force: true });
	await mkdir(out, { recursive: true });

	const apiData = await generate();
	const ctx = { root, site: here, out, SITE, apiData, escapeHtml, codeBlock, prose, markdown };

	await page(home, ctx);
	await page(download, ctx);
	await page(api, ctx);
	await page(tutorials, ctx);
	await page(screenshots, ctx);
	await page(notfound, ctx);

	// The reference's data, fetched by api.js rather than inlined: 113 KB of
	// JSON in the markup would be paid for by every page load, and this one
	// is cacheable on its own.
	await mkdir(join(out, 'assets'), { recursive: true });
	await writeFile(join(out, 'assets/api.json'), JSON.stringify({
		version: apiData.version,
		sections: apiData.sections,
		entries: apiData.entries.map(e => ({ path: e.path, section: e.section, name: e.name, value: e.value })),
	}));

	await cp(join(here, 'assets'), join(out, 'assets'), { recursive: true });

	if (existsSync(join(here, 'screenshots'))) {
		await cp(join(here, 'screenshots'), join(out, 'screenshots'), { recursive: true });
	}

	// Pages serves what it is given and adds nothing; this stops Jekyll from
	// eating anything if the source is ever pointed at a branch instead.
	await writeFile(join(out, '.nojekyll'), '');

	const files = await walk(out);
	const present = new Set(files.map(file => relative(out, file)));
	for (const file of files) {
		if (!file.endsWith('.html')) continue;
		checkLinks(await readFile(file, 'utf8'), relative(out, file), present);
	}

	const ms = Number(process.hrtime.bigint() - started) / 1e6;
	const bytes = written.reduce((sum, w) => sum + w.bytes, 0);
	console.log(`built ${written.length} pages, ${(bytes / 1024).toFixed(0)} KB, in ${ms.toFixed(0)} ms`);
	for (const w of written) console.log(`  ${w.path.padEnd(34)} ${(w.bytes / 1024).toFixed(1)} KB`);
}

async function walk(dir) {
	const found = [];
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) found.push(...await walk(full));
		else found.push(full);
	}
	return found;
}

await build();
