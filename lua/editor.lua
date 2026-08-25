-- editor.lua
-- A small local-only browser editor server for obj, built on LuaSocket.
--
--   local editor = require("editor")
--   editor.serve({ port = 8787 })   -- blocks until Ctrl-C
--
-- Design rules (enforced below):
--   * Never binds publicly. Binds only 127.0.0.1 (loopback).
--   * One client at a time; each client is closed after the response.
--   * No dependencies besides LuaSocket (stdlib only otherwise).
--   * All user data is HTML-escaped before injection; only the HTML
--     produced by markdown.to_html is ever emitted raw.
--   * Existing post files are resolved by scanning posts/ and deriving
--     the same slug; a user-supplied path is never trusted.
--
-- Runs on LuaJIT 5.1 / Lua 5.4 / 5.5 (stdlib only besides LuaSocket).

local editor = {}

----------------------------------------------------------------------
-- Locate sibling modules regardless of caller CWD.
----------------------------------------------------------------------
local function script_dir()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	return src:match("^(.*/)") or "./"
end
local self_dir = script_dir()
package.path = self_dir .. "?.lua;" .. self_dir .. "?/init.lua;" .. package.path

local schema    = require("schema")
local markdown  = require("markdown")
local templates = require("templates")
local catalog   = require("catalog")

----------------------------------------------------------------------
-- Constants.
----------------------------------------------------------------------
local MAX_BODY      = 2 * 1024 * 1024   -- 2 MB request body cap (normal posts)
local MAX_MEDIA_BODY = 15 * 1024 * 1024  -- 15 MB cap (allows a 10 MB decoded upload)
local POSTS_DIR     = "posts"
local STATIC_DIR    = "static"
local MEDIA_DIR     = "media"
local TEMPLATE_NAME = "editor.html"
local SERVER_PORT   = 8787

local DATE_PREFIX_PAT = "^%d%d%d%d%-%d%d%-%d%d%-(.+)$"
local SAFE_TOKEN_PAT  = "^[%w%-_]+$"
local DATE_PAT        = "^%d%d%d%d%-%d%d%-%d%d$"

----------------------------------------------------------------------
-- Small helpers.
----------------------------------------------------------------------
local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Percent-decode a query/form value; "+" is a space.
local function urldecode(s)
	if s == nil then return "" end
	s = s:gsub("+", " ")
	s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	return s
end

-- Parse an application/x-www-form-urlencoded string into a table.
local function parse_urlencoded(s)
	local out = {}
	if not s or s == "" then return out end
	for pair in s:gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=?(.*)$")
		k = urldecode(k)
		v = urldecode(v)
		out[k] = v
	end
	return out
end

