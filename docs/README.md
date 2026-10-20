# The three.c3 scripting API

A Three.js-shaped scene API over direct Vulkan.

- [differences](differences.md) — Where this is not Three.js. Read this section first — nearly every script that fails does so against one of these.
- [classes](classes.md) — The constructors, their properties and their methods.
- [functions](functions.md) — Everything on `three` itself, keyed by its whole call.
- [stats](stats.md) — What each number from `scene.stats()` counts.
- [intersection](intersection.md) — The record a raycast or a pick answers with.
- keys — The names `three.input` and `three.onKey` match against. `three.input.keys()` lists them, read out of the engine's own key table, so it is the list that actually matches.
- [example](examples.md#example) — A complete scene, with the draw-call count it ends on.
- [exampleFromFile](examples.md#example-from-a-file) — The same, from a glTF file.

## How these files are used

This folder is the one source of the API documentation, and it is read as it is — nothing compiles
it into the engine.

- **Agents** read it over the MCP: `run_script`'s description names this folder's path on the
  machine the server runs on, and an agent opens and greps the files with its own tools.
- **A release** ships it beside the binary as `docs/`, which is the folder the server finds there.

`test/docs_test.c3` checks the folder against the API: every export and every public member of an
exported class needs its own entry here.

## The layout

The paragraph at the top of this file says what the API is, and the list under it is the order to
read the sections in — `differences` first, because it is the section that stops scripts failing.
Each item links to the file its section is written in and ends in a one-line blurb after the ` — `.
Keep to that shape: one paragraph, then one list, an item per section.

- `differences.md` and `functions.md` hold one entry per `## heading`.
- `classes.md` holds one class per `## Name`, laid out as below.
- `stats.md` and `intersection.md` hold one entry per `- ` list item.
- `examples.md` holds both examples, a fenced code block each under its own heading, which is why
  two items above link into it with a `#heading` each.

## Writing an entry

A section file holds entries and nothing else.

A `# heading` — at the top, or anywhere — is a title or a divider for the reader, not an entry,
which is how `functions.md` groups its entries by area. A paragraph about the section itself belongs
in the list above, not in the file.

```markdown
# Spatial queries

## three.query.sphere(centre, radius, into)

Every drawable node whose bounding box reaches within radius of a point. ...

## three.query.box(box, into)

The same, for a Box3, a { min, max } or a flat [minX, minY, minZ, maxX, maxY, maxZ].
```

The heading is the entry's key, exactly as written — it is what an agent greps for, so it spells the
call the way a script writes it.

Short entries can be a list instead, one per item, which is how `stats.md` is written:

```markdown
- `drawCalls` — vkCmdDrawIndexed calls for one frame of this scene.
- `instances` — Total placed meshes.
```

The prose is a small subset of Markdown: paragraphs, `code` spans, **bold**, fenced blocks and `- `
lists. Wrap lines wherever you like. Tables and numbered lists are not in the subset — keep to the
rest so every file reads the same way. An identifier with `*`, `_` or `<` in it wants backticks, or
Markdown will read it as emphasis or a tag.

Aim entries at a reader who has only that entry in front of them: open with one sentence saying what
the thing is, put the options and the gotchas in a `- ` list rather than in a run-on paragraph, and
show a two-line example where it replaces a paragraph of prose.

## Writing a class

`classes.md` holds one class per `## Name`: how it is constructed, what it is, then up to three parts
at `###`, in this order — `Properties`, `Methods`, `Details`.

````markdown
## Scene

```js
new three.Scene()
```

An independent world, made and immediately shown. ...

### Properties

- `position`
- `isActive` — whether this is the one being rendered — only one is

### Methods

- `add(...objects)`
- `play(name, { loop, speed, time, fade })`

### Details

#### isActive

Whether this is the Scene being rendered. Exactly one is. ...
````

A member is a name or a signature in backticks, with an optional ` — one line` after it. Keep that
line short: anything longer is a `Details` entry, because a member list a reader scans should stay
scannable, and a paragraph inside the backticks reads as the member's *name*.

`Details` is for the members whose one line was not enough: a `#### member` heading naming something
in either list, then paragraphs. A detail names a member that is in the lists — one that does not is
almost always a typo.
