-- schema.lua
-- Frontmatter validation for obj, a personal blog.
-- Posts require only: title, date, tags. description is optional.
-- No typed metadata (id/type/mood/location/...) is required or understood here.
-- Stdlib only. Runs on LuaJIT 5.1 / Lua 5.4.

local schema = {}

-- Keys the blog frontmatter understands. Anything else is ignored (and,
-- optionally, warned about) rather than rejected.
local BASE_KEYS = { title = true, date = true, tags = true, description = true }

-- A token safe to use as a URL/path component: alnum, dash, underscore.
-- No slashes, dots, or spaces, so it can never escape a directory.
local SAFE_TOKEN_PAT = "^[%w%-_]+$"
local function is_safe_token(s)
	return type(s) == "string" and s ~= "" and s:match(SAFE_TOKEN_PAT) ~= nil
end

local DATE_PAT = "^%d%d%d%d%-%d%d%-%d%d$"

-- Real calendar date check: month 1..12, day valid for that month (leap aware).
local DAYS = { 31,28,31,30,31,30,31,31,30,31,30,31 }
local function valid_calendar_date(y, m, d)
	if m < 1 or m > 12 then return false end
	local dim = DAYS[m]
	if m == 2 then
		local leap = (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0))
		if leap then dim = 29 end
	end
	return d >= 1 and d <= dim
end

-- validate(fm) -> nil if OK, else an error message string (first problem).
-- Rejects malformed posts with a clear message instead of crashing.
function schema.validate(fm)
	if type(fm) ~= "table" then
		return "frontmatter is not a table"
	end

	-- title: required, non-empty string.
	local title = fm.title
	if type(title) ~= "string" or title == "" then
		return 'missing or empty "title"'
	end

	-- date: required, real calendar date yyyy-mm-dd.
	local date = fm.date
	if type(date) ~= "string" or date == "" then
		return 'missing or empty "date"'
	end
	if not date:match(DATE_PAT) then
		return 'invalid date "' .. date .. '": expected yyyy-mm-dd'
	end
	local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not valid_calendar_date(tonumber(y), tonumber(m), tonumber(d)) then
		return 'invalid calendar date "' .. date .. '"'
	end

	-- tags: required array of safe lowercase tokens.
	local tags = fm.tags
	if type(tags) ~= "table" then
		return 'missing "tags" (expected an array)'
	end
	for _, t in ipairs(tags) do
		if type(t) ~= "string" or t == "" then
			return 'invalid tags: each tag must be a non-empty string'
		end
		if not is_safe_token(t) then
			return 'unsafe tag "' .. t .. '": only a-z, 0-9, "-" and "_" allowed'
		end
	end

	-- description: optional, must be a string if present.
	if fm.description ~= nil and type(fm.description) ~= "string" then
		return 'invalid "description": expected a string'
	end

	return nil
end

-- warn(fm) -> array of warning strings (may be empty).
-- Flags frontmatter keys the blog does not understand, so authors get a
-- gentle nudge without failing the build.
function schema.warn(fm)
	local out = {}
	if type(fm) ~= "table" then return out end
	for k, _ in pairs(fm) do
		if not BASE_KEYS[k] then
			out[#out + 1] = 'unknown frontmatter key "' .. tostring(k) .. '" (ignored)'
		end
	end
	return out
end

return schema
