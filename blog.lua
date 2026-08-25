#!/usr/bin/env luajit
-- The small command-line face of obj.
--
--   lua blog.lua new "A post title"
--   lua blog.lua build
--   lua blog.lua editor [port]
--   lua blog.lua publish
--   lua blog.lua help

-- Modules under lua/ are required by plain name, matching build.lua.
package.path = "./lua/?.lua;" .. (package.path or "")

local command = arg[1] or "help"

-- True when running on macOS, used to open a browser safely.
local is_macos = false
do
	local p = io.popen("uname -s 2>/dev/null")
	if p then
		local u = p:read("*l")
		p:close()
		is_macos = (u == "Darwin")
	end
end

local function usage()
	print([[obj - a small Lua blog maker

usage:
  lua blog.lua new "A post title"  create a dated Markdown post
  lua blog.lua build                 build dist/
  lua blog.lua editor [port]         open the local writing GUI (default port 8787)
  lua blog.lua publish               build, commit, and push to GitHub
  lua blog.lua help                  show this help]])
end

local function run(cmd)
	local r = { os.execute(cmd) }
	local ok = r[1]
	-- Lua 5.3+: true on success, false/nil on failure.
	-- Lua 5.1: numeric exit status (0 == success).
	if ok == true then
		return
	elseif ok == false or ok == nil then
		io.stderr:write("publish: command failed: " .. cmd .. "\n")
		os.exit(1)
	elseif type(ok) == "number" and ok ~= 0 then
		io.stderr:write("publish: command failed: " .. cmd .. "\n")
		os.exit(1)
	end
end

local function run_editor(port_arg)
	local port = tonumber(port_arg)
	if port_arg and not port then
		io.stderr:write("editor: invalid port: " .. tostring(port_arg) .. "\n")
		os.exit(2)
	end
	port = port or 8787

	-- The editor serves over HTTP, so LuaSocket must be present.
	local socket_ok, socket_err = pcall(require, "socket")
	if not socket_ok then
		io.stderr:write([[
editor needs LuaSocket, which is not installed.

Install it with your package manager:
  brew install luarocks
  luarocks install luasocket

Then run:
  lua blog.lua editor
]])
		os.exit(1)
	end

	local ok, editor = pcall(require, "editor")
	if not ok then
		io.stderr:write("editor: could not load the editor module: " .. tostring(editor) .. "\n")
		os.exit(1)
	end

	print("http://127.0.0.1:" .. port .. "/")

	-- On macOS, `open` launches the browser and returns immediately,
	-- so it is safe and non-blocking. Elsewhere we stay silent.
	if is_macos then
		os.execute("open 'http://127.0.0.1:" .. port .. "/' >/dev/null 2>&1 &")
	end

	editor.serve({ port = port })
end

local function run_publish()
	-- Same build as `lua blog.lua build`.
	dofile("build.lua")

	-- Do not absorb an unrelated staging area into a publish.
	local staged_before = io.popen("git diff --cached --name-only")
	local already_staged = staged_before:read("*a") or ""
	staged_before:close()
	if already_staged:gsub("%s+$", "") ~= "" then
		io.stderr:write("publish: staged changes already exist; clear or commit them first\n")
		os.exit(1)
	end

	-- Stage tracked changes and deletions in project paths, then pick up any
	-- NEW content (posts, media, workflow files) by directory. Directory-level
	-- adds avoid the empty-glob failures that per-extension globs hit when a
	-- category has no files yet, while still not staging arbitrary repo-root
	-- files. Untracked media images are intended to be published.
	run('git add -u -- blog.lua build.lua lua templates static media posts README.md .github/workflows')
	run('git add -A -- posts media .github/workflows')

	-- If nothing was actually staged, there is nothing to publish.
	local h = io.popen("git diff --cached --name-only")
	local staged = h:read("*a") or ""
	h:close()
	if staged:gsub("%s+$", "") == "" then
		print("nothing to publish")
		os.exit(0)
	end

	run('git commit -m "post: publish blog changes"')
	run("git push origin HEAD")
	print("published")
end

local function slugify(title)
	local slug = title:lower()
	slug = slug:gsub("[^%w%s%-_]", "")
	slug = slug:gsub("%s+", "-")
	slug = slug:gsub("%-+", "-")
	slug = slug:gsub("^%-", ""):gsub("-$", "")
	return slug
end

local function write_new(title)
	if not title or title == "" then
		io.stderr:write('new needs a title, e.g. `lua blog.lua new "A small thought"`\n')
		os.exit(2)
	end
	if title:find("%c") then
		io.stderr:write("title cannot contain newlines or other control characters\n")
		os.exit(2)
	end

	local slug = slugify(title)
	if slug == "" then
		io.stderr:write("title did not produce a usable filename\n")
		os.exit(2)
	end

	local date = os.date("%Y-%m-%d")
	local path = "posts/" .. date .. "-" .. slug .. ".md"
	local n = 2
	local existing = io.open(path, "r")
	while existing do
		existing:close()
		path = "posts/" .. date .. "-" .. slug .. "-" .. n .. ".md"
		n = n + 1
		existing = io.open(path, "r")
	end

	local f = assert(io.open(path, "w"))
	f:write("---\n")
	f:write("title: " .. title .. "\n")
	f:write("date: " .. date .. "\n")
	f:write("tags: life\n")
	f:write("---\n\n")
	f:write("Write here.\n")
	f:close()
	print("created " .. path)
end

if command == "new" then
	write_new(table.concat(arg, " ", 2))
elseif command == "build" then
	dofile("build.lua")
elseif command == "editor" then
	run_editor(arg[2])
elseif command == "publish" then
	run_publish()
elseif command == "help" or command == "--help" or command == "-h" then
	usage()
else
	io.stderr:write("unknown command: " .. command .. "\n\n")
	usage()
	os.exit(2)
end
