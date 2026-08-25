#!/usr/bin/env luajit
-- obj - a small personal blog, built from Markdown.
-- build.lua: reads posts/, validates them, renders every page, and writes dist/.
-- Run: luajit build.lua  (or: lua build.lua)

package.path = "./lua/?.lua;" .. package.path

local catalog   = require("catalog")
local markdown  = require("markdown")
local templates = require("templates")

--------------------------------------------------------------------------
-- Site config. Single source of truth for title/URL used everywhere.
--------------------------------------------------------------------------
local site = {
	title       = "obj",
	tagline     = "A place to put the things I keep thinking about.",
	description = "my blog. things I've been thinking about, doing, making, eating, listening to, whatever.",
	url         = "https://wheevu.github.io/obj/",
}

--------------------------------------------------------------------------
-- fs helpers. Portable across macOS and the Ubuntu GitHub runner.
--------------------------------------------------------------------------
local M = {}

local function sh(cmd)
	local f = assert(io.popen(cmd, "r"))
	local out = f:read("*a")
	f:close()
	return out
end

M.mkdirp = function(path)
	os.execute("mkdir -p " .. path)
end

M.read = function(path)
	local f = assert(io.open(path, "r"))
	local ok, content = pcall(f.read, f, "*a")
	f:close()
	if ok then return content end
	return nil
end

