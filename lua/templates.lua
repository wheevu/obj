-- templates.lua - a tiny mustache-style templating engine (stdlib only).
-- Runs on LuaJIT 5.1 and Lua 5.4.
--
--   local templates = require("templates")
--   local html = templates.render("index.html", data)  -- reads templates/<name>
--   local escaped = templates.escape(s)
--
-- Placeholder forms:
--   {{path}}    HTML-escaped value at dot-path `path`
--   {{{path}}}  RAW (unescaped) value at dot-path `path`
--   {{#list}} X {{/list}}  iterate a table; X repeats once per element.
-- Unknown placeholders resolve to "" (they vanish, never leak into output).

local M = {}

local function escape(s)
	if s == nil then return "" end
	s = tostring(s)
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
	return s
end
M.escape = escape

local function split_path(p)
	local parts = {}
	for k in p:gmatch("[^.]+") do parts[#parts + 1] = k end
	return parts
end

local function walk(base, parts)
	local v = base
	for _, k in ipairs(parts) do
		if type(v) == "table" and v[k] ~= nil then v = v[k] else return nil end
	end
	return v
end

-- Resolve a dot-path against the current scope. Inside a loop the current
-- element's keys win; otherwise (and for unresolved keys) fall back to data.
local function resolve(ctx, path)
	local parts = split_path(path)
	if ctx.element then
		local v = walk(ctx.element, parts)
		if v ~= nil then return v end
	end
	return walk(ctx.data, parts)
end

-- Read one tag from `text` starting at `from`. Returns a table or nil.
local function next_tag(text, from)
	local a = text:find("{{", from)
	if not a then return nil end
	local raw, cstart, ce, after
	if text:sub(a, a + 2) == "{{{" then
		raw = true
		cstart = a + 3
		ce = text:find("}}}", cstart)
		if not ce then error("unclosed {{{ at " .. a) end
		after = ce + 3
	else
		raw = false
		cstart = a + 2
		ce = text:find("}}", cstart)
		if not ce then error("unclosed {{ at " .. a) end
		after = ce + 2
	end
	local inner = text:sub(cstart, ce - 1):match("^%s*(.-)%s*$")
	local tagtype, name
	if inner:sub(1, 1) == "#" then
		tagtype, name = "open", inner:sub(2):match("^%s*(.-)%s*$")
	elseif inner:sub(1, 1) == "/" then
		tagtype, name = "close", inner:sub(2):match("^%s*(.-)%s*$")
	else
		tagtype, name = "var", inner
	end
	return { tagtype = tagtype, name = name, raw = raw, a = a, after = after }
end

-- Find the matching close for an open section; return (body, after_close).
local function find_section(text, open_a)
	local ot = next_tag(text, open_a)
	local body_start = ot.after
	local depth = 1
	local p = body_start
	while p <= #text do
		local t = next_tag(text, p)
		if not t then error("unclosed section: " .. ot.name) end
		if t.tagtype == "open" then
			depth = depth + 1
		elseif t.tagtype == "close" then
			depth = depth - 1
			if depth == 0 then
				return text:sub(body_start, t.a - 1), t.after
			end
		end
		p = t.after
	end
	error("unclosed section: " .. ot.name)
end

-- Render `text` against scope `ctx`, starting at byte `start`.
local function render_block(text, ctx, start)
	local out = {}
	local i = start
	while i <= #text do
		local tag = next_tag(text, i)
		if not tag then
			out[#out + 1] = text:sub(i)
			break
		end
		out[#out + 1] = text:sub(i, tag.a - 1)
		if tag.tagtype == "open" then
			local body, after = find_section(text, tag.a)
			local list = resolve(ctx, tag.name)
			if type(list) == "table" then
				if #list > 0 then
					for _, el in ipairs(list) do
						out[#out + 1] = render_block(body, { data = ctx.data, element = el }, 1)
					end
				else
					local empty = true
					for _ in pairs(list) do empty = false break end
					if not empty then
						out[#out + 1] = render_block(body, { data = ctx.data, element = list }, 1)
					end
				end
			end
			i = after
		elseif tag.tagtype == "close" then
			i = tag.after
		else
			local val = resolve(ctx, tag.name) or ""
			out[#out + 1] = tag.raw and tostring(val) or escape(val)
			i = tag.after
		end
	end
	return table.concat(out)
end

function M.render(name, data)
	local f = io.open("templates/" .. name, "r")
	if not f then error("template not found: " .. name) end
	local content = f:read("*a")
	f:close()
	return render_block(content, { data = data, element = nil }, 1)
end

return M
