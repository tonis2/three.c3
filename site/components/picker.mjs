// The download button and the platform switch beside it.
//
// The release assets are version-suffixed — `three-macos-arm64-0.1.0.zip` — so
// the usual `/releases/latest/download/<name>` cannot be written down: the name
// is not knowable without the version. `asset` is what `<three-download>` fills
// in once it has asked; until then, and if the answer never comes, every link
// here is already a working link to the releases page.

import { html } from 'lit';
import { SITE } from '../lib/site.mjs';

export const PLATFORMS = [
	{ id: 'macos-arm64', prefix: 'three-macos-arm64', name: 'macOS', short: 'macOS', match: 'mac' },
	{ id: 'linux-x64', prefix: 'three-linux-x64', name: 'Linux', short: 'Linux', match: 'linux' },
	{ id: 'windows-x64', prefix: 'three-windows-x64', name: 'Windows', short: 'Windows', match: 'win' },
];

const RELEASES = `${SITE.repo}/releases/latest`;

function size(bytes) {
	return bytes >= 1024 * 1024
		? `${(bytes / 1024 / 1024).toFixed(1)} MB`
		: `${Math.round(bytes / 1024)} KB`;
}

// `choose` is a factory rather than a handler: it is asked for the listener for
// one platform and answers with the same function every time, so a repaint
// rebinds nothing. The build passes no factory at all and Lit drops the
// attribute, which is why the static page carries no inline handlers.
export function downloadPicker({
	chosen = PLATFORMS[0], asset = null, version = '', status = '', error = false, choose,
} = {}) {
	return html`<div class="picker">
      <a class="button primary" href="${asset ? asset.url : RELEASES}"
         ?download=${Boolean(asset)}>Download for ${chosen.name}</a>
      <div class="os" role="group" aria-label="Choose a platform">${PLATFORMS.map(platform => html`<button
            type="button" aria-pressed="${String(platform === chosen)}"
            @click=${choose?.(platform)}>${platform.short}</button>`)}</div>
    </div>
    <p class="picker-meta">
      <strong>v${version}</strong>
      <span class="asset">${asset ? `${asset.name} · ${size(asset.size)}` : ''}</span>
      <a href="${SITE.repo}/releases">All builds</a>
      <a href="#first-run">First run</a>
    </p>
    <p class="status" ?hidden=${!status} ?data-error=${error}>${status}</p>`;
}
