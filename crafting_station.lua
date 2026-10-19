-- Crafting Station: a crafty turtle that does 3x3 crafting for Create 6 Factory Gauges.
-- Gauges with "Use Mechanical Crafting" send their ingredients to the shared address;
-- the recipe comes with each package. The turtle crafts and sends the results to storage.
-- Build as many stations as you like with the same Frogport address: each one is identical.
--
-- One station:  Crafty Turtle with an input Packager on its front (Frogport with the shared
-- crafting address), an output Packager on its back (its own Frogport), and a Barrel on top of
-- or under the turtle as its buffer.

OUT_ADDRESS = "MB-Storage-In"  -- where finished items (and anything without a recipe) are sent
INPUT_SIDE = "front"           -- the Packager that receives ingredient packages
OUTPUT_SIDE = "back"           -- the Packager that sends the results
QUIET_SECONDS = 1              -- wait this long after the last package, then craft everything at once
STATION_NAME = nil             -- nil = the turtle's label, or "Station <id>"
DISCORD_WEBHOOK = nil          -- Discord webhook URL (in quotes) for "stuck" alerts
DISCORD_MENTION = nil          -- who to ping when stuck, e.g. "<@&ROLE_ID>"
AUTO_UPDATE = true             -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end

-- ============================================================ basics

local VERSION = "1.0.0"
local DIR = "/station"
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local IS_GRID = {}       -- [turtle slot] = position 1..9 in the recipe
for k, s in ipairs(GRID) do IS_GRID[s] = k end

local function now() return os.epoch("utc") / 1000 end
local function stationName()
  return STATION_NAME or os.getComputerLabel() or ("Station " .. os.getComputerID())
end
local function short(name) return (tostring(name):gsub("^[^:]+:", ""):gsub("_", " ")) end

local function readFile(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if data == nil then return default end
  return data
end

local function writeFile(path, data)
  local f = fs.open(path .. ".tmp", "w")
  f.write(textutils.serialize(data))
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".tmp", path)
end

if not fs.exists(DIR) then fs.makeDir(DIR) end

-- jobs[key] = { recipe = { [1..9] = name or false }, crafts = n, since = t, output = name }
local jobs = readFile(DIR .. "/jobs", {})
local stats = readFile(DIR .. "/stats", { total = 0, day = "", today = 0, items = {} })
local function saveJobs() writeFile(DIR .. "/jobs", jobs) end
local function saveStats() writeFile(DIR .. "/stats", stats) end

local logLines = {}
local function log(kind, text)
  table.insert(logLines, 1, { t = now(), kind = kind, text = text })
  while #logLines > 40 do table.remove(logLines) end
end

local state = {
  status = "Starting",       -- what the turtle is doing right now
  problem = nil,             -- setup problem shown in red
  lastArrival = 0,
  paused = false,
  busy = false,
  sendFails = 0,
  lastCraft = nil,           -- { text, t }
  returnAll = false,         -- the "send everything back" button
}

-- ============================================================ peripherals

local inputPackager, outputPackager, buffer, bufferSide

local function findPeripherals()
  inputPackager, outputPackager, buffer, bufferSide = nil, nil, nil, nil
  if peripheral.hasType(INPUT_SIDE, "Create_Packager") then inputPackager = peripheral.wrap(INPUT_SIDE) end
  if peripheral.hasType(OUTPUT_SIDE, "Create_Packager") then outputPackager = peripheral.wrap(OUTPUT_SIDE) end
  for _, side in ipairs({ "top", "bottom" }) do
    if not buffer and peripheral.hasType(side, "inventory") and not peripheral.hasType(side, "Create_Packager") then
      buffer, bufferSide = peripheral.wrap(side), side
    end
  end
end

local function setupProblem()
  if not turtle then return "This program needs a turtle" end
  if not turtle.craft then return "No crafting table: use a Crafty Turtle" end
  if not inputPackager then return "No input Packager on the turtle's " .. INPUT_SIDE end
  if not outputPackager then return "No output Packager on the turtle's " .. OUTPUT_SIDE end
  if not buffer then return "No Barrel on top of or under the turtle" end
  return nil
end

-- ============================================================ inventory helpers

local maxStackCache = {}

local function turtleSlots()
  local slots = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then slots[i] = d end
  end
  return slots
end

local function turtleEmpty()
  for i = 1, 16 do if turtle.getItemCount(i) > 0 then return false end end
  return true
