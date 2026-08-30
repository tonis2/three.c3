# three.c3 — the website

**A plan for one deliverable and nothing else.** The engine's task list is
`plan.md`; this file is the site that ships beside it, from an empty repository
folder to a page on `tonis2.github.io/three.c3`. An entry leaves this file when
it stops being work somebody has to do.

The site answers five questions and no others: what is this, where do I get it,
what can it do, what does the API say, and how do I write my first scene.

**State: built.** `node site/build.mjs` produces eleven pages into `site/dist`,
the five tutorials are written and every one of their scripts has been run
against the engine, and the five screenshots are captured and committed. What
is left is at the bottom of this file, and two of the four items are somebody
pressing a button in the repository settings.

    npm ci                 # marked and highlight.js, build-time only
    node site/gen-api.mjs  # the reference, as a check on its own
    node site/build.mjs    # the site, into site/dist
    node site/serve.mjs    # and look at it on localhost:4173

---

## 0. The finding this whole plan turns on

**The API reference is not written, it is generated.**
`src/js/prelude/docs.js` is already the single source of truth — 113 KB of
`DOCS`, plus `docsIndex`, `docsSearch`, `findSection` and `docsMarkdown` — and
it is deliberately import-free: its one live call is `H.keyNames()`. So a Node
script can `import` that module with a four-line stub for `globalThis.__three`
and emit the whole surface as JSON, with no C3 build, no GPU and no binary.

That is what makes the site cheap to keep honest. The page a human reads, the
answer `three.getApiDocs()` gives an agent and the `get_api_docs` MCP tool all
come out of the same object, so they cannot drift. A doc string edited in
`docs.js` is on the website the next time `main` moves, and nothing has to be
copied by hand — which is the failure every hand-written API page eventually
has.

The one value that does not travel with the module is the key table, because
`keyNames` is a host binding over `KEY_NAMES` in `src/scene/input.c3:384`. The
generator parses the names out of that table, so the key list on the page is
the list the engine actually matches against rather than a second copy of it.

## 1. Shape and hosting

- [x] **Plain HTML, CSS and JavaScript. No runtime framework, no CDN.** Every
      page is static and loads with no dependency; `marked` and `highlight.js`
      are build-time devDependencies and nothing they produce is shipped as a
      library. The site should open from a file:// URL as readily as from
      Pages.
- [x] **Built by a Node script, deployed by Actions.** Not Jekyll — the API
      generator has to run anyway, and once a build step exists, Jekyll is a
      second one that earns nothing. `actions/upload-pages-artifact` and
      `actions/deploy-pages`, so no `gh-pages` branch and no generated files in
      the tree.
- [x] **The base path is `/three.c3/`, not `/`.** A project Pages site is
      served from a subdirectory, and an absolute `/assets/style.css` is the
      standard way this breaks — it works locally and 404s on the deploy. Every
      href and src is relative, and the build fails on an absolute one rather
      than trusting a review to catch it.

### The layout

    site/
      build.mjs         markdown -> html, page templates, the whole build
      gen-api.mjs       imports src/js/prelude/docs.js under a __three stub
      serve.mjs         site/dist on localhost, for looking at it
      pages/            index, download, api, tutorials, screenshots, notfound
      tutorials/        01-hello-scene.md ... 05-input-and-systems.md
      assets/           style.css, api.js, download.js, slider.js, copy.js, favicon.svg
      screenshots/      *.jpg and captions.json  (committed, see section 6)
      dist/             the built site  (git-ignored)
    package.json        marked and highlight.js, build-time only
    .github/workflows/pages.yml

Everything the site is made of lives under `site/`, the tutorials included, so
one path in the workflow covers the whole thing and nothing at the repository
root belongs to the website. The markdown is still readable on its own —
headings, prose and fenced code, which GitHub renders and any editor opens —
so a tutorial is a document that a build turns into a page rather than a
template that only means something after one.

## 2. The generator

- [x] **`site/gen-api.mjs` emits `api.json` from `docs.js`.** Stub
      `globalThis.__three = { keyNames: () => [...] }` before the import, take
      the exported `DOCS`, write it whole. The key names come from parsing the
      `KEY_NAMES` table in `src/scene/input.c3`; if that parse finds nothing,
      the build FAILS rather than shipping an empty key table — a silently
      missing section is worse than a red build.
- [x] **Emit a flat entry list beside it**, keyed by the same paths
      `getApiDocs({ section })` accepts — `classes.ShaderMaterial`,
      `functions.three.load(path)`. One walk, the same two-deep rule
      `docsEntries()` uses: a top-level plain object is a SECTION and
      everything one level inside it is an entry. Getting that rule wrong is
      what glues fifty separate `differences` answers into one blob.