-- Parse a comma-separated tag list into a lowercased array, exactly as
-- catalog.lua does for the frontmatter `tags` field.
local function parse_tags_csv(s)
	local arr = {}
	if type(s) ~= "string" or s == "" then return arr end
	for part in s:gmatch("[^,]+") do
		local p = trim(part)
		if p ~= "" then arr[#arr + 1] = p:lower() end
	end
	return arr
end

-- Derive the URL-safe slug from a post filename, mirroring catalog.lua.
local function slug_for_file(filename)
	local base = filename:match("([^/]+)%.md$") or filename:match("([^/]+)$")
	if not base then return nil end
	local core = base:match(DATE_PREFIX_PAT) or base
	if core == "" then core = base end
	if not core:match(SAFE_TOKEN_PAT) then return nil end
	return core
end

-- Build a slug from a title (alnum/dash/underscore only).
local function slugify(title)
	local slug = title:lower()
	slug = slug:gsub("[^%w%s%-_]", "")
	slug = slug:gsub("%s+", "-")
	slug = slug:gsub("%-+", "-")
	slug = slug:gsub("^%-", ""):gsub("%-$", "")
	return slug
end

-- List *.md files under the posts directory (full paths).
local function list_post_files()
	local paths = {}
	local f = io.popen('find "' .. POSTS_DIR .. '" -name "*.md" 2>/dev/null')
	if f then
		for line in f:lines() do
			local p = trim(line)
			if p ~= "" then
				local base = p:match("([^/]+)$") or p
				if not base:lower():match("^readme") then
					paths[#paths + 1] = p
				end
			end
		end
		f:close()
	end
	table.sort(paths)
	return paths
end

-- Read a whole file as a string, or nil.
local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_atomic(path, data, mode)
	local tmp = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
	local f, err = io.open(tmp, mode or "w")
	if not f then return nil, err end
	local ok, write_err = f:write(data)
	if not ok then
		f:close()
		os.remove(tmp)
		return nil, write_err or "write failed"
	end
	local close_ok, close_err = f:close()
	if not close_ok then
		os.remove(tmp)
		return nil, close_err or "close failed"
	end
	local renamed, rename_err = os.rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return nil, rename_err or "rename failed"
	end
	return true
end

----------------------------------------------------------------------
-- Base64 decoding (stdlib only; no external dependency).
----------------------------------------------------------------------
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Decode a standard base64 string into its binary payload.
-- Returns (decoded_string) on success, or (nil, error_message) on failure.
local function base64_decode(s)
	if type(s) ~= "string" then return nil, "not a string" end
	s = s:gsub("%s+", "")
	if s == "" or #s % 4 ~= 0 then return nil, "length must be a multiple of 4" end
	if s:match("[^A-Za-z0-9+/=]") then
		return nil, "invalid base64 character"
	end
	-- Padding, if present, must be a trailing run of 1 or 2 '=' only.
	if s:match("=") then
		local core = s:gsub("=*$", "")
		if s:sub(#core + 1):match("[^=]") then
			return nil, "invalid padding"
		end
		local pad = #s - #core
		if pad > 2 or #core % 4 == 1 then return nil, "invalid padding" end
	end

	local lookup = {}
	for i = 1, #BASE64_ALPHABET do
		lookup[BASE64_ALPHABET:sub(i, i)] = i - 1
	end

	local out = {}
	local buffer = 0
	local nbits = 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "=" then break end
		local val = lookup[c]
		buffer = buffer * 64 + val
		nbits = nbits + 6
		if nbits >= 8 then
			nbits = nbits - 8
			local shifted = math.floor(buffer / (2 ^ nbits))
			out[#out + 1] = string.char(shifted % 256)
			buffer = buffer % (2 ^ nbits)
		end
	end
	local result = table.concat(out)
	if result == "" then return nil, "empty payload" end
	return result
end

local function valid_image_bytes(ext, data)
	ext = ext:lower()
	if ext == "png" then return data:sub(1, 8) == "\137PNG\r\n\026\n" end
	if ext == "jpg" or ext == "jpeg" then return data:sub(1, 3) == "\255\216\255" end
	if ext == "gif" then return data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" end
	if ext == "webp" then return data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" end
	if ext == "svg" then
		local head = data:sub(1, 1024):gsub("^%s+", ""):lower()
		return head:match("^<svg[%s>]") ~= nil
			or head:match("^<%?xml[^%c]*%?>%s*<svg[%s>]") ~= nil
	end
	return false
end

----------------------------------------------------------------------
-- Minimal JSON encoding for our controlled response shapes.
----------------------------------------------------------------------
local function json_escape_str(s)
	s = tostring(s):gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function json_value(v)
	if type(v) == "boolean" then return v and "true" or "false" end
	if type(v) == "number" then return tostring(v) end
	return json_escape_str(v)
end

local function json_obj(t)
	local parts = {}
	for k, v in pairs(t) do
		parts[#parts + 1] = json_escape_str(k) .. ":" .. json_value(v)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function local_origin(req)
	local headers = req.headers or {}
	local expected = {
		["http://127.0.0.1:" .. SERVER_PORT] = true,
		["http://localhost:" .. SERVER_PORT] = true,
	}
	local host = headers.host
	if host and host ~= "127.0.0.1:" .. SERVER_PORT and host ~= "localhost:" .. SERVER_PORT then
		return false
	end
	local origin = headers.origin
	if origin and not expected[origin] then return false end
	if headers["sec-fetch-site"] == "cross-site" then return false end
	return true
end

local function form_content_type(req)
	local content_type = (req.headers or {})["content-type"] or ""
	return content_type == "" or content_type:lower():match("^application/x%-www%-form%-urlencoded") ~= nil
end

----------------------------------------------------------------------
-- HTTP response writer.
----------------------------------------------------------------------
local STATUS_TEXT = {
	[200] = "OK",
	[303] = "See Other",
	[400] = "Bad Request",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[409] = "Conflict",
	[413] = "Payload Too Large",
	[415] = "Unsupported Media Type",
	[422] = "Unprocessable Entity",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
}

local function send_response(client, status, content_type, body)
	body = body or ""
	local reason = STATUS_TEXT[status] or "OK"
	client:send(string.format("HTTP/1.1 %d %s\r\n", status, reason))
	client:send("Content-Type: " .. content_type .. "\r\n")
	client:send("Content-Length: " .. #body .. "\r\n")
	client:send("Connection: close\r\n")
	client:send("\r\n")
	if #body > 0 then client:send(body) end
end

----------------------------------------------------------------------
-- Request reader.
----------------------------------------------------------------------
local function read_request(client)
	client:settimeout(10)
	local request_line = client:receive("*l")
	if not request_line then return nil end

	local method, target = request_line:match("^(%S+)%s+(%S+)%s+HTTP/%d%.%d$")
	if not method or not target then
		return { bad = true }
	end

	-- Split path and query.
	local path = target:match("^([^?]*)")
	local query = target:match("%?(.*)$")

	-- Headers until a blank line.
	local headers = {}
	while true do
		local line = client:receive("*l")
		if not line or line == "" then break end
		local k, v = line:match("^([^:]+):%s*(.-)%s*$")
		if k then headers[k:lower()] = v end
	end

	-- Body (bounded by Content-Length). The media endpoint accepts larger
	-- uploads; everything else stays under the normal post cap.
	local body
	local cl = tonumber(headers["content-length"])
	if cl then
		if cl < 0 then
			return { method = method, path = path, query = query, bad_length = true }
		end
		local cap = (path == "/media") and MAX_MEDIA_BODY or MAX_BODY
		if cl > cap then
			return { method = method, path = path, query = query, too_large = true }
		end
		body = client:receive(cl)
	end

	return {
		method = method,
		path = path,
		query = query,
		headers = headers,
		body = body,
	}
end

----------------------------------------------------------------------
-- Route handlers.
----------------------------------------------------------------------

-- GET / : render the editor with the post list and optional selected post.
local function handle_index(client, req)
	local entries, _ = catalog.load(POSTS_DIR)

	local posts = {}
	for _, e in ipairs(entries) do
		posts[#posts + 1] = {
			slug  = e.slug,
			title = e.title,
			date  = e.date,
			href  = "/?slug=" .. e.slug,
		}
	end

	-- Selected post (if a slug was requested).
	local selected
	local requested_slug = req.query and parse_urlencoded(req.query).slug
	local saved_flag = req.query and parse_urlencoded(req.query).saved
	if requested_slug and requested_slug ~= "" then
		for _, e in ipairs(entries) do
			if e.slug == requested_slug then
				selected = {
					slug        = e.slug,
					title       = e.title,
					date        = e.date,
					tags_csv    = table.concat(e.tags or {}, ","),
					description = e.description or "",
					-- Public posts live under dist/posts/, but the local editor
					-- is served from the project root.
					body_html   = (e.body_html or ""):gsub('src="%.%./media/', 'src="/media/'),
					status      = (saved_flag and saved_flag ~= "") and "saved" or "loaded",
				}
				break
			end
		end
	end

	-- Media filenames (if easy).
	local media = {}
	local f = io.popen('ls -1 "' .. MEDIA_DIR .. '" 2>/dev/null')
	if f then
		for line in f:lines() do
			local name = trim(line)
			if name ~= "" and not name:match("^%.") then
				media[#media + 1] = { path = MEDIA_DIR .. "/" .. name, label = name }
			end
		end
		f:close()
	end

	local ok, html = pcall(templates.render, TEMPLATE_NAME, {
		posts    = posts,
		selected = selected,
		media    = media,
	})
	if not ok then
		send_response(client, 500, "text/plain; charset=utf-8",
			"template error: " .. tostring(html))
		return
	end
	send_response(client, 200, "text/html; charset=utf-8", html)
end

-- POST /preview : validate and return an HTML fragment for live preview.
local function handle_preview(client, req)
	local form = parse_urlencoded(req.body or "")

	local title       = form.title or ""
	local date        = form.date or ""
	local tags_csv    = form.tags or ""
	local description = form.description or ""
	local body_md     = form.body or ""

	local fm = {
		title       = title,
		date        = date,
		tags        = parse_tags_csv(tags_csv),
		description = description ~= "" and description or nil,
	}
	local err = schema.validate(fm)
	if err then
		send_response(client, 422, "text/plain; charset=utf-8", err)
		return
	end

	local body_html = markdown.to_html(body_md, { media_prefix = "" })

	local fragment = "<article class=\"preview\">\n"
		.. "<h1>" .. templates.escape(title) .. "</h1>\n"
		.. "<p class=\"meta\"><time>" .. templates.escape(date) .. "</time>"
		.. (description ~= "" and " &middot; " .. templates.escape(description) or "")
		.. "</p>\n"
		.. "<div class=\"preview-body\">" .. body_html .. "</div>\n"
		.. "</article>\n"

	send_response(client, 200, "text/html; charset=utf-8", fragment)
end

-- POST /save : validate and persist a post (new or existing), then 303.
local function handle_save(client, req)
	local form = parse_urlencoded(req.body or "")

	local slug_in     = form.slug or ""
	local title       = form.title or ""
	local date        = form.date or ""
	local tags_csv    = form.tags or ""
	local description = form.description or ""
	local body_md     = form.body or ""

	if title:match("[\r\n]") or (description ~= "" and description:match("[\r\n]")) then
		send_response(client, 422, "text/plain; charset=utf-8",
			"title and description must not contain newlines")
		return
	end

	local fm = {
		title       = title,
		date        = date,
		tags        = parse_tags_csv(tags_csv),
		description = description ~= "" and description or nil,
	}
	local err = schema.validate(fm)
	if err then
		send_response(client, 422, "text/plain; charset=utf-8", err)
		return
	end

	local target_path
	local final_slug

	if slug_in and slug_in ~= "" then
		if not slug_in:match(SAFE_TOKEN_PAT) then
			send_response(client, 422, "text/plain; charset=utf-8", "unsafe slug")
			return
		end
		for _, p in ipairs(list_post_files()) do
			if slug_for_file(p) == slug_in then
				target_path = p
				final_slug = slug_in
				break
			end
		end
		if not target_path then
			send_response(client, 422, "text/plain; charset=utf-8",
				"unknown slug: " .. slug_in)
			return
		end
	else
		final_slug = slugify(title)
		if final_slug == "" or not final_slug:match(SAFE_TOKEN_PAT) then
			send_response(client, 422, "text/plain; charset=utf-8",
				"title did not produce a usable slug")
			return
		end
		if not date:match(DATE_PAT) then
			send_response(client, 422, "text/plain; charset=utf-8", "invalid date")
			return
		end
		target_path = string.format("%s/%s-%s.md", POSTS_DIR, date, final_slug)
		if read_file(target_path) then
			send_response(client, 422, "text/plain; charset=utf-8",
				"post already exists: " .. target_path)
			return
		end
	end

	local content = "---\n"
		.. "title: " .. title .. "\n"
		.. "date: " .. date .. "\n"
		.. "tags: " .. table.concat(fm.tags, ", ") .. "\n"
		.. (description ~= "" and "description: " .. description .. "\n" or "")
		.. "---\n\n"
		.. body_md
		.. (body_md:match("\n$") and "" or "\n")
	local ok, werr = write_atomic(target_path, content, "w")
	if not ok then
		send_response(client, 500, "text/plain; charset=utf-8",
			"write failed: " .. tostring(werr))
		return
	end

	local location = "/?slug=" .. final_slug .. "&saved=1"
	local reason = STATUS_TEXT[303]
	client:send(string.format("HTTP/1.1 %d %s\r\n", 303, reason))
	client:send("Location: " .. location .. "\r\n")
	client:send("Content-Type: text/html; charset=utf-8\r\n")
	client:send("Content-Length: 0\r\n")
	client:send("Connection: close\r\n")
	client:send("\r\n")
end

-- POST /media : accept a base64 image (URL-encoded) and store it under
-- media/. Filename is treated as a basename only; the binary is decoded
-- with a stdlib base64 decoder and never written outside media/.
local function handle_media(client, req)
	local form = parse_urlencoded(req.body or "")

	local name = form.name or ""
	local data = form.data or ""
	local mime = form.mime or ""

	-- --- Filename validation -----------------------------------------
	if name == "" then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "missing name" }))
		return
	end

	-- Basename only: reject any path component outright.
	local base = name:match("^([^/\\]+)$")
	if not base then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "invalid filename: path components not allowed: " .. name }))
		return
	end

	-- Safe characters only (no ".." tricks survive the extension check,
	-- and there is no directory separator here anyway).
	if not base:match("^[A-Za-z0-9._-]+$") then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "invalid filename: unsafe characters: " .. name }))
		return
	end

	-- Allowed image extensions only, case-insensitive.
	local ext = base:match("%.(%w+)$")
	local ALLOWED_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true }
	if not ext or not ALLOWED_EXT[ext:lower()] then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "invalid filename: unsupported image extension: " .. name }))
		return
	end

	-- --- Payload validation ------------------------------------------
	-- Strip an optional data URL prefix like "data:image/png;base64,".
	local payload = data
	local prefix = data:match("^data:[^;]*;base64,")
	if prefix then
		payload = data:sub(#prefix + 1)
	end

	local bin, dec_err = base64_decode(payload)
	if not bin then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "invalid base64 data: " .. tostring(dec_err) }))
		return
	end

	-- Optional mime cross-check (informational; we trust the extension).
	if mime ~= "" then
		local expect = {
			[".png"]  = "image/png",
			[".jpg"]  = "image/jpeg",
			[".jpeg"] = "image/jpeg",
			[".gif"]  = "image/gif",
			[".webp"] = "image/webp",
			[".svg"]  = "image/svg+xml",
		}
		if expect["." .. ext:lower()] and mime ~= expect["." .. ext:lower()] then
			send_response(client, 422, "application/json",
				json_obj({ ok = false, error = "mime does not match extension: " .. mime }))
			return
		end
	end

	-- Enforce decoded size (hard 10 MB ceiling).
	if #bin > 10 * 1024 * 1024 then
		send_response(client, 413, "application/json",
			json_obj({ ok = false, error = "decoded image exceeds 10 MB limit" }))
		return
	end
	if not valid_image_bytes(ext, bin) then
		send_response(client, 422, "application/json",
			json_obj({ ok = false, error = "file does not contain a valid " .. ext .. " image" }))
		return
	end

	-- --- Duplicate check (no overwrite) ------------------------------
	local out_path = MEDIA_DIR .. "/" .. base
	if read_file(out_path) then
		send_response(client, 409, "application/json",
			json_obj({ ok = false, error = "file already exists: " .. base }))
		return
	end

	-- --- Write binary data -------------------------------------------
	local ok, werr = write_atomic(out_path, bin, "wb")
	if not ok then
		send_response(client, 500, "application/json",
			json_obj({ ok = false, error = "write failed: " .. tostring(werr) }))
		return
	end

	local rel = MEDIA_DIR .. "/" .. base
	send_response(client, 200, "application/json",
		json_obj({ ok = true, path = rel }))