end

local function freeSlots()
  local n = 0
  for i = 1, 16 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
  return n
end

local function maxStack(name)
  if maxStackCache[name] then return maxStackCache[name] end
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == name then
      local full = turtle.getItemDetail(i, true)
      if full and full.maxCount then maxStackCache[name] = full.maxCount return full.maxCount end
    end
  end
  local ok, list = pcall(buffer.list)
  if ok and list then
    for slot, it in pairs(list) do
      if it.name == name then
        local okD, d = pcall(buffer.getItemDetail, slot)
        if okD and d and d.maxCount then maxStackCache[name] = d.maxCount return d.maxCount end
      end
    end
  end
  return 64
end

local function bufferCounts()
  local counts = {}
  local ok, list = pcall(buffer.list)
  if ok and list then
    for _, it in pairs(list) do counts[it.name] = (counts[it.name] or 0) + it.count end
  end
  return counts
end

local function dropToBuffer(count)
  if bufferSide == "top" then return turtle.dropUp(count) end
  return turtle.dropDown(count)
end

local function suckFromBuffer(count)
  if bufferSide == "top" then return turtle.suckUp(count) end
  return turtle.suckDown(count)
end

-- Put everything the turtle holds into the buffer. Returns false if the buffer is full.
local function parkAll(keep)
  local ok = true
  for i = 1, 16 do
    if not (keep and keep[i]) and turtle.getItemCount(i) > 0 then
      turtle.select(i)
      if not dropToBuffer() then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

-- Pull `count` of `name` from the buffer into the selected turtle slot.
-- A suck takes from the first filled buffer slot, so that item is moved to the front first.
local function fetch(name, count)
  local got = 0
  for _ = 1, 8 do
    if got >= count then break end
    local ok, list = pcall(buffer.list)
    if not ok or not list then break end
    local from
    for slot, it in pairs(list) do
      if it.name == name and (not from or slot < from) then from = slot end
    end
    if not from then break end
    if from ~= 1 then
      if list[1] then
        local size = buffer.size()
        local empty
        for s = size, 2, -1 do if not list[s] then empty = s break end end
        if not empty then break end
        pcall(buffer.pushItems, bufferSide, 1, 64, empty)
      end
      pcall(buffer.pushItems, bufferSide, from, count - got, 1)
    end
    local before = turtle.getItemCount()
    suckFromBuffer(count - got)
    local gained = turtle.getItemCount() - before
    if gained <= 0 then break end
    got = got + gained
  end
  return got
end

-- ============================================================ jobs

local function recipeKey(recipe)
  local parts = {}
  for i = 1, 9 do parts[i] = recipe[i] or "-" end
  return table.concat(parts, ",")
end

local function perCraft(recipe)
  local need = {}
  for i = 1, 9 do
    local name = recipe[i]
    if name then need[name] = (need[name] or 0) + 1 end
  end
  return need
end

local function jobLabel(job)
  return job.output and short(job.output) or ("recipe with " .. short(next(perCraft(job.recipe)) or "?"))
end

local function onPackage(pkg)
  state.lastArrival = now()
  local okO, order = pcall(pkg.getOrderData)
  local crafts
  if okO and type(order) == "table" then
    local okC, c = pcall(order.getCrafts)
    if okC and type(c) == "table" and next(c) then crafts = c end
  end
  if not crafts then
    log("warn", "Package without a recipe: sending it back. Turn on 'Use Mechanical Crafting' on its gauge.")
    state.looseItems = true
    return
  end
  for _, c in pairs(crafts) do
    local recipe = {}
    for i = 1, 9 do
      local name = c.recipe and c.recipe[i]
      recipe[i] = (type(name) == "string" and name ~= "minecraft:air") and name or false
    end
    local key = recipeKey(recipe)
    local job = jobs[key]
    if not job then
      job = { recipe = recipe, crafts = 0, since = now() }
      jobs[key] = job
    end
    job.crafts = job.crafts + (tonumber(c.count) or 1)
    job.waitingSince = job.waitingSince or now()
  end
  saveJobs()
end

-- ============================================================ sending

