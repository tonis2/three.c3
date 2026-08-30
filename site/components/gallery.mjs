// The screenshot slider.
//
// The images are committed to the repository, and that is not an oversight: no
// runner in the release matrix has a GPU that will draw this, so a picture of
// the renderer has to come off a machine with a graphics card.
//
// The captions travel in the bundle — five short strings — so the section is
// there in the first render rather than after a request.

import { html, nothing } from 'lit';
import { SITE } from '../lib/site.mjs';

export function slide(shot, index) {
	return html`<figure class="slide">
      <img src="screenshots/${shot.file}" alt="${shot.alt || shot.caption || ''}"
           width="1600" height="900" loading="${index === 0 ? 'eager' : 'lazy'}" decoding="async">
      <figcaption>
        <span>${shot.caption || ''}</span>
        ${shot.source
			? html`<a href="${SITE.repo}/blob/main/${shot.source}">${shot.source}</a>`
			: nothing}
      </figcaption>
    </figure>`;
}

// Scroll-snap does the moving; `on` is the bag of listeners that decides which
// dot is lit and when. Kept apart from the element so the markup is readable as
// markup — see `elements/gallery.js` for the behaviour.
export function galleryFrame({ shots, current = 0, on = {} }) {
	return html`<div class="slider"
      @mouseenter=${on.rest} @mouseleave=${on.resume}
      @focusin=${on.take} @pointerdown=${on.take}>
    <button class="arrow prev" type="button" aria-label="Previous" @click=${on.prev}>&larr;</button>
    <div class="track" @scroll=${on.scroll}>${shots.map(slide)}</div>
    <button class="arrow next" type="button" aria-label="Next" @click=${on.next}>&rarr;</button>
  </div>
  <p class="dots">${shots.map((_, i) => html`<button
        type="button" aria-label="Screenshot ${i + 1}"
        ?data-current=${i === current} @click=${on.dot?.(i)}></button>`)}</p>`;
}

// The section around it: the note is prose and the element has no business
// owning it.
export function gallerySection(shots) {
	if (shots.length === 0) return nothing;

	return html`<section class="gallery" id="screenshots">
  <three-gallery .shots=${shots} autoplay="6000"></three-gallery>
  <p class="gallery-note">Every one of these is an example in the repository that
     builds everything it draws in code — no models and no textures on disk, the
     geometry and the images are arithmetic.</p>
</section>`;
}