- [x] **Run the generator in CI as its own check.** A `docs.js` edit that
      breaks the site should fail on the commit that made it, not on the next
      deploy.

## 3. Home

- [x] **Say what it is in one sentence, above the fold.** `DOCS.summary`
      already is that sentence — a Three.js-shaped scene API over Vulkan where
      every mesh placed with the same asset reference is one instanced draw
      call. Generated, so it cannot go stale.
- [x] **A code sample that is not written by hand.** `DOCS.example` is a
      complete scene ending in `stats()` with the draw-call count in a comment,
      which is the claim the whole engine rests on. Render that.
- [x] **A feature grid, six cells.** Instanced by default with no batching step
      to invoke; one binary with the Slang compiler and the shader templates
      inside it; glTF with skinning, morph targets and crossfades; physics,
      navigation and spatial queries; a Slang `ShaderMaterial` with a vertex
      stage; an MCP server so an agent can drive it.
- [x] **Three calls to action** — Download, Tutorials, API — and nothing else
      competing with them.

## 4. Download

- [x] **Resolve the release at runtime, from the GitHub API.** The assets are
      version-suffixed (`three-macos-arm64-0.1.0.zip`), so the usual
      `/releases/latest/download/<name>` trick cannot work: the name is not
      knowable without the version. The page fetches
      `api.github.com/repos/tonis2/three.c3/releases/latest`, matches assets by
      their `three-<os>-<arch>` prefix and fills in the links.
- [x] **Fall back to the releases page when that fetch fails.** Unauthenticated
      API calls are rate-limited per IP, and a download page that shows nothing
      is the worst page on the site. The static link is in the markup and the
      script replaces it, so it degrades rather than disappears.
- [x] **Detect the visitor's platform and put that card first.** The other two
      stay visible — a person on a Mac downloading the Windows zip for someone
      else is an ordinary thing to do.
- [x] **Carry the first-run lines from `packaging/bundle-README.md`**, macOS
      quarantine included. Somebody who downloads a non-notarised binary and
      hits a Gatekeeper dialog with no explanation on the page they came from
      does not come back.
- [ ] **Consider unversioned aliases instead.** If `release.yml` also uploaded
      `three-macos-arm64.zip` beside the versioned asset, this page would be
      three static links and no JavaScript at all. Worth doing if the fetch
      turns out to be a nuisance.

## 5. The API reference

- [x] **A sidebar of the sections and a pane for one entry.** Sections are
      whatever `DOCS` has: `differences`, `classes`, `functions`, `stats`,
      `intersection`, `keys`. `differences` and `stats` are the two read on
      nearly every task — `docsIndex()` already knows this, and the page should
      open on `differences` rather than on an empty state.
- [x] **Render both entry shapes.** An entry is either a string, an array, or
      the class record `{ construct, note, properties, methods, details }`.
      Three renderers, and `details` hangs under the property or method it
      explains rather than as a fourth list.
- [x] **Search, client-side, over the whole JSON.** The same rule
      `docsSearch()` uses: a hit is any entry whose PATH or PROSE contains the
      term, case-insensitively. No index library — 113 KB gzips to about 30 KB
      and a substring scan over it is instant. No `SEARCH_BUDGET` here: that
      cap exists because an agent pays tokens for an answer, and a human
      scrolling does not.
- [x] **The URL fragment is the path `getApiDocs` takes.**
      `#/classes/ShaderMaterial` on the page, `{ section:
      "classes.ShaderMaterial" }` in the tool. One vocabulary for the person
      and the agent, and a link somebody pastes into a chat is a link the agent
      can act on.
- [x] **Deep links must survive a reload**, which means reading the fragment on
      load and not only on click.

## 6. Screenshots

- [x] **The images are committed. They cannot be generated in CI.** Not an
      oversight — `release.yml` says it at length: no runner in the matrix has
      a GPU that will draw this, the Linux one would be on lavapipe and the
      macOS one answers `VK_ERROR_INITIALIZATION_FAILED`. A picture of the
      renderer has to come off a machine with a graphics card, so it is a file
      in the repository.
- [x] **Capture them from `examples/`**, which is five finished scenes already:

          ./three --script examples/village.js --headless \
                  --screenshot site/screenshots/village.jpg \
                  --width 1600 --height 900 --frames 120

      `--frames` matters: a scene screenshotted on frame 0 is a scene before
      its first animation tick.
