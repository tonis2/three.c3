// The shapes a docs entry can take, and the markup for each.
//
// An entry is what `site/tools/docs.mjs` compiled out of `docs/`: a Markdown
// string, a list of strings, or a class record — and a record's prose fields
// are Markdown too. Everything here is written so that a key nobody
// anticipated is still shown, labelled, rather than dropped.

import { html, nothing, code, markdown, prose } from '../lib/markup.js';

const CLASS_KEYS = ['construct', 'note', 'properties', 'methods', 'details'];

// The two leaves whose string is code rather than prose.
const CODE = ['example', 'exampleFromFile'];

export function value(entry, path = '') {
	if (typeof entry === 'string') return CODE.includes(path) ? code(entry) : markdown(entry);
	if (Array.isArray(entry)) return list(entry);
	return record(entry);
}

function list(items) {
	// The key table is a hundred short names — a list of chips reads as the
	// lookup table it is, where a bullet list would be a column of noise.
	const short = items.every(item => typeof item === 'string' && item.length <= 16);
	return short
		? html`<ul class="chips">${items.map(item => html`<li><code>${item}</code></li>`)}</ul>`
		: html`<ul>${items.map(item => html`<li>${prose(item)}</li>`)}</ul>`;
}

function record(entry) {
	const details = entry.details || {};

	// A detail whose member is in neither list would otherwise vanish.
	const used = new Set([...(entry.properties || []), ...(entry.methods || [])].map(name));
	const orphans = Object.entries(details).filter(([key]) => !used.has(key));

	return html`
		${entry.construct ? code(entry.construct) : nothing}
		${entry.note ? markdown(entry.note) : nothing}
		${entry.properties ? members('Properties', entry.properties, details) : nothing}
		${entry.methods ? members('Methods', entry.methods, details) : nothing}
		${Object.entries(entry)
			.filter(([key]) => !CLASS_KEYS.includes(key))
			.map(([key, own]) => html`<h3>${key}</h3>${value(own)}`)}
		${orphans.length === 0 ? nothing : html`<h3>Details</h3>
			<dl class="members">${orphans.map(([key, text]) => html`
				<dt><code>${key}</code></dt><dd>${markdown(text)}</dd>`)}</dl>`}`;
}

// `details` hangs under the property or method it explains rather than as a
// fourth list — it is an explanation OF a member, and two lists away from the
// name it belongs to is where a reader stops following it.
function members(title, entries, details) {
	return html`<h3>${title}</h3><dl class="members">${entries.map(entry => {
		const { signature, inline } = split(entry);
		// `hasOwn`, not a plain lookup: twenty classes here document a
		// `toString()`, and `details.toString` on a bare object from JSON is
		// Object.prototype's — a function, handed to a Markdown parser.
		const key = name(entry);
		const detail = Object.hasOwn(details, key) ? details[key] : '';
		return html`<dt><code>${signature}</code></dt><dd>${
			inline ? html`<p>${prose(inline)}</p>` : nothing}${
			detail ? html`<div class="detail">${markdown(detail)}</div>` : nothing}</dd>`;
	})}</dl>`;
}

// A member is either a signature — `play(name, { loop, speed })` — or a name
// with its explanation in brackets after it: `isActive (whether this is ...)`.
// The difference is whether the parenthesis opens straight off the identifier,
// and the second form is a name and a paragraph rather than one long code span.
function split(entry) {
	const text = String(entry);
	if (/^[A-Za-z_$][\w$]*\(/.test(text)) return { signature: text, inline: '' };
	const open = text.indexOf(' (');
	if (open === -1 || !text.endsWith(')')) return { signature: text, inline: '' };
	return { signature: text.slice(0, open), inline: text.slice(open + 2, -1) };
}

function name(entry) {
	const found = String(entry).match(/^[A-Za-z_$][\w$]*/);
	return found ? found[0] : String(entry);
}
