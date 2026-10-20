-- Crafting Station: a crafty turtle that does 3x3 crafting for Create 6 Factory Gauges.
-- Gauges with "Use Mechanical Crafting" (or Factory Controller's "Use Custom Arrangement", laid
-- out like a crafting table) send their ingredients to the shared address; the recipe comes with
-- each package. The turtle crafts and sends the results to storage.
-- Build as many stations as you like with the same Frogport address: each one is identical.
--
-- One station:  Crafty Turtle with its input Frogport on its front (standing on the input
-- Packager, which is attached to the Barrel under the turtle), and an output Packager on its back
-- (with its own Frogport). The turtle switches its Frogport between the shared address (empty,
-- taking orders) and a busy address, so several stations share the work.
-- Older layout, still supported: the input Packager itself on the front, unpacking into the turtle.

OUT_ADDRESS = "MB-Storage-In"  -- where finished items (and anything without a recipe) are sent
CRAFT_ADDRESS = "MB-Crafting-In"  -- the shared address all crafting gauges send to
BUSY_ADDRESS = nil             -- the input Frogport's address while busy; nil = CRAFT_ADDRESS .. "-Busy"
INPUT_SIDE = "front"           -- the input Frogport (or, older layout, the input Packager); also takes a
                               -- network name like "Create_Frogport_3". Not found: it pairs by itself
                               -- with the network Frogport whose packages land in its barrel.
