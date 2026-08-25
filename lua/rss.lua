-- rss.lua - build an RSS 2.0 feed from blog entries.
-- build.lua calls: rss.build(entries, site)
--   entries: array newest-first of { slug, title, date, tags, body_html }
--   site:    { title, description, url }

local M = {}

local function esc(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	return s
end

-- yyyy-mm-dd -> "Thu, 21 Mar 2026 00:00:00 +0000" (RFC 822 for RSS).
local DOW = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MON = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function rfc822(iso)
	local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	if not y then return iso end
	-- Sakamoto's Gregorian calendar algorithm.  Unlike the old anchor
	-- calculation, this works for dates before 2026 too.
	local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
	local year = y
	if m < 3 then year = year - 1 end
	local dow = (year + math.floor(year / 4) - math.floor(year / 100)
		+ math.floor(year / 400) + offsets[m] + d) % 7
	return string.format("%s, %02d %s %04d 00:00:00 +0000",
		DOW[dow + 1], d, MON[m], y)
end

M.build = function(entries, site)
	local out = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
		"  <channel>",
		string.format("    <title>%s</title>", esc(site.title)),
		string.format("    <link>%s</link>", esc(site.url)),
		string.format("    <description>%s</description>", esc(site.description)),
		string.format("    <atom:link href=\"%s\" rel=\"self\" type=\"application/rss+xml\"/>",
			esc(site.url .. "rss.xml")),
	}

	for _, e in ipairs(entries) do
		local link = site.url .. "posts/" .. e.slug .. ".html"
		out[#out + 1] = "    <item>"
		out[#out + 1] = string.format("      <title>%s</title>", esc(e.title))
		out[#out + 1] = string.format("      <link>%s</link>", esc(link))
		out[#out + 1] = string.format("      <guid isPermaLink=\"true\">%s</guid>", esc(link))
		out[#out + 1] = string.format("      <pubDate>%s</pubDate>", esc(rfc822(e.date)))
		for _, t in ipairs(e.tags or {}) do
			out[#out + 1] = string.format("      <category>%s</category>", esc(t))
		end
		out[#out + 1] = string.format("      <description><![CDATA[%s]]></description>", e.body_html or "")
		out[#out + 1] = "    </item>"
	end

	out[#out + 1] = "  </channel>"
	out[#out + 1] = "</rss>"
	return table.concat(out, "\n") .. "\n"
end

return M
