-- Hub check: reads every package in the Repackager vault and says why it's still there.
-- A Repackager only lets an order go once it has every piece (link 1.. , fragment 1..), so:
--   complete   = all pieces here, just waiting for a Repackager to get to it (too slow?)
--   incomplete = a piece is missing; it will sit here forever
--   plain      = no order data; a Repackager passes these straight through
-- Usage:  hubcheck            (finds the vault with the most packages)
--         hubcheck <vault>    (network name, e.g. create:item_vault_5)
-- The full report is saved to /hubcheck.txt; upload it with: pastebin put hubcheck.txt

local args = { ... }

local function vaults()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") and (name:find("vault", 1, true) or name:find("silo", 1, true)) then
      table.insert(out, name)
    end
  end
  return out
end

local function isPackage(item)
  return item and item.name and item.name:find("package", 1, true) ~= nil
end

local function scan(name)
  local inv = peripheral.wrap(name)
  local ok, list = pcall(inv.list)
  if not ok or type(list) ~= "table" then return nil end
  local found = {}
  for slot, item in pairs(list) do
    if isPackage(item) then
      local okD, d = pcall(inv.getItemDetail, slot)
      local p = { slot = slot, count = item.count }
      local pkg = okD and type(d) == "table" and d.package
      if type(pkg) == "table" then
        local function call(obj, fn, ...)
          if type(obj) == "table" and type(obj[fn]) == "function" then
            local okC, v = pcall(obj[fn], ...)
            if okC then return v end
          end
          return obj and obj[fn] ~= nil and type(obj[fn]) ~= "function" and obj[fn] or nil
        end
        p.address = call(pkg, "getAddress") or pkg.address
        local items = 0
        local contents = call(pkg, "list") or pkg.items or {}
        if type(contents) == "table" then
          for _, it in pairs(contents) do if type(it) == "table" then items = items + (it.count or 0) end end
        end
        p.items = items
        local order = call(pkg, "getOrderData") or pkg.orderData
        if type(order) == "table" then
          p.order = call(order, "getOrderID") or order.orderId
          p.link = call(order, "getLinkIndex") or order.linkIndex
          p.finalLink = call(order, "isFinalLink") or order.isFinalLink
          p.frag = call(order, "getIndex") or order.index
          p.final = call(order, "isFinal") or order.isFinal
          local layout = call(order, "list")
          if type(layout) == "table" then
            for _, it in pairs(layout) do
              if type(it) == "table" and it.name == "createfactorycontroller:arrangement_marker" then p.arranged = true end
            end
          end
          local crafts = call(order, "getCrafts")
          if type(crafts) == "table" and next(crafts) then p.crafting = true end
        end
      end
      table.insert(found, p)
    end
  end
  return found
end

-- the Repackager's own rule (Create's PackageRepackageHelper.isOrderComplete), with Lua's 1-based numbers
local function missingPiece(pieces)
  local link = 1
  while link < 1000 do
    local frag = 1
    local finalLink = false
    while frag < 1000 do
      local piece
      for _, p in ipairs(pieces) do
        if p.link == link and p.frag == frag then piece = p break end
      end
      if not piece then return "link " .. link .. " piece " .. frag end
      finalLink = piece.finalLink == true
      if piece.final then break end
      frag = frag + 1
    end
    if finalLink then return nil end
    link = link + 1
  end
  return "too many pieces?"
end

-- ---------------------------------------------------------------- run
local target = args[1]
if not target then
  local best, bestN = nil, -1
  for _, name in ipairs(vaults()) do
    local s = scan(name) or {}
    if #s > bestN then best, bestN = name, #s end
  end
  target = best
end
if not target then
  printError("No vault found on this computer's network. Run: hubcheck <vault name>")
  return
end

local pkgs = scan(target)
if not pkgs then printError("Can't read " .. target) return end

local lines = {}
local function out(s) print(s) table.insert(lines, s) end

out("Hub check: " .. target .. " (" .. os.date("!%Y-%m-%d %H:%M UTC") .. ")")
out(#pkgs .. " packages")
if #pkgs > 0 and pkgs[1].address == nil and pkgs[1].order == nil then
  out("Package details aren't readable here; can't check orders.")
end

local orders, plain, byAddress = {}, 0, {}
for _, p in ipairs(pkgs) do
  local a = tostring(p.address or "?")
  byAddress[a] = (byAddress[a] or 0) + (p.count or 1)
  if p.order then
    orders[p.order] = orders[p.order] or {}
    table.insert(orders[p.order], p)
  else
    plain = plain + (p.count or 1)
  end
end

out("")
out("By address:")
for a, n in pairs(byAddress) do out("  " .. n .. "x  " .. a) end

local complete, incomplete = 0, 0
local detail = {}
for id, pieces in pairs(orders) do
  local miss = missingPiece(pieces)
  local p1 = pieces[1]
  local kind = p1.arranged and "arranged" or p1.crafting and "crafting" or "normal"
  local desc = "order " .. tostring(id) .. " -> " .. tostring(p1.address) .. " (" .. kind .. "), " .. #pieces .. " piece(s)"
  if miss then
    incomplete = incomplete + 1
    table.insert(detail, "STUCK " .. desc .. ", missing " .. miss)
  else
    complete = complete + 1
    table.insert(detail, "ready " .. desc)
  end
  for _, p in ipairs(pieces) do
    table.insert(detail, "      link " .. tostring(p.link) .. (p.finalLink and " (last link)" or "")
      .. " piece " .. tostring(p.frag) .. (p.final and " (last piece)" or "") .. ", " .. tostring(p.items) .. " items")
  end
end

out("")
out("Orders complete, waiting for a Repackager: " .. complete)
out("Orders INCOMPLETE (stuck for good):       " .. incomplete)
out("Plain packages (no order data):          " .. plain)
out("")
if incomplete > 0 then
  out("Incomplete orders never leave: a piece of each went somewhere else.")
elseif complete > 0 then
  out("Everything here is complete: the Repackagers are just too slow for the traffic.")
end

local f = fs.open("/hubcheck.txt", "w")
for _, l in ipairs(lines) do f.writeLine(l) end
f.writeLine("")
for _, l in ipairs(detail) do f.writeLine(l) end
f.close()
print("")
print("Full list in hubcheck.txt. Share it: pastebin put hubcheck.txt")