end

-- Serve a file from a known directory, rejecting traversal and unsafe names.
local function serve_file(client, req, dir, requested)
	-- Only a single safe filename, flat under dir.
	if requested:match("/") or requested:match("\\") or requested:match("%.%.") then
		send_response(client, 400, "text/plain; charset=utf-8", "invalid path")
		return
	end
	if not requested:match("^[%w%.%-_]+$") then
		send_response(client, 400, "text/plain; charset=utf-8", "unsafe name")
		return
	end
	local path = dir .. "/" .. requested
	local data = read_file(path)
	if not data then
		send_response(client, 404, "text/plain; charset=utf-8", "not found")
		return
	end
	local ctype = "application/octet-stream"
	if requested:match("%.css$") then
		ctype = "text/css; charset=utf-8"
	elseif requested:match("%.png$") then
		ctype = "image/png"
	elseif requested:match("%.jpe?g$") then
		ctype = "image/jpeg"
	elseif requested:match("%.gif$") then
		ctype = "image/gif"
	elseif requested:match("%.svg$") then
		ctype = "image/svg+xml"
	elseif requested:match("%.webp$") then
		ctype = "image/webp"
	elseif requested:match("%.md$") then
		ctype = "text/plain; charset=utf-8"
	end
	send_response(client, 200, ctype, data)
