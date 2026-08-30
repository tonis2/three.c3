// Resolve the latest release, and pick the visitor's platform.
//
// The assets are version-suffixed — `three-macos-arm64-0.1.0.zip` — so the
// usual `/releases/latest/download/<name>` cannot be written down: the name
// is not knowable without the version. So ask, match by prefix, and fill the
// links in. Every card already links to the releases page, and this only ever
// replaces that href — an unauthenticated API call is rate-limited per IP,
// and a download page that shows nothing is the worst page on the site.

const REPO = 'tonis2/three.c3';
const cards = [...document.querySelectorAll('.platform')];
const status = document.querySelector('[data-status]');

// The visitor's card goes first, and the other two stay visible: downloading
// the Windows zip from a Mac, for somebody else, is an ordinary thing to do.
function markMine() {
	const platform = `${navigator.userAgentData?.platform || ''} ${navigator.platform || ''} ${navigator.userAgent}`.toLowerCase();
	const mine = cards.find(card => platform.includes(card.dataset.match));
	if (!mine) return;
	mine.classList.add('mine');
	mine.querySelector('.badge').hidden = false;
}

function bytes(n) {
	return n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.round(n / 1024)} KB`;
}

async function resolve() {
	const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
		headers: { Accept: 'application/vnd.github+json' },
	});
	if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
	const release = await response.json();

	let filled = 0;
	for (const card of cards) {
		const asset = (release.assets || []).find(a => a.name.startsWith(card.dataset.prefix));
		if (!asset) continue;
		const link = card.querySelector('[data-download]');
		link.href = asset.browser_download_url;
		link.setAttribute('download', '');
		card.querySelector('[data-asset]').textContent = `${asset.name} · ${bytes(asset.size)}`;
		filled++;
	}

	const tag = release.tag_name || '';
	status.textContent = filled > 0
		? `${tag} — released ${new Date(release.published_at).toLocaleDateString(undefined, { dateStyle: 'medium' })}.`
		: `${tag} has no platform bundles yet. The buttons go to the releases page.`;
}

markMine();
resolve().catch(error => {
	// The static hrefs are already right; say why they are the general link.
	status.textContent = `Could not reach the GitHub API (${error.message}). The buttons go to the releases page, where every build is listed.`;
	status.setAttribute('data-error', '');
});
