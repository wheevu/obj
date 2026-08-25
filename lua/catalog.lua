-- catalog.lua
-- Loads *.md posts, parses frontmatter, validates via schema, and renders
-- bodies to HTML via the markdown module.
-- Stdlib only. Runs on LuaJIT 5.1 / Lua 5.4.

local catalog = {}

local schema = require("schema")
local markdown = require("markdown")   -- contract: markdown.to_html(md_text) -> html

catalog.TYPES  = schema.TYPES
catalog.LABELS = schema.LABELS

local BASE_KEYS = { id = true, title = true, date = true, type = true, tags = true }

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

	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	-- drop a trailing blank produced by the appended newline
	if lines[#lines] == "" then lines[#lines] = nil end

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
					-- tags must always be an array of strings
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

	-- body = remaining lines joined
	local body = table.concat(lines, "\n", i)
	return fm, body
end

-- Recursively list *.md files under dir, sorted.
local function list_md(dir)
	local cmd = 'find "' .. dir .. '" -name "*.md" 2>/dev/null'
	local f = io.popen(cmd)
	if not f then return {} end
	local paths = {}
	for line in f:lines() do
		local p = trim(line)
		if p ~= "" then paths[#paths + 1] = p end
	end
	f:close()
	table.sort(paths)
	return paths
end

-- catalog.load(dir) -> entries, errors
function catalog.load(dir)
	local entries = {}
	local errors = {}

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

		local err = schema.validate(fm)
		if err then
			errors[#errors + 1] = path .. ": " .. err
			goto continue
		end

		local meta = {}
		for k, v in pairs(fm) do
			if not BASE_KEYS[k] then meta[k] = v end
		end

		entries[#entries + 1] = {
			id        = fm.id,
			title     = fm.title,
			date      = fm.date,
			type      = fm.type,
			tags      = fm.tags or {},
			body_html = markdown.to_html(body),
			meta      = meta,
		}

		::continue::
	end

	return entries, errors
end

return catalog
