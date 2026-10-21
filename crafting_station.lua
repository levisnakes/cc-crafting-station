-- Crafting Station has been replaced by Crafter (github.com/levisnakes/cc-craft-dispatch).
-- This file installs crafter.lua in its place and restarts the turtle. Your /config.lua stays.

local API = "https://api.github.com/repos/levisnakes/cc-craft-dispatch/commits/main"
local path = (shell and shell.getRunningProgram()) or "startup.lua"

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
print("Crafting Station -> Crafter")
print("Installing crafter.lua from cc-craft-dispatch...")

local function get(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

for attempt = 1, 10 do
  local sha = get(API, { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  sha = sha and sha:match("^%s*(%x+)%s*$")
  local url = "https://raw.githubusercontent.com/levisnakes/cc-craft-dispatch/" .. (sha or "main") .. "/crafter.lua"
  local src = get(url)
  if src and load(src, "crafter") then
    if fs.exists(path) then
      if fs.exists(path .. ".old") then fs.delete(path .. ".old") end
      fs.copy(path, path .. ".old")
    end
    local f = fs.open(path, "w")
    f.write(src)
    f.close()
    if sha then
      local v = fs.open("/.version_crafter.lua", "w")
      v.write(sha)
      v.close()
    end
    print("Installed. Restarting...")
    sleep(1)
    os.reboot()
  end
  print("Download failed (try " .. attempt .. "), retrying in 5 s...")
  sleep(5)
end
printError("Couldn't download crafter.lua. Install it by hand:")
print("wget https://raw.githubusercontent.com/levisnakes/cc-craft-dispatch/main/crafter.lua startup.lua")