end

----------------------------------------------------------------------
-- Routing.
----------------------------------------------------------------------
local function route(client, req)
	if req.bad then
		send_response(client, 400, "text/plain; charset=utf-8", "bad request line")
		return
	end
	if req.too_large then
		send_response(client, 413, "text/plain; charset=utf-8", "request body too large")
		return
	end
	if req.bad_length then
		send_response(client, 400, "text/plain; charset=utf-8", "invalid content length")
		return
	end

	local method = req.method
	local path = req.path or ""

	if method == "GET" then
		if path == "" or path == "/" then
			handle_index(client, req)
			return
		else
			local static_name = path:match("^/static/(.+)$")
			if static_name then
				serve_file(client, req, STATIC_DIR, static_name)
				return
			end
			local media_name = path:match("^/media/(.+)$")
			if media_name then
				serve_file(client, req, MEDIA_DIR, media_name)
				return
			end
		end
		send_response(client, 404, "text/plain; charset=utf-8", "not found")
		return
	elseif method == "POST" then
		if not local_origin(req) then
			send_response(client, 403, "text/plain; charset=utf-8", "editor requests must come from localhost")
			return
		end
		if not form_content_type(req) then
			send_response(client, 415, "text/plain; charset=utf-8",
				"use application/x-www-form-urlencoded")
			return
		end
		if path == "/preview" then
			handle_preview(client, req)
			return
		elseif path == "/save" then
			handle_save(client, req)
			return
		elseif path == "/media" then
			handle_media(client, req)
			return
		end
		send_response(client, 404, "text/plain; charset=utf-8", "not found")
		return
	else
		send_response(client, 405, "text/plain; charset=utf-8", "method not allowed")
		return
	end
