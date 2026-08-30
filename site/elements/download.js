// <three-download> — the platform picker and the button it fills in.
//
// It starts as a working link to the releases page, guesses which platform the
// visitor is on and asks GitHub which files the latest release actually has, so
// the button ends up pointing at one file. Every state it can be in is the same
// template — see `components/picker.mjs` — so there is no reaching into markup
// anywhere in here.

import { LightElement } from './base.js';
import { PLATFORMS, downloadPicker } from '../components/picker.mjs';

const REPO = 'tonis2/three.c3';

// The visitor's platform is a GUESS and the picker is the correction, which is
// why the other two stay one click away: downloading the Windows zip from a Mac,
// for somebody else, is an ordinary thing to do.
function guess() {
	const platform = `${navigator.userAgentData?.platform || ''} ${navigator.platform || ''} ${navigator.userAgent}`.toLowerCase();
	return PLATFORMS.find(one => platform.includes(one.match)) || PLATFORMS[0];
}

class Download extends LightElement {
	static properties = {
		version: { type: String },
		chosen: { state: true },
		assets: { state: true },
		status: { state: true },
		error: { state: true },
	};

	constructor() {
		super();
		this.version = '';
		this.chosen = guess();
		this.assets = new Map();
		this.status = '';
		this.error = false;
		this.handlers = new Map();
	}

	firstUpdated() {
		this.resolve().catch(error => {
			// The static href is already right; say why it is the general link.
			this.status = `Could not reach the GitHub API (${error.message}). `
				+ 'The button goes to the releases page, where every build is listed.';
			this.error = true;
		});
	}

	render() {
		return downloadPicker({
			chosen: this.chosen,
			asset: this.assets.get(this.chosen.prefix) || null,
			version: this.version,
			status: this.status,
			error: this.error,
			choose: platform => this.choose(platform),
		});
	}

	// One listener per platform, made once. A repaint that handed the button a
	// fresh arrow function would have Lit unbind and rebind on every click.
	choose(platform) {
		if (!this.handlers.has(platform)) {
			this.handlers.set(platform, () => { this.chosen = platform; });
		}
		return this.handlers.get(platform);
	}

	async resolve() {
		const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
			headers: { Accept: 'application/vnd.github+json' },
		});
		if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
		const release = await response.json();

		const assets = new Map();
		for (const asset of release.assets || []) {
			const prefix = asset.name.replace(/-\d[\d.]*\.(zip|tar\.gz|tgz)$/i, '');
			assets.set(prefix, { name: asset.name, url: asset.browser_download_url, size: asset.size });
		}
		this.assets = assets;

		const tag = release.tag_name || '';
		if (tag) this.version = tag.replace(/^v/, '');

		// Only a shortfall gets a line. A release that HAS the bundles says so by
		// naming the file beside the button, and a sentence repeating it would be
		// the one piece of chrome on this page saying nothing.
		if (assets.size === 0) {
			this.status = `${tag} has no platform bundles yet. The button goes to the releases page.`;
		}
	}
}

customElements.define('three-download', Download);
