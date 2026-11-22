-- Checks and fixes the active mod list on the world-gen / arena Mods screen.
--@ module = true
--[====[
mod-load-order
==============
Adds a panel to the Mods screen (Create world -> Mods) that checks the active
(right-hand) mod list and helps fix it:

- load order against each mod's "Must be after" / "Must be before" rules
- missing required mods (alert + Workshop search links)
- declared conflicts (batch removal with one confirmation)
- hidden conflicts found by scanning the mods' raw files
- order suggestions for mods that declare no rules
- newer installed versions of active mods
- undo, saving the list as a Mod Manager preset, per-mod "why is it here"
- a warning when clicking Create world while problems remain

Usage:
    mod-load-order          show the details window (must be on the Mods screen)
    mod-load-order check    print problems to the console
    mod-load-order fix      fix the load order and print what moved
    mod-load-order scan     print what the raw-file scan found
]====]

local dialogs = require('gui.dialogs')
local gui = require('gui')
local json = require('json')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local FIELD_SUFFIXES = {
    'id', 'numeric_version', 'earliest_compat_numeric_version', 'src_dir',
    'name', 'displayed_version', 'mod_header',
}
local WORKSHOP_SEARCH = 'https://steamcommunity.com/workshop/browse/?appid=975370&searchtext=%s'
local WORKSHOP_ITEM = 'https://steamcommunity.com/sharedfiles/filedetails/?id=%s'
local PRESETS_FILE = 'dfhack-config/mod-manager.json'

function get_mod_screen()
    return dfhack.gui.getViewscreenByType(df.viewscreen_new_regionst, 0)
        or dfhack.gui.getViewscreenByType(df.viewscreen_new_arenast, 0)
end

local function modkey(id, version) return id .. '\0' .. tostring(version) end
local function key_id(k) return k:match('^(.-)%z') end

-- plural(3, 'mod') -> '3 mods'; with verb=true: plural(1, 'graphic', true) -> '1 graphic is'
local function plural(n, word, verb)
    if verb then
        if word:endswith(' is') then
            return ('%d %s'):format(n, n == 1 and word or (word:gsub(' is$', 's are'):gsub('graphicss', 'graphics')))
        end
        return ('%d %s%s'):format(n, word, n == 1 and ' is' or 's are')
    end
    return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

local function hdr_name(hdr) return hdr.name ~= '' and hdr.name or hdr.id end

---------------------------------------------------------------------------
-- reading the mod lists

-- Active mods in load order (index 1 = loads first).
local function read_active(vs)
    local mods = {}
    for i, hdr in ipairs(vs.object_load_order_mod_header) do
        local m = {
            idx = i, pos = i + 1,
            id = hdr.id,
            version = vs.object_load_order_numeric_version[i],
            displayed_version = hdr.displayed_version,
            name = hdr_name(hdr),
            vanilla = hdr.flags.vanilla or hdr.src_dir:startswith('data/vanilla'),
            path = hdr.absolute_path,
            steam_id = hdr.steam_file_id,
            after = {},    -- ids this mod must load after
            before = {},   -- ids this mod must load before
            requires = {}, -- ids required with no ordering rule
            conflicts = {},
        }
        m.key = modkey(m.id, m.version)
        for j, dep in ipairs(hdr.dependencies) do
            local flags = hdr.dependency_type[j]
            if flags.id_must_be_before then
                table.insert(m.after, dep.value)   -- REQUIRES_ID_BEFORE_ME
            elseif flags.id_must_be_after then
                table.insert(m.before, dep.value)  -- REQUIRES_ID_AFTER_ME
            else
                table.insert(m.requires, dep.value)
            end
        end
        for _, c in ipairs(hdr.conflicts) do
            table.insert(m.conflicts, c.value)
        end
        table.insert(mods, m)
    end
    return mods
end

local function index_mods(mods)
    local by_id = {}
    for _, m in ipairs(mods) do by_id[m.id] = m end
    return by_id
end

-- id -> name for every installed mod the game knows about
local function known_names(vs)
    local names = {}
    for _, hdr in ipairs(vs.base_available_mod_header) do names[hdr.id] = hdr_name(hdr) end
    return names
end

local function available_ids(vs)
    local ids = {}
    for _, hdr in ipairs(vs.available_mod_header) do ids[hdr.id] = true end
    return ids
end

