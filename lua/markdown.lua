-- markdown.lua - a small, dependency-free Markdown-to-HTML block parser.
--
-- Runs on LuaJIT 5.1 and plain Lua 5.4 (stdlib only). No external modules.
--
-- Public API:
--   local markdown = require("markdown")
--   local html = markdown.to_html(md_text)                 -- md_text: string -> HTML string
--   local html = markdown.to_html(md_text, opts)           -- opts is optional
--   -- opts.media_prefix: string prepended to relative "media/" URLs in images
--   --    (e.g. "../"); default is "". Absolute http(s)://, //, data:, and
--   --    fragment links are left untouched.
--
-- Design: a single pass that groups input lines into blocks (headings,
-- fenced code, lists, blockquotes, paragraphs), then renders each block.
-- Blank lines separate blocks. Lists/blockquotes group consecutive
-- qualifying lines into one wrapping element.

local M = {}

----------------------------------------------------------------------
-- HTML escaping for visible text content.
-- Order matters: ampersand first, so we never double-escape entities.
----------------------------------------------------------------------
local function escape(s)
	s = s:gsub("&", "&amp;")   -- ampersand first, so we never double-escape
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	return s
end

local function safe_url(url, allow_data_image)
	url = url:gsub("^%s+", ""):gsub("%s+$", "")
	local lower = url:lower()
	if lower:match("^javascript%s*:") or lower:match("^vbscript%s*:") then
		return "#"
	end
	if lower:match("^data:") and not (allow_data_image and lower:match("^data:image/")) then
		return "#"
	end
	return url
end

