---
title: Why I made this blog in Lua
date: 2026-01-14
tags: meta, software
---

Most personal websites are either a blog that has not been updated since 2021 or a shrine to whatever framework was fashionable when they were built.
I wanted something less ambitious and somehow more unnecessary.

This is a blog for the things I encounter, build, break, and occasionally decide were worth keeping.
The tone is deliberate: slightly severe, a little funny, and free of the warm gradients currently afflicting the open web.

The whole thing is driven by one stdlib-only Lua script.
No client-side JavaScript, no analytics quietly counting your pulse, and no dependency tree that needs its own family tree.
I write a Markdown file, give it a title and a date, and let the script turn it into HTML.

## Why Lua

Lua is small enough to hold in your head, which is useful when the project starts acquiring features it does not need.
To produce this very page:

```lua
-- from the project root
lua5.4 build.lua
-- or, if you prefer:
luajit build.lua
```

That copies `static/` into `dist/static/` and renders every post.
The output is plain files you can host anywhere, which is the entire point.

## What goes here

A mix of things.
Some are small notes from daily life: coffee, a gecko, a stubborn keyboard.
Others are software stories: a concurrency runtime, a deploy that did nothing, the Lua script that builds this page.
The point is not volume.
It is that a thing, once written down, is kept.

> A blog is an argument that the ordinary is worth writing down.