end

----------------------------------------------------------------------
-- Server loop.
----------------------------------------------------------------------
function editor.serve(opts)
	opts = opts or {}
	local port = opts.port or 8787
	SERVER_PORT = port

	local socket = require("socket")
	local server, serr = socket.bind("127.0.0.1", port)
	if not server then
		error("editor: failed to bind 127.0.0.1:" .. tostring(port) .. " (" .. tostring(serr) .. ")")
	end
	server:settimeout(0.5)   -- periodic wake so Ctrl-C is honored

	print(string.format("[editor] serving on http://127.0.0.1:%d (Ctrl-C to stop)", port))

	while true do
		local client, err, errcode = server:accept()
		if not client then
			-- "timeout" is our periodic wake-up; anything else ends the loop.
			if err == "timeout" or errcode == "timeout" then
				goto continue
			end
			break
		end

		local ok, perr = pcall(function()
			local req = read_request(client)
			if req then
				route(client, req)
				print(string.format('[editor] %s %s -> handled',
					req.method or "?", req.path or "?"))
			end
		end)
		if not ok then
			pcall(send_response, client, 500, "text/plain; charset=utf-8",
				"internal error: " .. tostring(perr))
			print("[editor] error: " .. tostring(perr))
		end

		pcall(client.close, client)
		::continue::
	end

	pcall(server.close, server)
	print("[editor] stopped")
end

return editor