----------------------------------------------------------------------
-- Inline formatting: code spans, links, bold, italic.
--
-- Strategy: pull inline code spans out first (escape + wrap them, then
-- hide them behind a null-delimited placeholder). Escape the remaining
-- text, apply links/bold/italic, then restore the code spans untouched.
----------------------------------------------------------------------
local function inline(text, opts)
	if text == nil then return "" end
	opts = opts or {}
	local media_prefix = opts.media_prefix or ""

	-- 1. extract `inline code` spans; escape their content, wrap, hide.
	local codes = {}
	text = text:gsub("`([^`]+)`", function(c)
		local wrapped = "<code>" .. escape(c) .. "</code>"
		codes[#codes + 1] = wrapped
		return "\1" .. #codes .. "\1"
	end)

	-- 1b. extract ![alt](url) images. Apply media_prefix to relative
	--     "media/" URLs (before escaping) and escape both alt and URL so
	--     neither can inject raw HTML. Hide the finished tag so the later
	--     escape/links steps never touch it.
	local images = {}
	text = text:gsub("!%[(.-)%]%((.-)%)", function(alt, url)
		url = url:gsub("^%s+", ""):gsub("%s+$", "")
		if url:match("^media/") then
			url = media_prefix .. url
		end
		url = safe_url(url, true)
		local tag = '<img src="' .. escape(url) .. '" alt="' .. escape(alt) .. '" loading="lazy">'
		images[#images + 1] = tag
		return "\2" .. #images .. "\2"
	end)

	-- 2. escape everything else (links/formatting markers survive this).
	text = escape(text)

	-- 3. bold **...**
	text = text:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")

	-- 4. italic *...*
	text = text:gsub("%*(.-)%*", "<em>%1</em>")

	-- 5. italic _..._ (guarded so in-word underscores, e.g. snake_case,
	--    are not treated as emphasis).
	text = apply_underscore(text)

	-- 6. links [text](url) -> <a href="url">text</a>
	--    url is already escaped from step 2, which is correct for an
	--    HTML attribute (& -> &amp;, " -> &quot;).
	text = text:gsub("%[(.-)%]%((.-)%)", function(t, u)
		return '<a href="' .. safe_url(u, false) .. '">' .. t .. "</a>"
	end)

	-- 7. restore code spans.
	text = text:gsub("\1(%d+)\1", function(i)
		return codes[tonumber(i)]
	end)

	-- 8. restore image tags.
	text = text:gsub("\2(%d+)\2", function(i)
		return images[tonumber(i)]
	end)

	return text
end

-- guarded underscore-italic: only treat _x_ as emphasis when neither
-- side is an alphanumeric character (so snake_case is left alone).
function apply_underscore(text)
	local out = {}
	local i = 1
	local n = #text
	while i <= n do
		local s, e = text:find("_(.-)_", i)
		if not s then
			out[#out + 1] = text:sub(i)
			break
		end
		local before = text:sub(s - 1, s - 1)
		local after = text:sub(e + 1, e + 1)
		local bad_before = (s > 1) and before:match("%w")
		local bad_after = (e < n) and after:match("%w")
		if bad_before or bad_after then
			out[#out + 1] = text:sub(i, s)
			i = s + 1
		else
			out[#out + 1] = text:sub(i, s - 1) .. "<em>" .. text:sub(s + 1, e - 1) .. "</em>"
			i = e + 1
		end
	end
	return table.concat(out)
end

----------------------------------------------------------------------
-- Block grouping.
----------------------------------------------------------------------
local function is_blank(line)
	return line:match("^%s*$") ~= nil
end

local function block_type(line)
	local h = line:match("^(#+)%s")
	if h and #h <= 6 then
		return "heading"
	elseif line:match("^%s*[%*%-]%s") then
		return "ul"
	elseif line:match("^%s*%d+%.%s") then
		return "ol"
	elseif line:match("^>%s?") then
		return "quote"
	else
		return "para"
	end
end

-- Group lines into blocks. Headings and fences are always one block per
-- construct; ul/ol/quote/para group consecutive same-type lines.
local function split_blocks(lines)
	local blocks = {}
	local cur = nil
	local i = 1
	while i <= #lines do
		local line = lines[i]
		if is_blank(line) then
			if cur then blocks[#blocks + 1] = cur; cur = nil end
			i = i + 1
		elseif line:match("^```") then
			-- fenced code block: collect until a matching closing fence.
			local open = line
			local lang = open:match("^```%s*(%S+)") or ""
			local body = {}
			i = i + 1
			while i <= #lines and not lines[i]:match("^```") do
				body[#body + 1] = lines[i]
				i = i + 1
			end
			i = i + 1 -- skip the closing fence line (if present)
			blocks[#blocks + 1] = { type = "fence", lang = lang, lines = body }
			cur = nil
		else
			local t = block_type(line)
			-- headings never group with a following heading.
			if cur and cur.type == t and t ~= "heading" then
				cur.lines[#cur.lines + 1] = line
			else
				if cur then blocks[#blocks + 1] = cur end
				cur = { type = t, lines = { line } }
			end
			i = i + 1
		end
	end
	if cur then blocks[#blocks + 1] = cur end
	return blocks
end

----------------------------------------------------------------------
-- Block rendering.
----------------------------------------------------------------------
local function render_block(b, out, opts)
	if b.type == "heading" then
		local line = b.lines[1]
		local level = line:match("^(#+)")
		local txt = line:sub(#level + 1)
		txt = txt:gsub("^%s+", "")
		txt = txt:gsub("%s#+$", "") -- trim trailing #'s
		txt = txt:gsub("%s+$", "")
		out[#out + 1] = string.format("<h%d>%s</h%d>\n", #level, inline(txt, opts), #level)

	elseif b.type == "fence" then
		local body = table.concat(b.lines, "\n")
		local cls = ""
		if b.lang ~= "" then
			cls = ' class="language-' .. escape(b.lang) .. '"'
		end
		out[#out + 1] = string.format("<pre><code%s>%s</code></pre>\n", cls, escape(body))

	elseif b.type == "ul" then
		local items = {}
		for _, l in ipairs(b.lines) do
			local c = l:gsub("^%s*[%*%-]%s", "")
			items[#items + 1] = "<li>" .. inline(c, opts) .. "</li>"
		end
		out[#out + 1] = "<ul>\n" .. table.concat(items, "\n") .. "\n</ul>\n"

	elseif b.type == "ol" then
		local items = {}
		for _, l in ipairs(b.lines) do
			local c = l:gsub("^%s*%d+%.%s", "")
			items[#items + 1] = "<li>" .. inline(c, opts) .. "</li>"
		end
		out[#out + 1] = "<ol>\n" .. table.concat(items, "\n") .. "\n</ol>\n"

	elseif b.type == "quote" then
		local stripped = {}
		for _, l in ipairs(b.lines) do
			stripped[#stripped + 1] = l:gsub("^>%s?", "")
		end
		local inner = "<p>" .. inline(table.concat(stripped, " "), opts) .. "</p>"
		out[#out + 1] = "<blockquote>\n" .. inner .. "\n</blockquote>\n"

	elseif b.type == "para" then
		local c = table.concat(b.lines, " ")
		out[#out + 1] = "<p>" .. inline(c, opts) .. "</p>\n"
	end
end

----------------------------------------------------------------------
-- Public entry point.
----------------------------------------------------------------------
function M.to_html(text, opts)
	if text == nil or text == "" then return "" end
	-- normalize line endings
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

	-- split into lines, tolerating a missing trailing newline
	local lines = {}
	do
		local s = text .. "\n"
		for l in s:gmatch("(.-)\n") do
			lines[#lines + 1] = l
		end
	end

	local blocks = split_blocks(lines)
	local out = {}
	for _, b in ipairs(blocks) do
		render_block(b, out, opts)
	end
	return table.concat(out)
end

return M
