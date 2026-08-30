// Hash routing.
//
// Pages serves files and has no rewrite rules, so a path-based router would
// 404 on every deep link that was not typed at the root. A fragment is never
// sent to the server, which makes `#/tutorials/03-loading-a-gltf-kit` a URL
// that works pasted into a chat, opened cold, or reloaded — and works the same
// from a `file://` URL, which a path router cannot do at all.
//
// The routes:
//   #/                            home
//   #/api                         the reference, first section
//   #/api/<section>               that section
//   #/api/<section>/<entry>       that section, scrolled to the entry
//   #/tutorials                   the list
//   #/tutorials/<slug>            one tutorial

export function parse(hash) {
	const parts = hash.replace(/^#?\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
	if (parts.length === 0) return { name: 'home', parts: [] };
	const [head, ...rest] = parts;
	if (head === 'api') return { name: 'api', parts: rest };
	if (head === 'tutorials') return { name: 'tutorials', parts: rest };
	return { name: 'notfound', parts };
}

export function current() {
	return parse(location.hash);
}

export function listen(onChange) {
	addEventListener('hashchange', onChange);
	return () => removeEventListener('hashchange', onChange);
}

export function go(hash) {
	location.hash = hash;
}
