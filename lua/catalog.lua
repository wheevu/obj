-- catalog.lua
-- Loads *.md posts, parses frontmatter, validates via schema, and renders
-- bodies to HTML via the markdown module.
-- Stdlib only. Runs on LuaJIT 5.1 / Lua 5.4.

local catalog = {}

local schema   = require("schema")
local markdown = require("markdown")   -- contract: markdown.to_html(md_text) -> html

local DATE_PREFIX_PAT = "^%d%d%d%d%-%d%d%-%d%d%-(.+)$"
local SAFE_TOKEN_PAT  = "^[%w%-_]+$"

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse a scalar/number/comma-list value into a Lua value.
local function parse_value(raw)
	local v = trim(raw)
	if v == "" then return "" end

	-- strip surrounding quotes -> plain string (commas inside are literal)
	local q = v:match('^"(.*)"$') or v:match("^'(.*)'$")
	if q then return q end

	-- comma-separated list -> array
	if v:find(",") then
		local arr = {}
		for part in v:gmatch("[^,]+") do
			local p = trim(part)
			if p ~= "" then arr[#arr + 1] = p end
		end
		return arr
	end

	-- number
	local n = tonumber(v)
	if n then return n end

	return v
end

-- Read an entire file as a string.
local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

-- Parse frontmatter + body from raw file text.
-- Returns fm (table) and body (string), or nil, errmsg on failure.
local function parse_post(text)
	if not text then return nil, "empty file" end

	-- Split into lines, preserving real blank lines, so the markdown
	-- block parser sees them exactly as written.
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	if #lines == 0 or trim(lines[1]) ~= "---" then
		return nil, "missing opening ---"
	end

	local fm = {}
	local i = 2
	local closed = false
	while i <= #lines do
		if trim(lines[i]) == "---" then
			closed = true
			i = i + 1
			break
		end
		local key, val = lines[i]:match("^([^:]*):(.*)$")
		if key then
			key = trim(key)
			if key ~= "" then
				local value = parse_value(val or "")
				if key == "tags" then
					-- tags must always be an array of strings, lowercased.
					if type(value) ~= "table" then value = { tostring(value) } end
					local norm = {}
					for _, t in ipairs(value) do
						norm[#norm + 1] = trim(tostring(t)):lower()
					end
					fm.tags = norm
				else
					fm[key] = value
				end
			end
		end
		i = i + 1
	end

	if not closed then
		return nil, "missing closing ---"
	end

	-- body = remaining lines joined (blank lines preserved)
	local body = table.concat(lines, "\n", i)
	return fm, body
end

-- Derive a URL-safe slug from a post's filename.
-- "2026-03-21-argued-with-a-gecko.md" -> "argued-with-a-gecko".
-- Strips a leading yyyy-mm-dd- for readable URLs, keeps uniqueness, and
-- validates the result is a safe path token. `used` tracks taken slugs.
local function slug_for(filename, used)
	local base = filename:match("([^/]+)%.md$") or filename:match("([^/]+)$")
	if not base then return nil, "unusable filename: " .. tostring(filename) end

	local core = base:match(DATE_PREFIX_PAT) or base
	if core == "" then core = base end

	-- uniqueness: append -2, -3, ... on collision
	local candidate = core
	local n = 2
	while used[candidate] do
		candidate = core .. "-" .. n
		n = n + 1
	end

	if not candidate:match(SAFE_TOKEN_PAT) then
		return nil, 'unsafe slug "' .. candidate .. '" from file "' .. filename
			.. '": only a-z, 0-9, "-" and "_" allowed'
	end

	used[candidate] = true
	return candidate
end

-- Recursively list *.md files under dir, sorted. Skips README files.
local function list_md(dir)
	local cmd = 'find "' .. dir .. '" -name "*.md" 2>/dev/null'
	local f = io.popen(cmd)
	if not f then return {} end
	local paths = {}
	for line in f:lines() do
		local p = trim(line)
		if p ~= "" then
			local base = p:match("([^/]+)$") or p
			-- README is documentation, never post content (any case).
			if not base:lower():match("^readme") then
				paths[#paths + 1] = p
			end
		end
	end
	f:close()
	table.sort(paths)
	return paths
end

-- catalog.load(dir) -> entries, errors
-- entries: array of { slug, title, date, tags, description, body_html }
function catalog.load(dir)
	local entries = {}
	local errors = {}

	local used_slugs = {}
	local paths = list_md(dir)
	for _, path in ipairs(paths) do
		local text = read_file(path)
		if not text then
			errors[#errors + 1] = path .. ": cannot read file"
			goto continue
		end

		local fm, body = parse_post(text)
		if not fm then
			errors[#errors + 1] = path .. ": " .. (body or "parse error")
			goto continue
		end

		local slug, serr = slug_for(path, used_slugs)
		if not slug then
			errors[#errors + 1] = path .. ": " .. serr
			goto continue
		end

		local err = schema.validate(fm)
		if err then
			errors[#errors + 1] = path .. ": " .. err
			goto continue
		end

		entries[#entries + 1] = {
			slug        = slug,
			title       = fm.title,
			date        = fm.date,
			tags        = fm.tags or {},
			description = fm.description,
			body_html   = markdown.to_html(body, { media_prefix = "../" }),
		}

		::continue::
	end

	return entries, errors
end

return catalog
