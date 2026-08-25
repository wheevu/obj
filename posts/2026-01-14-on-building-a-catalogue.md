---
id: JOSH-2026-0001
title: On building a catalogue out of Lua and spite
date: 2026-01-14
type: essay
tags: lua, software, meta
subtitle: a short account of why this exists
---

Most personal websites are either a blog that has not been updated since
2021 or a shrine to whatever framework was fashionable when they were built.
I wanted something less ambitious and somehow more unnecessary.

This is a *catalogue* for the things I encounter, build, break, and
occasionally decide were worth keeping.
The tone is deliberate: slightly severe, a little funny, and free of the
warm gradients currently afflicting the open web.

The whole thing is driven by one stdlib-only Lua script.
No client-side JavaScript, no analytics quietly counting your pulse, and no
dependency tree that needs its own family tree.
I write a Markdown file, give it an accession number, and let the script
turn it into HTML.

## Why Lua

Lua is small enough to hold in your head, which is useful when the project
starts acquiring features it does not need.
To produce this very page:

```lua
-- from the project root
lua5.4 build.lua
-- or, if you prefer:
luajit build.lua
```

That copies `static/` into `dist/static/`, renders every entry, and emits
an RSS feed.
The output is plain files you can host anywhere, which is the entire point.

## What goes in the catalogue

- **field-notes** - observations from a specific place and mood.
- **specimens** - things rated and recorded, like a naturalist's drawer.
- **incidents** - failures, with a severity and a status.
- **artifacts** - software and objects I have made or kept.
- **essays** - longer, occasionally coherent thoughts.

The point is not volume.
It is that a thing, once accessioned, is *kept*.
The cost of keeping it should be one Markdown file and one slightly dramatic
decision that it belongs in the archive.

> A catalogue is an argument that the ordinary is worth filing.
