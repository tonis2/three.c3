// The two payloads that are too big to bundle, fetched the first time a route
// needs them and kept after that.
//
// The reference is 250 KB of JSON — 85 KB over the wire — and the tutorials are
// another 36 KB. Bundling either would put it on the home page, which shows
// neither, so each is a file the browser asks for when the reader actually goes
// there and caches on its own terms afterwards.

const pending = new Map();

function once(path) {
	if (!pending.has(path)) {
		pending.set(path, fetch(path).then(response => {
			if (!response.ok) throw new Error(`${path} answered ${response.status}`);
			return response.json();
		}).catch(error => {
			// Clear it, or a failed load is cached forever and the retry a
			// reader gets by navigating back is not a retry.
			pending.delete(path);
			throw error;
		}));
	}
	return pending.get(path);
}

export const apiData = () => once('assets/api.json');
export const tutorialData = () => once('assets/tutorials.json');