local function current_keys(vs)
    local keys = {}
    for i, hdr in ipairs(vs.object_load_order_mod_header) do
        keys[#keys + 1] = modkey(hdr.id, vs.object_load_order_numeric_version[i])
    end
    return keys
end

---------------------------------------------------------------------------
-- rewriting the lists

local function copy_entry(vs, prefix, i)
    local entry = {}
    for _, suffix in ipairs(FIELD_SUFFIXES) do
        local v = vs[prefix .. '_' .. suffix][i]
        entry[suffix] = type(v) == 'userdata' and v:new() or v
    end
    return entry
end

-- Makes the active (right) list exactly `keys` (id+version, in order) and
-- keeps the available (left) list consistent: mods taken out of the active
-- list go back to the left list, mods put in are taken out of it.
local function apply_active(vs, keys)
    local where = {}
    for _, prefix in ipairs{'object_load_order', 'available', 'base_available'} do
        for i, hdr in ipairs(vs[prefix .. '_mod_header']) do
            local k = modkey(hdr.id, vs[prefix .. '_numeric_version'][i])
            if not where[k] then where[k] = {prefix=prefix, i=i} end
        end
    end
    local base_order = {}
    for i, hdr in ipairs(vs.base_available_mod_header) do
        base_order[modkey(hdr.id, vs.base_available_numeric_version[i])] = i
    end

    local new_active, active_ids, in_new = {}, {}, {}
    for _, k in ipairs(keys) do
        local w = where[k]
        if w and not in_new[k] then
            in_new[k] = true
            new_active[#new_active + 1] = copy_entry(vs, w.prefix, w.i)
            active_ids[key_id(k)] = true
        end
    end

    -- left list = what was there + what left the active list, minus what's
    -- active now (DF hides other versions of an active mod)
    local avail_keys, seen = {}, {}
    local function add_avail(k)
        if seen[k] or in_new[k] or active_ids[key_id(k)] then return end
        seen[k] = true
        avail_keys[#avail_keys + 1] = k
    end
    for _, k in ipairs(current_keys(vs)) do add_avail(k) end
    for i, hdr in ipairs(vs.available_mod_header) do
        add_avail(modkey(hdr.id, vs.available_numeric_version[i]))
    end
    table.sort(avail_keys, function(a, b)
        return (base_order[a] or math.huge) < (base_order[b] or math.huge)
    end)
    local new_avail = {}
    for _, k in ipairs(avail_keys) do
        local w = where[k]
        if w then new_avail[#new_avail + 1] = copy_entry(vs, w.prefix, w.i) end
    end

    for _, pair in ipairs{{'object_load_order', new_active}, {'available', new_avail}} do
        local prefix, entries = pair[1], pair[2]
        for _, suffix in ipairs(FIELD_SUFFIXES) do
            local vec = vs[prefix .. '_' .. suffix]
            for i = #vec - 1, 0, -1 do vec:erase(i) end
            for _, e in ipairs(entries) do vec:insert('#', e[suffix]) end
        end
    end
end

---------------------------------------------------------------------------
-- undo

-- State lives in a global so it survives the script being re-run (running
-- the command re-executes this file in the same environment as the module).
STATE = STATE or {}
STATE.undo_stack = STATE.undo_stack or {}
STATE.scan_cache = STATE.scan_cache or {}
STATE.guard = STATE.guard or {armed_until=0}

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function push_undo(vs, label)
    local addr = tostring(vs)
    if STATE.undo_screen ~= addr then STATE.undo_stack, STATE.undo_screen = {}, addr end
    table.insert(STATE.undo_stack, {keys=current_keys(vs), label=label})
    if #STATE.undo_stack > 30 then table.remove(STATE.undo_stack, 1) end
end

function can_undo()
    local vs = get_mod_screen()
    return vs ~= nil and STATE.undo_screen == tostring(vs) and #STATE.undo_stack > 0
end

function undo()
    local vs = get_mod_screen()
    if not can_undo() then return false, 'Nothing to undo.' end
    local entry = table.remove(STATE.undo_stack)
    apply_active(vs, entry.keys)
    return true, 'Undid: ' .. entry.label
end

-- Applies a new active list, recording an undo step if anything changed.
local function commit(vs, keys, label)
    if same_list(keys, current_keys(vs)) then return false end
    push_undo(vs, label)
    apply_active(vs, keys)
    return true
end

---------------------------------------------------------------------------
-- declared rules

-- Ordering edges among active mods: {first=id, second=id, owner=id}
local function build_edges(mods)
    local by_id = index_mods(mods)
    local edges, seen = {}, {}
    local function add(first, second, owner)
        if not by_id[first] or not by_id[second] or first == second then return end
        local k = first .. '\0' .. second
        if seen[k] then return end
        seen[k] = true
        table.insert(edges, {first=first, second=second, owner=owner})
    end
    for _, m in ipairs(mods) do
        for _, id in ipairs(m.after) do add(id, m.id, m.id) end
        for _, id in ipairs(m.before) do add(m.id, id, m.id) end
    end
    return edges
end

local function positions(order)
    local pos = {}
    for i, id in ipairs(order) do pos[id] = i end
    return pos
end

local function find_violations(order, edges)
    local pos, bad = positions(order), {}
    for _, e in ipairs(edges) do
        if pos[e.first] and pos[e.second] and pos[e.first] > pos[e.second] then
            table.insert(bad, e)
        end
    end
    return bad
end

-- Problems with the declared rules: {kind='order'|'missing'|'conflict', text=, id=}
local function analyze(vs)
    local mods = read_active(vs)
    local by_id = index_mods(mods)
    local names, avail = known_names(vs), available_ids(vs)
    local function nm(id) return by_id[id] and by_id[id].name or names[id] or id end
    local order = {}
    for _, m in ipairs(mods) do order[#order + 1] = m.id end

    local issues = {}
    for _, e in ipairs(find_violations(order, build_edges(mods))) do
        local text
        if e.owner == e.second then
            text = ('%s must be after %s'):format(nm(e.second), nm(e.first))
        else
            text = ('%s must be before %s'):format(nm(e.first), nm(e.second))
        end
        table.insert(issues, {kind='order', text=text})
    end

    local seen_conflict = {}
    for _, m in ipairs(mods) do
        for _, list in ipairs{m.after, m.before, m.requires} do
            for _, id in ipairs(list) do
                if not by_id[id] then
                    local where = avail[id] and 'in the left list - add it'
                        or names[id] and 'installed but not listed'
                        or 'not installed'
                    table.insert(issues, {kind='missing', id=id, installed=names[id] ~= nil,
                        text=('%s needs %s (%s)'):format(m.name, nm(id), where)})
                end
            end
        end
        for _, id in ipairs(m.conflicts) do
            local k = m.id < id and (m.id .. '\0' .. id) or (id .. '\0' .. m.id)
            if by_id[id] and id ~= m.id and not seen_conflict[k] then
                seen_conflict[k] = true
                table.insert(issues, {kind='conflict',
                    text=('%s conflicts with %s'):format(m.name, nm(id))})
            end
        end
    end
    return issues
end

function check(vs)
    vs = vs or get_mod_screen()
    if not vs then return nil end
    return analyze(vs)
end

---------------------------------------------------------------------------
-- newer installed versions

-- {id=, name=, from=displayed, to=displayed, old_key=, new_key=}
function find_updates(vs)
    vs = vs or get_mod_screen()
    if not vs then return {} end
    local newest = {}
    for i, hdr in ipairs(vs.base_available_mod_header) do
        local v = vs.base_available_numeric_version[i]
        local cur = newest[hdr.id]
        if not cur or v > cur.version then
            newest[hdr.id] = {version=v, displayed=hdr.displayed_version}
        end
    end
    local updates = {}
    for _, m in ipairs(read_active(vs)) do
        local n = newest[m.id]
        if n and n.version > m.version then
            table.insert(updates, {id=m.id, name=m.name, from=m.displayed_version,
                to=n.displayed, old_key=m.key, new_key=modkey(m.id, n.version)})
        end
    end
    return updates
end

function use_newest(vs)
    vs = vs or get_mod_screen()
    local updates = find_updates(vs)
    if #updates == 0 then return false, 'All active mods are the newest installed version.' end
    local swap = {}
    for _, u in ipairs(updates) do swap[u.old_key] = u.new_key end
    local keys = current_keys(vs)
    for i, k in ipairs(keys) do keys[i] = swap[k] or k end
    commit(vs, keys, 'use newest versions')
    local names = {}
    for _, u in ipairs(updates) do table.insert(names, ('%s %s -> %s'):format(u.name, u.from, u.to)) end
    return true, 'Updated: ' .. table.concat(names, ', ')
end

---------------------------------------------------------------------------
-- raw file scan (hidden conflicts and suggestions)

-- object type -> tokens that define an object of that type
local DEFINE_TOKENS = {
    CREATURE={'CREATURE'},
    ITEM={'ITEM_WEAPON', 'ITEM_ARMOR', 'ITEM_HELM', 'ITEM_GLOVES', 'ITEM_SHOES',
        'ITEM_PANTS', 'ITEM_SHIELD', 'ITEM_AMMO', 'ITEM_SIEGEAMMO', 'ITEM_TRAPCOMP',
        'ITEM_TOOL', 'ITEM_TOY', 'ITEM_INSTRUMENT', 'ITEM_FOOD'},
    INORGANIC={'INORGANIC'}, PLANT={'PLANT'}, BODY={'BODY', 'BODYGLOSS'},
    ENTITY={'ENTITY'}, REACTION={'REACTION'}, INTERACTION={'INTERACTION'},
    MATERIAL_TEMPLATE={'MATERIAL_TEMPLATE'}, TISSUE_TEMPLATE={'TISSUE_TEMPLATE'},
    BODY_DETAIL_PLAN={'BODY_DETAIL_PLAN'}, CREATURE_VARIATION={'CREATURE_VARIATION'},
    LANGUAGE={'WORD', 'SYMBOL', 'TRANSLATION'}, DESCRIPTOR_COLOR={'COLOR'},
    DESCRIPTOR_SHAPE={'SHAPE'}, DESCRIPTOR_PATTERN={'COLOR_PATTERN'},
    BUILDING={'BUILDING_WORKSHOP', 'BUILDING_FURNACE'},
}
local DEFINES = {}
for obj, toks in pairs(DEFINE_TOKENS) do
    DEFINES[obj] = {}
    for _, t in ipairs(toks) do DEFINES[obj][t] = true end
end
local NOT_EDIT_TARGETS = {CASTE=true, ADDITIONAL_CASTE=true, MATERIAL=true,
    TISSUE=true, TISSUE_LAYER=true, BP=true}

local ITEM_GRAPHICS = {}
for _, t in ipairs{'ARMOR', 'HELM', 'GLOVES', 'SHOES', 'PANTS', 'SHIELD', 'WEAPON',
        'AMMO', 'SIEGEAMMO', 'TRAPCOMP', 'TOOL', 'TOY', 'INSTRUMENT', 'FOOD'} do
    ITEM_GRAPHICS[t .. '_GRAPHICS'] = true
end

local function norm_type(t) return t:startswith('ITEM') and 'ITEM' or t end

local function key_kind(k)
    return k:match('^([^:]+):(.*)$')
end

local scan_cache = STATE.scan_cache -- path -> result

local function scan_file(path, res)
    local f = io.open(path, 'rb')
    if not f then return end
    local text = f:read('a')
    f:close()
    local obj
    for tok, rest in text:gmatch('%[([%u_]+):?([^%]]*)') do
        local arg = rest:match('^[^:]*')
        if tok == 'OBJECT' then
            obj = arg
        elseif arg ~= '' then
            local defs = obj and DEFINES[obj]
            if defs and defs[tok] then
                res.defs[norm_type(tok) .. ':' .. arg] = true
            elseif (obj == 'TILE_PAGE' and tok == 'TILE_PAGE')
                    or (obj == 'GRAPHICS' and tok:endswith('_GRAPHICS')
                        and tok ~= 'TILE_GRAPHICS' and tok ~= 'LAYER_GRAPHICS') then
                -- item graphics name the item last: [HELM_GRAPHICS:page:x:y:ITEM_HELM_CAP]
                if ITEM_GRAPHICS[tok] then arg = rest:match('([^:]*)$') end
                res.gfx[tok .. ':' .. arg] = true
            else
                local verb, typ = tok:match('^(%u+)_([%u_]+)$')
                if (verb == 'SELECT' or verb == 'CUT') and not NOT_EDIT_TARGETS[typ] then
                    local k = norm_type(typ) .. ':' .. arg
                    res.edits[k] = true
                    if verb == 'CUT' then res.cuts[k] = true end
                end
            end
        end
    end
end

local function scan_mod(path)
    if scan_cache[path] then return scan_cache[path] end
    local res = {defs={}, gfx={}, edits={}, cuts={}}
    for _, sub in ipairs{'objects', 'graphics'} do
        local dir = path .. '/' .. sub
        if dfhack.filesystem.isdir(dir) then
            for _, f in ipairs(dfhack.filesystem.listdir_recursive(dir, 10, true) or {}) do
                if not f.isdir and f.path:lower():endswith('.txt') then
                    scan_file(f.path, res)
                end
            end
        end
    end
    scan_cache[path] = res
    return res
end

function is_scanned(vs)
    vs = vs or get_mod_screen()
    if not vs then return false end
    for _, hdr in ipairs(vs.object_load_order_mod_header) do
        if not scan_cache[hdr.absolute_path] then return false end
    end
    return true
end

function clear_scan_cache()
    for k in pairs(scan_cache) do scan_cache[k] = nil end
    STATE.scanned_once = false
end

-- Returns {duplicates=, hidden=, suggestions=} for the current active list.
--   duplicates:  both mods define the same object (DF reports duplicates)
--   hidden:      a mod's graphics are hidden by an earlier non-vanilla mod
--   suggestions: {first=id, second=id, ...} order changes that would help
function scan(vs)
    vs = vs or get_mod_screen()
    if not vs then return nil end
    local mods = read_active(vs)
    local data = {}
    for _, m in ipairs(mods) do data[m.id] = scan_mod(m.path) end
    STATE.scanned_once = true

    -- who defines what, in load order
    local definers, providers = {}, {}
    for _, m in ipairs(mods) do
        for k in pairs(data[m.id].defs) do
            definers[k] = definers[k] or {}
            table.insert(definers[k], m)
        end
        for k in pairs(data[m.id].gfx) do
            providers[k] = providers[k] or {}
            table.insert(providers[k], m)
        end
    end

    local function bump(tbl, key, init, example)
        local e = tbl[key]
        if not e then e = init; e.n = 0; e.example = example; tbl[key] = e end
        e.n = e.n + 1
    end

    -- duplicate object definitions: fine if the later mod cuts the object first
    local dup = {}
    for k, ds in pairs(definers) do
        for i = 2, #ds do
            local a, b = ds[1], ds[i]
            if not data[b.id].cuts[k] then
                bump(dup, a.id .. '\0' .. b.id, {a=a, b=b}, k)
            end
        end
    end

    -- graphics: the first mod to define something wins
    local hidden, sugg = {}, {}
    for k, ps in pairs(providers) do
        local first = ps[1]
        for i = 2, #ps do
            local p = ps[i]
            if not p.vanilla then
                if first.vanilla then
                    bump(sugg, p.id .. '\0' .. first.id .. '\0gfx',
                        {first=p.id, second=first.id, mod=p, other=first, why='gfx'}, k)
                else
                    bump(hidden, p.id .. '\0' .. first.id, {mod=p, by=first}, k)
                end
            end
        end
    end

    -- edits (SELECT_/CUT_) have to load after the mod that defines the object
    for _, m in ipairs(mods) do
        for k in pairs(data[m.id].edits) do
            for _, d in ipairs(definers[k] or {}) do
                if d.id ~= m.id and d.pos > m.pos then
                    bump(sugg, d.id .. '\0' .. m.id .. '\0edit',
                        {first=d.id, second=m.id, mod=m, other=d, why='edit'}, k)
                end
            end
        end
    end

    local function sorted(tbl)
        local out = {}
        for _, v in pairs(tbl) do out[#out + 1] = v end
        table.sort(out, function(x, y) return x.n > y.n end)
        return out
    end

    local suggestions = sorted(sugg)
    for _, s in ipairs(suggestions) do
        local t, id = key_kind(s.example)
        if s.why == 'gfx' then
            s.text = ('%s should load above %s (%s hidden, e.g. %s %s)')
                :format(s.mod.name, s.other.name, plural(s.n, 'of its graphics is', true), t:lower(), id)
        else
            s.text = ('%s should load below %s (it edits %s from it, e.g. %s %s)')
                :format(s.mod.name, s.other.name, plural(s.n, 'object'), t:lower(), id)
        end
    end
    local duplicates = sorted(dup)
    for _, d in ipairs(duplicates) do
        local t, id = key_kind(d.example)
        d.text = ('%s and %s both define %s (e.g. %s %s) - DF will report duplicate objects')
            :format(d.a.name, d.b.name, plural(d.n, 'object'), t:lower(), id)
    end
    local hidden_list = sorted(hidden)
    for _, h in ipairs(hidden_list) do
        local t, id = key_kind(h.example)
        h.text = ('%s: %s hidden by %s, which loads first (e.g. %s %s). Move it above if you prefer its look.')
            :format(h.mod.name, plural(h.n, 'graphic', true), h.by.name, t:lower(), id)
    end
    return {duplicates=duplicates, hidden=hidden_list, suggestions=suggestions}
end

-- Scan only if it's cheap: after the first full scan, mods added since then
-- (or switched to another version) are scanned on the fly. Used by the
-- overlay, the Create world check and the mod info window.
local function scan_if_cached(vs)
    if STATE.scanned_once or is_scanned(vs) then return scan(vs) end
end

---------------------------------------------------------------------------
-- fixing the order

local function move(order, from, to)
    local id = table.remove(order, from)
    if to > from then to = to - 1 end
    table.insert(order, to, id)
end

local function moved_copy(order, from, to)
    local copy = {table.unpack(order)}
    move(copy, from, to)
    return copy
end

-- Moves mods the way a person would: each step tries every move that fixes
-- one broken rule (move A just above B, or B just below A) and takes the one
-- leaving the fewest broken rules, preferring to move non-vanilla mods and to
-- move them the shortest distance.
local function fix_by_moves(order, edges, vanilla)
    local visited = {[table.concat(order, '\0')] = true}
    for _ = 1, 300 do
        local bad = find_violations(order, edges)
        if #bad == 0 then return true end
        local pos = positions(order)
        local best, best_score
        for _, e in ipairs(bad) do
            local a, b = pos[e.first], pos[e.second] -- a > b; need first before second
            for _, c in ipairs{
                {order=moved_copy(order, a, b), mover=e.first},      -- first up above second
                {order=moved_copy(order, b, a + 1), mover=e.second}, -- second down below first
            } do
                local k = table.concat(c.order, '\0')
                if not visited[k] then
                    local score = #find_violations(c.order, edges) * 100000
                        + (vanilla[c.mover] and 10000000 or 0) + (a - b)
                    if not best_score or score < best_score then best, best_score = c, score end
                end
            end
        end
        if not best then return false end
        visited[table.concat(best.order, '\0')] = true
        for i, id in ipairs(best.order) do order[i] = id end
    end
    return false
end

-- Fallback: stable topological sort. Returns false if the rules have a cycle.
local function fix_by_toposort(order, edges)
    local pos = positions(order)
    local indeg, out = {}, {}
    for _, id in ipairs(order) do indeg[id], out[id] = 0, {} end
    for _, e in ipairs(edges) do
        table.insert(out[e.first], e.second)
        indeg[e.second] = indeg[e.second] + 1
    end
    local result, done = {}, {}
    while #result < #order do
        local pick
        for _, id in ipairs(order) do
            if not done[id] and indeg[id] == 0 and (not pick or pos[id] < pos[pick]) then pick = id end
        end
        if not pick then return false end
        done[pick] = true
        table.insert(result, pick)
        for _, nxt in ipairs(out[pick]) do indeg[nxt] = indeg[nxt] - 1 end
    end
    for i, id in ipairs(result) do order[i] = id end
    return true
end

-- Which ids actually changed place? The longest run of ids kept in the same
-- relative order didn't move; everything else did. `skip` ids are ignored.
local function moved_ids(old, new, skip)
    skip = skip or {}
    local a, b = {}, {}
    for _, id in ipairs(old) do if not skip[id] then a[#a + 1] = id end end
    for _, id in ipairs(new) do if not skip[id] then b[#b + 1] = id end end
    local n, m = #a, #b
    local dp = {}
    for i = 0, n do dp[i] = {[0]=0} end
    for j = 0, m do dp[0][j] = 0 end
    for i = 1, n do
        for j = 1, m do
            dp[i][j] = a[i] == b[j] and dp[i - 1][j - 1] + 1 or math.max(dp[i - 1][j], dp[i][j - 1])
        end
    end
    local kept, i, j = {}, n, m
    while i > 0 and j > 0 do
        if a[i] == b[j] then kept[a[i]] = true; i, j = i - 1, j - 1
        elseif dp[i - 1][j] >= dp[i][j - 1] then i = i - 1
        else j = j - 1 end
    end
    local moved = {}
    for _, id in ipairs(b) do if not kept[id] then moved[#moved + 1] = id end end
    return moved
end

local function is_acyclic(ids, edges)
    return fix_by_toposort({table.unpack(ids)}, edges)
end

-- Reorders the active list to satisfy the declared rules plus `extra_edges`.
-- Returns ok, moved_names, message. Pass no_undo=true when the caller has
-- already recorded an undo step.
local function reorder(vs, extra_edges, label, no_undo)
    local mods = read_active(vs)
    local edges = build_edges(mods)
    for _, e in ipairs(extra_edges or {}) do table.insert(edges, e) end
    local order, vanilla, by_id = {}, {}, {}
    for _, m in ipairs(mods) do
        order[#order + 1] = m.id
        vanilla[m.id] = m.vanilla
        by_id[m.id] = m
    end
    if #find_violations(order, edges) == 0 then
        return true, {}, 'Load order is already correct.'
    end
    local original = {table.unpack(order)}
    if not fix_by_moves(order, edges, vanilla) then
        order = {table.unpack(original)}
        if not fix_by_toposort(order, edges) then
            return false, {}, 'Could not fix: some mods have circular before/after rules.'
        end
    end

    local moved = {}
    for _, id in ipairs(moved_ids(original, order)) do table.insert(moved, by_id[id].name) end
    local keys = {}
    for i, id in ipairs(order) do keys[i] = by_id[id].key end
    if no_undo then apply_active(vs, keys) else commit(vs, keys, label or 'fix order') end
    return true, moved, ('Fixed load order (%s moved).'):format(plural(#moved, 'mod'))
end

function fix(vs)
    vs = vs or get_mod_screen()
    if not vs then return false, {}, 'Not on the mod screen.' end
    return reorder(vs, nil, 'fix order')
end

-- Moves one mod just above (or below) another, then fixes anything that
-- breaks the mods' own rules. Returns ok, message.
function move_relative(vs, mod_id, other_id, where)
    vs = vs or get_mod_screen()
    local mods = read_active(vs)
    local by_id = index_mods(mods)
    local m, o = by_id[mod_id], by_id[other_id]
    if not m or not o then return false, 'That mod is no longer active.' end
    local want = where == 'above' and {first=mod_id, second=other_id} or {first=other_id, second=mod_id}
    local edges = build_edges(mods)
    table.insert(edges, want)
    local order, vanilla = {}, {}
    for _, x in ipairs(mods) do order[#order + 1] = x.id; vanilla[x.id] = x.vanilla end
    if not is_acyclic(order, edges) then
        return false, ('Can\'t move %s %s %s: the mods\' own load-order rules don\'t allow it.')
            :format(m.name, where, o.name)
    end
    local original = {table.unpack(order)}
    -- the move itself
    local from = positions(order)[mod_id]
    table.remove(order, from)
    local to = positions(order)[other_id]
    table.insert(order, where == 'above' and to or to + 1, mod_id)
    -- then whatever else the rules need
    if #find_violations(order, edges) > 0 and not fix_by_moves(order, edges, vanilla) then
        order = {table.unpack(original)}
        fix_by_toposort(order, edges)
    end
    -- also moved: mods that changed sides relative to the target mod, plus
    -- any other reshuffling
    local also, seen = {}, {[mod_id]=true, [other_id]=true}
    local op, np = positions(original), positions(order)
    local function add(id) if not seen[id] then seen[id] = true; table.insert(also, by_id[id].name) end end
    for _, id in ipairs(order) do
        if not seen[id] and (op[id] < op[other_id]) ~= (np[id] < np[other_id]) then add(id) end
    end
    for _, id in ipairs(moved_ids(original, order, {[mod_id]=true, [other_id]=true})) do add(id) end
    local keys = {}
    for i, id in ipairs(order) do keys[i] = by_id[id].key end
    commit(vs, keys, ('move %s %s %s'):format(m.name, where, o.name))
    local msg = ('Moved %s %s %s.'):format(m.name, where, o.name)
    if #also > 0 then msg = msg .. (' Also moved %s to keep its rules.'):format(table.concat(also, ', ')) end
    return true, msg .. ' (u undoes it)'
end

-- Applies scan suggestions that don't contradict the declared rules.
function apply_suggestions(vs)
    vs = vs or get_mod_screen()
    local result = scan(vs)
    if not result or #result.suggestions == 0 then return true, {}, 'No suggestions to apply.' end
    local mods = read_active(vs)
    local ids = {}
    for _, m in ipairs(mods) do ids[#ids + 1] = m.id end
    local edges, extra, skipped = build_edges(mods), {}, 0
    for _, s in ipairs(result.suggestions) do
        table.insert(edges, {first=s.first, second=s.second})
        if is_acyclic(ids, edges) then
            table.insert(extra, {first=s.first, second=s.second})
        else
            table.remove(edges)
            skipped = skipped + 1
        end
    end
    local ok, moved, msg = reorder(vs, extra, 'apply suggestions')
    if ok and #moved > 0 then msg = ('Applied suggestions (%s moved).'):format(plural(#moved, 'mod')) end
    if skipped > 0 then
        msg = msg .. (' Skipped %s that clash with mod rules.'):format(plural(skipped, 'suggestion'))
    end
    return ok, moved, msg
end

---------------------------------------------------------------------------
-- conflicts

-- One entry per active mod involved in a declared conflict:
-- {id=, name=, checked=, with={names}, needed_by={names}}
-- `checked` is the suggestion: for each pair, remove the mod *named* in the
-- other's conflict list (usually what an overhaul replaces), unless other
-- active mods depend on it.
function conflict_plan(vs)
    vs = vs or get_mod_screen()
    if not vs then return {} end
    local mods = read_active(vs)
    local by_id = index_mods(mods)

    local needed_by = {}
    for _, m in ipairs(mods) do
        for _, list in ipairs{m.after, m.before, m.requires} do
            for _, id in ipairs(list) do
                if by_id[id] then
                    needed_by[id] = needed_by[id] or {}
                    table.insert(needed_by[id], m.name)
                end
            end
        end
    end

    local pairs_list, seen, involved = {}, {}, {}
    for _, m in ipairs(mods) do
        for _, id in ipairs(m.conflicts) do
            local k = m.id < id and (m.id .. '\0' .. id) or (id .. '\0' .. m.id)
            if by_id[id] and id ~= m.id and not seen[k] then
                seen[k] = true
                table.insert(pairs_list, {declarer=m.id, target=id})
                involved[m.id] = involved[m.id] or {}
                involved[id] = involved[id] or {}
                table.insert(involved[m.id], by_id[id].name)
                table.insert(involved[id], m.name)
            end
        end
    end

    local remove = {}
    for _, p in ipairs(pairs_list) do
        if not remove[p.declarer] and not remove[p.target] then
            local victim = p.target
            if needed_by[victim] and not needed_by[p.declarer] then victim = p.declarer end
            remove[victim] = true
        end
    end

    local entries = {}
    for _, m in ipairs(mods) do
        if involved[m.id] then
            table.insert(entries, {id=m.id, name=m.name, checked=remove[m.id] or false,
                with=involved[m.id], needed_by=needed_by[m.id] or {}})
        end
    end
    return entries
end

-- Moves the given active mods back to the left list. Returns their names.
function remove_mods(vs, ids, no_undo)
    vs = vs or get_mod_screen()
    local want = {}
    for _, id in ipairs(ids) do want[id] = true end
    local keys, removed = {}, {}
    for _, m in ipairs(read_active(vs)) do
        if want[m.id] then table.insert(removed, m.name) else keys[#keys + 1] = m.key end
    end
    if no_undo then apply_active(vs, keys) else commit(vs, keys, 'remove conflicting mods') end
    return removed
end

---------------------------------------------------------------------------
-- presets (shared with DFHack's gui/mod-manager)

local function open_presets()
    local ok, f = pcall(json.open, PRESETS_FILE)
    if ok and f then
        if type(f.data) ~= 'table' then f.data = {} end
        return f
    end
end

function preset_names()
    local f = open_presets()
    local names, default = {}, nil
    for _, p in ipairs(f and f.data or {}) do
        table.insert(names, p.name)
        if p.default and not default then default = p.name end
    end
    return names, default
end

function save_preset(vs, name)
    vs = vs or get_mod_screen()
    local f = open_presets()
    if not f then return false, 'Could not open ' .. PRESETS_FILE end
    local modlist = {}
    for _, m in ipairs(read_active(vs)) do
        table.insert(modlist, {id=m.id, version=m.version})
    end
    local vanilla = {}
    for i, hdr in ipairs(vs.base_available_mod_header) do
        if vs.base_available_src_dir[i]:startswith('data/vanilla') then table.insert(vanilla, hdr.id) end
    end
    local existing
    for _, p in ipairs(f.data) do if p.name == name then existing = p end end
    if existing then
        existing.modlist, existing.vanilla_mods = modlist, vanilla
    else
        table.insert(f.data, {name=name, modlist=modlist, vanilla_mods=vanilla})
    end
    f:write()
    return true, ('Saved preset "%s"%s.'):format(name,
        existing and existing.default and ' (your default - it will load like this next time)' or '')
end

---------------------------------------------------------------------------
-- missing mods: Workshop links

function missing_links(vs)
    local lines, seen = {}, {}
    for _, issue in ipairs(check(vs) or {}) do
        if issue.kind == 'missing' and not issue.installed and not seen[issue.id] then
            seen[issue.id] = true
            table.insert(lines, ('%s: %s'):format(issue.id, WORKSHOP_SEARCH:format(issue.id)))
        end
    end
    return lines
end

function copy_missing_links(vs)
    local lines = missing_links(vs)
    if #lines == 0 then return false, 'No missing mods that need downloading.' end
    dfhack.internal.setClipboardTextCp437Multiline(table.concat(lines, NEWLINE))
    return true, ('Copied %s to the clipboard - paste into your browser.'):format(
        plural(#lines, 'Workshop search link'))
end

---------------------------------------------------------------------------
-- UI helpers

local function wrap(text, width)
    local lines = {}
    width = math.max(width, 10)
    local line = ''
    for word in text:gmatch('%S+') do
        if #line == 0 then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. ' ' .. word
        else
            table.insert(lines, line)
            line = '    ' .. word
        end
        while #line > width do
            table.insert(lines, line:sub(1, width))
            line = '    ' .. line:sub(width + 1)
        end
    end
    table.insert(lines, line)
    return lines
end

-- Adds one line made of coloured segments ({text, pen}), wrapping long lines
-- with a deeper indent. Segments after the first should start with a space.
-- clickable links: which link the mouse is over (set by ClickLabel each frame)
HOVER = HOVER or {}
local LINK_HOVER_PEN = COLOR_YELLOW
local function link_pen(pen, action)
    if not action then return pen end
    return function() return HOVER.action == action and LINK_HOVER_PEN or pen end
end

local function add_segs(tokens, indent, segs, width)
    local cont = indent .. '  '
    table.insert(tokens, {text=indent})
    local x = #indent
    local pending = '' -- whitespace carried over from the end of the last segment
    for _, seg in ipairs(segs) do
        for space, word in seg[1]:gmatch('(%s*)(%S+)') do
            local piece = pending .. space .. word
            pending = ''
            if x + #piece > width and x > #cont then
                table.insert(tokens, NEWLINE)
                table.insert(tokens, {text=cont})
                x, piece = #cont, word
            end
            table.insert(tokens, {text=piece, pen=link_pen(seg[2], seg[3]), action=seg[3]})
            x = x + #piece
        end
        pending = pending .. (seg[1]:match('%s+$') or '')
    end
    local last = segs[#segs]
    if pending ~= '' and last and last[3] then -- keep a clickable button's right padding
        table.insert(tokens, {text=pending, pen=link_pen(last[2], last[3]), action=last[3]})
    end
    table.insert(tokens, NEWLINE)
end

local HLINE = string.char(196) -- thin horizontal box line in the DF font
local DOT = string.char(250)   -- small centred dot

-- Section header drawn as a divider:  ─── Title (3)  hint ──────────
local function section(tokens, width, title, count, hint)
    local segs = {{HLINE:rep(3) .. ' ', COLOR_GREY}, {title, COLOR_WHITE}}
    local used = 4 + #title
    if count then
        local c = (' (%d)'):format(count)
        table.insert(segs, {c, COLOR_GREY})
        used = used + #c
    end
    if hint and used + 2 + #hint + 4 <= width then
        table.insert(segs, {'  ' .. hint, COLOR_DARKGREY})
        used = used + 2 + #hint
        hint = nil
    end
    table.insert(segs, {' ' .. HLINE:rep(math.max(3, width - used - 1)), COLOR_GREY})
    for _, seg in ipairs(segs) do table.insert(tokens, {text=seg[1], pen=seg[2]}) end
    table.insert(tokens, NEWLINE)
    if hint then -- didn't fit on the divider line
        table.insert(tokens, {text='  ' .. hint, pen=COLOR_DARKGREY})
        table.insert(tokens, NEWLINE)
    end
end

-- faint dotted line between items inside a section
local function item_divider(tokens, width)
    table.insert(tokens, {text='    ' .. DOT:rep(math.max(3, width - 8)), pen=COLOR_DARKGREY})
    table.insert(tokens, NEWLINE)
end

-- 'TILE_PAGE:DWARF_BODY' -> 'tile page DWARF_BODY'
local FRIENDLY_TYPES = {TILE_PAGE='tile page', CREATURE_GRAPHICS='creature graphics',
    CREATURE_CASTE_GRAPHICS='creature graphics', STATUE_CREATURE_GRAPHICS='statue graphics',
    PLANT_GRAPHICS='plant graphics'}
local function friendly(k)
    local t, id = k:match('^([^:]+):(.*)$')
    local name = FRIENDLY_TYPES[t] or (ITEM_GRAPHICS[t] and 'item graphics') or (t:lower():gsub('_', ' '))
    return name .. ' ' .. id
end

-- adds wrapped, coloured lines to a token list
local function add_lines(tokens, text, pen, width)
    for _, l in ipairs(wrap(text, width)) do
        table.insert(tokens, {text=l, pen=pen})
        table.insert(tokens, NEWLINE)
    end
end

-- base class for our screens: keep keyboard focus (so Esc closes the window
-- rather than the game screen) and close when the Mods screen goes away
ModScreen = defclass(nil, gui.ZScreen)
ModScreen.ATTRS{defocusable=false}

function ModScreen:render(dc)
    if not get_mod_screen() then self:dismiss() return end
    ModScreen.super.render(self, dc)
end

---------------------------------------------------------------------------
-- conflict checklist

ConflictWindow = defclass(nil, widgets.Window)
ConflictWindow.ATTRS{
    frame_title='Remove Conflicting Mods',
    frame={w=100, h=22},
    resizable=true,
    resize_min={w=50, h=12},
    on_done=DEFAULT_NIL, -- called with the ticked ids
}

function ConflictWindow:init()
    self.entries = conflict_plan()
    self:addviews{
        widgets.WrappedLabel{
            frame={t=0, l=0, r=0},
            text_to_wrap='Ticked mods will be moved back to the left list. '
                .. 'Click a mod (or press Enter) to tick/untick it.',
        },
        widgets.List{
            view_id='list',
            frame={t=3, l=0, r=0, b=5},
            on_submit=function(idx) self:toggle(idx) end,
        },
        widgets.WrappedLabel{
            frame={b=2, l=0, r=0, h=2},
            text_pen=COLOR_YELLOW,
            text_to_wrap=function() return self:get_warning() end,
            auto_height=false,
        },
        widgets.HotkeyLabel{
            frame={b=0, l=0},
            key='CUSTOM_Y',
            label=function() return ('Remove %s'):format(plural(self:count_checked(), 'ticked mod')) end,
            auto_width=true,
            enabled=function() return self:count_checked() > 0 end,
            on_activate=function() self:confirm() end,
        },
        widgets.HotkeyLabel{
            frame={b=0, l=32},
            key='LEAVESCREEN',
            label='Cancel',
            auto_width=true,
            on_activate=function() self.parent_view:dismiss() end,
        },
    }
    self:refresh()
end

function ConflictWindow:count_checked()
    local n = 0
    for _, e in ipairs(self.entries) do if e.checked then n = n + 1 end end
    return n
end

function ConflictWindow:refresh()
    local choices = {}
    for _, e in ipairs(self.entries) do
        table.insert(choices, {text={
            {text=e.checked and '[x] ' or '[ ] ', pen=e.checked and COLOR_LIGHTRED or COLOR_GREY},
            {text=e.name, pen=e.checked and COLOR_LIGHTRED or COLOR_WHITE},
            {text='  conflicts with ' .. table.concat(e.with, ', '), pen=COLOR_GREY},
        }})
    end
    if #choices == 0 then choices = {{text='No conflicting mods in the active list.'}} end
    local sel = self.subviews.list:getSelected()
    self.subviews.list:setChoices(choices, sel)
    if self.frame_parent_rect then self:updateLayout() end
end

function ConflictWindow:toggle(idx)
    local e = self.entries[idx]
    if not e then return end
    e.checked = not e.checked
    self:refresh()
end

function ConflictWindow:get_warning()
    local checked = {}
    for _, e in ipairs(self.entries) do if e.checked then checked[e.name] = true end end
    local msgs, shown = {}, {}
    local function add(m) if not shown[m] then shown[m] = true; table.insert(msgs, m) end end
    for _, e in ipairs(self.entries) do
        if e.checked then
            for _, user in ipairs(e.needed_by) do
                if not checked[user] then add(('%s is needed by %s.'):format(e.name, user)) end
            end
        else
            local unresolved = {}
            for _, other in ipairs(e.with) do
                if not checked[other] then table.insert(unresolved, other) end
            end
            if #unresolved > 0 then
                add(('%s still conflicts with %s.'):format(e.name, table.concat(unresolved, ', ')))
            end
        end
    end
    return table.concat(msgs, ' ')
end

function ConflictWindow:confirm()
    local ids = {}
    for _, e in ipairs(self.entries) do if e.checked then table.insert(ids, e.id) end end
    if #ids == 0 then return end
    self.parent_view:dismiss()
    if self.on_done then self.on_done(ids) end
end

ConflictScreen = defclass(nil, ModScreen)
ConflictScreen.ATTRS{focus_path='mod-load-order/conflicts', on_done=DEFAULT_NIL}

function ConflictScreen:init()
    self:addviews{ConflictWindow{on_done=self.on_done}}
end

-- Opens the checklist; on confirm removes the ticked mods (one undo step)
-- and calls on_result(message).
function remove_conflicts_ui(on_result)
    ConflictScreen{on_done=function(ids)
        local removed = remove_mods(nil, ids)
        if on_result then on_result('Removed: ' .. table.concat(removed, ', ')) end
    end}:show()
end

-- Fix all: conflicts (one checklist) then load order, as a single undo step.
function fix_all_ui(on_result)
    on_result = on_result or function() end
    local vs = get_mod_screen()
    if not vs then return end
    local function finish(prefix, undo_pushed)
        local ok, moved, msg = reorder(vs, nil, 'fix all', undo_pushed)
        if #moved > 0 then msg = msg .. ' Moved: ' .. table.concat(moved, ', ') end
        on_result((prefix and (prefix .. ' ') or '') .. msg, ok and COLOR_GREEN or COLOR_LIGHTRED)
    end
    if #conflict_plan(vs) == 0 then return finish(nil, false) end
    ConflictScreen{on_done=function(ids)
        push_undo(vs, 'fix all')
        local removed = remove_mods(vs, ids, true)
        finish('Removed: ' .. table.concat(removed, ', ') .. '.', true)
    end}:show()
end

---------------------------------------------------------------------------
-- report builder: shared layout for all the tabs

local MARK = string.char(254) .. ' ' -- small square in the DF font
LINK_ARROW = string.char(16) -- small right-pointing triangle in the DF font

-- Wraps a token list with helpers for the layout used in every tab:
--   ─── Section (n)  hint ───────
--     [mark] Title line
--         detail line
--         e.g. example                  (dimmed)
--     · · · · · · · · · · ·             (between items)
local function Report(width)
    local r = {t={}, width=width, items=0}
    function r.section(title, count, hint)
        if #r.t > 0 then table.insert(r.t, NEWLINE) end
        section(r.t, width, title, count, hint)
        r.items = 0
    end
    function r.line(segs, indent)
        if type(segs) == 'string' then segs = {{segs, COLOR_WHITE}} end
        add_segs(r.t, indent or '  ', segs, width)
    end
    function r.item(marker_pen, segs)
        if r.items > 0 then item_divider(r.t, width) end
        r.items = r.items + 1
        table.insert(segs, 1, {MARK, marker_pen})
        add_segs(r.t, '  ', segs, width)
    end
    function r.detail(segs) add_segs(r.t, '      ', segs, width) end
    function r.example(k) r.detail{{'e.g. ' .. friendly(k), COLOR_DARKGREY}} end
    function r.blank() table.insert(r.t, NEWLINE) end
    return r
end

local function modpos(m) return ('%s (#%d)'):format(m.name, m.pos) end

-- Does the default Mod Manager preset hold exactly the current list?
-- Returns name, matches (name is nil when there's no default preset).
local function default_preset_status(vs)
    local f = open_presets()
    for _, p in ipairs(f and f.data or {}) do
        if p.default then
            local cur = read_active(vs)
            local same = type(p.modlist) == 'table' and #p.modlist == #cur
            if same then
                for i, m in ipairs(cur) do
                    local e = p.modlist[i]
                    if e.id ~= m.id or e.version ~= m.version then same = false break end
                end
            end
            return p.name, same
        end
    end
end

---------------------------------------------------------------------------
-- tab pages

-- A page: scrollable report on top, its own buttons at the bottom.
-- Subclasses implement build(report, vs) and list their buttons.
-- Label whose individual words can be clicked (tokens with an `action`).
ClickLabel = defclass(nil, widgets.Label)

function ClickLabel:shouldHover() return false end -- don't highlight the whole text

-- the link token under the mouse, if any
function ClickLabel:link_at_mouse()
    local x, y = self:getMousePos()
    if not x then return end
    local line = self.text_lines and self.text_lines[y + (self.start_line_num or 1)]
    for _, token in ipairs(line or {}) do
        local text = type(token.text) == 'string' and token.text or ''
        if token.action and token.x1 and x >= token.x1 and x < token.x1 + #text then
            return token.action
        end
    end
end

function ClickLabel:onRenderBody(dc)
    HOVER.action = self:link_at_mouse()
    ClickLabel.super.onRenderBody(self, dc)
end

function ClickLabel:onInput(keys)
    if keys._MOUSE_L then
        local action = self:link_at_mouse()
        if action then action() return true end
    end
    return ClickLabel.super.onInput(self, keys)
end

ReportPage = defclass(nil, widgets.Panel)
ReportPage.ATTRS{
    window=DEFAULT_NIL, -- the LoadOrderWindow, for messages and shared state
    buttons=DEFAULT_NIL, -- list of HotkeyLabel specs for this tab
}

function ReportPage:init()
    local has_buttons = self.buttons and #self.buttons > 0
    self:addviews{
        ClickLabel{
            view_id='body',
            frame={t=0, l=0, r=0, b=has_buttons and 2 or 0},
            auto_height=false,
            text='',
        },
    }
    if has_buttons then
        local x = 0
        for _, spec in ipairs(self.buttons) do
            spec.frame = {b=0, l=x}
            spec.auto_width = true
            self:addviews{widgets.HotkeyLabel(spec)}
            x = x + #spec.label + #gui.getKeyDisplay(spec.key) + 6
        end
    end
end

function ReportPage:postUpdateLayout()
    local vs = get_mod_screen()
    local body = self.subviews.body
    if not vs then body:setText('Not on the mod screen.') return end
    local width = (self.frame_body and self.frame_body.width or 100) - 3 -- room for scrollbar
    local r = Report(width)
    local ok, err = pcall(self.build, self, r, vs)
    if not ok then r.line{{'Error: ' .. tostring(err), COLOR_LIGHTRED}} end
    body:setText(r.t)
end

function ReportPage:build(r, vs) end

-- a clickable '► Move it above Y' link
function ReportPage:button(label, mod_id, other_id, where)
    return {LINK_ARROW .. ' ' .. label, COLOR_LIGHTGREEN, function()
        local ok, msg = move_relative(nil, mod_id, other_id, where)
        self.window:set_message(msg, ok and COLOR_GREEN or COLOR_LIGHTRED)
    end}
end

-- scan results, or nil while the first scan is still running
function ReportPage:scan_result(r, vs)
    if self.window.scanning then
        r.line{{'Scanning mod files...', COLOR_GREY}}
        return nil
    end
    local ok, result = pcall(scan_if_cached, vs)
    if not ok then r.line{{'Scan failed: ' .. tostring(result), COLOR_LIGHTRED}} return nil end
    return result
end

-------------------- Overview

OverviewPage = defclass(nil, ReportPage)

function OverviewPage:build(r, vs)
    local issues = check(vs)
    local counts = {order=0, missing=0, conflict=0}
    for _, i in ipairs(issues) do counts[i.kind] = counts[i.kind] + 1 end
    local updates = find_updates(vs)
    local result = not self.window.scanning and select(2, pcall(scan_if_cached, vs)) or nil
    if type(result) ~= 'table' then result = nil end

    r.section('Status')
    -- one row per check: name | state | what it means | where to look
    local function row(name, n, bad_pen, ok_text, bad_text, tab)
        local state, pen
        if n == nil then state, pen = 'scanning...', COLOR_GREY
        elseif n == 0 then state, pen = ok_text, COLOR_LIGHTGREEN
        else state, pen = bad_text:format(n), bad_pen end
        r.line({{('%-20s'):format(name), COLOR_WHITE}, {('%-34s'):format(state), pen},
            {n and n > 0 and ('see ' .. tab .. ' tab') or '', COLOR_DARKGREY}})
    end
    row('Load order', counts.order, COLOR_YELLOW, 'OK', '%d out of order', 'Problems')
    row('Required mods', counts.missing, COLOR_LIGHTRED, 'all present', '%d missing', 'Problems')
    row('Declared conflicts', counts.conflict, COLOR_LIGHTRED, 'none', '%d conflicting pairs', 'Problems')
    row('Duplicate objects', result and #result.duplicates, COLOR_LIGHTRED, 'none', '%d - worth fixing', 'Hidden conflicts')
    row('Graphics overlaps', result and #result.hidden, COLOR_YELLOW, 'none', '%d - not game-breaking', 'Hidden conflicts')
    row('Suggestions', result and #result.suggestions, COLOR_LIGHTCYAN, 'none', '%d available', 'Suggestions')
    row('Newer versions', #updates, COLOR_LIGHTCYAN, 'all up to date', '%d installed', 'Versions')

    r.section('Default preset')
    local name, same = default_preset_status(vs)
    if not name then
        r.line{{'No default preset. ', COLOR_GREY},
            {'p: Save preset', COLOR_LIGHTGREEN}, {', then mark it default in the Mod Manager (m)', COLOR_GREY}}
        r.line{{'to load this list automatically.', COLOR_GREY}}
    elseif same then
        r.line{{('"%s"'):format(name), COLOR_WHITE}, {' matches the current list - ', COLOR_GREY},
            {'this is what loads next time.', COLOR_LIGHTGREEN}}
    else
        r.line{{('"%s"'):format(name), COLOR_WHITE}, {' loads automatically and ', COLOR_GREY},
            {'is different from the current list.', COLOR_YELLOW}}
        r.line{{'Press ', COLOR_GREY}, {'p', COLOR_LIGHTGREEN}, {(' and keep the name "%s" to save this list over it.'):format(name), COLOR_GREY}}
    end

    r.section('Keys')
    local function key(k, text) r.line{{('%-4s'):format(k), COLOR_LIGHTGREEN}, {text, COLOR_GREY}} end
    key('a', 'Fix all: remove declared conflicts (asks first), then fix the load order')
    key('u', 'Undo the last change made here')
    key('p', 'Save the current list as a Mod Manager preset')
    key('r', 'Rescan the mods\' raw files')
    r.line{{'Ctrl-T / Ctrl-Y or click a tab to switch tabs.', COLOR_DARKGREY}}
end

-------------------- Problems

ProblemsPage = defclass(nil, ReportPage)

function ProblemsPage:build(r, vs)
    local issues = check(vs)
    local by_kind = {order={}, missing={}, conflict={}}
    for _, i in ipairs(issues) do table.insert(by_kind[i.kind], i) end

    r.section('Load order', #by_kind.order > 0 and #by_kind.order or nil, 'f fixes these')
    if #by_kind.order == 0 then r.line{{'OK - every before/after rule is satisfied.', COLOR_GREEN}} end
    for _, i in ipairs(by_kind.order) do r.item(COLOR_YELLOW, {{i.text, COLOR_WHITE}}) end

    r.section('Missing required mods', #by_kind.missing > 0 and #by_kind.missing or nil)
    if #by_kind.missing == 0 then r.line{{'None.', COLOR_GREEN}} end
    for _, i in ipairs(by_kind.missing) do
        r.item(COLOR_LIGHTRED, {{i.text, COLOR_WHITE}})
        if not i.installed then
            r.detail{{'Not installed - ', COLOR_GREY}, {'l', COLOR_LIGHTGREEN}, {' copies a Workshop search link.', COLOR_GREY}}
        end
    end

    r.section('Declared conflicts', #by_kind.conflict > 0 and #by_kind.conflict or nil, 'c removes one of each pair')
    if #by_kind.conflict == 0 then r.line{{'None.', COLOR_GREEN}} end
    for _, i in ipairs(by_kind.conflict) do r.item(COLOR_LIGHTRED, {{i.text, COLOR_WHITE}}) end
end

-------------------- Hidden conflicts

HiddenPage = defclass(nil, ReportPage)

function HiddenPage:build(r, vs)
    r.line{{'Found by reading the mods\' raw files: things two mods both define.', COLOR_GREY}}
    local result = self:scan_result(r, vs)
    if not result then return end

    r.section('Duplicate objects', #result.duplicates > 0 and #result.duplicates or nil, 'worth fixing')
    if #result.duplicates == 0 then
        r.line{{'None.', COLOR_GREEN}}
    else
        r.line{{'DF reports these as errors when it loads the mods.', COLOR_LIGHTRED}}
        r.blank()
    end
    for _, d in ipairs(result.duplicates) do
        r.item(COLOR_LIGHTRED, {{modpos(d.a), COLOR_WHITE}, {' and ', COLOR_GREY}, {modpos(d.b), COLOR_WHITE}})
        r.detail{{'Both define the same ', COLOR_GREY}, {plural(d.n, 'object'), COLOR_LIGHTRED}, {'.', COLOR_GREY}}
        r.example(d.example)
        r.detail{{'Fix: ', COLOR_GREY}, {'remove one of them', COLOR_LIGHTGREEN}, {' (move it to the left list).', COLOR_GREY}}
    end

    r.section('Graphics overlaps', #result.hidden > 0 and #result.hidden or nil, 'optional')
    if #result.hidden == 0 then
        r.line{{'None.', COLOR_GREEN}}
    else
        r.line{{'Not game-breaking if left alone', COLOR_LIGHTGREEN},
            {' - the mod that loads first decides the look.', COLOR_GREY}}
        r.line{{'Click a ', COLOR_GREY}, {LINK_ARROW .. ' Move', COLOR_LIGHTGREEN}, {' link to move just that mod; u undoes it.', COLOR_GREY}}
        r.blank()
    end
    for _, h in ipairs(result.hidden) do
        r.item(COLOR_YELLOW, {{modpos(h.mod), COLOR_WHITE}})
        r.detail{{plural(h.n, 'graphic', true), COLOR_YELLOW}, {' hidden by ', COLOR_GREY},
            {modpos(h.by), COLOR_LIGHTCYAN}, {', which loads first.', COLOR_GREY}}
        r.example(h.example)
        r.detail{{'Prefer its look?  ', COLOR_GREY},
            self:button('Move it above ' .. h.by.name, h.mod.id, h.by.id, 'above')}
    end
end

-------------------- Suggestions

SuggestionsPage = defclass(nil, ReportPage)

function SuggestionsPage:build(r, vs)
    r.line{{'For mods that declare no load-order rules, based on what their raw files do.', COLOR_GREY}}
    r.line{{'Never applied automatically - click a ', COLOR_GREY}, {LINK_ARROW .. ' Move', COLOR_LIGHTGREEN},
        {' link to apply one, or press ', COLOR_GREY}, {'s', COLOR_LIGHTGREEN}, {' to apply them all.', COLOR_GREY}}
    local result = self:scan_result(r, vs)
    if not result then return end
    r.section('Suggestions', #result.suggestions > 0 and #result.suggestions or nil)
    if #result.suggestions == 0 then r.line{{'None - nothing to suggest.', COLOR_GREEN}} end
    for _, s in ipairs(result.suggestions) do
        r.item(COLOR_LIGHTCYAN, {{modpos(s.mod), COLOR_WHITE}})
        if s.why == 'gfx' then
            r.detail{{'-> Move above ', COLOR_LIGHTGREEN}, {modpos(s.other), COLOR_LIGHTCYAN}}
            r.detail{{'Why: ', COLOR_GREY}, {plural(s.n, 'of its graphics is', true), COLOR_YELLOW},
                {' hidden while it loads after that mod.', COLOR_GREY}}
        else
            r.detail{{'-> Move below ', COLOR_LIGHTGREEN}, {modpos(s.other), COLOR_LIGHTCYAN}}
            r.detail{{'Why: it edits ', COLOR_GREY}, {plural(s.n, 'object'), COLOR_YELLOW},
                {' that mod defines, so it has to load after it.', COLOR_GREY}}
        end
        r.example(s.example)
        r.detail{self:button(('Move it %s %s'):format(s.why == 'gfx' and 'above' or 'below', s.other.name),
            s.mod.id, s.other.id, s.why == 'gfx' and 'above' or 'below')}
    end
end

-------------------- Versions

VersionsPage = defclass(nil, ReportPage)

function VersionsPage:build(r, vs)
    r.line{{'Active mods that have a newer version installed (e.g. a Workshop update).', COLOR_GREY}}
    local updates = find_updates(vs)
    r.section('Newer versions', #updates > 0 and #updates or nil, 'v switches to them')
    if #updates == 0 then r.line{{'All active mods are the newest installed version.', COLOR_GREEN}} end
    for _, u in ipairs(updates) do
        r.item(COLOR_LIGHTCYAN, {{u.name, COLOR_WHITE}})
        r.detail{{'Using ', COLOR_GREY}, {u.from, COLOR_YELLOW}, {' - newer ', COLOR_GREY},
            {u.to, COLOR_LIGHTGREEN}, {' is installed.', COLOR_GREY}}
    end
end

-------------------- Mod info ("why is it here")

ModInfoPage = defclass(nil, widgets.Panel)
ModInfoPage.ATTRS{window=DEFAULT_NIL}

function ModInfoPage:init()
    self:addviews{
        widgets.Label{
            frame={t=0, l=0},
            text={{text='Pick a mod (up/down or click):', pen=COLOR_GREY}},
        },
        widgets.List{
            view_id='list',
            frame={t=2, l=0, w=40, b=0},
            text_pen=COLOR_GREY,
            cursor_pen={fg=COLOR_BLACK, bg=COLOR_LIGHTCYAN},
            on_select=function() self:show_mod() end,
        },
        widgets.Label{
            view_id='info',
            frame={t=0, l=42, r=0, b=0},
            auto_height=false,
            text='',
        },
    }
end

function ModInfoPage:refresh_list()
    local vs = get_mod_screen()
    self.mods = vs and read_active(vs) or {}
    local sel = self.subviews.list:getSelected()
    local choices = {}
    for _, m in ipairs(self.mods) do
        -- plain text so the list's selection highlight shows
        table.insert(choices, {text=('%2d %s'):format(m.pos, m.name)})
    end
    self.subviews.list:setChoices(choices, sel)
end

function ModInfoPage:postUpdateLayout()
    self:refresh_list()
    self:show_mod()
end

function ModInfoPage:show_mod()
    local idx = self.subviews.list:getSelected()
    local m = self.mods and self.mods[idx]
    local vs = get_mod_screen()
    if not m or not vs then return end
    local by_id = index_mods(self.mods)
    local names = known_names(vs)
    local r = Report((self.frame_body and self.frame_body.width or 110) - 42 - 3)
    local function where(id)
        local o = by_id[id]
        return o and modpos(o) or ((names[id] or id) .. ' (not active)')
    end
    local function rule(text, id, ok)
        local o = by_id[id]
        local state, pen = 'ok', COLOR_LIGHTGREEN
        if not o then state, pen = 'MISSING', COLOR_LIGHTRED
        elseif not ok then state, pen = 'WRONG', COLOR_YELLOW end
        r.item(pen, {{text, COLOR_GREY}, {' ' .. where(id), COLOR_WHITE}, {' - ' .. state, pen}})
    end

    r.line({{m.name, COLOR_YELLOW}, {'  ' .. m.displayed_version, COLOR_GREY}}, '')
    r.line({{('id %s, position #%d%s'):format(m.id, m.pos, m.vanilla and ', vanilla' or ''), COLOR_DARKGREY}}, '')
    if m.steam_id ~= 0 then r.line({{WORKSHOP_ITEM:format(tostring(m.steam_id)), COLOR_DARKGREY}}, '') end

    r.section('Its rules')
    for _, id in ipairs(m.after) do local o = by_id[id]; rule('Must load after', id, o and o.pos < m.pos) end
    for _, id in ipairs(m.before) do local o = by_id[id]; rule('Must load before', id, o and o.pos > m.pos) end
    for _, id in ipairs(m.requires) do rule('Requires', id, true) end
    for _, id in ipairs(m.conflicts) do
        r.item(by_id[id] and COLOR_LIGHTRED or COLOR_DARKGREY, {{'Conflicts with', COLOR_GREY},
            {' ' .. where(id), COLOR_WHITE}, {by_id[id] and ' - BOTH ACTIVE' or '', COLOR_LIGHTRED}})
    end
    if r.items == 0 then r.line{{'This mod declares no rules.', COLOR_GREY}} end

    r.section('Other mods\' rules about it')
    for _, o in ipairs(self.mods) do
        for _, id in ipairs(o.after) do
            if id == m.id then r.item(COLOR_CYAN, {{modpos(o), COLOR_WHITE}, {' must load after this one', COLOR_GREY}}) end
        end
        for _, id in ipairs(o.before) do
            if id == m.id then r.item(COLOR_CYAN, {{modpos(o), COLOR_WHITE}, {' must load before this one', COLOR_GREY}}) end
        end
        for _, id in ipairs(o.requires) do
            if id == m.id then r.item(COLOR_CYAN, {{modpos(o), COLOR_WHITE}, {' requires this one', COLOR_GREY}}) end
        end
    end
    if r.items == 0 then r.line{{'None.', COLOR_GREY}} end

    r.section('Raw files')
    local data = scan_cache[m.path]
    if not data then
        r.line{{'Not scanned yet.', COLOR_GREY}}
    else
        local function count(s) local n = 0 for _ in pairs(s) do n = n + 1 end return n end
        r.line{{('Defines %s and %s, edits %s.'):format(plural(count(data.defs), 'object'),
            plural(count(data.gfx), 'graphic'), plural(count(data.edits), 'object')), COLOR_GREY}}
        local ok, result = pcall(scan_if_cached, vs)
        if ok and result then
            for _, s in ipairs(result.suggestions) do
                if s.mod.id == m.id then
                    r.item(COLOR_LIGHTCYAN, {{'Suggestion: move ', COLOR_GREY},
                        {(s.why == 'gfx' and 'above ' or 'below ') .. modpos(s.other), COLOR_LIGHTGREEN}})
                end
            end
            for _, d in ipairs(result.duplicates) do
                if d.a.id == m.id or d.b.id == m.id then
                    local other = d.a.id == m.id and d.b or d.a
                    r.item(COLOR_LIGHTRED, {{'Duplicate objects with ', COLOR_GREY}, {modpos(other), COLOR_WHITE}})
                end
            end
            for _, h in ipairs(result.hidden) do
                if h.mod.id == m.id then
                    r.item(COLOR_YELLOW, {{plural(h.n, 'graphic', true), COLOR_YELLOW}, {' hidden by ', COLOR_GREY}, {modpos(h.by), COLOR_WHITE}})
                end
                if h.by.id == m.id then
                    r.item(COLOR_DARKGREY, {{'Hides ' .. plural(h.n, 'graphic') .. ' from ', COLOR_GREY}, {modpos(h.mod), COLOR_WHITE}})
                end
            end
        end
    end
    self.subviews.info:setText(r.t)
end

---------------------------------------------------------------------------
-- main window with tabs

local TABS = {'Overview', 'Problems', 'Hidden conflicts', 'Suggestions', 'Versions', 'Mod info'}
local TAB_MODINFO = 6

LoadOrderWindow = defclass(nil, widgets.Window)
LoadOrderWindow.ATTRS{
    frame_title='Mod Load Order',
    frame={w=112, h=44},
    resizable=true,
    resize_min={w=100, h=24},
}

function LoadOrderWindow:init()
    local function show(ok, moved, msg)
        if moved and #moved > 0 then msg = msg .. ' Moved: ' .. table.concat(moved, ', ') end
        self:set_message(msg, ok and COLOR_GREEN or COLOR_LIGHTRED)
    end
    local function on_result(msg, pen) self:set_message(msg, pen or COLOR_GREEN) end

    self:addviews{
        widgets.TabBar{
            view_id='tabs',
            frame={t=0, l=0},
            labels=TABS,
            on_select=function(idx)
                self.subviews.pages:setSelected(idx)
                STATE.last_tab = idx
                self:refresh()
            end,
            get_cur_page=function() return self.subviews.pages:getSelected() end,
        },
        widgets.Pages{
            view_id='pages',
            frame={t=3, l=0, r=0, b=5},
            subviews={
                OverviewPage{window=self},
                ProblemsPage{window=self, buttons={
                    {key='CUSTOM_F', label='Fix order', on_activate=function() show(fix()) end},
                    {key='CUSTOM_C', label='Remove conflicts', on_activate=function() remove_conflicts_ui(on_result) end},
                    {key='CUSTOM_L', label='Copy Workshop links',
                        enabled=function() return #missing_links() > 0 end,
                        on_activate=function() local ok, msg = copy_missing_links() show(ok, nil, msg) end},
                }},
                HiddenPage{window=self},
                SuggestionsPage{window=self, buttons={
                    {key='CUSTOM_S', label='Apply suggestions',
                        enabled=function()
                            local ok, res = pcall(scan_if_cached, get_mod_screen())
                            return ok and res and #res.suggestions > 0
                        end,
                        on_activate=function() show(apply_suggestions()) end},
                }},
                VersionsPage{window=self, buttons={
                    {key='CUSTOM_V', label='Use newest versions',
                        enabled=function() return #find_updates() > 0 end,
                        on_activate=function() local ok, msg = use_newest() show(ok, nil, msg) end},
                }},
                ModInfoPage{window=self},
            },
        },
        widgets.Divider{
            frame={b=4, l=0, r=0, h=1},
            frame_style=gui.FRAME_THIN,
            frame_style_l=false,
            frame_style_r=false,
        },
        widgets.WrappedLabel{
            frame={b=2, l=0, r=0, h=2},
            text_to_wrap=function() return self.message or '' end,
            text_pen=function() return self.message_pen or COLOR_GREEN end,
            auto_height=false,
        },
        -- shared actions, on every tab
        widgets.HotkeyLabel{frame={b=0, l=0}, key='CUSTOM_A', label='Fix all', auto_width=true,
            on_activate=function() fix_all_ui(on_result) end},
        widgets.HotkeyLabel{frame={b=0, l=14}, key='CUSTOM_U', label='Undo', auto_width=true,
            enabled=can_undo,
            on_activate=function() local ok, msg = undo() show(ok, nil, msg) end},
        widgets.HotkeyLabel{frame={b=0, l=25}, key='CUSTOM_P', label='Save preset', auto_width=true,
            on_activate=function() self:save_preset() end},
        widgets.HotkeyLabel{frame={b=0, l=43}, key='CUSTOM_R', label='Rescan', auto_width=true,
            on_activate=function() self:start_scan(true) end},
        widgets.HotkeyLabel{frame={b=0, r=0}, key='LEAVESCREEN', label='Close', auto_width=true,
            on_activate=function() self.parent_view:dismiss() end},
    }
    self.subviews.pages:setSelected(STATE.last_tab or 1)
    if not is_scanned() then self:start_scan(false) end
end

function LoadOrderWindow:show_tab(idx)
    self.subviews.pages:setSelected(idx)
    STATE.last_tab = idx
    self:refresh()
end

-- the scan blocks for a moment, so draw "Scanning..." first
function LoadOrderWindow:start_scan(rescan)
    if rescan then clear_scan_cache() end
    self.scanning = true
    self:refresh()
    dfhack.timeout(2, 'frames', function()
        local t0 = dfhack.getTickCount()
        local ok, err = true, nil
        if get_mod_screen() then ok, err = pcall(scan) end
        self.scanning = false
        if not ok then
            self:set_message('Scan failed: ' .. tostring(err), COLOR_LIGHTRED)
        elseif rescan then
            self:set_message(('Rescanned mod files (%.1f s).'):format((dfhack.getTickCount() - t0) / 1000), COLOR_GREEN)
        else
            self:refresh()
        end
    end)
end

function LoadOrderWindow:save_preset()
    local names, default = preset_names()
    dialogs.showInputPrompt('Save as Mod Manager preset',
        default and ('Your default preset is "%s". Keep that name to update it,\nso it loads in this order next time.'):format(default)
            or 'Name for this mod list (shows up in the Mod Manager, m).',
        COLOR_WHITE, default or 'Fixed load order',
        function(name)
            if not name or name == '' then return end
            local function do_save()
                local ok, msg = save_preset(nil, name)
                self:set_message(msg, ok and COLOR_GREEN or COLOR_LIGHTRED)
            end
            for _, n in ipairs(names) do
                if n == name then
                    dialogs.showYesNoPrompt('Overwrite preset?',
                        ('Replace the mod list saved in "%s" with the current one?'):format(name),
                        COLOR_YELLOW, do_save)
                    return
                end
            end
            do_save()
        end)
end

function LoadOrderWindow:set_message(msg, pen)
    self.message, self.message_pen = msg, pen
    self:refresh()
end

function LoadOrderWindow:refresh()
    if self.frame_parent_rect then self:updateLayout() end
end

LoadOrderScreen = defclass(nil, ModScreen)
LoadOrderScreen.ATTRS{focus_path='mod-load-order'}

function LoadOrderScreen:init()
    self:addviews{LoadOrderWindow{view_id='main'}}
end

function LoadOrderScreen:onDismiss()
    view = nil
end

-- opens the window (optionally on a given tab number)
function show_details(tab)
    if tab then STATE.last_tab = tab end
    if view then
        view:raise()
        if tab then view.subviews.main:show_tab(tab) end
    else
        view = LoadOrderScreen{}:show()
    end
end
---------------------------------------------------------------------------
-- warning when clicking Create world with problems

local guard = STATE.guard

WarnWindow = defclass(nil, widgets.Window)
WarnWindow.ATTRS{
    frame_title='Mod problems',
    frame={w=72, h=13},
    lines=DEFAULT_NIL,
}

function WarnWindow:init()
    local text = {{text='The active mod list still has problems:', pen=COLOR_WHITE}, NEWLINE, NEWLINE}
    for _, l in ipairs(self.lines) do
        table.insert(text, {text='  ' .. l.text, pen=l.pen})
        table.insert(text, NEWLINE)
    end
    table.insert(text, NEWLINE)
    table.insert(text, {text='Click Create world again within 30 seconds to create it anyway.', pen=COLOR_GREY})
    self:addviews{
        widgets.Label{frame={t=0, l=0, r=0, b=2}, text=text},
        widgets.HotkeyLabel{frame={b=0, l=0}, key='CUSTOM_A', label='Fix all', auto_width=true,
            on_activate=function()
                self.parent_view:dismiss()
                guard.armed_until = 0
                fix_all_ui()
            end},
        widgets.HotkeyLabel{frame={b=0, l=14}, key='CUSTOM_D', label='Details', auto_width=true,
            on_activate=function() self.parent_view:dismiss(); show_details() end},
        widgets.HotkeyLabel{frame={b=0, r=0}, key='LEAVESCREEN', label='Close', auto_width=true,
            on_activate=function() self.parent_view:dismiss() end},
    }
end

WarnScreen = defclass(nil, ModScreen)
WarnScreen.ATTRS{focus_path='mod-load-order/warn', lines=DEFAULT_NIL}
function WarnScreen:init() self:addviews{WarnWindow{lines=self.lines}} end

-- Is the mouse over the game's "Create world" button? (found by its text)
local function mouse_on_create_world()
    local mx, my = dfhack.screen.getMousePos()
    if not mx then return false end
    local w = dfhack.screen.getWindowSize()
    for y = my - 1, my + 1 do
        local chars = {}
        for x = 0, w - 1 do
            local pen = dfhack.screen.readTile(x, y, false)
            local c = pen and pen.ch or 32
            chars[#chars + 1] = (c >= 32 and c < 127) and string.char(c) or ' '
        end
        local s, e = table.concat(chars):find('Create world', 1, true)
        -- find() is 1-based, screen x is 0-based; allow for the button border
        if s and mx >= s - 3 and mx <= e + 1 then return true end
    end
    return false
end

local function blocking_lines(vs)
    local counts = {order=0, missing=0, conflict=0}
    for _, i in ipairs(check(vs) or {}) do counts[i.kind] = counts[i.kind] + 1 end
    local lines = {}
    if counts.order > 0 then
        table.insert(lines, {text=plural(counts.order, 'mod') .. ' out of order', pen=COLOR_YELLOW})
    end
    if counts.missing > 0 then
        table.insert(lines, {text=plural(counts.missing, 'required mod') .. ' missing', pen=COLOR_LIGHTRED})
    end
    if counts.conflict > 0 then
        table.insert(lines, {text=plural(counts.conflict, 'conflict'), pen=COLOR_LIGHTRED})
    end
    local ok, result = pcall(scan_if_cached, vs)
    if ok and result and #result.duplicates > 0 then
        table.insert(lines, {text=plural(#result.duplicates, 'hidden conflict') .. ' (duplicate objects)',
            pen=COLOR_LIGHTRED})
    end
    return lines
end

---------------------------------------------------------------------------
-- overlay panel on the Mods screen

LoadOrderOverlay = defclass(nil, overlay.OverlayWidget)
LoadOrderOverlay.ATTRS{
    desc='Checks the active mod list for load-order problems and conflicts and can fix them.',
    default_pos={x=24, y=-6},
    default_enabled=true,
    viewscreens={'new_region/Mods', 'new_arena/Mods'},
    frame={w=36, h=4},
    frame_style=gui.MEDIUM_FRAME,
    frame_background=gui.CLEAR_PEN,
}

local cache = {tick=0, counts=nil}

local function get_counts()
    local now = dfhack.getTickCount()
    if cache.counts and now - cache.tick < 500 then return cache.counts end
    local counts = {order=0, missing=0, conflict=0, notes=0}
    local vs = get_mod_screen()
    for _, issue in ipairs(check(vs) or {}) do counts[issue.kind] = counts[issue.kind] + 1 end
    if vs then
        counts.notes = #find_updates(vs)
        local ok, result = pcall(scan_if_cached, vs)
        if ok and result then
            counts.notes = counts.notes + #result.duplicates + #result.hidden + #result.suggestions
        end
    end
    cache.tick, cache.counts = now, counts
    return counts
end

local function invalidate() cache.counts = nil end

-- one short status line, e.g. "2 order, 1 missing, 1 conflict" or
-- "Load order OK - 5 notes"; it has to fit in the small panel
local function status_text()
    local c = get_counts()
    local parts = {}
    if c.order > 0 then table.insert(parts, ('%d order'):format(c.order)) end
    if c.missing > 0 then table.insert(parts, ('%d missing'):format(c.missing)) end
    if c.conflict > 0 then table.insert(parts, plural(c.conflict, 'conflict')) end
    if #parts > 0 then return table.concat(parts, ', ') end
    return 'Load order OK'
end

local function status_pen()
    local c = get_counts()
    if c.missing + c.conflict > 0 then return COLOR_LIGHTRED end
    if c.order > 0 then return COLOR_YELLOW end
    return COLOR_LIGHTGREEN
end

local function status_notes()
    local c = get_counts()
    if c.order + c.missing + c.conflict > 0 or c.notes == 0 then return '' end
    return ' - ' .. plural(c.notes, 'note')
end

function LoadOrderOverlay:init()
    self:addviews{
        widgets.Label{
            view_id='status',
            frame={t=0, l=0, r=0},
            text={
                {text=status_text, pen=status_pen},
                {text=status_notes, pen=COLOR_LIGHTCYAN},
            },
        },
        -- Fix order / Remove conflicts live in the window's Problems tab;
        -- Fix all does both
        widgets.HotkeyLabel{frame={t=1, l=0}, key='CUSTOM_A', label='Fix all', auto_width=true,
            enabled=function() local c = get_counts() return c.order + c.conflict > 0 end,
            on_activate=function() fix_all_ui(invalidate) end},
        widgets.HotkeyLabel{frame={t=1, l=12}, key='CUSTOM_U', label='Undo', auto_width=true,
            enabled=can_undo,
            on_activate=function() undo(); invalidate() end},
        widgets.HotkeyLabel{frame={t=1, l=21}, key='CUSTOM_D', label='Details', auto_width=true,
            on_activate=function() show_details() end},
    }
end

function LoadOrderOverlay:onInput(keys)
    if (keys._MOUSE_L or keys._MOUSE_L_DOWN)
            and df.viewscreen_new_regionst:is_instance(dfhack.gui.getCurViewscreen(true))
            and mouse_on_create_world() then
        if dfhack.getTickCount() < guard.armed_until then
            return false -- second click: let the game create the world
        end
        local lines = blocking_lines(get_mod_screen())
        if #lines > 0 then
            if keys._MOUSE_L then
                guard.armed_until = dfhack.getTickCount() + 30000
                WarnScreen{lines=lines}:show()
            end
            return true
        end
    end
    return LoadOrderOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {panel=LoadOrderOverlay}

---------------------------------------------------------------------------
-- command line

if dfhack_flags.module then return end

local m = reqscript('mod-load-order') -- run the UI from the shared module
local cmd = ({...})[1]
if not m.get_mod_screen() then
    qerror('Open the Mods screen (Create world -> Mods) first.')
end
if cmd == 'check' then
    local issues = m.check()
    if #issues == 0 then print('No problems found.') end
    for _, issue in ipairs(issues) do print(('[%s] %s'):format(issue.kind, issue.text)) end
    for _, u in ipairs(m.find_updates()) do print(('[update] %s %s -> %s'):format(u.name, u.from, u.to)) end
elseif cmd == 'fix' then
    local ok, moved, msg = m.fix()
    print(msg)
    for _, name in ipairs(moved) do print('  moved: ' .. name) end
    if not ok then qerror(msg) end
elseif cmd == 'scan' then
    local t0 = dfhack.getTickCount()
    local result = m.scan()
    print(('scan took %d ms'):format(dfhack.getTickCount() - t0))
    for _, d in ipairs(result.duplicates) do print('[duplicate] ' .. d.text) end
    for _, h in ipairs(result.hidden) do print('[hidden] ' .. h.text) end
    for _, s in ipairs(result.suggestions) do print('[suggest] ' .. s.text) end
else
    m.show_details()
end
