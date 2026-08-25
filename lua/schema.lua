-- schema.lua
-- Frontmatter schema + validation/warnings for the obj catalogue.
-- Stdlib only. Runs on LuaJIT 5.1 / Lua 5.4.

local schema = {}

schema.TYPES = { "essay", "field-note", "specimen", "incident", "artifact" }

schema.LABELS = {
	essay      = "ESSAY",
	["field-note"] = "FIELD NOTE",
	specimen   = "SPECIMEN",
	incident   = "INCIDENT",
	artifact   = "ARTIFACT",
}

local TYPES_SET = {}
for _, t in ipairs(schema.TYPES) do TYPES_SET[t] = true end

-- Per-type extra (non-base) required fields.
local REQUIRED = {
	["field-note"] = { "mood", "location" },
	specimen       = { "rating", "location" },
	incident       = { "severity", "status" },
	artifact       = { "language", "status", "classification" },
	essay          = {},
}

local DATE_PAT = "^%d%d%d%d%-%d%d%-%d%d$"
local BASE_KEYS = { id = true, title = true, date = true, type = true, tags = true }

-- A token that is safe to use as a path component (no "/", no "..", no dots).
local SAFE_TOKEN_PAT = "^[%w%-_]+$"
local function is_safe_token(s)
	return type(s) == "string" and s ~= "" and s:match(SAFE_TOKEN_PAT) ~= nil
end

-- Real calendar date: month 1..12, day valid for that month (leap aware).
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
function schema.validate(fm)
	if type(fm) ~= "table" then
		return "frontmatter is not a table"
	end

	-- id
	local id = fm.id
	if type(id) ~= "string" or id == "" then
		return 'missing "id"'
	end
	if not is_safe_token(id) then
		return 'unsafe "id" "' .. id .. '": only A-Z, a-z, 0-9, "-" and "_" allowed'
	end

	-- title
	local title = fm.title
	if type(title) ~= "string" or title == "" then
		return 'missing "title"'
	end

	-- date
	local date = fm.date
	if type(date) ~= "string" or date == "" then
		return 'missing "date"'
	end
	if not date:match(DATE_PAT) then
		return 'invalid date "' .. date .. '"'
	end
	local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not valid_calendar_date(tonumber(y), tonumber(m), tonumber(d)) then
		return 'invalid date "' .. date .. '"'
	end

	-- type
	local ftype = fm.type
	if type(ftype) ~= "string" or ftype == "" then
		return 'missing "type"'
	end
	if not TYPES_SET[ftype] then
		return 'unsupported type "' .. ftype .. '"'
	end

	-- tags
	local tags = fm.tags
	if type(tags) ~= "table" then
		return 'missing "tags"'
	end
	for _, t in ipairs(tags) do
		if type(t) ~= "string" or t == "" then
			return 'invalid tags'
		end
		if not is_safe_token(t) then
			return 'unsafe tag "' .. t .. '": only A-Z, a-z, 0-9, "-" and "_" allowed'
		end
	end

	-- per-type required fields (present and non-empty)
	local req = REQUIRED[ftype] or {}
	for _, k in ipairs(req) do
		local v = fm[k]
		if v == nil or v == "" then
			return 'missing "' .. k .. '"'
		end
	end

	return nil
end

-- warn(fm) -> array of warning strings (may be empty).
local WHITELIST = {
	["field-note"] = { mood = true, location = true },
	specimen       = { rating = true, location = true, price = true, brand = true, verdict = true },
	incident       = { severity = true, status = true, resolution = true, cause = true },
	artifact       = {
		language = true, status = true, classification = true,
		known_hazards = true, repo = true, license = true, first_seen = true,
	},
	essay = { subtitle = true, updated = true, draft = true },
}

function schema.warn(fm)
	local out = {}
	if type(fm) ~= "table" then return out end
	local wl = WHITELIST[fm.type] or {}
	for k, _ in pairs(fm) do
		if BASE_KEYS[k] then
			-- base metadata is always fine
		elseif not wl[k] then
			out[#out + 1] = 'unknown key "' .. tostring(k) .. '"'
		end
	end
	return out
end

return schema
