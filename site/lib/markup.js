// Markdown and the escaping helpers.
//
// No highlighter is reachable from here. A fenced block becomes
// `<pre><code class="language-js">`, escaped and nothing else; `lib/highlight.js`
// walks the rendered DOM and colours it, and the stylesheet holds the palette.
// That is the whole reason the language is written into the markup as a class
// rather than resolved here: the block is complete and correct as HTML, and
// what colours it is a separate concern that never touches this file.

import { marked } from 'marked';
import { unsafeHTML } from 'lit/directives/unsafe-html.js';

export { html, nothing } from 'lit';
export { unsafeHTML };

// The spellings a fence can carry, mapped onto the grammars `lib/highlight.js`
// loads. `none` is Prism's own word for a block to leave alone.
const LANGUAGES = { js: 'javascript', javascript: 'javascript', sh: 'bash', bash: 'bash' };

export function escapeHtml(text) {
	return String(text)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// A fenced block with its copy button.
//
// A string rather than a template because `marked` renders code through a
// synchronous hook that has to be given one. `code()` below is the same markup
// for use inside a template, so the two forms cannot drift.
//
// A fence in a language nothing here reads is left as plain text, class and
// all: the block is still a block, and it is not this function's business to
// know which grammars got loaded.
export function codeHtml(source, language = 'javascript') {
	const known = LANGUAGES[language] || 'none';
	return `<div class="code"><button class="copy" type="button" aria-label="Copy">Copy</button>`
		+ `<pre class="language-${known}"><code class="language-${known}">${escapeHtml(source)}</code></pre></div>`;
}

export function code(source, language = 'javascript') {
	return unsafeHTML(codeHtml(source, language));
}

// Inline markdown-ish prose: the docs strings use `code` spans and nothing
// else, so this is the whole of the markup they need.
export function prose(text) {
	return unsafeHTML(escapeHtml(text).replace(/`([^`]+)`/g, (_, span) => `<code>${span}</code>`));
}

// The tutorials are Markdown files in the repository and are written to be read
// there too, so they link to each other the way files do — `02-creating-
// materials.html`, `../api.html`. Those were page names when the site was nine
// pages; here they are routes, and rewriting them on the way through is what
// lets the same file serve GitHub's renderer and this one.
function route(href) {
	if (/^(https?:|mailto:|#)/.test(href)) return href;
	const tutorial = href.match(/^(\d\d-[a-z0-9-]+)\.html$/);
	if (tutorial) return `#/tutorials/${tutorial[1]}`;
	if (/^(\.\.\/)?api\.html$/.test(href)) return '#/api';
	if (/^(\.\.\/)?(tutorials\/)?index\.html$/.test(href)) return '#/tutorials';
	return href;
}

marked.use({
	renderer: {
		code({ text, lang }) { return codeHtml(text, lang || 'plaintext'); },
		link({ href, title, tokens }) {
			const text = this.parser.parseInline(tokens);
			const label = title ? ` title="${escapeHtml(title)}"` : '';
			return `<a href="${escapeHtml(route(href))}"${label}>${text}</a>`;
		},
	},
});

export function markdown(source) {
	return unsafeHTML(marked.parse(source));
}
