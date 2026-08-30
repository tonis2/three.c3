// The API reference: which pane is showing, and search.
//
// Every entry is already in the page, so this moves nothing across the
// network. Search is a substring scan over text the browser has parsed
// anyway — the same rule `docsSearch()` uses, a hit being any entry whose
// PATH or PROSE contains the term — and there is no budget on it: the cap in
// the engine exists because an agent pays tokens for an answer, and a human
// scrolling does not.

const panes = [...document.querySelectorAll('.pane')];
const entries = [...document.querySelectorAll('.entry')];
const navLinks = [...document.querySelectorAll('[data-nav]')];
const navSections = [...document.querySelectorAll('.nav-section')];
const input = document.getElementById('q');
const hits = document.querySelector('[data-hits]');
const empty = document.querySelector('[data-empty]');

// Lowercased once. The prose is long and the scan runs on every keystroke.
const haystack = new Map(entries.map(el => [el, (el.dataset.path + ' ' + el.textContent).toLowerCase()]));

// `differences` is what the page opens on — it is the section that stops
// scripts failing. Resolved against what is actually here, so removing it
// from the docs changes the landing page rather than recursing forever.
const DEFAULT = panes.some(pane => pane.dataset.section === 'differences')
	? 'differences'
	: (panes[0] && panes[0].dataset.section);

function show(section, path) {
	let found = false;
	for (const pane of panes) {
		const active = pane.dataset.section === section;
		pane.classList.toggle('active', active);
		found ||= active;
	}
	if (!found) return show(DEFAULT, null);

	for (const link of navLinks) link.classList.toggle('current', link.dataset.nav === path);

	if (path) {
		const target = entries.find(el => el.dataset.path === path);
		// A pane that has just been unhidden has no layout yet, so scroll on
		// the next frame or the target is measured at zero.
		if (target) requestAnimationFrame(() => target.scrollIntoView({ block: 'start' }));
	} else {
		window.scrollTo({ top: 0 });
	}
}

// `#/classes/ShaderMaterial` is `{ section: 'classes.ShaderMaterial' }`, and
// a function's key carries its whole call — `three.load(path)` — so the
// fragment is matched against the slug the build wrote rather than parsed.
function fromHash() {
	const hash = decodeURIComponent(location.hash.replace(/^#\/?/, ''));
	if (hash === '') return show(DEFAULT, null);

	const byId = document.getElementById(hash);
	if (byId && byId.classList.contains('entry')) {
		return show(byId.closest('.pane').dataset.section, byId.dataset.path);
	}
	const section = hash.split('/')[0];
	show(section, null);
}

function search(term) {
	const wanted = term.trim().toLowerCase();

	if (wanted === '') {
		for (const el of entries) el.hidden = false;
		for (const li of document.querySelectorAll('.toc li')) li.hidden = false;
		for (const nav of navSections) nav.hidden = false;
		hits.textContent = '';
		empty.hidden = true;
		fromHash();
		return;
	}

	let matched = 0;
	const live = new Set();
	for (const el of entries) {
		const hit = haystack.get(el).includes(wanted);
		el.hidden = !hit;
		if (hit) { matched++; live.add(el.dataset.path); }
	}

	// Searching looks across sections, so every pane with a hit is shown at
	// once rather than the one that happened to be open.
	for (const pane of panes) {
		pane.classList.toggle('active', [...pane.querySelectorAll('.entry')].some(e => !e.hidden));
	}
	for (const li of document.querySelectorAll('.toc li')) {
		const link = li.querySelector('[data-nav]');
		li.hidden = !(link && live.has(link.dataset.nav));
	}
	for (const nav of navSections) {
		const own = [...nav.querySelectorAll('[data-nav]')];
		nav.hidden = own.length > 0 && own.every(link => !live.has(link.dataset.nav));
	}

	hits.textContent = `${matched} ${matched === 1 ? 'entry' : 'entries'}`;
	empty.hidden = matched > 0;
}

let pending;
input.addEventListener('input', () => {
	clearTimeout(pending);
	pending = setTimeout(() => search(input.value), 60);
});

// The search term lives in the query string so a search is linkable too.
input.addEventListener('change', () => {
	const url = new URL(location.href);
	if (input.value.trim()) url.searchParams.set('q', input.value.trim());
	else url.searchParams.delete('q');
	history.replaceState(null, '', url);
});

document.addEventListener('keydown', event => {
	if (event.key === '/' && document.activeElement !== input) {
		event.preventDefault();
		input.focus();
		input.select();
	}
	if (event.key === 'Escape' && document.activeElement === input) {
		input.value = '';
		search('');
		input.blur();
	}
});

// Deep links have to survive a reload, which means reading the fragment on
// load and not only on click.
window.addEventListener('hashchange', () => { if (input.value.trim() === '') fromHash(); });

const initial = new URL(location.href).searchParams.get('q');
if (initial) { input.value = initial; search(initial); }
else fromHash();