-- Package everything in the turtle and send it to OUT_ADDRESS. With `keep` (slot -> count),
-- anything beyond those counts arrived in the meantime and goes to the buffer first.
local function sendTurtle(keep)
  pcall(outputPackager.setAddress, OUT_ADDRESS)
  for _ = 1, 40 do
    if turtleEmpty() then
      state.sendFails = 0
      return true
    end
    if keep then
      for i = 1, 16 do
        local extra = turtle.getItemCount(i) - (keep[i] or 0)
        if extra > 0 then
          turtle.select(i)
          dropToBuffer(extra)
        end
      end
      turtle.select(1)
    end
    local ok, made = pcall(outputPackager.makePackage)
    if not (ok and made) then sleep(0.5) end
  end
  state.sendFails = state.sendFails + 1
  log("error", "Couldn't send items to " .. OUT_ADDRESS .. " (Packager busy or its Frogport full)")
  return false
end

-- ============================================================ crafting

local function recordCraft(job, results)
  local total, mainName, mainCount = 0, nil, 0
  for name, n in pairs(results) do
    total = total + n
    if n > mainCount then mainName, mainCount = name, n end
  end
  if mainName then job.output = mainName end
  local day = os.date("!%Y-%m-%d")
  if stats.day ~= day then stats.day, stats.today = day, 0 end
  stats.today = stats.today + mainCount
  stats.total = stats.total + mainCount
  if mainName then stats.items[mainName] = (stats.items[mainName] or 0) + mainCount end
  saveStats()
  state.lastCraft = { text = mainCount .. "x " .. short(mainName or "?"), t = now() }
  log("craft", "Crafted " .. mainCount .. "x " .. short(mainName or "?"))
end

