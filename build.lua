#!/usr/bin/env luajit
-- obj - a Lua-powered catalogue.
-- build.lua: reads posts/, validates them, renders every page, and writes dist/.
-- Run: luajit build.lua  (or: lua build.lua)

package.path = "./lua/?.lua;" .. package.path

local catalog   = require("catalog")
local markdown  = require("markdown")
local templates = require("templates")
local rss       = require("rss")

--------------------------------------------------------------------------
-- Site config. Single source of truth for title/URL used everywhere.
--------------------------------------------------------------------------
local site = {
	title       = "obj",
	tagline     = "A place to put the things I keep thinking about.",
	description = "obj - notes, incidents, software, and other things Josh decided to keep.",
	url         = "https://josh.github.io/obj/",
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

-- Recursively list *.md files rooted at dir. Returns relative paths.
M.list_md = function(dir)
	local out = sh(string.format("find %s -name '*.md'", dir))
	local files = {}
	for line in out:gmatch("[^\r\n]+") do
		if line ~= "" then
			files[#files + 1] = line
		end
	end
	table.sort(files)
	return files
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
-- Date formatting helpers.
--------------------------------------------------------------------------
local MONTHS = { "January","February","March","April","May","June","July",
	"August","September","October","November","December" }
M.month_name = function(n) return MONTHS[n] end

M.date_display = function(iso)
	local y, m, d = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if not y then return iso end
	return string.format("%d %s %d", tonumber(d), M.month_name(tonumber(m)), tonumber(y))
end

-- yyyymmdd numeric key for sorting.
M.date_sort = function(iso)
	local key = iso:gsub("%D", "")
	return tonumber(key) or 0
end

M.slug = function(id)
	-- "JOSH-2026-0042" -> "0042"
	return id:match("(%d+)$") or id
end

--------------------------------------------------------------------------
-- Accumulate everything.
--------------------------------------------------------------------------
local entries, errors = catalog.load("posts")
if #errors > 0 then
	for _, e in ipairs(errors) do
		print("[error] " .. e)
	end
	os.exit(1)
end

-- Sort ascending by date (oldest first). Archive displays newest first.
for i = 1, #entries do
	entries[i].date_sort  = M.date_sort(entries[i].date)
	entries[i].date_display = M.date_display(entries[i].date)
	entries[i].slug = M.slug(entries[i].id)
end
table.sort(entries, function(a, b) return a.date_sort < b.date_sort end)

-- Newest first for the index.
local newest = {}
for i = #entries, 1, -1 do
	newest[#newest + 1] = entries[i]
end

-- Build tags ordered by count desc, then name.
local tags = {}
for _, e in ipairs(entries) do
	for _, t in ipairs(e.tags) do
		tags[t] = (tags[t] or 0) + 1
	end
end
local ordered_tags = {}
for tag, count in pairs(tags) do
	ordered_tags[#ordered_tags + 1] = { label = tag, slug = tag, count = count }
end
table.sort(ordered_tags, function(a, b)
	if a.count ~= b.count then return a.count > b.count end
	return a.label < b.label
end)

-- Collections (by type) with counts.
local collections, type_count = {}, {}
for _, e in ipairs(entries) do
	type_count[e.type] = (type_count[e.type] or 0) + 1
end
for _, tname in ipairs(catalog.TYPES) do
	if type_count[tname] then
		collections[#collections + 1] = {
			label = catalog.LABELS[tname],
			type  = tname,
			count = type_count[tname],
			href  = "types/" .. tname .. ".html",
		}
	end
end

local last_newest = newest[1]

--------------------------------------------------------------------------
-- Render helpers.
--------------------------------------------------------------------------
-- base: prefix for internal links. "" at dist/ root, "../" one level deep
-- (dist/posts/, dist/types/). All hrefs passed to templates are kept
-- root-relative, and templates prepend {{base}} to them.
local render_page = function(template, data, base)
	data.base = base or ""
	data.site = site
	data.entry_count = #entries
	data.collection_count = #collections
	return templates.render(template, data)
end

-- Each entry -> list row for index/archive/tag pages.
local entry_row = function(e)
	return {
		id       = e.id,
		slug     = e.slug,
		title    = e.title,
		date     = e.date_display,
		type     = e.type,
		type_label = catalog.LABELS[e.type],
		href     = "posts/" .. e.slug .. ".html",
	}
end

--------------------------------------------------------------------------
-- Go generate.
--------------------------------------------------------------------------
M.mkdirp("dist")
M.mkdirp("dist/posts")
M.mkdirp("dist/types")
M.mkdirp("dist/static")

-- index (archive dashboard)
do
	local rows = {}
	for i = 1, math.min(24, #newest) do
		rows[#rows + 1] = entry_row(newest[i])
	end
	local html = render_page("index.html", {
		page = "ARCHIVE",
		recent = rows,
		collections = collections,
		last_accession = last_newest and last_newest.date_display or "n/a",
		count_display = string.format("%04d", #entries),
	})
	M.write("dist/index.html", html)
end

-- archive: every entry, chronological.
do
	local rows = {}
	for _, e in ipairs(entries) do
		rows[#rows + 1] = entry_row(e)
	end
	local html = render_page("archive.html", {
		page = "ARCHIVE / ALL",
		entries = rows,
	})
	M.write("dist/archive.html", html)
end

-- individual post pages.
local written_posts = 0
for _, e in ipairs(entries) do
	-- meta rows for the post template loop.
	local meta_rows = {}
	local known = {
		["field-note"] = { "mood", "location" },
		specimen        = { "rating", "location", "price", "brand", "verdict" },
		incident        = { "severity", "status", "resolution", "cause" },
		artifact        = { "language", "status", "classification", "known_hazards", "repo", "license", "first_seen" },
		essay           = { "subtitle", "updated", "draft" },
	}
	local order = known[e.type] or {}
	for _, k in ipairs(order) do
		local v = e.meta[k]
		if v ~= nil and v ~= "" then
			if type(v) == "table" then v = table.concat(v, ", ") end
			meta_rows[#meta_rows + 1] = { label = k, value = tostring(v) }
		end
	end

	-- previous / next navigation by date.
	local idx = nil
	for i, x in ipairs(entries) do if x.id == e.id then idx = i break end end
	local prev = idx and idx > 1 and entries[idx - 1]
	local next = idx and idx < #entries and entries[idx + 1]

	local html = render_page("post.html", {
		page = catalog.LABELS[e.type] .. " " .. e.slug,
		entry = {
			id = e.id,
			slug = e.slug,
			title = e.title,
			date = e.date_display,
			type_label = catalog.LABELS[e.type],
			body_html = e.body_html,
			tags = (function()
				local t = {}
				for _, tag in ipairs(e.tags) do
					t[#t + 1] = { label = tag, slug = tag }
				end
				return t
			end)(),
			meta_rows = meta_rows,
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
		page = "TAG: " .. tag.label,
		tag = tag.label,
		tag_count = tag.count,
		entries = rows,
	}, "../")
	M.write(string.format("dist/types/tag--%s.html", tag.slug), html)
	written_tags = written_tags + 1
end

-- collection (type) index pages.
for _, c in ipairs(collections) do
	local rows = {}
	for _, e in ipairs(newest) do
		if e.type == c.type then rows[#rows + 1] = entry_row(e) end
	end
	local html = render_page("types.html", {
		page = c.label,
		collection = c.label,
		collection_count = c.count,
		entries = rows,
	}, "../")
	M.write("dist/types/" .. c.type .. ".html", html)
end

-- rss
M.write("dist/rss.xml", rss.build(newest, site))

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

--------------------------------------------------------------------------
-- The satisfying bit.
--------------------------------------------------------------------------
print()
print("catalogue")
print("--------------------------------------------------")
print(string.format("indexed %d records", #entries))
print(string.format("rendered %d entries", written_posts))
print(string.format("generated %d collections (%d tag indexes)", #collections, written_tags))
print("wrote rss.xml")
print("done.")
