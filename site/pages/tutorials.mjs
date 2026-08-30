// Tutorials, rendered from `site/tutorials/*.md` at BUILD time.
//
// A tutorial fetched by JavaScript is invisible to search engines, blank with
// JS off and slower for everyone, so the markdown becomes a page here. The
// markdown stays readable on its own — it is a file in the repository with
// nothing but headings, prose and fenced code in it, so GitHub renders it and
// so does any editor. What this build adds is the sidebar, the prev/next, the
// copy buttons and the runnable script.

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { existsSync } from 'node:fs';

export async function render(ctx) {
	const { site, out, escapeHtml, markdown, codeBlock } = ctx;
	const dir = join(site, 'tutorials');

	const files = existsSync(dir)
		? (await readdir(dir)).filter(f => f.endsWith('.md')).sort()
		: [];

	const parsed = [];
	for (const file of files) {
		const raw = await readFile(join(dir, file), 'utf8');
		const { meta, content } = frontmatter(raw);
		const slug = file.replace(/\.md$/, '');
		parsed.push({
			file, slug,
			title: meta.title || slug,
			summary: meta.summary || '',
			order: Number(meta.order ?? 999),
			content,
		});
	}
	parsed.sort((a, b) => a.order - b.order || a.slug.localeCompare(b.slug));

	const pages = [];

	// The index.
	const list = parsed.length === 0
		? '<p class="empty-state">No tutorials yet.</p>'
		: `<ol class="tutorial-list">${parsed.map((t, i) => `
      <li>
        <a href="${t.slug}.html">
          <span class="num">${String(i + 1).padStart(2, '0')}</span>
          <span class="text"><strong>${escapeHtml(t.title)}</strong>
          <span class="summary">${escapeHtml(t.summary)}</span></span>
        </a>
      </li>`).join('')}</ol>`;

	pages.push({
		path: 'tutorials/index.html',
		nav: 'Tutorials',
		title: 'Tutorials — three.c3',
		description: 'From an empty window to a lit, animated scene, one file at a time.',
		body: `
<section class="page-head">
  <h1>Tutorials</h1>
  <p class="lede">Each one is a scene you can run. Every code block is written out
     as a file beside the page, so the command under it is the command — nothing
     in here is a snippet that has never been run.</p>
</section>
${list}
<section class="after">
  <p class="aside">Looking for a reference rather than a walkthrough?
     <a href="../api.html">The API</a> is searchable, and <code>SKILL.md</code> in
     the release zip is the long-form guide.</p>
</section>
`,
	});

	// One page per tutorial, and the script it teaches beside it.
	await mkdir(join(out, 'tutorials'), { recursive: true });

	for (let i = 0; i < parsed.length; i++) {
		const t = parsed[i];
		const prev = parsed[i - 1];
		const next = parsed[i + 1];

		const script = scriptFrom(t.content);
		let run = '';
		if (script) {
			await writeFile(join(out, 'tutorials', `${t.slug}.js`), script);
			run = `
<section class="run">
  <h2>Run it</h2>
  <p>Every JavaScript block on this page, in order, as one file:
     <a href="${t.slug}.js" download>${escapeHtml(t.slug)}.js</a></p>
  ${codeBlock(`./three --script ${t.slug}.js`, 'bash')}
</section>`;
		}

		const sidebar = `<nav class="tutorial-nav">
      <p class="label">Tutorials</p>
      <ol>${parsed.map(other =>
			`<li${other.slug === t.slug ? ' class="current"' : ''}><a href="${other.slug}.html">${escapeHtml(other.title)}</a></li>`
		).join('')}</ol>
    </nav>`;

		const steps = `<p class="prevnext">
      ${prev ? `<a class="prev" href="${prev.slug}.html">&larr; ${escapeHtml(prev.title)}</a>` : '<span></span>'}
      ${next ? `<a class="next" href="${next.slug}.html">${escapeHtml(next.title)} &rarr;</a>` : '<span></span>'}
    </p>`;

		pages.push({
			path: `tutorials/${t.slug}.html`,
			nav: 'Tutorials',
			title: `${t.title} — three.c3`,
			description: t.summary,
			body: `
<div class="tutorial">
  ${sidebar}
  <article class="prose">
    ${markdown(t.content)}
    ${run}
    ${steps}
  </article>
</div>
`,
		});
	}

	return pages;
}

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
function scriptFrom(markdownSource) {
	const blocks = [];
	for (const block of markdownSource.matchAll(/^```(js|javascript)([^\n]*)\n([\s\S]*?)^```/gm)) {
		if (/\bignore\b/.test(block[2])) continue;
		blocks.push(block[3].trimEnd());
	}
	return blocks.length === 0 ? null : blocks.join('\n\n') + '\n';
}