OUTPUT_SIDE = "back"           -- the Packager that sends the results
TAKE_TURNS = false             -- false: every station keeps CRAFT_ADDRESS and Create spreads the load (a busy
                               -- station's Frogport fills up and the chain moves on). true: one station takes
                               -- orders at a time (slower: the chain needs ~5 s to notice address changes)
MAX_QUEUE = 2                  -- packages a station keeps waiting in its Frogport; past that it goes busy and
                               -- the extra ones go back onto the chain to other stations
QUIET_SECONDS = 1              -- wait this long after the last package, then craft everything at once
STATION_NAME = nil             -- nil = the turtle's label, or "Station <id>"
DISCORD_WEBHOOK = nil          -- Discord webhook URL (in quotes) for "stuck" alerts
DISCORD_MENTION = nil          -- who to ping when stuck, e.g. "<@&ROLE_ID>"
AUTO_UPDATE = true             -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
-- /station.lua is this turtle's own settings (loaded after config.lua), e.g.
--   INPUT_SIDE = "Create_Frogport_3"
for _, path in ipairs({ "/config.lua", "/station.lua" }) do
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError(path .. ": " .. tostring(runErr)) sleep(3) end
    else
      printError(path .. ": " .. tostring(err))
      sleep(3)
    end
  end
end

-- ============================================================ basics

local VERSION = "1.4.0"
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
-- /station/log.txt gets everything (the screen's log plus the detailed "dbg" lines); the
-- "Upload log" button puts it on Pastebin.
local LOG_PATH = DIR .. "/log.txt"
local function writeLogLine(text)
  pcall(function()
    if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > 150000 then
      if fs.exists(LOG_PATH .. ".old") then fs.delete(LOG_PATH .. ".old") end
      fs.move(LOG_PATH, LOG_PATH .. ".old")
    end
    local ms = os.epoch("utc") % 1000
    local f = fs.open(LOG_PATH, "a")
    f.writeLine(os.date("!%H:%M:%S") .. string.format(".%03d ", ms) .. text)
    f.close()
  end)
end

local function log(kind, text)
  table.insert(logLines, 1, { t = now(), kind = kind, text = text })
  while #logLines > 40 do table.remove(logLines) end
  writeLogLine("[" .. kind .. "] " .. text)
end

local function dbg(text) writeLogLine("  " .. text) end

-- "64 oak_planks, 8 stick"
local function fmtCounts(counts)
  local parts = {}
  for name, n in pairs(counts or {}) do parts[#parts + 1] = n .. " " .. tostring(name):gsub("^minecraft:", "") end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "nothing"
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

local inputPackager, inputFrogport, inputName, outputPackager, buffer, bufferSide
local pairing = { candidates = {} }  -- network Frogport packages seen while unpaired

local function findPeripherals()
  inputPackager, inputFrogport, inputName, outputPackager, buffer, bufferSide = nil, nil, nil, nil, nil, nil
  -- a Frogport touching the turtle's front always wins: a network name in station.lua may be
  -- stale and belong to another station's Frogport by now
  for _, side in ipairs({ "front", INPUT_SIDE }) do
    if not inputName and peripheral.hasType(side, "Create_Packager") and side ~= OUTPUT_SIDE then
      inputPackager, inputName = peripheral.wrap(side), side
    elseif not inputName and peripheral.hasType(side, "Create_Frogport") then
      inputFrogport, inputName = peripheral.wrap(side), side
    end
  end
  if not inputName then
    local paired = readFile(DIR .. "/input", nil)
    if type(paired) == "string" and peripheral.hasType(paired, "Create_Frogport") then
      inputFrogport, inputName = peripheral.wrap(paired), paired
    end
  end
  if peripheral.hasType(OUTPUT_SIDE, "Create_Packager") then outputPackager = peripheral.wrap(OUTPUT_SIDE) end
  for _, side in ipairs({ "top", "bottom" }) do
    if not buffer and peripheral.hasType(side, "inventory") and not peripheral.hasType(side, "Create_Packager") then
      buffer, bufferSide = peripheral.wrap(side), side
    end
  end
end

local function networkFrogports()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "Create_Frogport") then table.insert(out, name) end
  end
  return out
end

local function setupProblem()
  if not turtle then return "This program needs a turtle" end
  if not turtle.craft then return "No crafting table: use a Crafty Turtle" end
  state.pairing = not inputPackager and not inputFrogport and #networkFrogports() > 0
  if not inputPackager and not inputFrogport and not state.pairing then
    return "No input Frogport on the turtle's " .. INPUT_SIDE .. " or its network"
  end
  if not outputPackager then return "No output Packager on the turtle's " .. OUTPUT_SIDE end
  if state.bounced then return "Output Frogport sends packages back: give it an unused address" end
  if not buffer then return "No Barrel on top of or under the turtle" end
  return nil
end

-- Frogport layout: the station takes orders on CRAFT_ADDRESS only while it's empty, so the chain
-- carries the next packages on to a free station.
local function busyAddress() return BUSY_ADDRESS or (CRAFT_ADDRESS .. "-Busy") end

local function setOpen(open, why)
  if not inputFrogport then return end
  local want = open and CRAFT_ADDRESS or busyAddress()
  if state.advertised ~= want then
    local ok, err = pcall(inputFrogport.setAddress, want)
    if ok then
      state.advertised = want
      state.lastBeat = 0  -- announce the change on the next loop
    end
    dbg("Frogport " .. tostring(inputName) .. " -> " .. want .. (why and (" (" .. why .. ")") or "")
      .. (ok and "" or (" FAILED: " .. tostring(err))))
  end
end

-- Running stations announce themselves over rednet every 2 s and whenever they open or close:
-- peers[computer id] = { t = last heard, open = taking orders }. Frogport names don't matter.
-- Only their Frogports count; a Frogport whose turtle isn't running is ignored.
local HEARTBEAT = "crafting-station"
local peers = {}

local function openModems()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") and not rednet.isOpen(name) then pcall(rednet.open, name) end
  end
end

-- Another running station's input Frogport that is taking orders right now.
local MY_ID = os.getComputerID()

-- The lowest computer id among other running stations that are taking orders right now
-- (or, with idleToo, that are idle and could take them).
local function openStation(idleToo)
  local found
  for id, p in pairs(peers) do
    if id ~= MY_ID and (p.open or (idleToo and p.idle)) and now() - p.t < 6 and (not found or id < found) then found = id end
  end
  return found
end

local function heartbeat()
  if not inputFrogport then return end
  state.lastBeat = now()
  pcall(rednet.broadcast, { id = MY_ID, open = state.advertised == CRAFT_ADDRESS, idle = state.idle == true, name = stationName() }, HEARTBEAT)
end

local function frogportEmpty()
  if not inputFrogport then return true end
  local ok, list = pcall(inputFrogport.list)
  return not ok or type(list) ~= "table" or next(list) == nil
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

local function turtleCounts()
  local counts = {}
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then counts[d.name] = (counts[d.name] or 0) + d.count end
  end
  return counts
end

local function snapshot()
  local frog = "?"
  if inputFrogport then
    local ok, l = pcall(inputFrogport.list)
    local n = 0
    if ok and type(l) == "table" then for _ in pairs(l) do n = n + 1 end end
    frog = n .. " pkg"
  end
  return "turtle [" .. fmtCounts(turtleCounts()) .. "] barrel [" .. fmtCounts(buffer and bufferCounts() or {})
    .. "] frogport [" .. frog .. "]"
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

-- Pull `count` of `name` from the buffer into turtle slot `target`.
-- A suck takes the first filled barrel slot, so each one lands in an empty spare (non-grid) slot:
-- the wanted item moves on to `target`, anything else stays in the spare slot out of the way
-- (the caller parks it again). Moving the item to the barrel's front first is only a shortcut.
local SPARE = { 4, 8, 12, 13, 14, 15, 16 }

local function fetch(name, count, target)
  local got = 0
  local result = {}
  for _ = 1, 12 do
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
        local empty
        for s = buffer.size(), 2, -1 do if not list[s] then empty = s break end end
        if empty then pcall(buffer.pushItems, bufferSide, 1, 64, empty) end
      end
      pcall(buffer.pushItems, bufferSide, from, 64, 1)
    end
    local spare
    for _, s in ipairs(SPARE) do if turtle.getItemCount(s) == 0 then spare = s break end end
    if not spare then break end
    turtle.select(spare)
    if not suckFromBuffer(64) then break end
    local d = turtle.getItemDetail(spare)
    if d and d.name ~= name then dbg("    fetch " .. name .. ": dug out " .. d.count .. " " .. d.name .. " first") end
    if d and d.name == name then
      local before = turtle.getItemCount(target)
      turtle.transferTo(target, count - got)
      local moved = turtle.getItemCount(target) - before
      got = got + moved
      if turtle.getItemCount(spare) > 0 then dropToBuffer() end
      if moved <= 0 then break end
    end
  end
  dbg("    fetch " .. count .. " " .. name .. " -> slot " .. target .. ": got " .. got)
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

-- Whole crafts covered by the ingredients that have arrived for a job.
local function craftsFromReceived(job)
  local n
  for name, per in pairs(perCraft(job.recipe)) do
    local k = math.floor(((job.received or {})[name] or 0) / per)
    n = n and math.min(n, k) or k
  end
  return n or 0
end

local function jobLabel(job)
  return job.output and short(job.output) or ("recipe with " .. short(next(perCraft(job.recipe)) or "?"))
end

-- An order too big for one package arrives as several. orders[id] = { need = items in the whole
-- order, got = items caught here so far, t = first seen }; the station keeps taking packages
-- until every order it started is complete, so an order is never split between stations.
local ORDER_WAIT_SECONDS = 30
local orders = {}
-- Packages the Frogport caught whose items aren't in the barrel yet. While any are on their way
-- down, the Frogport's address must not change: a package that lands in a Frogport whose address
-- no longer matches is sent straight back out onto the chain.
local landing = {}
local LAND_SECONDS = 2   -- a caught package that hasn't been sent away by then has gone down to the barrel
local recentlyLanded = {} -- kept a while, in case the Frogport still sends one of them away

local function trackOrder(order, pkg)
  local okI, id = pcall(order.getOrderID)
  if not okI or id == nil then return end
  local need = 0
  local okL, list = pcall(order.list)
  if okL and type(list) == "table" then
    for _, it in pairs(list) do
      if type(it) == "table" and it.name and it.name ~= "minecraft:air"
        and it.name ~= "createfactorycontroller:arrangement_marker" then
        need = need + (it.count or 0)
      end
    end
  end
  local got = 0
  local okP, items = pcall(pkg.list)
  if okP and type(items) == "table" then
    for _, it in pairs(items) do if type(it) == "table" then got = got + (it.count or 0) end end
  end
  local o = orders[id] or { need = 0, got = 0, t = now() }
  if need > o.need then o.need = need end
  o.got = o.got + got
  orders[id] = o
  dbg("order " .. tostring(id) .. ": " .. o.got .. " of " .. o.need .. " items here")
end

-- True while an order this station started still has packages on the way.
local function waitingForRest()
  for id, o in pairs(orders) do
    if o.got >= o.need or now() - o.t > ORDER_WAIT_SECONDS then orders[id] = nil end
  end
  return next(orders) ~= nil
end

local function onPackage(pkg)
  state.lastArrival = now()
  local okO, order = pcall(pkg.getOrderData)
  do
    local items = {}
    local okL, list = pcall(pkg.list)
    if okL and type(list) == "table" then
      for _, it in pairs(list) do
        if type(it) == "table" and it.name then items[it.name] = (items[it.name] or 0) + (it.count or 0) end
      end
    end
    local info = "no order data"
    if okO and type(order) == "table" then
      local okI, id = pcall(order.getOrderID)
      local okF, final = pcall(order.isFinal)
      local okK, link = pcall(order.getLinkIndex)
      local okFL, finalLink = pcall(order.isFinalLink)
      info = "order " .. tostring(okI and id) .. " link " .. tostring(okK and link) .. " final " .. tostring(okF and final)
        .. " finalLink " .. tostring(okFL and finalLink)
      local okOL, olist = pcall(order.list)
      if okOL and type(olist) == "table" then
        local whole = {}
        for k, it in pairs(olist) do
          if type(it) == "table" then whole[#whole + 1] = tostring(k) .. "=" .. (it.count or "?") .. " " .. tostring(it.name):gsub("^minecraft:", "") end
        end
        table.sort(whole)
        info = info .. " | order list: " .. table.concat(whole, "; ")
      end
      local okC, c = pcall(order.getCrafts)
      if okC and type(c) == "table" and next(c) then
        for i, craft in pairs(c) do
          local cells = {}
          for k = 1, 9 do cells[k] = craft.recipe and craft.recipe[k] and tostring(craft.recipe[k]):gsub("^[^:]+:", "") or "-" end
          info = info .. " | craft " .. i .. " x" .. tostring(craft.count) .. ": " .. table.concat(cells, ",")
        end
      end
    end
    dbg("PACKAGE in: " .. fmtCounts(items) .. " | " .. info)
  end
  if okO and type(order) == "table" then pcall(trackOrder, order, pkg) end
  local crafts
  if okO and type(order) == "table" then
    local okC, c = pcall(order.getCrafts)
    if okC and type(c) == "table" and next(c) then crafts = c end
  end
  if not crafts and okO and type(order) == "table" then
    -- Factory Controller's "Use Custom Arrangement": the order lists 9 slots in crafting-table
    -- order (air for gaps) plus a marker item; that layout is the recipe
    local okL, layout = pcall(order.list)
    if okL and type(layout) == "table" then
      local marked, recipe, any = false, {}, false
      for _, it in pairs(layout) do
        if type(it) == "table" and it.name == "createfactorycontroller:arrangement_marker" then marked = true end
      end
      for i = 1, 9 do
        local it = layout[i]
        local name = type(it) == "table" and it.name
        if name and name ~= "minecraft:air" and name ~= "createfactorycontroller:arrangement_marker" and (it.count or 1) > 0 then
          recipe[i], any = name, true
        else
          recipe[i] = false
        end
      end
      if marked and any then crafts = { { count = 1, recipe = recipe } } end
    end
  end
  if not crafts then
    log("warn", "Package without a recipe: sending it back. Use 'Use Mechanical Crafting' or 'Use Custom Arrangement' on its gauge.")
    state.looseItems = true
    return
  end
  -- what's in the box: a bulk order (no Repackager) holds many crafts' worth even though
  -- its recipe says "craft 1", so the number of crafts comes from the items themselves
  local touched = {}
  local got = {}
  local okL, contents = pcall(pkg.list)
  if okL and type(contents) == "table" then
    for _, it in pairs(contents) do
      if type(it) == "table" and it.name then got[it.name] = (got[it.name] or 0) + (it.count or 0) end
    end
  end
  for _, c in pairs(crafts) do
    local recipe = {}
    for i = 1, 9 do
      local name = c.recipe and c.recipe[i]
      recipe[i] = (type(name) == "string" and name ~= "minecraft:air") and name or false
    end
    local key = recipeKey(recipe)
    touched[#touched + 1] = key
    local job = jobs[key]
    if not job then
      job = { recipe = recipe, crafts = 0, since = now() }
      jobs[key] = job
    end
    job.received = job.received or {}
    local per = perCraft(recipe)
    local counted = false
    for name in pairs(per) do
      if got[name] then
        job.received[name] = (job.received[name] or 0) + got[name]
        got[name] = nil
        counted = true
      end
    end
    if not counted then
      -- couldn't read the contents: trust the package's own craft count
      for name, n in pairs(per) do job.received[name] = (job.received[name] or 0) + n * (tonumber(c.count) or 1) end
    end
    job.crafts = craftsFromReceived(job)
    job.waitingSince = job.waitingSince or now()
    dbg("job " .. jobLabel(job) .. " [" .. key .. "]: received " .. fmtCounts(job.received) .. " -> " .. job.crafts .. " crafts")
  end
  saveJobs()
  local orderId
  if okO and type(order) == "table" then
    local okI, id = pcall(order.getOrderID)
    if okI then orderId = id end
  end
  return touched, orderId
end

-- ============================================================ sending

-- Package everything in the turtle and send it to OUT_ADDRESS. With `keep` (slot -> count),
-- anything beyond those counts arrived in the meantime and goes to the buffer first.
local function sendTurtle(keep)
  pcall(outputPackager.setAddress, OUT_ADDRESS)
  dbg("SEND to " .. OUT_ADDRESS .. ": " .. fmtCounts(turtleCounts()))
  for attempt = 1, 40 do
    if state.bounced then dbg("  send stopped: output bounce") return false end
    if turtleEmpty() then
      state.sendFails = 0
      dbg("  sent after " .. (attempt - 1) .. " makePackage call(s)")
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
    if not (ok and made) then
      if attempt == 1 or attempt % 10 == 0 then dbg("  makePackage #" .. attempt .. ": " .. tostring(ok and made or made)) end
      sleep(0.5)
    end
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
  dbg("CRAFT " .. n .. "x " .. jobLabel(job) .. " | before: " .. snapshot())
  -- 1. empty the turtle into the buffer, then pull each grid slot's items in place
  if not parkAll() then
    state.problem = "Barrel is full"
    return 0
  end
  for i = 1, 9 do
    local name = job.recipe[i]
    if name then
      local have = turtle.getItemCount(GRID[i])
      if have < n then fetch(name, n - have, GRID[i]) end
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
    state.lastFail = "couldn't get all the ingredients out of the Barrel"
    dbg("  grid incomplete: " .. snapshot())
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
    local okc, why = turtle.craft(crafts)
    dbg("  turtle.craft(" .. crafts .. "): " .. tostring(okc) .. (why and (" " .. tostring(why)) or ""))
    if okc then done = crafts break end
  end
  turtle.select(1)
  if done <= 0 then
    state.lastFail = "the turtle couldn't craft that layout (not a crafting recipe?)"
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
  dbg("  results: " .. fmtCounts(results))
  recordCraft(job, results)
  sendTurtle(keep)
  dbg("  after: " .. snapshot())
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

-- Send everything in the turtle and the barrel back to storage (only called with no orders
-- waiting, or for "Send all back").
-- Arranged packages unpack into barrel slots 1-9 and only when those are free, so move what's
-- there up to slots 10+: the next order can then unpack while this one is being crafted.
local function clearInbox()
  if not buffer then return end
  local okS, size = pcall(buffer.size)
  if not okS or not size or size <= 9 then return end
  local ok, list = pcall(buffer.list)
  if not ok or type(list) ~= "table" then return end
  local free = {}
  for slot = size, 10, -1 do if not list[slot] then table.insert(free, slot) end end
  local moved = 0
  for slot = 1, 9 do
    if list[slot] and #free > 0 then
      local target = table.remove(free)
      local okP, n = pcall(buffer.pushItems, bufferSide, slot, 64, target)
      if okP and n and n > 0 then moved = moved + 1 end
    end
  end
  if moved > 0 then dbg("cleared barrel slots 1-9 (" .. moved .. " stacks moved up) for the next order") end
end

-- Default mode (TAKE_TURNS = false): open by default; busy while too many packages wait in the
-- Frogport and the station has work of its own (they go back onto the chain to the other
-- stations); open again once the queue is gone and at most one order is left.
local function gate()
  if not inputFrogport or TAKE_TURNS or #landing > 0 then return end
  local okF, fl = pcall(inputFrogport.list)
  local queue = 0
  if okF and type(fl) == "table" then for _ in pairs(fl) do queue = queue + 1 end end
  local orders, working = 0, state.busy
  local counts = buffer and bufferCounts() or {}
  for name, n in pairs(turtleCounts()) do counts[name] = (counts[name] or 0) + n end
  for _, job in pairs(jobs) do
    orders = orders + 1
    local can = job.crafts
    for name, per in pairs(perCraft(job.recipe)) do can = math.min(can, math.floor((counts[name] or 0) / per)) end
    if can > 0 then working = true end
  end
  if state.problem or state.paused then
    setOpen(false, state.paused and "paused" or "setup problem")
  elseif queue >= MAX_QUEUE and working then
    setOpen(false, queue .. " packages waiting: the rest go to other stations")
  elseif state.advertised ~= CRAFT_ADDRESS and queue == 0 and orders <= 1 then
    setOpen(true, "room for more")
  elseif state.advertised == nil then
    setOpen(true, "taking orders")
  end
end

local function returnLeftovers()
  if not parkAll() then
    -- the barrel is full: send what the turtle holds first, then keep emptying the barrel
    sendTurtle()
  end
  dbg("LEFTOVERS: " .. snapshot())
  local any = false
  for _ = 1, 60 do
    local ok, list = pcall(buffer.list)
    if not ok or not list or next(list) == nil then break end
    local slot
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then slot = i break end end
    if not slot then
      sendTurtle()
      slot = 1
    end
    turtle.select(slot)
    if not suckFromBuffer() then break end
    any = true
  end
  turtle.select(1)
  if not turtleEmpty() then sendTurtle() end
  if any then
    if state.unordered then
      log("warn", "Items I never ordered landed in my barrel: another station's Packager feeds it? Sent them to " .. OUT_ADDRESS)
    else
      log("info", "Sent leftover items back to " .. OUT_ADDRESS)
    end
  end
  state.unordered = false
end

local function bufferEmpty()
  local ok, list = pcall(buffer.list)
  return not ok or not list or next(list) == nil
end

local function work()
  state.busy = true
  pcall(clearInbox)
  do
    local js = {}
    for _, job in pairs(jobs) do js[#js + 1] = job.crafts .. "x " .. jobLabel(job) end
    dbg("WORK jobs [" .. (#js > 0 and table.concat(js, "; ") or "none") .. "] " .. snapshot())
  end
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
      pcall(gate)
      if done <= 0 then
        job.fails = (job.fails or 0) + 1
        if job.fails >= 3 then
          log("error", "Gave up on " .. job.crafts .. "x " .. jobLabel(job) .. ": " .. tostring(state.lastFail) .. ". Items sent back.")
          dbg("  gave up; recipe " .. recipeKey(job.recipe) .. " | " .. snapshot())
          job.crafts, job.givenUp = 0, true
        end
        break
      end
      job.fails = 0
      reserve(counts, job, done)
      if job.received then
        for name, per in pairs(perCraft(job.recipe)) do
          job.received[name] = math.max(0, (job.received[name] or 0) - per * done)
        end
        job.crafts = craftsFromReceived(job)
      else
        job.crafts = job.crafts - done
      end
      can = can - done
      job.waitingSince = now()
    end
    if job.crafts <= 0 then
      jobs[key] = nil
    elseif can <= 0 and now() - state.lastArrival > 60 and now() - (job.waitingSince or now()) > 60 then
      -- its ingredients never came (or went back to storage): drop it, the gauge orders again
      log("warn", "Gave up on " .. job.crafts .. "x " .. jobLabel(job) .. ": its items never reached my barrel")
      if inputFrogport then
        log("warn", "Check " .. tostring(inputName) .. " is MY Frogport and its Packager feeds MY barrel")
      end
      jobs[key] = nil
    end
  end
  saveJobs()
  if state.returnAll then
    state.returnAll = false
    jobs = {}
    saveJobs()
    returnLeftovers()
    log("info", "Sent everything back to " .. OUT_ADDRESS)
  elseif next(jobs) == nil then
    returnLeftovers()
  end
  state.looseItems = false
  state.busy = false
end

-- ============================================================ loops

local function itemsOf(pkg)
  local got = {}
  local ok, list = pcall(pkg.list)
  if ok and type(list) == "table" then
    for _, it in pairs(list) do
      if type(it) == "table" and it.name then got[it.name] = (got[it.name] or 0) + (it.count or 0) end
    end
  end
  return got
end

-- Unpaired: the network Frogport whose caught packages are exactly what landed in our barrel is ours.
local function tryPair()
  if not buffer or #pairing.candidates == 0 then return end
  local counts = bufferCounts()
  if next(counts) == nil then return end
  local sums = {}
  for _, c in ipairs(pairing.candidates) do
    sums[c.name] = sums[c.name] or {}
    for name, n in pairs(c.items) do sums[c.name][name] = (sums[c.name][name] or 0) + n end
  end
  local match
  for name, sum in pairs(sums) do
    local same = true
    for item, n in pairs(sum) do if counts[item] ~= n then same = false end end
    for item, n in pairs(counts) do if sum[item] ~= n then same = false end end
    if same then
      if match then return end  -- two Frogports fit: wait for a clearer package
      match = name
    end
  end
  if not match then return end
  writeFile(DIR .. "/input", match)
  findPeripherals()
  log("info", "Paired with " .. match .. ", this station's input Frogport")
  for _, c in ipairs(pairing.candidates) do
    if c.name == match then pcall(onPackage, c.pkg) end
  end
  pairing.candidates = {}
  setOpen(false)
end

local function unpair()
  if fs.exists(DIR .. "/input") then fs.delete(DIR .. "/input") end
  pairing.candidates = {}
  findPeripherals()
  log("info", "Forgot the input Frogport; pairing again with the next package")
end

-- Trace: where do an order's items go after the Frogport catches it?
local trace = { checks = {} }  -- { at = time, label = text }

local function itemTotal(pkg)
  local n = 0
  local ok, list = pcall(pkg.list)
  if ok and type(list) == "table" then
    for _, it in pairs(list) do if type(it) == "table" then n = n + (it.count or 0) end end
  end
  return n
end

local function peripheralLabel(name)
  return (tostring(name):gsub("^Create_", ""))
end

local function sameCounts(a, b)
  for k, v in pairs(a or {}) do if (b or {})[k] ~= v then return false end end
  for k, v in pairs(b or {}) do if (a or {})[k] ~= v then return false end end
  return true
end

-- A caught package whose items will never arrive here: take it out of its jobs and order again,
-- so nothing waits for it. The chain delivers it to an open station instead.
local function undoPackage(entry, why)
  for _, key in ipairs(entry.keys or {}) do
    local job = jobs[key]
    if job and job.received then
      for name, n in pairs(entry.items or {}) do
        if job.received[name] then job.received[name] = math.max(0, job.received[name] - n) end
      end
      job.crafts = craftsFromReceived(job)
      if job.crafts <= 0 then jobs[key] = nil end
    end
  end
  if entry.order ~= nil and orders[entry.order] then
    local total = 0
    for _, n in pairs(entry.items or {}) do total = total + n end
    orders[entry.order].got = orders[entry.order].got - total
    if orders[entry.order].got <= 0 then orders[entry.order] = nil end
  end
  saveJobs()
  log("info", "A package went back onto the chain (" .. why .. "): " .. fmtCounts(entry.items))
end

local function eventLoop()
  while true do
    local e = { os.pullEvent() }
    -- our Frogport caught a package: note it before anything else can yield, so the address
    -- isn't changed while the package is still landing
    local caught
    if e[1] == "package_received" and inputFrogport and e[2] == inputName then
      caught = { t = now() }
      table.insert(landing, caught)
    end
    if e[1] == "package_received" or e[1] == "package_created" or e[1] == "package_sent" then
      local tbl
      for i = 2, #e do if type(e[i]) == "table" then tbl = e[i] break end end
      dbg("event " .. e[1] .. " from " .. tostring(e[2]) .. (tbl and (": " .. itemTotal(tbl) .. " items") or ""))
    end
    -- the output Packager unpacking means its Frogport handed our own package straight back
    -- (its address matches OUT_ADDRESS): stop instead of sending the same items round forever
    if e[1] == "package_received" and e[2] == OUTPUT_SIDE and not state.bounced then
      state.bounced = true
      log("error", "My output Frogport sent my package back! Its address must NOT be " .. OUT_ADDRESS
        .. ": set it to something unused like MB-Crafting-Out, then restart me")
    end
    -- any Packager on the modem network unpacking or packing: log it
    if (e[1] == "package_received" or e[1] == "package_created") and type(e[2]) == "string"
      and e[2] ~= OUTPUT_SIDE and peripheral.hasType(e[2], "Create_Packager") and type(e[3]) == "table" then
      log("info", peripheralLabel(e[2]) .. (e[1] == "package_received" and " unpacked " or " packed ") .. itemTotal(e[3]) .. " items")
    end
    if e[1] == "package_received" and inputName and e[2] == inputName and type(e[3]) == "table" then
      log("info", "Frogport caught " .. itemTotal(e[3]) .. " items")
      table.insert(trace.checks, { at = now() + 2 })
      table.insert(trace.checks, { at = now() + 6 })
    end
    if e[1] == "package_received" then
      local from = type(e[2]) == "string" and e[2] or nil
      local pkg
      for i = 2, #e do if type(e[i]) == "table" then pkg = e[i] break end end
      if pkg and inputName and (from == nil or from == inputName) then
        local items = itemsOf(pkg)
        local ok, keys, orderId = pcall(onPackage, pkg)
        if caught then
          caught.items = items
          if ok then caught.keys, caught.order = keys, orderId end
        end
      elseif pkg and not inputName and from and peripheral.hasType(from, "Create_Frogport") then
        table.insert(pairing.candidates, { name = from, pkg = pkg, items = itemsOf(pkg), t = now() })
      end
    elseif e[1] == "package_sent" and inputFrogport and e[2] == inputName and type(e[3]) == "table" then
      -- our input Frogport sent a package away: one we caught that was still landing when we went busy
      local items = itemsOf(e[3])
      local found = false
      for _, list in ipairs({ landing, recentlyLanded }) do
        for i, l in ipairs(list) do
          if not found and l.items and sameCounts(l.items, items) then
            undoPackage(table.remove(list, i), "it was still landing when I went busy")
            found = true
          end
        end
      end
    elseif e[1] == "rednet_message" and e[4] == HEARTBEAT and type(e[3]) == "table" then
      local id = tonumber(e[3].id) or e[2]
      if id and id ~= MY_ID then
        peers[id] = { t = now(), open = e[3].open == true, idle = e[3].idle == true, name = tostring(e[3].name or ("Station " .. id)) }
      end
    elseif e[1] == "peripheral" or e[1] == "peripheral_detach" then
      findPeripherals()
      openModems()
    end
  end
end

local function workLoop()
  while true do
    for i = #trace.checks, 1, -1 do
      if now() >= trace.checks[i].at then
        table.remove(trace.checks, i)
        local n = 0
        if buffer then for _, c in pairs(bufferCounts()) do n = n + c end end
        local t = 0
        for slot = 1, 16 do t = t + turtle.getItemCount(slot) end
        log("info", "Barrel " .. n .. ", turtle " .. t .. ", Frogport " .. (frogportEmpty() and "empty" or "has pkg"))
      end
    end
    if #landing > 0 then
      -- a caught package has landed once LAND_SECONDS pass without the Frogport sending it away
      local landed = false
      while landing[1] and landing[1].items and now() - landing[1].t >= LAND_SECONDS do
        local l = table.remove(landing, 1)
        l.landedAt = now()
        table.insert(recentlyLanded, l)
        dbg("landed: " .. fmtCounts(l.items))
        landed = true
      end
      -- go busy once one package is in (unless more of its order is still coming); anything
      -- still in the air goes back onto the chain and is handled by the package_sent event
      if TAKE_TURNS and landed and inputFrogport and not waitingForRest() then setOpen(false, "order is in, crafting") end
    end
    for i = #recentlyLanded, 1, -1 do
      if now() - recentlyLanded[i].landedAt > 120 then table.remove(recentlyLanded, i) end
    end
    state.problem = setupProblem()
    if state.pairing and not state.problem then pcall(tryPair) end
    for i = #pairing.candidates, 1, -1 do
      if now() - pairing.candidates[i].t > 15 then table.remove(pairing.candidates, i) end
    end
    local pending = next(jobs) ~= nil or state.looseItems or state.returnAll
    if state.problem then
      if inputFrogport then setOpen(false) end
      state.status = "Setup needed"
    elseif state.paused then
      state.status = "Paused"
    elseif pending and (now() - state.lastArrival >= QUIET_SECONDS or freeSlots() <= 4 or state.returnAll) then
      local ok, err = pcall(work)
      state.busy = false
      if not ok then log("error", "Error: " .. tostring(err)) end
    elseif pending then
      state.status = "Receiving..."
    elseif state.pairing and #pairing.candidates > 0 and now() - (state.pairingWait or now()) < 20 then
      -- give a pairing 20 s at most; after that the barrel is emptied like any leftovers
      state.pairingWait = state.pairingWait or now()
      state.status = "Pairing..."
    elseif now() - state.lastArrival > 5 and (not turtleEmpty() or (now() - (state.lastBufferCheck or 0) > 10 and not bufferEmpty())) then
      -- items with no order (after a restart, or a given-up order): send them home
      state.lastBufferCheck = now()
      state.unordered = now() - state.lastArrival > 30 and not bufferEmpty()
      pcall(work)
      state.busy = false
    else
      state.status = "Ready"
    end
    if not state.pairing or bufferEmpty() then state.pairingWait = nil end
    if inputFrogport and #landing == 0 and not TAKE_TURNS then
      -- always open (unless paused or not set up): Create's own backpressure shares the work
      gate()
    elseif inputFrogport and #landing == 0 then
      local idle = not state.problem and not state.paused and not state.busy and next(jobs) == nil
        and now() - state.lastArrival > 0.5 and turtleEmpty() and frogportEmpty() and bufferEmpty()
      if idle ~= state.idle then
        state.idle = idle
        state.lastBeat = 0  -- tell the others straight away
      end
      local open = false
      if not state.problem and waitingForRest() then
        open = true  -- the rest of an order is on its way: keep taking it here
      elseif idle then
        -- only one station takes orders at a time. When none is open, the idle station with the
        -- lowest id opens; if two are open anyway, the lower id keeps it.
        local other = openStation()
        if state.advertised == CRAFT_ADDRESS then
          open = other == nil or other > MY_ID
        else
          local first = openStation(true)
          open = other == nil and (first == nil or first > MY_ID)
          other = other or first
        end
        state.standbyFor = (not open and other) and peers[other].name or nil
      end
      setOpen(open, open and "taking orders" or "busy")
    end
    if inputFrogport and now() - (state.lastBeat or 0) >= 2 then heartbeat() end
    if state.status ~= state.lastLoggedStatus then
      dbg("status: " .. tostring(state.status) .. (state.problem and (" | problem: " .. state.problem) or ""))
      state.lastLoggedStatus = state.status
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

-- Upload /station/log.txt (plus a summary) to Pastebin; the code shows on the screen.
local PASTEBIN_KEY = "0ec2eb25b6166c0c27a394ae118ad829"  -- the key CC's own `pastebin` program uses

local function uploadLog()
  local lines = {
    "Crafting Station " .. VERSION .. " | " .. stationName() .. " | computer " .. os.getComputerID(),
    "CRAFT_ADDRESS=" .. tostring(CRAFT_ADDRESS) .. " BUSY=" .. busyAddress() .. " OUT_ADDRESS=" .. tostring(OUT_ADDRESS)
      .. " INPUT_SIDE=" .. tostring(INPUT_SIDE) .. " OUTPUT_SIDE=" .. tostring(OUTPUT_SIDE) .. " QUIET=" .. tostring(QUIET_SECONDS),
    "input: " .. tostring(inputName) .. (inputFrogport and " (Frogport)" or inputPackager and " (Packager)" or " (none)")
      .. " advertised=" .. tostring(state.advertised) .. " | output: " .. (outputPackager and OUTPUT_SIDE or "none")
      .. " | buffer: " .. tostring(bufferSide) .. " | problem: " .. tostring(state.problem),
    "now: " .. snapshot(),
    "peripherals: " .. table.concat(peripheral.getNames(), ", "),
    "stats: today " .. tostring(stats.today) .. ", total " .. tostring(stats.total),
    "---- log ----",
  }
  local body = table.concat(lines, "\n") .. "\n"
  for _, path in ipairs({ LOG_PATH .. ".old", LOG_PATH }) do
    if fs.exists(path) then
      local f = fs.open(path, "r")
      body = body .. f.readAll() .. "\n"
      f.close()
    end
  end
  local post = "api_option=paste&api_dev_key=" .. PASTEBIN_KEY .. "&api_paste_format=text"
    .. "&api_paste_name=" .. textutils.urlEncode(stationName() .. " log")
    .. "&api_paste_code=" .. textutils.urlEncode(body)
  local ok, res, err = pcall(http.post, "https://pastebin.com/api/api_post.php", post,
    { ["Content-Type"] = "application/x-www-form-urlencoded" })
  if ok and res then
    local answer = res.readAll()
    res.close()
    local code = answer:match("pastebin%.com/(%w+)")
    if code then
      state.pasteCode = code
      log("info", "Log uploaded: pastebin code " .. code)
      return
    end
    log("error", "Pastebin said: " .. tostring(answer):sub(1, 80))
  else
    log("error", "Upload failed (" .. tostring(err or res) .. "). Run: pastebin put station/log.txt")
  end
end

local function alertLoop()
  local lastCheck = 0
  while true do
    if state.uploadWanted then
      state.uploadWanted = false
      state.pasteCode = "..."
      pcall(uploadLog)
      if state.pasteCode == "..." then state.pasteCode = nil end
    end
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
  if status == "Ready" and state.pairing then
    status = "Ready, pairing with its Frogport on the first order"
  elseif status == "Ready" and inputFrogport then
    if state.advertised == CRAFT_ADDRESS then
      status = "Ready, taking orders on " .. CRAFT_ADDRESS
    elseif state.standbyFor then
      status, color = "Standby: " .. state.standbyFor .. " is taking orders", colors.lightBlue
    else
      status = "Finishing up"
    end
  end
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

  if inputFrogport then
    local okF, fl = pcall(inputFrogport.list)
    local waiting = 0
    if okF and type(fl) == "table" then for _ in pairs(fl) do waiting = waiting + 1 end end
    local inBarrel = 0
    for _, n in pairs(buffer and bufferCounts() or {}) do inBarrel = inBarrel + n end
    put(2, y, "In Frogport ", colors.lightGray)
    put(14, y, waiting .. " pkg", waiting > 0 and colors.orange or colors.white)
    put(22, y, "Barrel ", colors.lightGray)
    put(29, y, inBarrel .. " items", colors.white)
    y = y + 1
    if waiting > 0 and inBarrel == 0 and now() - state.lastArrival > 10 then
      put(2, y, fit("Frogport can't pass packages down: is the", w - 2), colors.orange)
      put(2, y + 1, fit("input Packager right under it, on my barrel?", w - 2), colors.orange)
      y = y + 2
    end
  end
  if state.pasteCode and state.pasteCode ~= "..." then
    put(2, y, "Log on Pastebin: ", colors.lightGray)
    put(19, y, state.pasteCode, colors.yellow)
    y = y + 1
  end
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
  if state.pairing then
    put(2, y, "?", colors.yellow, colors.black)
    put(4, y, "Input", colors.lightGray)
    put(16, y, fit("pairing on the first order", w - 16), colors.yellow)
    y = y + 1
  else
    row("Input", inputPackager ~= nil or inputFrogport ~= nil, inputFrogport and ("Frogport " .. inputName)
      or inputPackager and ("Packager " .. inputName) or ("Frogport on the " .. INPUT_SIDE))
  end
  if inputFrogport then
    row("Orders", true, state.advertised == CRAFT_ADDRESS and ("open: " .. CRAFT_ADDRESS)
      or state.standbyFor and ("standby (" .. state.standbyFor .. " open)") or "busy")
  end
  row("Output", outputPackager ~= nil, outputPackager and ("Packager " .. OUTPUT_SIDE) or ("Packager on the " .. OUTPUT_SIDE))
  row("Buffer", buffer ~= nil, buffer and ("barrel " .. bufferSide) or "barrel on top or under")
  row("Sends to", true, OUT_ADDRESS)
  row("Discord", DISCORD_WEBHOOK ~= nil, DISCORD_WEBHOOK and (alerts.error and "error" or "stuck alerts on") or "off")
  row("Name", true, stationName())
  y = y + 1
  if inputFrogport and inputName ~= INPUT_SIDE then
    button(2, y, " Re-pair input Frogport ", colors.white, colors.gray, unpair)
    y = y + 2
  end
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
  local upLabel = state.pasteCode and (" " .. state.pasteCode .. " ") or " Upload log "
  button(w - #upLabel + 1, h, upLabel, colors.white, colors.blue, function()
    if http and state.pasteCode ~= "..." then state.uploadWanted = true end
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
      elseif e[2] == keys.u then
        if http then state.uploadWanted = true end
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
openModems()
if outputPackager then pcall(outputPackager.setAddress, OUT_ADDRESS) end
log("info", "Started " .. stationName() .. " v" .. VERSION)
dbg("settings: CRAFT_ADDRESS=" .. tostring(CRAFT_ADDRESS) .. " OUT_ADDRESS=" .. tostring(OUT_ADDRESS)
  .. " INPUT_SIDE=" .. tostring(INPUT_SIDE) .. " OUTPUT_SIDE=" .. tostring(OUTPUT_SIDE))
dbg("found: input " .. tostring(inputName) .. (inputFrogport and " (Frogport)" or inputPackager and " (Packager)" or " (none)")
  .. ", output " .. (outputPackager and OUTPUT_SIDE or "none") .. ", buffer " .. tostring(bufferSide))
dbg("peripherals: " .. table.concat(peripheral.getNames(), ", "))

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
