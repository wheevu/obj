-- rss.lua - build an RSS 2.0 feed from catalog entries.
-- build.lua calls: rss.build(entries, site)
--   entries: array newest-first of {id,title,date,slug,tags,body_html}
--   site:    {title, description, url}

local M = {}

local function esc(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	return s
end

M.build = function(entries, site)
	local out = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
		"  <channel>",
		string.format("    <title>%s</title>", esc(site.title)),
		string.format("    <link>%s</link>", esc(site.url)),
		string.format("    <description>%s</description>", esc(site.description)),
		string.format("    <atom:link href=\"%s\" rel=\"self\" type=\"application/rss+xml\"/>", esc(site.url .. "rss.xml")),
	}

	for _, e in ipairs(entries) do
		local link = site.url .. "posts/" .. e.slug .. ".html"
		out[#out + 1] = "    <item>"
		out[#out + 1] = string.format("      <title>%s</title>", esc(e.title))
		out[#out + 1] = string.format("      <link>%s</link>", esc(link))
		out[#out + 1] = string.format("      <guid isPermaLink=\"false\">%s</guid>", esc(e.id))
		out[#out + 1] = string.format("      <pubDate>%s</pubDate>", esc(e.date))
		if e.tags and #e.tags > 0 then
			out[#out + 1] = string.format("      <category>%s</category>", esc(e.tags[1]))
		end
		out[#out + 1] = string.format("      <description><![CDATA[%s]]></description>", e.body_html or "")
		out[#out + 1] = "    </item>"
	end

	out[#out + 1] = "  </channel>"
	out[#out + 1] = "</rss>"
	return table.concat(out, "\n") .. "\n"
end

return M
