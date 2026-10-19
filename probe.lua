-- Crafting Station test. Run it on the crafty turtle with the Packager next to it,
-- then let a Factory Gauge order something to this station's Frogport address.
-- Everything it prints is also saved to /probe.log so you can send it over.

local OUT_ADDRESS = "MB-Storage-In"

local log = fs.open("/probe.log", "a")
local function say(s)
  print(s)
  log.writeLine(s)
  log.flush()
end

local packager = peripheral.find("Create_Packager")
if not packager then
  say("No Packager found next to the turtle.")
  log.close()
  return
end
say("Packager found, its address: " .. tostring(packager.getAddress()))
say("Waiting for packages. S = send what the turtle holds")
say("to " .. OUT_ADDRESS .. ", Q = quit.")

local function turtleItems()
  local n, kinds = 0, 0
  for i = 1, 16 do
    local d = turtle.getItemDetail(i)
    if d then n, kinds = n + d.count, kinds + 1 end
  end
  return n, kinds
end

local function showPackage(ev, pkg)
  say("== " .. ev)
  local ok, addr = pcall(pkg.getAddress)
  say(" address: " .. tostring(ok and addr or "?"))
  local okL, list = pcall(pkg.list)
  if okL and type(list) == "table" then
    for _, it in pairs(list) do say(" " .. it.count .. "x " .. it.name) end
  end
  local okO, order = pcall(pkg.getOrderData)
  if not okO or type(order) ~= "table" then
    say(" no order data: " .. tostring(order))
    return
  end
  local okI, id = pcall(order.getOrderID)
  local okF, final = pcall(order.isFinal)
  say(" order " .. tostring(okI and id) .. ", last package: " .. tostring(okF and final))
  local okOL, olist = pcall(order.list)
  if okOL and type(olist) == "table" then
    local keys = {}
    for k in pairs(olist) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local it = olist[k]
      say(" order slot " .. tostring(k) .. ": " .. tostring(type(it) == "table" and ((it.count or "?") .. "x " .. tostring(it.name)) or it))
    end
  else
    say(" order list: " .. tostring(olist))
  end
  local okC, crafts = pcall(order.getCrafts)
  if not okC or type(crafts) ~= "table" or next(crafts) == nil then
    say(" order data, but no crafts: " .. tostring(crafts))
    return
  end
  for i, c in pairs(crafts) do
    say(" recipe " .. i .. ", craft " .. tostring(c.count) .. " times:")
    for row = 0, 2 do
      local cells = {}
      for col = 1, 3 do
        local name = c.recipe and c.recipe[row * 3 + col]
        cells[col] = name and name:gsub("^[^:]+:", ""):sub(1, 10) or "-"
      end
      say("  " .. table.concat(cells, " | "))
    end
  end
end

while true do
  local e = { os.pullEvent() }
  local ev = e[1]
  if ev == "package_received" or ev == "package_created" then
    local pkg
    for i = 2, #e do if type(e[i]) == "table" then pkg = e[i] end end
    if pkg then showPackage(ev, pkg) else say("== " .. ev .. " (no package object)") end
    sleep(2)
    local n, kinds = turtleItems()
    say(" turtle now holds " .. n .. " items (" .. kinds .. " kinds)")
  elseif ev == "char" and (e[2] == "s" or e[2] == "S") then
    local n = turtleItems()
    say("Sending " .. n .. " items to " .. OUT_ADDRESS .. "...")
    local okA, errA = pcall(packager.setAddress, OUT_ADDRESS)
    if not okA then say(" setAddress failed: " .. tostring(errA)) end
    local okM, res = pcall(packager.makePackage)
    say(" makePackage: " .. tostring(okM and res or ("error " .. tostring(res))))
    sleep(2)
    say(" turtle now holds " .. turtleItems() .. " items")
  elseif ev == "char" and (e[2] == "q" or e[2] == "Q") then
    break
  end
end
log.close()
