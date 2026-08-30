// The screenshot gallery.
//
// The images are committed, and that is not an oversight: no runner in the
// release matrix has a GPU that will draw this — the Linux one would be on
// lavapipe and the macOS one answers VK_ERROR_INITIALIZATION_FAILED — so a
// picture of the renderer has to come off a machine with a graphics card.
// `site/screenshots/captions.json` is the list, and a shot missing from disk
// is dropped here rather than rendered as a broken image.

import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { existsSync } from 'node:fs';

export async function render(ctx) {
	const { site, SITE, escapeHtml, codeBlock } = ctx;
	const dir = join(site, 'screenshots');
	const manifest = join(dir, 'captions.json');

	let shots = [];
	if (existsSync(manifest)) {
		shots = JSON.parse(await readFile(manifest, 'utf8'))
			.filter(shot => existsSync(join(dir, shot.file)));
	}

	const slides = shots.map((shot, i) => `
    <figure class="slide" id="shot-${i}">
      <img src="screenshots/${escapeHtml(shot.file)}" alt="${escapeHtml(shot.alt || shot.caption || '')}"
           width="1600" height="900" loading="${i === 0 ? 'eager' : 'lazy'}" decoding="async">
      <figcaption>
        <span>${escapeHtml(shot.caption || '')}</span>
        ${shot.source ? `<a href="${SITE.repo}/blob/main/${escapeHtml(shot.source)}">${escapeHtml(shot.source)}</a>` : ''}
      </figcaption>
    </figure>`).join('');

	const gallery = shots.length === 0 ? `
  <p class="empty-state">No screenshots committed yet. They are captured from a machine
     with a GPU and checked in — see below.</p>` : `
  <div class="slider" data-slider>
    <button class="arrow prev" type="button" aria-label="Previous">&larr;</button>
    <div class="track" data-track>${slides}</div>
    <button class="arrow next" type="button" aria-label="Next">&rarr;</button>
  </div>
  <p class="dots" data-dots>${shots.map((_, i) =>
		`<button type="button" data-dot="${i}" aria-label="Screenshot ${i + 1}"></button>`).join('')}</p>`;

	const body = `
<section class="page-head">
  <h1>Screenshots</h1>
  <p class="lede">Every one of these is an example in the repository that builds
     everything it draws in code — no models and no textures on disk, the geometry
     and the images are arithmetic.</p>
</section>

<section class="gallery">${gallery}</section>

<section class="after">
  <h2>Take your own</h2>
  <p>The engine screenshots itself. <code>--frames</code> matters: a scene captured
     on frame 0 is a scene before its first animation tick.</p>
  ${codeBlock(`./three --script examples/village.js --headless \\\n        --screenshot village.jpg \\\n        --width 1600 --height 900 --frames 120`, 'bash')}
  <p class="aside">These cannot be generated in CI. No GitHub runner in the release
     matrix has a GPU that will draw this, so the images in this gallery are files in
     the repository, captured on a machine with a graphics card.</p>
</section>
`;

	return {
		path: 'screenshots.html',
		title: 'Screenshots — three.c3',
		description: 'Scenes rendered by three.c3, every one of them built in code.',
		body,
		scripts: ['slider.js'],
	};
}