- [x] **A slider with no library.** CSS scroll-snap, arrow buttons, arrow keys,
      lazy-loaded images. `captions.json` holds one line per shot and the
      example it came from, and each caption links to that file on GitHub — so
      the gallery doubles as the examples page and there is no second list to
      keep in step.

## 7. Tutorials

- [x] **One markdown file per tutorial, with frontmatter** — `title`, `order`,
      `summary`. Numbered filenames so the folder reads in order:
      `01-hello-scene.md`, `02-creating-materials.md`.
- [x] **Rendered at BUILD time, not fetched at run time.** A tutorial fetched
      by JavaScript is invisible to search engines, blank with JS off and
      slower for everyone. The build turns each file into a page.
- [x] **Write the fenced JavaScript out as a runnable file too.** A tutorial's
      code block becomes `tutorials/01-hello-scene.js`, so the page can say
      `./three --script tutorials/01-hello-scene.js` and mean it exactly. A
      snippet that has never been run is a snippet that does not run.
- [x] **Sidebar, prev/next, and a copy button on every block.**
- [x] **The first five.** Their material is in `SKILL.md` and the `examples/`,
      and none of it has to be invented:
      hello scene; creating materials; loading a glTF kit; animation and
      skinning; input and systems.

## 8. Deploy

- [x] **`.github/workflows/pages.yml`** on push to `main` touching `site/`,
      `tutorials/` or `src/js/prelude/docs.js`, plus `workflow_dispatch`.
      `npm ci`, `node site/build.mjs`, upload, deploy.
- [ ] **Enable Pages with the Actions source** in the repository settings once,
      by hand. Nothing in the workflow can do it and a first deploy against the
      branch source silently serves the wrong thing.
- [ ] **Link the site from `README.md` and from the release body.**

## 9. Polish, last

- [x] Dark and light, from `prefers-color-scheme`. One stylesheet.
- [x] Open Graph tags and one card image, so a pasted link shows the renderer.
- [x] A 404 that offers the four pages.
- [x] Favicon.

## Where this went differently

Three decisions the build made that this file did not, written down because
each one is a thing a reader would otherwise have to work out from the source.

**The reference is rendered at build time, not fetched.** Section 5 assumed the
page would pull `api.json` and draw itself. It does not: every entry is in
`api.html` as markup, `api.json` is emitted beside it and linked for anything
that wants the data. It costs about 370 KB — around 70 KB over the wire — and buys
four things. A deep link resolves with no round trip, the page opens from a
`file://` URL, the whole reference is there with JavaScript off, and search
became a scan over nodes the browser has already parsed rather than a second
copy of the prose. Search behaves as section 5 asked for either way.

**The card image is a screenshot.** Section 9 wanted a card so a pasted link
shows the renderer. `screenshots/village.jpg` IS the renderer, which is better
than a drawing of it, so `og:image` points there and there is no card to
maintain.

**The build checks its own links.** The absolute-path check section 1 asked for
is there, and a second one grew beside it: every relative `href` and `src` is
resolved against the output tree and the build fails on one that lands nowhere.
Both were tested by breaking them on purpose. They are the same class of bug —
a link that is only wrong after the deploy.

## What is left

- [ ] **Enable Pages with the Actions source**, in Settings → Pages. By hand,
      once. Nothing in the workflow can do it and a repository left on the
      branch source serves the wrong thing silently. Until this is done the
      workflow will build and fail at the deploy step.
- [ ] **Link the site from the release body**, and from a README — there is no
      `README.md` in this repository, so that half is a file that does not
      exist yet rather than an edit.
- [ ] **Consider unversioned asset aliases in `release.yml`.** If it also
      uploaded `three-macos-arm64.zip` beside the versioned asset, the download
      page would be three static links and no JavaScript. The fetch works and
      degrades; this is only worth doing if it turns out to be a nuisance.
- [ ] **Re-capture the screenshots when the examples change.** They are files
      in the repository and nothing can notice they have gone stale. The
      command is in section 6.

## Milestones

1. ~~Scaffold and pipeline~~ — `site/build.mjs`, `site/pages/`, `site/assets/`
   and `.github/workflows/pages.yml`. Done.
2. ~~Home and Download.~~ Done.
3. ~~The API reference and its search.~~ Done.
4. ~~The tutorial pipeline and the first five.~~ Done — and each tutorial's
   extracted script was run headless against the engine, which is what the
   "a snippet that has never been run is a snippet that does not run" rule in
   section 7 was for. Three of the five run with no assets; the glTF and
   animation ones report what is missing instead of throwing.
5. ~~Screenshots, then section 9.~~ Done.