-- Craft up to `n` crafts of one job. Returns the number of crafts done.
local function craftBatch(job, n)
  -- 1. empty the turtle into the buffer, then pull each grid slot's items in place
  if not parkAll() then
    state.problem = "Barrel is full"
    return 0
  end
  for i = 1, 9 do
    local name = job.recipe[i]
    if name then
      turtle.select(GRID[i])
      local have = turtle.getItemCount()
      if have < n then fetch(name, n - have) end
    end
  end
  turtle.select(1)

  -- 2. every grid slot needs the same count; anything else (a package that just arrived) goes back
  local crafts = n
  for i = 1, 9 do
    if job.recipe[i] then
      local d = turtle.getItemDetail(GRID[i])
      if not d or d.name ~= job.recipe[i] then crafts = 0
      else crafts = math.min(crafts, d.count) end
    end
  end
  if crafts <= 0 then
    parkAll()
    return 0
  end
  for i = 1, 9 do
    if job.recipe[i] then
      local extra = turtle.getItemCount(GRID[i]) - crafts
      if extra > 0 then turtle.select(GRID[i]) dropToBuffer(extra) end
    end
  end
  -- 3. craft exactly `crafts` in one go (a single turtle step, so nothing can land mid-craft);
  -- a package arriving just before it is moved out of the way and the craft retried
  local done = 0
  for _ = 1, 3 do
    for i = 1, 16 do
      local wanted = IS_GRID[i] and job.recipe[IS_GRID[i]]
      if not wanted and turtle.getItemCount(i) > 0 then
        turtle.select(i)
        dropToBuffer()
      end
    end
    turtle.select(4)
    if turtle.craft(crafts) then done = crafts break end
  end
  turtle.select(1)
  if done <= 0 then
    parkAll()
    return 0
  end

  -- 4. read the results straight away (reading doesn't take a tick), then move everything
  -- else, leftover ingredients and anything that arrives from now on, into the buffer
  local keep, results = {}, {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d and not (IS_GRID[i] and job.recipe[IS_GRID[i]] == d.name) then
      keep[i] = d.count
      results[d.name] = (results[d.name] or 0) + d.count
    end
  end
  for i = 1, 16 do
    local extra = turtle.getItemCount(i) - (keep[i] or 0)
    if extra > 0 then
      turtle.select(i)
      dropToBuffer(extra)
    end
  end
  turtle.select(1)
  recordCraft(job, results)
  sendTurtle(keep)
  return done
end

-- How many crafts of a job the buffer + turtle can cover right now.
local function available(job, counts)
  local can = job.crafts
  for name, per in pairs(perCraft(job.recipe)) do
    can = math.min(can, math.floor((counts[name] or 0) / per))
  end
  return can
end

local function reserve(counts, job, crafts)
  for name, per in pairs(perCraft(job.recipe)) do
    counts[name] = (counts[name] or 0) - per * crafts
  end
end

-- Send everything not needed by a waiting job back to storage.
local function returnLeftovers(all)
  if not parkAll() then return end
  local counts = bufferCounts()
  if not all then
    for _, job in pairs(jobs) do reserve(counts, job, job.crafts) end
  end
  local any = false
  for name, n in pairs(counts) do
    while n > 0 do
      local slot
      for i = 1, 16 do if turtle.getItemCount(i) == 0 then slot = i break end end
      if not slot then
        sendTurtle()
        slot = 1
      end
      turtle.select(slot)
      local got = fetch(name, math.min(n, maxStack(name)))
      if got <= 0 then break end
      n = n - got
      any = true
    end
  end
  turtle.select(1)
  if any and not turtleEmpty() then
    log("info", "Sent leftover items back to " .. OUT_ADDRESS)
    sendTurtle()
  end
end

local function work()
  state.busy = true
  if not parkAll() then state.problem = "Barrel is full" end
  local counts = bufferCounts()
  local keys = {}
  for key in pairs(jobs) do table.insert(keys, key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local job = jobs[key]
    local can = available(job, counts)
    while can > 0 do
      local limit = 64
      for name in pairs(perCraft(job.recipe)) do limit = math.min(limit, maxStack(name)) end
      local n = math.min(can, limit)
      state.status = "Crafting " .. n .. "x " .. jobLabel(job)
      local done = craftBatch(job, n)
      if done <= 0 then break end
      reserve(counts, job, done)
      job.crafts = job.crafts - done
      can = can - done
      job.waitingSince = now()
    end
    if job.crafts <= 0 then
      jobs[key] = nil
    elseif can <= 0 and now() - state.lastArrival > 60 and now() - (job.waitingSince or now()) > 60 then
      -- its ingredients never came (or went back to storage): drop it, the gauge orders again
      log("warn", "Gave up on " .. job.crafts .. "x " .. jobLabel(job) .. ": ingredients missing")
      jobs[key] = nil
    end
  end
  saveJobs()
  if state.returnAll then
    state.returnAll = false
    jobs = {}
    saveJobs()
    returnLeftovers(true)
    log("info", "Sent everything back to " .. OUT_ADDRESS)
  elseif next(jobs) == nil then
    returnLeftovers(false)
  end
  state.looseItems = false
  state.busy = false
end

-- ============================================================ loops

local function eventLoop()
  while true do
    local e = { os.pullEvent() }
    if e[1] == "package_received" then
      for i = 2, #e do
        if type(e[i]) == "table" then pcall(onPackage, e[i]) break end
      end
    elseif e[1] == "peripheral" or e[1] == "peripheral_detach" then
      findPeripherals()
    end
  end
end

local function workLoop()
  while true do
    state.problem = setupProblem()
    local pending = next(jobs) ~= nil or state.looseItems or state.returnAll
    if state.problem then
      state.status = "Setup needed"
    elseif state.paused then
      state.status = "Paused"
    elseif pending and (now() - state.lastArrival >= QUIET_SECONDS or freeSlots() <= 4 or state.returnAll) then
      local ok, err = pcall(work)
      state.busy = false
      if not ok then log("error", "Error: " .. tostring(err)) end
    elseif pending then
      state.status = "Receiving..."
    elseif not turtleEmpty() and now() - state.lastArrival > 5 then
      -- items with no job (e.g. after a restart): send them home
      pcall(work)
      state.busy = false
    else
      state.status = "Ready"
    end
    sleep(0.25)
  end
end

-- ============================================================ stuck alerts

local alerts = { queue = {}, open = {}, error = nil }

local function alertEmbed(title, what, fix, color, ping)
  local fields = { { name = "What happened", value = what } }
  if fix then table.insert(fields, { name = "What to do", value = fix }) end
  local ok, body = pcall(textutils.serializeJSON, {
    username = "Crafting Station",
    content = (ping and DISCORD_MENTION) or "",
    allowed_mentions = { parse = { "roles", "users", "everyone" } },
    embeds = { { title = title, color = color, fields = fields, footer = { text = stationName() .. "  " .. os.date("!%Y-%m-%d %H:%M UTC") } } },
  }, { unicode_strings = true })
  if ok and DISCORD_WEBHOOK and DISCORD_WEBHOOK ~= "" and http then table.insert(alerts.queue, body) end
end

local function problemCheck(key, active, delay, title, what, fix)
  local p = alerts.open[key]
  if active then
    if not p then
      p = { since = now(), sent = false }
      alerts.open[key] = p
    end
    if not p.sent and now() - p.since >= delay then
      p.sent = true
      alertEmbed("STUCK: " .. title, what, fix, 15158332, true)
      log("error", "Alert sent: " .. title)
    end
  elseif p then
    if p.sent then alertEmbed("Fixed: " .. title, "Working again.", nil, 3066993, false) end
    alerts.open[key] = nil
  end
end

local function oldestJob()
  local oldest
  for _, job in pairs(jobs) do
    if not oldest or (job.waitingSince or now()) < oldest then oldest = job.waitingSince or now() end
  end
  return oldest
end

local function alertLoop()
  local lastCheck = 0
  while true do
    if now() - lastCheck >= 10 then
      lastCheck = now()
      local name = "**" .. stationName() .. "**"
      problemCheck("setup", state.problem ~= nil and state.problem ~= "Barrel is full", 60, "Crafting station not set up",
        name .. ": " .. tostring(state.problem), "Check the turtle's input and output Packagers, Barrel and crafting table, then restart the turtle.")
      problemCheck("full", state.problem == "Barrel is full", 60, "Crafting station buffer full",
        name .. "'s Barrel is full, so it can't sort ingredients.", "Empty the Barrel into storage, or press S on the turtle to send everything back.")
      problemCheck("send", state.sendFails >= 3, 0, "Crafting station can't send results",
        name .. " can't send to **" .. OUT_ADDRESS .. "**.", "Check the Frogport on the output Packager (" .. OUTPUT_SIDE .. " of the turtle) is connected, and that the address exists.")
      local oldest = oldestJob()
      problemCheck("waiting", oldest ~= nil and now() - oldest > 180, 0, "Crafting station waiting on ingredients",
        name .. " has had an order for 3+ minutes but not all of its ingredients arrived.", "Press S on the turtle to send the items back; the gauge will order again.")
    end
    local body = table.remove(alerts.queue, 1)
    if body then
      local ok, res, err = pcall(http.post, DISCORD_WEBHOOK, body, { ["Content-Type"] = "application/json" })
      if ok and res then res.close() alerts.error = nil else alerts.error = tostring(err or res) end
      sleep(2)
    else
      sleep(1)
    end
  end
end

-- ============================================================ console UI

local page = "home"
local buttons = {}

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if bg then term.setBackgroundColor(bg) end
  if fg then term.setTextColor(fg) end
  term.write(s)
end

local function button(x, y, label, fg, bg, action)
  put(x, y, label, fg, bg)
  table.insert(buttons, { x1 = x, x2 = x + #label - 1, y = y, action = action })
end

local function fit(s, w)
  s = tostring(s)
  if #s > w then return s:sub(1, w - 1) .. "." end
  return s
end

local function ago(t)
  local s = math.floor(now() - t)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

local function drawHome(w, h)
  local y = 3
  local status, color = state.status, colors.lime
  if state.problem then status, color = state.problem, colors.red
  elseif state.paused then color = colors.orange
  elseif state.busy or status:find("^Crafting") then color = colors.yellow end
  put(2, y, fit(status, w - 2), color, colors.black)
  y = y + 2

  put(2, y, "Orders", colors.lightGray)
  y = y + 1
  local shown = 0
  for _, job in pairs(jobs) do
    if shown < 3 then
      put(3, y, fit(job.crafts .. "x " .. jobLabel(job), w - 3), colors.white)
      y = y + 1
    end
    shown = shown + 1
  end
  if shown == 0 then put(3, y, "none, waiting for gauges", colors.gray) y = y + 1 end
  if shown > 3 then put(3, y, "+" .. (shown - 3) .. " more", colors.gray) y = y + 1 end
  y = y + 1

  put(2, y, "Today ", colors.lightGray)
  put(8, y, tostring(stats.today), colors.white)
  put(16, y, "All time ", colors.lightGray)
  put(25, y, tostring(stats.total), colors.white)
  y = y + 1
  if state.lastCraft then
    put(2, y, fit("Last: " .. state.lastCraft.text .. ", " .. ago(state.lastCraft.t), w - 2), colors.lightGray)
  end
end

local function drawSetup(w, h)
  local y = 3
  local function row(label, ok, value)
    put(2, y, ok and "\7" or "x", ok and colors.lime or colors.red, colors.black)
    put(4, y, label, colors.lightGray)
    put(16, y, fit(value, w - 16), ok and colors.white or colors.red)
    y = y + 1
  end
  row("Crafting", turtle and turtle.craft ~= nil, (turtle and turtle.craft) and "crafting table fitted" or "use a Crafty Turtle")
  row("Input", inputPackager ~= nil, inputPackager and ("Packager " .. INPUT_SIDE) or ("Packager on the " .. INPUT_SIDE))
  row("Output", outputPackager ~= nil, outputPackager and ("Packager " .. OUTPUT_SIDE) or ("Packager on the " .. OUTPUT_SIDE))
  row("Buffer", buffer ~= nil, buffer and ("barrel " .. bufferSide) or "barrel on top or under")
  row("Sends to", true, OUT_ADDRESS)
  row("Discord", DISCORD_WEBHOOK ~= nil, DISCORD_WEBHOOK and (alerts.error and "error" or "stuck alerts on") or "off")
  row("Name", true, stationName())
  y = y + 1
  put(2, y, fit("Input Frogport: the shared crafting", w - 2), colors.gray)
  put(2, y + 1, fit("address all your gauges send to.", w - 2), colors.gray)
end

local function drawLog(w, h)
  local y = 3
  for _, l in ipairs(logLines) do
    if y > h - 2 then break end
    local c = l.kind == "error" and colors.red or l.kind == "warn" and colors.orange or l.kind == "craft" and colors.lime or colors.lightGray
    put(2, y, fit(l.text, w - 2), c, colors.black)
    y = y + 1
  end
  if #logLines == 0 then put(2, y, "nothing yet", colors.gray, colors.black) end
end

local function draw()
  local w, h = term.getSize()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()
  put(1, 1, string.rep(" ", w), colors.white, colors.blue)
  put(2, 1, fit("CRAFTING STATION  " .. stationName(), w - 8), colors.white, colors.blue)
  put(w - #VERSION, 1, VERSION, colors.lightBlue, colors.blue)
  local tabs = { { "home", "Status" }, { "setup", "Setup" }, { "log", "Log" } }
  local x = 1
  put(1, 2, string.rep(" ", w), colors.white, colors.gray)
  for _, t in ipairs(tabs) do
    local on = page == t[1]
    local label = " " .. t[2] .. " "
    button(x, 2, label, on and colors.black or colors.white, on and colors.white or colors.gray, function() page = t[1] end)
    x = x + #label
  end
  term.setBackgroundColor(colors.black)
  if page == "setup" then drawSetup(w, h)
  elseif page == "log" then drawLog(w, h)
  else drawHome(w, h) end

  put(1, h, string.rep(" ", w), colors.white, colors.gray)
  button(1, h, " Send all back ", colors.white, colors.red, function()
    state.returnAll = true
    log("info", "Sending everything back to " .. OUT_ADDRESS)
  end)
  button(17, h, state.paused and " Resume " or " Pause ", colors.white, colors.gray, function()
    state.paused = not state.paused
    log("info", state.paused and "Paused" or "Resumed")
  end)
  term.setBackgroundColor(colors.black)
end

local function uiLoop()
  local timer = os.startTimer(0)
  while true do
    local e = { os.pullEvent() }
    if e[1] == "timer" and e[2] == timer then
      draw()
      timer = os.startTimer(0.5)
    elseif e[1] == "mouse_click" then
      for _, b in ipairs(buttons) do
        if e[4] == b.y and e[3] >= b.x1 and e[3] <= b.x2 then b.action() break end
      end
      draw()
    elseif e[1] == "key" then
      if e[2] == keys.one then page = "home"
      elseif e[2] == keys.two then page = "setup"
      elseif e[2] == keys.three then page = "log"
      elseif e[2] == keys.s then
        state.returnAll = true
        log("info", "Sending everything back to " .. OUT_ADDRESS)
      elseif e[2] == keys.p then
        state.paused = not state.paused
        log("info", state.paused and "Paused" or "Resumed")
      end
      draw()
    end
  end
end

-- ============================================================ start

findPeripherals()
if outputPackager then pcall(outputPackager.setAddress, OUT_ADDRESS) end
log("info", "Started " .. stationName() .. " v" .. VERSION)

local function readyToUpdate()
  return not state.busy and next(jobs) == nil
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-crafting-station"
local UPDATE_FILE = "crafting_station.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

bootUpdate()
parallel.waitForAny(eventLoop, workLoop, alertLoop, uiLoop, updateLoop)