M.write = function(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

--------------------------------------------------------------------------
-- Date helpers. Added by the build, not required frontmatter.
--------------------------------------------------------------------------
local MONTHS = { "January","February","March","April","May","June","July",
	"August","September","October","November","December" }
M.date_display = function(iso)
	local y, m, d = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if not y then return iso end
	return string.format("%d %s %d", tonumber(d), MONTHS[tonumber(m)], tonumber(y))
end

-- yyyymmdd numeric key for sorting.
M.date_sort = function(iso)
	local key = iso:gsub("%D", "")
	return tonumber(key) or 0
end

--------------------------------------------------------------------------
-- Load + validate posts.
--------------------------------------------------------------------------
local entries, errors = catalog.load("posts")
if #errors > 0 then
	for _, e in ipairs(errors) do
		print("[error] " .. e)
	end
	os.exit(1)
end

-- Attach build-time fields: sort key, display date, and a stable ordering.
for i = 1, #entries do
	entries[i].date_sort    = M.date_sort(entries[i].date)
	entries[i].date_display = M.date_display(entries[i].date)
end

-- Canonical order: oldest first. Used for prev/next neighbours.
table.sort(entries, function(a, b)
	if a.date_sort ~= b.date_sort then return a.date_sort < b.date_sort end
	return a.slug < b.slug
end)

-- Newest first for index / archive / tag listings.
local newest = {}
for i = #entries, 1, -1 do
	newest[#newest + 1] = entries[i]
end

--------------------------------------------------------------------------
-- Tags: ordered by count desc, then name. slug == label (safe token).
--------------------------------------------------------------------------
local tag_counts = {}
for _, e in ipairs(entries) do
	for _, t in ipairs(e.tags) do
		tag_counts[t] = (tag_counts[t] or 0) + 1
	end
end
local ordered_tags = {}
for tag, count in pairs(tag_counts) do
	ordered_tags[#ordered_tags + 1] = { label = tag, slug = tag, count = count }
end
table.sort(ordered_tags, function(a, b)
	if a.count ~= b.count then return a.count > b.count end
	return a.label < b.label
end)

--------------------------------------------------------------------------
-- Render helpers.
--------------------------------------------------------------------------
-- Cache-bust version for static assets: a short hash of the file content.
-- Templates emit style.css?v={{style_v}}, so any edit to the stylesheet
-- produces a fresh URL and browsers never serve a stale cached copy.
-- Plain arithmetic (no bit ops) so it runs on LuaJIT 5.1 through Lua 5.5.
local asset_version = function(path)
	local content = M.read(path) or ""
	local h = 0
	for i = 1, #content do
		h = (h * 31 + content:byte(i)) % 2147483647
	end
	return string.format("%08x", h)
end
local style_v = asset_version("static/style.css")

-- base: prefix for internal links. "" at dist/ root, "../" one level deep
-- (dist/posts/, dist/tags/). All hrefs passed to templates are kept
-- root-relative, and templates prepend {{base}} to them.
local render_page = function(template, data, base)
	data.base    = base or ""
	data.site    = site
	data.style_v = style_v
	return templates.render(template, data)
end

-- A list row: slug, title, date (display), href. Root-relative href only;
-- the template prepends {{base}}.
local entry_row = function(e)
	return {
		slug  = e.slug,
		title = e.title,
		date  = e.date_display,
		href  = "posts/" .. e.slug .. ".html",
	}
end

-- Tags for a post: { label, href } where href is root-relative.
local entry_tags = function(e)
	local t = {}
	for _, tag in ipairs(e.tags) do
		t[#t + 1] = { label = tag, href = "tags/" .. tag .. ".html" }
	end
	return t
end

--------------------------------------------------------------------------
-- Go generate.
--------------------------------------------------------------------------
-- Regenerate from scratch: remove any prior build output (including stale
-- type pages left over from the old catalogue) so dist/ always reflects
-- the current posts only.
os.execute("rm -rf dist")
M.mkdirp("dist")
M.mkdirp("dist/posts")
M.mkdirp("dist/tags")
M.mkdirp("dist/static")
M.mkdirp("dist/media")

-- index (recent posts)
do
	local rows = {}
	for i = 1, math.min(24, #newest) do
		rows[#rows + 1] = entry_row(newest[i])
	end
	local html = render_page("index.html", {
		recent = rows,
	})
	M.write("dist/index.html", html)
end

-- individual post pages (prev/next by date).
local written_posts = 0
for _, e in ipairs(entries) do
	local idx = nil
	for i, x in ipairs(entries) do if x.slug == e.slug then idx = i break end end
	local prev = idx and idx > 1 and entries[idx - 1]
	local next = idx and idx < #entries and entries[idx + 1]

	local html = render_page("post.html", {
		entry = {
			slug        = e.slug,
			title       = e.title,
			date        = e.date_display,
			date_iso    = e.date,
			tags        = entry_tags(e),
			body_html   = e.body_html,
			description = e.description,
		},
		prev = prev and entry_row(prev) or nil,
		next = next and entry_row(next) or nil,
	}, "../")
	M.write(string.format("dist/posts/%s.html", e.slug), html)
	written_posts = written_posts + 1
end

-- tag index pages.
local written_tags = 0
for _, tag in ipairs(ordered_tags) do
	local rows = {}
	for _, e in ipairs(newest) do
		for _, t in ipairs(e.tags) do
			if t == tag.label then
				rows[#rows + 1] = entry_row(e)
				break
			end
		end
	end
	local html = render_page("tag.html", {
		tag       = tag.label,
		tag_count = tag.count,
		entries   = rows,
	}, "../")
	M.write(string.format("dist/tags/%s.html", tag.slug), html)
	written_tags = written_tags + 1
end

--------------------------------------------------------------------------
-- Copy static assets.
--------------------------------------------------------------------------
local function copy_tree(src, dst)
	local out = sh(string.format("find %s -type f", src))
	for line in out:gmatch("[^\r\n]+") do
		if line ~= "" then
			local file = line:gsub("^" .. src .. "/", "")
			M.mkdirp(dst .. "/" .. (file:match("^(.*)/") or ""))
			local content = M.read(line)
			if content then M.write(dst .. "/" .. file, content) end
		end
	end
end
copy_tree("static", "dist/static")
copy_tree("media", "dist/media")

--------------------------------------------------------------------------
-- Plain output.
--------------------------------------------------------------------------
print("built " .. site.title)
print(#entries .. " posts")
print(#ordered_tags .. " tags")
print("done.")
