# obj

my blog.

I write about life and whatever else I feel like putting here.
The site is built from Markdown with a little Lua blog maker,
mostly because I wanted an excuse to use Lua.

## How it works

1. **Install Lua and LuaSocket locally.**
   `luarocks install luasocket`, or use your platform's Lua package
   (Homebrew's Lua ships LuaSocket).

2. **Write in the local GUI.**
   `lua blog.lua editor` opens a small writing view in your browser
   at `http://127.0.0.1:8787/`. You write without touching raw Markdown
   and save or preview right there.

3. **Publish.**
   `lua blog.lua publish` builds the site, commits the source and content,
   and pushes to GitHub. GitHub Actions builds the same source and GitHub
   Pages serves the result. No manual deploy step.

4. **Read it.**
   The live site is at <https://wheevu.github.io/obj/>.

## Commands

```sh
lua blog.lua new "A small thought"   # create a dated post in posts/
lua blog.lua editor [port]           # open the local writing GUI (default 8787)
lua blog.lua build                   # build dist/ by hand
lua blog.lua publish                 # build, commit, and push
lua blog.lua help                    # show help
```

## Posts

Each file in `posts/` is one blog post: a plain Markdown file with a small
frontmatter header. The filename starts with the date, like
`2026-02-03-espresso-machine-lied.md`, but the build uses the date inside
the file, not the filename.

Frontmatter is an implementation detail you can ignore in the editor.
It looks like this, and three fields are enough:

```md
---
title: A small thought
date: 2026-02-03
tags: life
---
```

Media goes in `media/` and is referenced normally:

```md
![A thing I saw](media/thing.jpg)
```

Posts support headings, bold and italic text, links, lists, blockquotes,
code blocks, and images.
