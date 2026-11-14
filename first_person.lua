-- HD2-Addon: mods/shodan/first_person
-- HD2-Requires: chef-shared-loader
-- SHODAN First Person: a first person camera with its own settings panel.
local chef = ...
local M = { version = '2.1.0' }
local log = chef.log
-- alive(u), the answers kept for one update or draw pass (M.update/M.render set alive.c, clear it after): nothing
-- destroys a unit while our own code runs, and the same few units were asked dozens of times a frame (timer
-- 2026-11-14). Outside a pass (stop, menus) every answer is asked fresh. A callable table: one local, the main chunk
-- is at Lua's 200
local alive = setmetatable({}, { __call = function(t, u)
  local c = t.c
  if not c or u == nil then return chef.unit_alive(u) end
  local a = c[u]
  if a == nil then a = chef.unit_alive(u) == true; c[u] = a end
  return a
end })
-- chef.call doesn't refuse a unit destroyed in this world (a swapped helmet): asking one ends the game
local function call(name, a, b, ...)
  local u = name:sub(1, 5) == 'Unit.' and a or (name == 'Camera.set_local_position' or name == 'Camera.set_local_rotation' or name == 'World.update_unit') and b
  if u and not alive(u) then return nil, 'gone' end
  return chef.call(name, a, b, ...)
end
local Vec = rawget(_G, 'Vector3') or stingray.Vector3
local sqrt, exp, abs, min, max, floor = math.sqrt, math.exp, math.abs, math.min, math.max, math.floor

local CAMERA_KIND = '465f4895f3dc98d1'                         -- core/units/camera
local AVATAR_KIND = '4d1c334d294dfa97'                         -- avatar_helldiver: only these can be you (not armour stands)
-- each FRV has its own settings (pre = settings id prefix, '' keeps the old ids). frv_superearth = the SEAF one
-- found in the world (going by its name); frv_heavy sits in the Incinerator's folder and shares its settings
local FRVS = { { kind = 'cc21c7ffd3ebefb9', name = 'GUNNER', pre = '' }, { kind = '9b2140378640432e', name = 'SUPPLY', pre = 'sp_', nogun = true },
  { kind = '2d85bfe3d8717fe5', name = 'INCINERATOR', pre = 'fl_' }, { kind = 'e9cd1d0d118886af', name = 'SEAF', pre = 'se_' } }
local FRV_KINDS, FRV_PRE = {}, {}
local FRV_GUN = {}
for _, f in ipairs(FRVS) do FRV_KINDS[f.kind] = true; FRV_PRE[f.kind] = f.pre; FRV_GUN[f.kind] = not f.nogun end
FRV_KINDS['0df7e312f561f8b9'], FRV_PRE['0df7e312f561f8b9'], FRV_GUN['0df7e312f561f8b9'] = true, 'fl_', true
-- each exosuit / emplacement has its own settings too. Every exosuit has the same body (combat_walker), so only
-- the Patriot entry carries the body kind; the model comes from the arms (MECH_ARMS, the game's mount data)
local MECHS = { { kind = '79e4b3d2da5e45e3', name = 'PATRIOT', pre = '' }, { name = 'EMANCIPATOR', pre = 'em_' },
  { name = 'BREAKTHROUGH', pre = 'bt_' }, { name = 'LUMBERER', pre = 'lb_' } }
local EMPLS = { { kind = '0e977c49db7604f9', name = 'HMG', pre = '' }, { kind = '2b11c9e4980ec479', name = 'ANTI-TANK', pre = 'at_' } }
local PRE = {}
for _, l in ipairs({ MECHS, EMPLS }) do for _, m in ipairs(l) do if m.kind then PRE[m.kind] = m.pre end end end
local MECH_ARMS = { ['824b7e0c4c879eb5'] = '', ['08f6089289c83d22'] = '',          -- Patriot: rockets, minigun
  ['e5f64dcc3bfe9dd1'] = 'em_', ['ff9878576a4c543b'] = 'em_',                       -- Emancipator: two autocannons
  ['65489809a8181b96'] = 'bt_', ['df51fe8d62f294be'] = 'bt_',                       -- Breakthrough: shield, flak cannon
  ['0736bee2d6328726'] = 'lb_', ['17c5d12d8d5dee2c'] = 'lb_' }                      -- Lumberer: flamethrower, AT cannon
local MECH_KINDS = { ['79e4b3d2da5e45e3'] = true, ['a526dc7d89ff696d'] = true }  -- content/fac_helldivers/vehicles/combat_walker*
for k in pairs(MECH_ARMS) do MECH_KINDS[k] = true end
-- hellpod/manned_turret (HMG), antitank_emplacement: how close your feet are to its base while you man it
-- AT: seated 1.25 m, on top of it 0.2-0.8 m, walking past 1.5 m or more (log, 2026-11-06)
local EMPL_DIST = { ['0e977c49db7604f9'] = { 0, 1.2 }, ['2b11c9e4980ec479'] = { 0.95, 1.45 } }
-- tanks: content/fac_helldivers/vehicles/tank/tank (Bastion), tank_storm/tank_storm (Maelstrom)
-- seats by the diver's animation, same on both (log 2026-11-06): 121 gunner at the back, 123 the two passengers; the
-- driver is hidden inside the tank (the game's own camera shows then)
local TANK_ANIM = { [121] = 'crew', [123] = 'passenger' }
local TANKS = { ['16474112801385b6'] = { name = 'Bastion', id = 'bastion', tp = 'tp_bastion' },
  ['b0c9faf4af8903f9'] = { name = 'Maelstrom', id = 'maelstrom', tp = 'tp_maelstrom' } }
local TANK_KINDS = {}
for k in pairs(TANKS) do TANK_KINDS[k] = true end
local EMPL_KINDS = {}
for k in pairs(EMPL_DIST) do EMPL_KINDS[k] = true end
-- the game's seat layer (layer 14, see layers()), from in-game logs: the Pelican (boarding 89, seated
-- 90-94), the Gator (driver 72, leaving 77; gunner 83, getting in 75, leaving 81) and the tank crew (96 and 97 the
-- gunner; 102 the driver and the passengers alike: the game camera sits about 11 m behind the driver and 4 m behind a
-- passenger, which tells them apart)
local L14 = {}
L14.PELICAN = { [89] = true, [90] = true, [91] = true, [92] = true, [93] = true, [94] = true }
L14.GATOR = { [72] = 'gator', [77] = 'gator', [83] = 'ggun', [75] = 'ggun', [81] = 'ggun' }
L14.TANK = { [96] = 'crew', [97] = 'crew', [102] = 'driver' }

---------------------------------------------------------------------------------------------------- settings
local TABS = {
  { name = 'CAMERA', rows = {
    { head = 'PROFILE' },
    { id = 'profile', label = 'Profile in use', min = 1, max = 5, step = 1, def = 1, global = true,
      hint = 'Five saved setups. Every setting except keys belongs to the profile in use. Switch with the profile key (KEYS tab).' },
    { head = 'POSITION' },
    { id = 'fwd', label = 'Forward', min = -0.3, max = 0.5, step = 0.01, def = 0.07, unit = ' m',
      hint = 'How far in front of your head the view sits, along the floor.' },
    { id = 'up', label = 'Height', min = -0.3, max = 0.3, step = 0.01, def = 0.04, unit = ' m',
      hint = 'Raise or lower the view.' },
    { id = 'side', label = 'Sideways', min = -0.3, max = 0.3, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right.' },
    { id = 'look_down', label = 'Looking down', min = 0, max = 0.4, step = 0.01, def = 0.12, unit = ' m',
      hint = 'Pushes the view forward as you look down, up to this far, so you look over your chest instead of into it.' },
    { head = 'VIEW' },
    { id = 'fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 100, unit = ' deg', zero = 'GAME',
      hint = 'Up-down view angle in degrees. GAME keeps the game\'s own.' },
    { id = 'near', label = 'Closest visible', min = 0, max = 0.3, step = 0.01, def = 0, unit = ' m', zero = 'GAME',
      hint = 'Anything nearer than this is not drawn, so the helmet and collar stay out of view.' },
    { id = 'aim_fov', label = 'Aiming field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Field of view while you aim with the right mouse button. SAME uses the field of view above.' },
    { id = 'aim_zoom_game', label = 'Follow the game\'s aim zoom', toggle = true, def = true,
      hint = 'With Aiming field of view at SAME: while you aim, the view zooms in as much as the game\'s own camera does for that weapon.' },
    { id = 'aim_zoom', label = 'Extra aim zoom', min = 0, max = 50, step = 5, def = 0, unit = ' %', zero = 'OFF',
      hint = 'With Aiming field of view at SAME: zooms in this much more while you aim.' },
    { id = 'aim_toggle', label = 'Aim button toggles', toggle = true, def = false, global = true,
      hint = 'Turn on if your game is set to toggle aiming instead of holding the button.' },
    { id = 'aim_game', label = 'Aim from the game', toggle = true, def = false, global = true,
      hint = 'Knows you aim from the game itself (its animation), so toggle aiming and a controller trigger work too. Off: the right mouse button only.' },
    { head = 'SMOOTHING' },
    { id = 'smooth', label = 'Smoothing up-down', min = 0, max = 10, step = 1, def = 3, zero = 'OFF',
      hint = 'Takes the up-down head bob out of walking and running. Higher is calmer.' },
    { id = 'smooth_side', label = 'Smoothing sideways', min = 0, max = 10, step = 1, def = 3, zero = 'OFF',
      hint = 'Takes the side-to-side sway out. Keep it low so turning still feels quick.' },
    { id = 'smooth_max', label = 'Smoothing lag limit', min = 0, max = 0.3, step = 0.01, def = 0.12, unit = ' m', zero = 'OFF',
      hint = 'The smoothed view never trails your head by more than this, so quick moves (crouching, a jolt in a seat) stay crisp.' },
    { id = 'bob_boost', label = 'Bigger head bob', min = 0, max = 100, step = 10, def = 0, unit = ' %', zero = 'OFF',
      hint = 'Makes the head bob bigger than the real one, on foot: 100 % is twice the real bob. Works on top of the smoothing (turn that off for the full effect).' },
    { id = 'back_shift', label = 'Walking backward: view forward', toggle = true, def = true,
      hint = 'Walking backward without aiming turns your Helldiver around to face you: the view slides forward so you do not look into your own back and shoulders. Never while aiming or prone.' },
    { id = 'back_fwd', label = 'Walking backward: forward', min = -0.3, max = 0.51, step = 0.01, def = 0.51, unit = ' m', top = 'SAME',
      hint = 'With Walking backward: view forward on: Forward while the view is slid forward. SAME (all the way right) = the normal Forward.' },
    { id = 'back_up', label = 'Walking backward: height', min = -0.3, max = 0.31, step = 0.01, def = 0.31, unit = ' m', top = 'SAME',
      hint = 'With Walking backward: view forward on: Height while the view is slid forward. SAME (all the way right) = the normal Height.' },
    { id = 'swing_hold', label = 'Hold through camera swings', toggle = true, def = false,
      hint = 'A sudden swing of the game camera (more than 60 deg in one frame: a crash, a ragdoll, a blast) is not followed for up to 0.4 s, so the view does not spin around. On foot only.' },
    { head = 'TILT' },
    { id = 'tilt', label = 'Sprint tilt', min = 0, max = 6, step = 0.5, def = 2, unit = ' deg', zero = 'OFF',
      hint = 'While you sprint, the view leans up to this far into turns and sideways runs. Never while aiming, lying or in a seat. Your aim stays exact.' },
    { id = 'tilt_dive', label = 'Sideways dive tilt', min = 0, max = 10, step = 0.5, def = 4, unit = ' deg', zero = 'OFF',
      hint = 'A dive to the side leans the view this far toward it while you fly, then levels out as you land.' },
    { id = 'sprint_fov', label = 'Sprint zoom-out', min = 0, max = 15, step = 1, def = 8, unit = ' deg', zero = 'OFF',
      hint = 'While you sprint, the view widens by this much and eases back as soon as you slow down. Never while aiming, lying or in a seat.' },
    { head = 'SWITCHING' },
    { id = 'blend', label = 'Glide time', min = 0, max = 1, step = 0.05, def = 0.25, unit = ' s', zero = 'OFF',
      hint = 'How long the view glides between first person and the game camera (peek, seats, terminals, the toggle key). Death, the hellpod and cutscenes always cut.' },
    { id = 'start_on', label = 'Start in first person', toggle = true, def = true,
      hint = 'Turn first person on by itself at the start of every mission.' },
    { id = 'messages', label = 'On-screen messages', toggle = true, def = true, global = true,
      hint = 'Shows FIRST PERSON ON or OFF and the profile number for a moment when you press their keys.' },
    { id = 'tp_galaxy', label = 'Third person at the galactic map', toggle = true, def = true,
      hint = 'Switches to the game camera while you use the galactic map.' },
    { id = 'tp_term', label = 'Third person at terminals', toggle = true, def = true,
      hint = 'Switches to the game camera while you use a mission terminal, and back when you step off it.' },
    { id = 'term_fov', label = 'Terminal field of view change', min = -40, max = 40, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'With Third person at terminals off: degrees added to the field of view while you use a terminal in first person (minus zooms in on its screen).' },
    { id = 'term_face', label = 'Face the terminal', toggle = true, def = true,
      hint = 'With Third person at terminals off: when the game turns its camera away from the terminal you use (the extraction terminal), the view turns to face where your Helldiver faces, and back when you step off.' },
    { head = '(Experimental, report issues!)', note = true },
    { id = 'tp_menus', label = 'Third person for map and stratagems', toggle = true, def = false,
      hint = 'Switches to the game camera while the map or stratagem list is out.' },
    { id = 'tp_down', label = 'Third person when knocked down', toggle = true, def = false,
      hint = 'Switches to the game\'s camera while you tumble or lie dead, and back once you are up.' },
    { head = 'DEATH' },
    { id = 'death_fx', label = 'Death effect', toggle = true, def = true, global = true,
      hint = 'When you die, the view on your body blurs in and out in slow swells for about 4 s, then cuts to black until your reinforcement drops in or the camera moves to a teammate.' },
    { id = 'death_blink', label = 'Death effect: blinking', toggle = true, def = true, global = true,
      hint = 'With Death effect on: your eyes blink at random, often several times in quick succession, then close before the black.' },
    { id = 'daze', label = 'Knockdown daze', toggle = true, def = true, global = true,
      hint = 'When a blast or a hit knocks you down, the view blurs and darkens at once and clears over about 2 s. Only drawn over the screen: the view itself is not moved.' },
  } },
  { name = 'AIM', rows = {
    { head = 'VIEW WHILE AIMING' },
    { id = 'aimpos_fwd', label = 'Forward', min = -0.2, max = 0.3, step = 0.01, def = 0, unit = ' m',
      hint = 'Moves the view forward (or back, minus) while you aim with the right mouse button. Eases in and out with the aim.' },
    { id = 'aimpos_up', label = 'Height', min = -0.15, max = 0.15, step = 0.01, def = 0, unit = ' m',
      hint = 'Raises or lowers the view while you aim, for example closer to the sights. Eases in and out with the aim.' },
    { id = 'aimpos_side', label = 'Sideways', min = -0.2, max = 0.2, step = 0.01, def = 0, unit = ' m',
      hint = 'Moves the view left (minus) or right while you aim. Eases in and out with the aim.' },
    { id = 'aimpos_time', label = 'Move time', min = 0, max = 1, step = 0.05, def = 0.15, unit = ' s',
      hint = 'How long the view takes to move to the aiming spot and back.' },
    { head = 'BALLISTIC SHIELD' },
    { id = 'shield_back', label = 'Distance behind the window', min = 0, max = 0.3, step = 0.01, def = 0.08, unit = ' m',
      hint = 'Aiming with the ballistic shield raised, the view moves into its window by itself, whatever your other view settings. This is how far behind the window it sits: more shows more of the shield round the slot.' },
    { id = 'shield_zoom', label = 'Aim zoom with the shield', min = 0, max = 60, step = 5, def = 0, unit = ' %', zero = 'OFF',
      hint = 'With the shield in your hand: zooms in this much more while you aim, so its window fills more of the view. Adds to Extra aim zoom.' },
    { id = 'shield_near', label = 'Closest visible with the shield', min = 0, max = 0.45, step = 0.01, def = 0, unit = ' m', zero = 'OFF',
      hint = 'With the shield in your hand: nothing nearer than this is drawn (your shoulder in front of the window). Too high and the shield itself goes.' },
    { head = 'CROSSHAIR FIX' },
    { id = 'aim_fix', label = 'Crosshair follows the gun', toggle = true, def = true,
      hint = 'The view turns a little so the crosshair sits where your shots land. Everything on this tab needs it on.' },
    { id = 'aim_dist', label = 'Distance with no enemy', min = 5, max = 100, step = 1, def = 30, unit = ' m',
      hint = 'Where the crosshair is exact while no enemy is under it. Nearer or further, shots land a little off.' },
    { id = 'run_dist', label = 'Distance while running', min = 0, max = 100, step = 1, def = 0, unit = ' m', zero = 'SAME',
      hint = 'Running or sprinting (not aiming) the gun is carried low and cannot be lined up: the crosshair is exact at this distance instead. An enemy under it still wins. Read from the game: needs the running state.' },
    { id = 'aim_ease', label = 'Correction time', min = 0, max = 2, step = 0.05, def = 0.15, unit = ' s',
      hint = 'How long the view takes to adjust when you aim or the target distance changes. Longer feels less like aim assist.' },
    { id = 'aim_max', label = 'Largest turn', min = 2, max = 20, step = 1, def = 20, unit = ' deg',
      hint = 'The most the view may turn off the game aim. Up close the needed turn is bigger; above this it stops at this angle.' },
    { id = 'aim_ground', label = 'Line up at the ground', toggle = true, def = true,
      hint = 'Looking down on foot, the crosshair sits where your shots meet the ground, not on a point under it.' },
    { id = 'gun_dist', label = 'Distance on the FRV gun', min = 0, max = 100, step = 1, def = 0, unit = ' m', zero = 'SAME',
      hint = 'The fixed distance on the FRV gunner seat. SAME = Distance with no enemy.' },
    { id = 'empl_dist', label = 'Distance on emplacements', min = 0, max = 100, step = 1, def = 0, unit = ' m', zero = 'SAME',
      hint = 'The fixed distance on emplacements. SAME = Distance with no enemy.' },
    { head = 'MEASURE FROM THE GUN' },
    { id = 'gun_measure', label = 'Measure from the gun', toggle = true, def = false,
      hint = 'On foot: the distance with no enemy is read from where your gun points (walls, slopes, things near you), not fixed. Needs both hands on the gun.' },
    { id = 'gun_nearest', label = 'Nearest', min = 2, max = 20, step = 1, def = 10, unit = ' m',
      hint = 'Measured from the gun: never lines up nearer than this. Shots at things closer land a little beside the crosshair.' },
    { id = 'gun_steps', label = 'Ranges 10/25/50/100', toggle = true, def = true,
      hint = 'Measured from the gun: only four distances (Nearest, 25, 50, 100 m), changed only on a clear difference. Off: the measured distance itself.' },
    { id = 'gun_glide', label = 'Glide', min = 0, max = 10, step = 0.5, def = 5, unit = ' s', zero = 'QUICK',
      hint = 'Measured from the gun: each new distance is followed at one even pace taking this long, so a change is hardly felt. QUICK = a new distance must hold a moment, then a quick move.' },
    { id = 'reload_hold', label = 'Hold while reloading', min = 0, max = 10, step = 0.5, def = 10, unit = ' s', zero = 'OFF',
      hint = 'Measured from the gun: after R the distance holds until you fire, aim, or this long passes, so the reload tilt never pulls the crosshair. Set it to your longest reload.' },
    { head = 'WHILE AIMING' },
    { id = 'aim_strength', label = 'Strength', min = 1, max = 10, step = 1, def = 10,
      hint = 'How much of the gap to the game aim gets corrected while aiming. 10 = exact, lower = gentler turns, shots land a bit off.' },
    { id = 'aim_range', label = 'Correct for enemies', toggle = true, def = true,
      hint = 'Use the distance of the enemy under the crosshair instead of the fixed distance. Stronger turns up close.' },
    { head = 'HIP FIRE' },
    { id = 'aim_hip', label = 'Correct hip fire', toggle = true, def = true,
      hint = 'Corrects the crosshair when not aiming too, at the fixed distance, so hip-fire shots land on it.' },
    { id = 'hip_range', label = 'Correct for enemies', toggle = true, def = true,
      hint = 'Also correct for the enemy under the crosshair, so close shots land on it too. Stronger turns.' },
    { id = 'hip_strength', label = 'Enemy strength', min = 1, max = 10, step = 1, def = 10,
      hint = 'With Correct for enemies on: how much of the extra turn toward a close enemy is made. 10 = exact, lower = gentler.' },
    { id = 'hip_ease', label = 'Enemy time', min = 0, max = 2, step = 0.05, def = 0.4, unit = ' s',
      hint = 'With Correct for enemies on: how long the view takes to adjust when an enemy comes under the crosshair or leaves it.' },
    { head = 'ENEMIES' },
    { id = 'aim_near', label = 'Nearest enemy distance', min = 2, max = 20, step = 1, def = 2, unit = ' m',
      hint = 'With Correct for enemies on: a closer enemy counts as this far away, so it never swings the view hard.' },
    { id = 'aim_cone', label = 'Near-miss angle', min = 0, max = 6, step = 0.5, def = 3, unit = ' deg', zero = 'OFF',
      hint = 'With Correct for enemies on: an enemy this close to the crosshair counts even when the line misses it (small or far targets).' },
    { id = 'aim_corpse', label = 'Skip dead enemies', toggle = true, def = true,
      hint = 'With Correct for enemies on: bodies on the ground never count as the enemy under the crosshair.' },
    { id = 'wall_first', label = 'Near walls first', toggle = true, def = true,
      hint = 'With Measure from the gun on: the mod cannot see walls, so an enemy behind a rock still counts. When the gun steadily measures something near (under 12 m) well in front of the enemy, the near distance wins.' },
    { id = 'seat_ease', label = 'Enemy time in seats', min = 0.1, max = 2, step = 0.05, def = 0.6, unit = ' s',
      hint = 'On the FRV gun, emplacements and mechs: how long the view takes to follow an enemy\'s distance. Slower than on foot, since a seat turns the whole view.' },
  } },
  { name = 'STANCE', rows = {
    { head = 'CROUCHED' },
    { id = 'crouch_fwd', label = 'Forward', min = -0.4, max = 0.4, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back while you crouch.' },
    { id = 'crouch_up', label = 'Height', min = -0.4, max = 0.4, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height while you crouch.' },
    { id = 'crouch_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right while you crouch.' },
    { id = 'crouch_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle while you crouch. SAME = the normal field of view.' },
    { head = 'PRONE' },
    { id = 'prone_fwd', label = 'Forward', min = -0.4, max = 0.4, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back while you lie down.' },
    { id = 'prone_up', label = 'Height', min = -0.4, max = 0.4, step = 0.01, def = 0.1, unit = ' m',
      hint = 'Extra height while you lie down. Raise it if the view sinks into the ground.' },
    { id = 'prone_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right while you lie down.' },
    { id = 'prone_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle while you lie down. SAME = the normal field of view.' },
    { head = 'DIVING' },
    { id = 'dive_hide', label = 'Hide collar and shoulders: forward', toggle = true, def = true,
      hint = 'Hides the neck, body and shoulder armour from the start of a forward dive until you stand up, so the view is not inside the collar.' },
    { id = 'dive_hide_side', label = 'Hide collar and shoulders: sideways', toggle = true, def = false,
      hint = 'The same for dives to the left or right.' },
    { id = 'dive_hide_back', label = 'Hide collar and shoulders: backward', toggle = true, def = false,
      hint = 'The same for dives backward.' },
    { id = 'dive_fwd', label = 'Forward', min = 0, max = 0.5, step = 0.01, def = 0.2, unit = ' m',
      hint = 'Moves the view forward during a forward or sideways dive, out of the collar.' },
    { id = 'bdive_fwd', label = 'Backward dive: forward', min = -0.4, max = 0.4, step = 0.01, def = -0.1, unit = ' m',
      hint = 'During a backward dive, until you lie still: moves the view the way you look. Minus = back toward your head, away from your legs.' },
    { id = 'dive_look', label = 'Backward dive: lowest look', min = 0, max = 80, step = 1, def = 24, unit = ' deg', zero = 'OFF',
      hint = 'During a backward dive, until you lie still, the view tilts no further down than this (eased), so it never looks into your own body.' },
    { id = 'onback_reach', label = 'On your back: most behind the hips', min = 0, max = 0.6, step = 0.01, def = 0.45, unit = ' m', zero = 'OFF',
      hint = 'Once you lie still on your back (not during the dive): the view is never further than this behind your hips. Higher = closer to your head.' },
    { id = 'onback_height', label = 'On your back: lowest height', min = 0, max = 1, step = 0.01, def = 0.4, unit = ' m', zero = 'OFF',
      hint = 'While you lie on your back the view is never lower than this over your hips (your head is about this high when you aim).' },
    { id = 'getup_cam', label = 'Smooth view while getting up', toggle = true, def = true,
      hint = 'While you get up from lying down the view follows your head smoothly instead of every jerk of the animation.' },
    { id = 'getup_ahead', label = 'Stay ahead when down', min = 0, max = 0.6, step = 0.05, def = 0.3, unit = ' m',
      hint = 'While you get up, the view stays at least this far in front of your body, the way you look, so you never see your own back.' },
    { id = 'getup_lift', label = 'Lift while getting up', min = 0, max = 0.6, step = 0.05, def = 0.45, unit = ' m',
      hint = 'Raises the view this much while you get up, eased in and out, so it stays over your shoulders.' },
    { head = 'STATIONARY RELOAD' },
    { id = 'srl_fwd', label = 'Forward', min = -0.4, max = 0.4, step = 0.01, def = 0.32, unit = ' m',
      hint = 'Extra forward or back while you look behind you during a support weapon reload that holds you in place, standing or crouched. Grows as you turn past your side.' },
    { id = 'srl_up', label = 'Height', min = -0.4, max = 0.4, step = 0.01, def = 0.04, unit = ' m',
      hint = 'Extra height during that reload.' },
    { id = 'srl_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right during that reload.' },
    { head = 'SLIDING' },
    { id = 'slide_fwd', label = 'Forward', min = -0.4, max = 0.4, step = 0.01, def = 0.08, unit = ' m',
      hint = 'Extra forward or back while you slide, so the view stays out of your armour.' },
    { id = 'slide_up', label = 'Height', min = -0.4, max = 0.4, step = 0.01, def = 0.05, unit = ' m',
      hint = 'Extra height while you slide.' },
    { id = 'slide_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right while you slide.' },
    { head = 'LYING DOWN' },
    { id = 'eyes', label = 'View from past the head when down', toggle = true, def = false,
      hint = 'While diving or lying, the view sits just past the top of your head, following the animation, so it stays out of your body.' },
    { id = 'eye_fwd', label = 'Distance past the head', min = 0, max = 0.3, step = 0.01, def = 0.1, unit = ' m',
      hint = 'How far past the top of the head the view sits while diving or lying.' },
    { id = 'back_lift', label = 'Lift when looking back lying down', min = 0, max = 1, step = 0.01, def = 0.1, unit = ' m',
      hint = 'Raises the view over your back and gun when you look behind you after a dive, while prone or while getting up.' },
  } },
  { name = 'MESHES', rows = {
    { head = 'THIRD PERSON' },
    { id = 'hide_tp', label = 'Keep hidden in third person', toggle = true, def = false,
      hint = 'On: everything hidden below stays hidden while the game\'s camera is in use too (third person, seats, terminals). Only for you.' },
    { head = 'ALWAYS' },
    { id = 'hide_helmet', label = 'Hide helmet and head', toggle = true, def = true,
      hint = 'Hidden only for you while first person is on. Others still see it.' },
    { id = 'hide_neck', label = 'Hide neck', toggle = true, def = true, hint = 'The collar and the undersuit neck that poke into the view.' },
    { id = 'hide_body', label = 'Hide body armour', toggle = true, def = false, hint = 'Chest armour and its kit.' },
    { id = 'hide_shoulders', label = 'Hide shoulders', toggle = true, def = false, hint = 'Both shoulder pads.' },
    { id = 'hide_arm_l', label = 'Hide left arm', toggle = true, def = false, hint = 'Left arm armour.' },
    { id = 'hide_arm_r', label = 'Hide right arm', toggle = true, def = false, hint = 'Right arm armour.' },
    { id = 'hide_hips', label = 'Hide hips', toggle = true, def = false, hint = 'Hip armour and its kit.' },
    { id = 'hide_legs', label = 'Hide legs', toggle = true, def = false, hint = 'Leg armour and its kit.' },
    { id = 'hide_under', label = 'Hide undergarments', toggle = true, def = false, hint = 'The suit under the hip and leg armour.' },
    { id = 'hide_cape', label = 'Hide cape', toggle = true, def = false, hint = 'Your cape.' },
    { id = 'hide_pda', label = 'Hide PDA', toggle = true, def = false, hint = 'The PDA hanging from your hips.' },
    { id = 'hide_sample', label = 'Hide sample container', toggle = true, def = false, hint = 'The sample container hanging from your hips.' },
    { head = 'GUNS' },
    { id = 'hide_held_primary', label = 'Hide primary in hand', toggle = true, def = false, hint = 'Your primary weapon while you hold it.' },
    { id = 'hide_held_secondary', label = 'Hide secondary in hand', toggle = true, def = false, hint = 'Your sidearm while you hold it.' },
    { id = 'hide_held_support', label = 'Hide support weapon in hand', toggle = true, def = false, hint = 'Your support weapon while you hold it.' },
    { id = 'hide_stowed_primary', label = 'Hide stowed primary', toggle = true, def = false, hint = 'Your primary weapon slung on your back.' },
    { id = 'hide_stowed_secondary', label = 'Hide stowed secondary', toggle = true, def = false, hint = 'Your sidearm in its holster.' },
    { id = 'hide_stowed_support', label = 'Hide stowed support weapon', toggle = true, def = true, hint = 'Your support weapon carried on your back.' },
    { id = 'hide_stowed_backpack', label = 'Hide backpack', toggle = true, def = false, hint = 'The backpack on your back (supply, shield, jump pack...).' },
    { head = 'OTHER PIECES' },
    { id = 'extra1', label = 'Piece 1', toggle = true, def = false, extra = 1,
      hint = 'A piece of your outfit with no known name (pouch, kit...): hides it whole. Numbered as found.' },
    { id = 'extra2', label = 'Piece 2', toggle = true, def = false, extra = 2, hint = 'Another unnamed piece: hides it whole.' },
    { id = 'extra3', label = 'Piece 3', toggle = true, def = false, extra = 3, hint = 'Another unnamed piece: hides it whole.' },
    { id = 'extra4', label = 'Piece 4', toggle = true, def = false, extra = 4, hint = 'Another unnamed piece: hides it whole.' },
    { head = 'WHILE SCOPED' },
    { id = 'hide_armor', label = 'Hide armour while scoped', toggle = true, def = true,
      hint = 'Hides neck, body armour and shoulders while you look down the game\'s own scope.' },
  } },
  { name = 'FRV', rows = {
    { head = 'MODEL' },
    { id = 'frv_pick', global = true, label = 'FRV model to edit', min = 1, max = #FRVS, step = 1, def = 1,
      hint = 'Pick the FRV the rows below change. Each FRV keeps its own settings.' },
    { id = 'frv_tp', label = 'Third person in this FRV', toggle = true, def = false,
      hint = 'Switches to the game\'s camera in this FRV. Off = first person with the offsets below.' },
    { id = 'frv_fov', label = 'Field of view in this FRV', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in this FRV, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'frv_look', label = 'Lowest look in this FRV', min = 0, max = 80, step = 1, def = 35, unit = ' deg', zero = 'OFF',
      hint = 'Every seat of this FRV: the view tilts no further down than this (eased), so you never look into your own collar. Not while aiming.' },
    { id = 'frv_back', label = 'Looking back: view forward', toggle = true, def = true,
      hint = 'Every seat of this FRV: looking back past your shoulder slides the view the way you look, so you do not look into your own back and shoulders. Not while aiming.' },
    { id = 'frv_back_fwd', label = 'Looking back: forward', min = 0, max = 0.5, step = 0.01, def = 0.15, unit = ' m',
      hint = 'How far the view slides the way you look when you look back in this FRV. Too far and it goes into the seat.' },
    { id = 'frv_back_up', label = 'Looking back: height', min = -0.3, max = 0.3, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height while you look back in this FRV.' },
    { head = 'DRIVER' },
    { id = 'frv_tpd', label = 'Third person when driving', toggle = true, def = false,
      hint = 'The game camera in the driver seat only. Third person in this FRV on = every seat.' },
    { id = 'frv_fwd', label = 'Forward', min = -0.6, max = 0.6, step = 0.01, def = 0.06, unit = ' m',
      hint = 'Extra forward or back while you drive an FRV.' },
    { id = 'frv_up', label = 'Height', min = -0.6, max = 0.6, step = 0.01, def = 0.02, unit = ' m',
      hint = 'Extra height while you drive an FRV.' },
    { id = 'frv_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right while you drive an FRV.' },
    { head = 'PASSENGER' },
    { id = 'frvp_tp', label = 'Third person as a passenger', toggle = true, def = false,
      hint = 'The game camera in a passenger seat only.' },
    { id = 'frvp_fwd', label = 'Forward', min = -0.6, max = 0.6, step = 0.01, def = 0.06, unit = ' m',
      hint = 'Extra forward or back in an FRV passenger seat.' },
    { id = 'frvp_up', label = 'Height', min = -0.6, max = 0.6, step = 0.01, def = 0.02, unit = ' m',
      hint = 'Extra height in an FRV passenger seat.' },
    { id = 'frvp_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in an FRV passenger seat.' },
    { head = 'GUNNER' },
    { id = 'frvg_tp', label = 'Third person on the gun', toggle = true, def = false,
      hint = 'The game camera on the gun only.' },
    { id = 'frvg_fwd', label = 'Forward', min = -0.6, max = 0.6, step = 0.01, def = -0.04, unit = ' m',
      hint = 'Extra forward or back on the FRV gun.' },
    { id = 'frvg_up', label = 'Height', min = -0.6, max = 0.6, step = 0.01, def = 0.2, unit = ' m',
      hint = 'Extra height on the FRV gun.' },
    { id = 'frvg_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right on the FRV gun.' },
  } },
  { name = 'TANKS', rows = {
    { head = 'BASTION PASSENGERS' },
    { id = 'tp_bastion', label = 'Third person', toggle = true, def = true,
      hint = 'The passenger seats. The driver and the gunner: TANK CREW below.' },
    { id = 'bastion_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in a Bastion passenger seat, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'bastion_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back in a Bastion passenger seat (third person there must be off).' },
    { id = 'bastion_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height in a Bastion passenger seat (third person there must be off).' },
    { id = 'bastion_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in a Bastion passenger seat (third person there must be off).' },
    { head = 'MAELSTROM PASSENGERS' },
    { id = 'tp_maelstrom', label = 'Third person', toggle = true, def = true,
      hint = 'The passenger seats. The driver and the gunner: TANK CREW below.' },
    { id = 'maelstrom_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in a Maelstrom passenger seat, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'maelstrom_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back in a Maelstrom passenger seat (third person there must be off).' },
    { id = 'maelstrom_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height in a Maelstrom passenger seat (third person there must be off).' },
    { id = 'maelstrom_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in a Maelstrom passenger seat (third person there must be off).' },
    { head = 'TANK CREW' },
    { id = 'tgun_fp', label = 'First person as gunner', toggle = true, def = false,
      hint = 'First person in the gunner seat of a Bastion or Maelstrom (off: the game camera). The view turns with the turret.' },
    { id = 'tgun_fwd', label = 'Gunner forward', min = -5, max = 5, step = 0.05, def = 2.2, unit = ' m',
      hint = 'Forward or back from your head in the gunner seat, along the look (the turret).' },
    { id = 'tgun_up', label = 'Gunner height', min = -1, max = 5, step = 0.05, def = 1.3, unit = ' m',
      hint = 'Up or down from your head in the gunner seat.' },
    { id = 'tgun_side', label = 'Gunner sideways', min = -3, max = 3, step = 0.05, def = 0, unit = ' m',
      hint = 'Left (minus) or right in the gunner seat.' },
    { id = 'tdrv_fp', label = 'First person as driver', toggle = true, def = false,
      hint = 'First person in the driver seat (off: the game camera). Its offsets go along the hull, so looking round turns the view in place.' },
    { id = 'tdrv_fwd', label = 'Driver forward', min = -5, max = 5, step = 0.05, def = 0.1, unit = ' m',
      hint = 'Forward or back from your head in the driver seat, along the hull.' },
    { id = 'tdrv_up', label = 'Driver height', min = -1, max = 5, step = 0.05, def = 1, unit = ' m',
      hint = 'Up or down from your head in the driver seat (the driver sits inside the hull: up puts the view at the hatch).' },
    { id = 'tdrv_side', label = 'Driver sideways', min = -3, max = 3, step = 0.05, def = 0, unit = ' m',
      hint = 'Left (minus) or right in the driver seat, along the hull.' },
  } },
  { name = 'MECHS', rows = {
    { head = 'MECH' },
    { id = 'cockpit_look', global = true, label = 'Cockpit', min = 1, max = 2, step = 1, def = 1, names = { 'GLASS', 'FULLY CLEAR' },
      hint = 'Every exosuit, with the Glass cockpit option ticked in Arsenal: while you sit in it the cockpit turns to glass (GLASS) or is not there at all (FULLY CLEAR).' },
    { id = 'cockpit_glass', global = true, label = 'Cockpit glass', min = 1, max = 2, step = 1, def = 1, names = { 'CLEARER', 'HARSHER' },
      hint = 'How the cockpit glass looks: CLEARER = a light see-through glass, HARSHER = the game glass (stronger shine and haze). Takes up to 2 seconds.' },
    { id = 'mech_pick', global = true, label = 'Mech model to edit', min = 1, max = #MECHS, step = 1, def = 1,
      hint = 'Pick the exosuit the mech rows below change. Each exosuit keeps its own settings.' },
    { id = 'glass_shield', global = true, label = 'Glass shield', toggle = true, def = true,
      hint = 'With the Glass cockpit option ticked in Arsenal: while you sit in a Breakthrough its shield turns to the same glass as the cockpit, so you see through it.' },
    { id = 'shield_glass', global = true, label = 'Shield glass', min = 1, max = 2, step = 1, def = 1, names = { 'CLEARER', 'HARSHER' },
      hint = 'How the Breakthrough shield glass looks: CLEARER = a light see-through glass, HARSHER = the game glass (stronger shine and haze). Takes up to 2 seconds.' },
    { id = 'tp_mech', label = 'Third person in a mech', toggle = true, def = false,
      hint = 'Switches to the game\'s camera while you pilot an exosuit. Off = first person with the offsets below.' },
    { id = 'mech_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in a mech, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'mech_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back in a mech (third person in a mech must be off).' },
    { id = 'mech_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height in a mech (third person in a mech must be off).' },
    { id = 'mech_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in a mech (third person in it must be off).' },
    { id = 'mech_view', label = 'View', min = 1, max = 2, step = 1, def = 1, names = { 'COCKPIT', 'GUN LINE' },
      hint = 'First person in a mech: COCKPIT = at your head; GUN LINE = on the line the mech aims along, so the crosshair is exact.' },
    { id = 'mech_dist', label = 'Line up at', min = 0, max = 300, step = 5, def = 50, unit = ' m', zero = 'OFF',
      hint = 'COCKPIT view: the view turns so the crosshair meets the shots this far away (the mech camera sits far behind you). OFF = the game look.' },
    { id = 'mech_near', label = 'Nearest enemy distance', min = 0, max = 100, step = 1, def = 25, unit = ' m',
      hint = 'With Correct for enemies (AIM tab): an enemy nearer than this lines up here instead, so the view is not thrown about up close.' },
    { id = 'mech_glide', label = 'Glide to a new distance', min = 0, max = 5, step = 0.5, def = 2, unit = ' s', zero = 'QUICK',
      hint = 'COCKPIT view: a new enemy distance is reached over this long, eased in and out. QUICK = a quarter second.' },
    { id = 'mech_clip', label = 'Cut the cockpit', min = 0, max = 2, step = 0.05, def = 0, unit = ' m', zero = 'OFF',
      hint = 'Nothing nearer the view than this is drawn in this mech: the cockpit frame and glass (about 0.6), the arm housing beside GUN LINE (about 1.2). Works on every mech, no extra files.' },
    { id = 'mech_wide', label = 'Keep the widest field of view', toggle = true, def = true,
      hint = 'The game narrows the view while the mech aims. On = first person keeps the widest seen in this mech (Field of view at SAME and GAME).' },
    { head = 'MECH HUD' },
    { id = 'hud_on', label = 'Mech HUD', toggle = true, def = true,
      hint = 'While you drive a mech: the hull exact, each part in the game damage steps, both arms and their rounds (bottom right).' },
    { id = 'hud_tp', label = 'Also in third person', toggle = true, def = true,
      hint = 'Off = the Mech HUD only while first person is on.' },
    { id = 'hud_size', label = 'Size', min = 50, max = 200, step = 5, def = 100, unit = ' %',
      hint = 'How big the Mech HUD is drawn.' },
    { id = 'hud_right', label = 'From the right', min = 0, max = 1200, step = 10, def = 40, unit = ' px',
      hint = 'Distance from the right edge (at 1080 lines; scales with the screen).' },
    { id = 'hud_bottom', label = 'From the bottom', min = 0, max = 800, step = 10, def = 40, unit = ' px',
      hint = 'Distance from the bottom edge (at 1080 lines; scales with the screen).' },
    { id = 'hud_alpha', label = 'Opacity', min = 10, max = 100, step = 5, def = 85, unit = ' %',
      hint = 'How solid the Mech HUD is.' },
    { head = 'EMPLACEMENT' },
    { id = 'empl_pick', global = true, label = 'Emplacement to edit', min = 1, max = #EMPLS, step = 1, def = 1,
      hint = 'Pick the emplacement the rows below change. Each one keeps its own settings.' },
    { id = 'tp_empl', label = 'Third person on an emplacement', toggle = true, def = true,
      hint = 'Switches to the game\'s camera on an HMG or anti-tank emplacement. Off = the offsets below.' },
    { id = 'empl_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle on an emplacement, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'empl_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back on an emplacement (third person on it must be off).' },
    { id = 'empl_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height on an emplacement (third person on it must be off).' },
    { id = 'empl_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right on an emplacement (third person on it must be off).' },
  } },
  { name = 'IMMERSE', rows = {
    { head = 'NECK' },
    { id = 'imm_on', label = 'Immersive mode', toggle = true, def = false,
      hint = 'Your head only turns so far, like a real neck. Look further and your whole body turns with you.' },
    { id = 'neck_yaw', label = 'Neck turn', min = 20, max = 120, step = 5, def = 45, unit = ' deg',
      hint = 'How far your head turns left or right of your chest before the body turns too. Lower = the body follows sooner.' },
    { id = 'look_back', label = 'Running: furthest look', min = 0, max = 180, step = 5, def = 75, unit = ' deg', zero = 'OFF',
      hint = 'While you sprint, the view stays within this of where your body runs, so you cannot look behind you. Walking is free. The mouse still steers.' },
  } },
  { name = 'KEYS', rows = {
    { head = 'FIRST PERSON' },
    { id = 'toggle', label = 'First person on/off', key = true, def = 'f6', hint = 'Press RIGHT, then the new key. DELETE sets none.' },
    { id = 'freelook', label = 'Hold for free look', key = true, def = 'x',
      hint = 'Hold to look around while your gun keeps aiming where it was. Let go and the view swings back. Press RIGHT, then the new key.' },
    { id = 'fl_max', label = 'Free look: furthest turn', min = 15, max = 180, step = 5, def = 75, unit = ' deg',
      hint = 'How far free look turns to each side. 180 = all the way round, so you can look behind you.' },
    { id = 'peek', label = 'Hold for third person', key = true, def = 'off',
      hint = 'Hold to see the game\'s camera, let go to go back. Press RIGHT, then the new key.' },
    { id = 'tp_key', label = 'Toggle for third person', key = true, def = 'off',
      hint = 'Press for the game\'s camera, press again to go back. Press RIGHT, then the new key. DELETE sets none.' },
    { id = 'profile_key', label = 'Next profile', key = true, def = 'off',
      hint = 'Switches to the next of the five profiles. Press RIGHT, then the new key. DELETE sets none.' },
    { id = 'reset_key', label = 'Reset camera', key = true, def = 'off',
      hint = 'Hands the camera back and finds your Helldiver again by where the game camera sits (first person stays on or off). For a stuck view or a wrong Helldiver.' },
    { head = 'CONTROLLER' },
    { id = 'pad_toggle', label = 'Controller: first person on/off', key = true, def = 'off',
      hint = 'A controller button: bind it in the loader options (this panel takes keyboard keys). Press: first person on or off. Hold 1 s: reset camera.' },
    { id = 'pad_hold', label = 'Controller: hold with it', key = true, def = 'off',
      hint = 'Set, the button above counts only while this one is held, and on a double tap (as LT + double-tap down: the D-pad also enters stratagems).' },
    { head = 'PANEL' },
    { id = 'panel', label = 'Open this panel', key = true, def = 'f10', hint = 'Press RIGHT, then the new key. DELETE sets none.' },
    { id = 'tab_prev', label = 'Previous tab', key = true, def = 'a', hint = 'Moves to the tab on the left. Press RIGHT, then the new key.' },
    { id = 'tab_next', label = 'Next tab', key = true, def = 'd', hint = 'Moves to the tab on the right. Press RIGHT, then the new key.' },
  } },
}
-- free look's rows also show at the top of CAMERA, under PROFILE (user): the same row tables, so both set one value
for i = #TABS[#TABS].rows, 1, -1 do
  local r = TABS[#TABS].rows[i]
  if r.id == 'freelook' or r.id == 'fl_max' then table.insert(TABS[1].rows, 3, r) end
end
table.insert(TABS[1].rows, 3, { head = 'FREE LOOK' })
for _, tab in ipairs(TABS) do  -- every tab ends with its own reset button
  tab.rows[#tab.rows + 1] = { reset_tab = true, label = 'RESET THIS TAB TO DEFAULT',
    hint = 'Puts every setting on this tab back to default (every model on model tabs). Press twice to confirm.' }
end
-- per-weapon settings: CAMERA, AIM and STANCE open with a weapon list; every row there except the shared ones
-- (switching, death, troubleshooting, vehicle distances, global rows) can have its own value per weapon (r.wpn)
-- the weapon the panel edits (nil = All weapons), whose values V holds (live: false = All weapons), the eased ones,
-- the per-weapon rows and the weapon list; its helpers live on it too (the main chunk is at Lua's 200-local limit)
local WP = { sel = nil, live = nil, tgt = {}, marks = {}, ROW = {}, LIST = {} }
do
  local NOT_WPN = { ['FREE LOOK'] = true, SWITCHING = true, ['(Experimental, report issues!)'] = true, DEATH = true, TILT = true,
    gun_dist = true, empl_dist = true, seat_ease = true }
  for _, tab in ipairs(TABS) do
    if tab.name == 'CAMERA' or tab.name == 'AIM' or tab.name == 'STANCE' then
      local h
      for _, r in ipairs(tab.rows) do
        if r.head then h = r.head
        elseif r.id and not r.global and not r.key and not NOT_WPN[h] and not NOT_WPN[r.id] then r.wpn = true; WP.ROW[r.id] = r end
      end
      table.insert(tab.rows, 1, { wpick = true, label = 'Settings for',
        hint = 'A weapon picked here gets its own values on CAMERA, AIM and STANCE, used while it is in your hands. ENTER: the list.' })
      table.insert(tab.rows, 1, { head = 'WEAPON' })
      tab.all = tab.rows
    end
  end
end
-- mesh names per row (each also tried with _male/_female, then _LOD1.._LOD5): the game's own names
local GROUPS = {
  hide_helmet = { 'g_helmet', 'g_helmet_low', 'g_head', 'g_head_01', 'g_helldiver_head_01', 'g_hair', 'g_visor' },
  hide_neck = { 'g_neck', 'g_neck_body', 'g_neck_armor', 'g_light_neck', 'neck', 'neck_body', 'neck_armor', 'light_neck',
    'g_c_neck', 'c_neck', 'g_c_neck1', 'c_neck1', 'g_m_neck', 'm_neck', 'g_neck1', 'neck1', 'g_neck2', 'neck2',
    'g_neck_01', 'neck_01', 'g_neck_02', 'neck_02', 'g_neck_03', 'neck_03', 'g_neck_04', 'neck_04', 'g_neck_whole',
    'neck_whole', 'g_neck_cull', 'neck_cull', 'g_neck_back_jiggle', 'neck_back_jiggle', 'g_neck_front_jiggle',
    'neck_front_jiggle', 'g_torso_undergarment' },  -- the undersuit's torso is the visible neck
  hide_body = { 'g_torso', 'g_torso_kit', 'g_torso_kit_1', 'g_torso_kit_2', 'g_helldiver_torso_01' },
  hide_shoulders = { 'g_shoulder_l', 'g_shoulder_r', 'g_l_shoulderpad', 'g_r_shoulderpad' },
  -- the body armour's arms are their own pieces (g_torso_arm_*: found in the game's short-name list, 2026-11-06)
  hide_arm_l = { 'g_arm_l', 'g_torso_arm_l' },
  hide_arm_r = { 'g_arm_r', 'g_torso_arm_r' },
  hide_hips = { 'g_legs_hips', 'g_legs_hips_kit', 'g_legs_hips_kit_1' },
  hide_legs = { 'g_leg_l', 'g_leg_r', 'g_leg_l_kit', 'g_leg_r_kit', 'g_helldiver_legs_01' },
  hide_under = { 'g_legs_hips_undergarment', 'g_legs_hips_undergarment_kit', 'g_leg_undergarment_l', 'g_leg_undergarment_r' },
  hide_cape = { 'g_cape', 'g_medium_cape', 'g_medium_cape_simple', 'g_medium_cape_simple_partial', 'g_shock_trooper_cape',
    'g_shock_trooper_cape_simple', 'g_shock_trooper_cape_simple_partial' },
}
local SCOPED = { hide_neck = true, hide_body = true, hide_shoulders = true }
local V, ROW = {}, {}
-- profile 1 keeps the plain save names (settings from before profiles); 2-5 save as p<N>_<id>; keys + global rows are shared
local function sk(r)
  local n = V.profile or tonumber(chef.load('profile', 1)) or 1
  return (n > 1 and not r.global) and ('p' .. n .. '_' .. r.id) or r.id
end
-- a weapon's own value: w<kind>_<save name>, saved only while it differs from All weapons
function WP.key(r, kind) return 'w' .. kind .. '_' .. sk(r) end
-- a row's saved value (for a weapon: its own, else All weapons'): its default when there's none or it's another type
-- (a setting added in a newer version, a damaged save), numbers held to the row's range
local function load_row(r, kind)
  local v = chef.load(sk(r), r.def)
  if kind and r.wpn then local w = chef.load(WP.key(r, kind)); if type(w) == type(v) then v = w end end
  if type(v) ~= type(r.def) then return r.def end
  if type(v) == 'number' and r.min then v = math.min(r.max, math.max(r.min, v)) end
  return v
end
-- the user's tuned values as defaults for vehicle rows, per model copy (copies otherwise take the base row's own default)
local MY_DEF = { frv_fwd = 0.08, frv_up = -0.08, frv_side = 0, frvp_fwd = 0, frvp_up = 0, frvp_side = 0, sp_frv_fwd = 0.08, sp_frv_up = -0.08, sp_frv_side = 0, sp_frvp_fwd = 0, sp_frvp_up = 0, sp_frvp_side = 0, fl_frv_fwd = 0.08, fl_frv_up = -0.08, fl_frv_side = 0, fl_frvp_fwd = 0, fl_frvp_up = 0, fl_frvp_side = 0, se_frv_fwd = 0.08, se_frv_up = -0.08, se_frv_side = 0, se_frvp_fwd = 0, se_frvp_up = 0, se_frvp_side = 0, frvg_fwd = 0, frvg_up = 0.06, frvg_side = 0, fl_frvg_fwd = 0, fl_frvg_up = 0.06, fl_frvg_side = 0,
  se_frvg_fwd = 0, se_frvg_up = 0.06, se_frvg_side = 0,
  tp_empl = false, at_tp_empl = false, empl_up = 0.15 }
-- immersive mode paused (user, 2026-11-07): tab hidden, V.imm_on stays nil so neck() never runs. The free look key is
-- live again (2.1.37, HUD.free_step): it turns only the view now, the body is left to the game
for i = #TABS, 1, -1 do if TABS[i].name == 'IMMERSE' then table.remove(TABS, i) end end
local binds = {}
for _, tab in ipairs(TABS) do
  for _, r in ipairs(tab.rows) do
    if r.id and ROW[r.id] ~= r then  -- headings and the reset button have none; free look's rows sit in two tabs
      r.def0 = r.def
      if MY_DEF[r.id] ~= nil then r.def = MY_DEF[r.id] end
      ROW[r.id] = r
      if r.key then binds[r.id] = chef.bind(r.id, r.def, r.label) else V[r.id] = load_row(r) end
    end
  end
end
-- one copy of a model's rows per model (FRVs, mechs, emplacements); the VEHICLES tab shows the picked model's copy
local PICKS = {
  frv_pick = { models = FRVS, match = function(id) return id:match('^frv[pg]?_') end,
    skip = function(f, r) return f.nogun and (r.head == 'GUNNER' or (r.id or ''):match('^frvg_')) end },
  mech_pick = { models = MECHS, match = function(id) return id == 'tp_mech' or id:match('^mech_') end,
    skip = function(f, r) return f.name ~= 'BREAKTHROUGH' and (r.id == 'glass_shield' or r.id == 'shield_glass') end },
  empl_pick = { models = EMPLS, match = function(id) return id == 'tp_empl' or id:match('^empl_') end },
}
for pid, pk in pairs(PICKS) do
  pk.at, pk.sets = {}, {}
  for _, tab in ipairs(TABS) do for _, r in ipairs(tab.rows) do if r.id == pid then pk.rows = tab.rows end end end
  local VEH = pk.rows
  pk.base = {}
  for i, r in ipairs(VEH) do pk.base[i] = r end
  for i, r in ipairs(VEH) do if r.id and r.id ~= pid and pk.match(r.id) then pk.at[#pk.at + 1] = i end end
  for i, f in ipairs(pk.models) do
    pk.sets[i] = {}
    for j, at in ipairs(pk.at) do
      local c = {}
      for k, v in pairs(VEH[at]) do c[k] = v end
      c.id = f.pre .. c.id
      c.def = MY_DEF[c.id]
      if c.def == nil then c.def = VEH[at].def0 end
      if c.id:match('frv_tp$') then c.label = 'Third person in ' .. f.name:sub(1, 1) .. f.name:sub(2):lower() .. ' FRV' end
      pk.sets[i][j] = c
      if f.pre ~= '' then ROW[c.id] = c; V[c.id] = load_row(c) end
    end
  end
end
local function show_pick(pid)
  local pk = PICKS[pid]
  local i = V[pid]
  local m, set = pk.models[i] or pk.models[1], pk.sets[i] or pk.sets[1]
  local j, n = 1, 0
  for k in pairs(pk.rows) do pk.rows[k] = nil end
  for at, r in ipairs(pk.base) do
    if pk.at[j] == at then r = set[j]; j = j + 1 end
    if not (pk.skip and pk.skip(m, pk.base[at])) then n = n + 1; pk.rows[n] = r end
  end
end
for pid in pairs(PICKS) do show_pick(pid) end
local function set(id, v)
  local r = ROW[id]
  if r.key then chef.set(id, v); return end
  if not r.toggle then v = max(r.min, min(r.max, floor(v / r.step + 0.5) * r.step)) end
  V[id], WP.tgt[id] = v, nil
  local w = r.wpn and WP.sel
  local key, base = sk(r), r.def
  if w then key, base, WP.marks[w] = WP.key(r, w), load_row(r), nil end
  if v == base then chef.save(key, nil) else chef.save(key, v) end  -- (v ~= def and v or nil) lost every false
  if PICKS[id] then show_pick(id) end
  if id == 'profile' then  -- load the new profile's values
    for rid, row in pairs(ROW) do if not row.key and not row.global then V[rid] = load_row(row, WP.live) end end
    for pid in pairs(PICKS) do show_pick(pid) end
    WP.tgt, WP.marks = {}, {}
  end
end

---------------------------------------------------------------------------------------------------- camera
local S = { on = false, cams = {}, head = nil, look = 0, bw = 0, shown = false, frv_t = 0, said = {}, parts = {}, hidden = {}, uhid = {}, ghid = {}, gst = {}, gsaid = {}, world = -1,
  t = 0, rescans = {} }
-- a node index is only passed on while the unit has that many nodes: the loader checks the unit, not the index, and
-- indices are kept (per kind, per unit), so a handle the engine hands out again for another unit must not get one
-- that is out of range. Counted once a frame per unit; no count to be had = asked as before.
local nodes_n, nodes_t = {}, nil
local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end
-- a position that isn't a number (NaN or infinite: a body mid-teardown, a bad frame) is never used: upos gives nil
-- and marks the unit for this frame (bad_now), so the head is kept and first person holds where it was this frame.
-- For 1 s at most: a body that stays NaN (stuck mid-teardown) is then let go like a gone one
local function bad_now(u) local b = S.bad and S.bad[u]; return b ~= nil and b.f == S.fno and S.t - b.t0 < 1 end
local function upos(u, i)
  if i and i ~= 1 then
    if nodes_t ~= S.t then nodes_n, nodes_t = {}, S.t end
    local n = nodes_n[u]
    if n == nil then n = tonumber((call('Unit.num_scene_graph_items', u))) or false; nodes_n[u] = n end
    if n and (i < 1 or i > n) then
      if not S.said['node' .. tostring(i)] then S.said['node' .. tostring(i)] = true; log('node %s not asked: the unit has %d', tostring(i), n) end
      return nil
    end
  end
  local x, y, z = chef.unit_position(u, i)
  if x ~= nil and not (finite(x) and finite(y) and finite(z)) then
    S.bad = S.bad or {}
    local b = S.bad[u]
    if not b or b.f < S.fno - 1 then b = { t0 = S.t }; S.bad[u] = b end  -- a new run of NaN frames
    b.f = S.fno
    if not S.said.badpos then S.said.badpos = true; log('a position came back not a number: that frame is skipped') end
    return nil
  end
  return x, y, z
end
-- a camera unit's camera, only while it still has that slot (the slot list is kept between camera list changes)
local function cam_of(k)
  local n = tonumber((call('Unit.num_cameras', k.u)))
  if n and k.slot > n then
    if not S.said['slot' .. k.slot] then S.said['slot' .. k.slot] = true; log('camera slot %d not asked: the unit has %d', k.slot, n) end
    return nil
  end
  return call('Unit.camera', k.u, k.slot)
end
-- the diver's animation state, only while the body still has its animation: asking a dead body whose animation the
-- game has torn down crashed the game a few seconds after every death (2026-11-07).
-- No animation left = dead: the game's view from then on (S.dead)
-- Never in a hellpod (S.nopod: climbing in on the ship, the drop in a mission) or on the ship's cutscene camera: the
-- game takes that body apart for the launch, the same tear-down the death crash came from. Reports of a crash at the
-- hellpod (2026-11-09) came with this asked every frame from climbing in until the ship unloaded.
local UnitApi = rawget(_G, 'Unit') or rawget(_G, 'stingray') and stingray.Unit
local function raw_anim(ok, ...)
  if ok then return ... end
  if not S.said.rawanim then S.said.rawanim = true; log('animation layers: %s', tostring((...))) end
end
-- all = every layer's state: chef.call passes on only the first 4, so the engine is called straight. That skips the
-- loader's guard, so never down, dead or in a hellpod, and inside a pcall (the ship too: the pod check needs it)
-- corpses, never picked as yours:
--   proven (the body's animation gone): every one in the mission, not just the latest (a second death let the first
--     corpse be picked again: its tallest height measured lying, so it read as standing). Dropped once the unit is
--     gone, since the engine hands handles out again
--   guessed (lying when the cameras changed, or lost while lying): every one too (a single slot let a second guess
--     free the first), but the body standing up again with its animation releases it, so a living body taken for
--     dead isn't shut out for good
-- S.corpses[u] = 'proven' or 'guess'; S.corpse is the latest marked
local function proven(u) return u ~= nil and S.corpses ~= nil and S.corpses[u] == 'proven' end
local function is_corpse(u) return u ~= nil and S.corpses ~= nil and S.corpses[u] ~= nil end
-- S.corpse_h[u]: how tall it stood alive (head over feet), when it was yours
local function tall_of(u)
  if S.head and S.head.u == u and S.hmax then S.corpse_h = S.corpse_h or {}; S.corpse_h[u] = S.hmax end
end
local function mark_corpse(u)
  if u == nil then return end
  S.corpses = S.corpses or {}; S.corpses[u], S.corpse = 'proven', u
  tall_of(u)
end
local function mark_guess(u)
  if u == nil then return end
  S.corpses = S.corpses or {}
  if S.corpses[u] ~= 'proven' then S.corpses[u] = 'guess' end
  S.corpse = u
  tall_of(u)
end
local function unmark(u)
  if S.corpses then S.corpses[u] = nil end
  if S.corpse_h then S.corpse_h[u] = nil end
  if S.corpse == u then S.corpse = nil end
end
local function prune_corpses()
  for u in pairs(S.corpses or {}) do if not alive(u) then S.corpses[u] = nil; if S.corpse_h then S.corpse_h[u] = nil end end end
  if S.corpse ~= nil and not alive(S.corpse) then S.corpse = nil end
end
local function anim(u, all)
  if not u or S.nopod then return nil end
  -- mission: not while the game camera falls (a drop not yet seen as one: the world can settle mid-drop) and not
  -- until it has been still for 0.5 s
  if chef.in_mission() and (S.calm_t or 0) < 0.5 then return nil end
  if S.down_any and chef.in_mission() and (S.atrace or 0) <= S.t then S.atrace = S.t + 0.5; log('asking the animation while down') end
  local has, why = call('Unit.has_animation_state_machine', u)
  if has == false then
    if S.head and u == S.head.u and not S.dead and chef.in_mission() then S.dead, S.dead_u = true, u; log('the body has no animation left (dead): game camera') end
    -- certain: the body's animation is gone. It's the corpse from now on (never picked, never 'up' again)
    if S.head and u == S.head.u and S.dead then S.dsure = 'anim'; mark_corpse(u) end
    return nil
  end
  -- the check itself refused: still never ask a body that's down
  if has == nil then if not S.said.asm then S.said.asm = true; log('animation check unavailable: %s', tostring(why)) end; if S.down_any then return nil end end
  if all then
    if not (has == true and not (S.down_any or S.dead or S.down) and UnitApi and UnitApi.animation_get_state and alive(u)) then return nil end
    return raw_anim(pcall(UnitApi.animation_get_state, u))
  end
  return call('Unit.animation_get_state', u)
end
local frv_watch = chef.watch and chef.watch(FRV_KINDS, 2) or nil
local mech_watch = chef.watch and chef.watch(MECH_KINDS, 2) or nil
local tank_watch = chef.watch and chef.watch(TANK_KINDS, 2) or nil
local empl_watch = chef.watch and chef.watch(EMPL_KINDS, 2) or nil

local function xyz(v)
  if v == nil then return nil end
  local x, y, z = call('Vector3.to_elements', v)
  if finite(x) and finite(y) and finite(z) then return x, y, z end
end
local function once(k, ...) if not S.said[k] then S.said[k] = true; log(...) end end

local BONES = { 'head', 'chest', 'hips' }
-- gear hung on the hips, separate units hidden whole (ids from the files a PDA/sample container remover replaces)
local GEAR = { ['1c8764d62e12925a'] = 'hide_pda', a9936cbe561e8180 = 'hide_sample' }
-- GUNS BEGIN
local GUNS = {  -- generated by gen_guns.py: kind = { category, mesh names (8 hex digits: name unknown), in-game name }
  ['028a1ed2394fb808'] = { 'attachment', { '6ab8513e' } },  -- (part 028a1ed2394fb808)
  ['02cd7321cd8445f5'] = { 'attachment', { '96e432de', '04e82c2b', '9390a8ea', '3753cefa' } },  -- (part 02cd7321cd8445f5)
  ['0aae32c4479eaa26'] = { 'attachment', { 'g_muzzle_12g_half_choke_LOD2', 'g_muzzle_12g_half_choke_LOD1', 'g_muzzle_12g_half_choke' } },  -- muzzle_12g_half_choke
  ['0c7314742b88806c'] = { 'attachment', { 'g_muzzle_plasma_choke_LOD2', 'g_muzzle_plasma_choke_LOD1', 'g_muzzle_plasma_choke' } },  -- muzzle_plasma_choke
  ['11eccafa4b56a49c'] = { 'attachment', { 'g_bullet' } },  -- (part 11eccafa4b56a49c)
  ['129e5fb1b13c2018'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_lowpower_scope
  ['177863efec0c9807'] = { 'attachment', { '0bff5ba3', '893a2efc', 'g_advanced_vertical_grip_LOD3', 'g_advanced_vertical_grip_LOD2', 'g_advanced_vertical_grip_LOD1', 'g_advanced_vertical_grip' } },  -- advanced_verticalgrip
  ['206cb0dd1696ceaa'] = { 'attachment', { '32fcead7' } },  -- (part 206cb0dd1696ceaa)
  ['20e05bca458a39e8'] = { 'attachment', { 'g_casing' } },  -- (part 20e05bca458a39e8)
  ['2457b559aa341cc1'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_support
  ['26ec4f9513fc6525'] = { 'attachment', { 'g_muzzlebreak_LOD2', 'g_muzzlebreak_LOD1', 'g_muzzlebreak' } },  -- muzzle_12mm_muzzlebreak
  ['28aee9c6a2282aa3'] = { 'attachment', { 'g_compensator_LOD2', 'g_compensator_LOD1', 'g_compensator' } },  -- muzzle_5mm_compensator
  ['2ed76d29ce509a74'] = { 'attachment', { 'g_flashhider_LOD2', 'g_flashhider_LOD1', 'g_flashhider' } },  -- muzzle_5mm_flashhider
  ['309f7e645a8d2b56'] = { 'attachment', { 'g_standard_laser_flashlight_pistol_LOD2', 'g_standard_laser_flashlight_pistol_LOD1', 'g_standard_laser_flashlight_pistol' } },  -- standard_laser_flashlight_pistol
  ['316a396d1939a997'] = { 'attachment', { 'g_flashhider_LOD2', 'g_flashhider_LOD1', 'g_flashhider' } },  -- muzzle_12mm_flashhider
  ['350168e3fd02b325'] = { 'attachment', { 'g_smart_pistol_missile_projectile' } },  -- (part 350168e3fd02b325)
  ['3692944f9a88fdef'] = { 'attachment', { 'g_lens', 'g_high_power_scope_LOD1', 'g_high_power_scope' } },  -- optics_highpower_scope_02
  ['36e235816805c17e'] = { 'attachment', { 'g_casing' } },  -- (part 36e235816805c17e)
  ['3a8ad42985c52dc7'] = { 'attachment', { 'g_optics_marksman_rifle_shark_LOD2', 'g_optics_marksman_rifle_shark_LOD1', 'g_lens', 'g_optics_marksman_rifle_shark' } },  -- optics_marksman_rifle_shark
  ['3ae8ba6377efe3ae'] = { 'attachment', { 'g_muzzle_10g_full_choke_LOD2', 'g_muzzle_10g_full_choke_LOD1', 'g_muzzle_10g_full_choke' } },  -- muzzle_10g_full_choke
  ['3d58ea61b2b485cc'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_reddot
  ['44a2a59ca08ac865'] = { 'attachment', { 'g_scope_LOD1', 'g_scope', 'g_lens' } },  -- optics_midpower_scope
  ['45be635fb904f4dc'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_reddot_04
  ['4851d75853622a47'] = { 'attachment', { 'g_muzzle_LOD3', 'g_muzzle_LOD2', 'g_muzzle_LOD1', 'g_muzzle', 'g_crosshair' } },  -- muzzle_revolver_medium
  ['5c1e075cba68340b'] = { 'attachment', { 'g_muzzlebreak_LOD2', 'g_muzzlebreak_LOD1', 'g_muzzlebreak' } },  -- muzzle_5mm_muzzlebreak
  ['642f2be0417d0beb'] = { 'attachment', { 'fb2d2b3a', 'db0230e8', '7984f3e8', 'g_muzzle_drake_LOD2', 'g_muzzle_drake_LOD1', 'g_muzzle_drake' } },  -- muzzle_drake
  ['6600b5e755a21f1f'] = { 'attachment', { 'e1fd6bb8', '72fa07d8', '165d989f', '35860123' } },  -- (part 6600b5e755a21f1f)
  ['679e174bb3bcca68'] = { 'attachment', { 'fb64cea2', 'c8a6ed88', 'a9a6a8fe', '53245725' } },  -- (part 679e174bb3bcca68)
  ['68513d59bafa8c7a'] = { 'attachment', { 'g_grenade_40mm' } },  -- (part 68513d59bafa8c7a)
  ['6b88fea13ec2d78e'] = { 'attachment', { 'g_muzzle_naked_LOD2', 'g_muzzle_naked_LOD1', 'g_muzzle_naked' } },  -- muzzle_12mm_naked
  ['6b9572ac0f687394'] = { 'attachment', { 'g_pistol_12mm' } },  -- (part 6b9572ac0f687394)
  ['6d54652ee217d712'] = { 'attachment', { 'g_lens', 'g_optics_highpower_scope_LOD1', 'g_optics_highpower_scope' } },  -- optics_highpower_scope
  ['7301b3dc5b1bffb8'] = { 'attachment', { 'g_lens', 'g_scope_LOD2', 'g_scope_LOD1', 'g_scope' } },  -- sniper_rifle_helghast_scope
  ['7441b048b94491fc'] = { 'attachment', { 'g_standard_laser_pistol_LOD2', 'g_standard_laser_pistol_LOD1', 'g_standard_laser_pistol' } },  -- standard_laser_pistol
  ['74b9289347cc3503'] = { 'attachment', { 'g_muzzle_10g_standard_LOD2', 'g_muzzle_10g_standard_LOD1', 'g_muzzle_10g_standard' } },  -- muzzle_10g_standard
  ['756e3fdaca41cfca'] = { 'attachment', { 'g_muzzle_5mm_naked_LOD2', 'g_muzzle_5mm_naked_LOD1', 'g_muzzle_5mm_naked' } },  -- muzzle_5mm_naked
  ['75713afac474d9c4'] = { 'attachment', { 'g_muzzle_12g_full_choke_LOD2', 'g_muzzle_12g_full_choke_LOD1', 'g_muzzle_12g_full_choke' } },  -- muzzle_12g_full_choke
  ['78829731a0563576'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- (part 78829731a0563576)
  ['7b153e02ad22d12c'] = { 'attachment', { 'g_muzzle_naked_LOD2', 'g_muzzle_naked_LOD1', 'g_muzzle_naked' } },  -- muzzle_8mm_naked
  ['7dc6dda584cc5223'] = { 'attachment', { 'g_muzzle_laser_rifle_charge_standard_LOD2', 'g_muzzle_laser_rifle_charge_standard_LOD1', 'g_muzzle_laser_rifle_charge_standard' } },  -- muzzle_laser_rifle_charge_standard
  ['7f19d05cd188c768'] = { 'attachment', { '21f5173c' } },  -- (part 7f19d05cd188c768)
  ['7fdd884ecd57231b'] = { 'attachment', { 'g_rifle_8mm' } },  -- (part 7fdd884ecd57231b)
  ['83970097f3d997ad'] = { 'attachment', { 'g_scope_LOD2', 'g_scope_LOD1', 'g_scope' } },  -- (part 83970097f3d997ad)
  ['8cd335a5f711bb59'] = { 'attachment', { 'g_muzzle_12g_duckbill_LOD2', 'g_muzzle_12g_duckbill_LOD1', 'g_muzzle_12g_duckbill' } },  -- muzzle_12g_duckbill
  ['8f063c5d3929316e'] = { 'attachment', { '0a690ec1' } },  -- (part 8f063c5d3929316e)
  ['8f6f7c8c1e4b9b6d'] = { 'attachment', { '1fc6a487', 'cd5f9024', 'bbdf1de4', '463f4c9c' } },  -- (part 8f6f7c8c1e4b9b6d)
  ['91eb62e0a02302ba'] = { 'attachment', { '180d0314' } },  -- (part 91eb62e0a02302ba)
  ['9549ff64ba3fd5a1'] = { 'attachment', { 'g_flashlight_verticalgrip_LOD2', 'g_flashlight_verticalgrip_LOD1', 'g_flashlight_verticalgrip' } },  -- flashlight_verticalgrip
  ['9d5e0d88df992aa6'] = { 'attachment', { 'eaf366e4' } },  -- (part 9d5e0d88df992aa6)
  ['9dbc8aa8702ac9e1'] = { 'attachment', { 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_reddot_02
  ['a0b52d203e689d18'] = { 'attachment', { 'g_compensator_LOD2', 'g_compensator_LOD1', 'g_compensator' } },  -- muzzle_8mm_compensator
  ['a188cbb5913fbd63'] = { 'attachment', { '7c833a3b', '88490e43', 'c1aec98c', '0a99f9ee' } },  -- (part a188cbb5913fbd63)
  ['a9a19cffe985c468'] = { 'attachment', { 'g_knife_LOD3', 'g_knife_LOD2', 'g_knife_LOD1', 'g_knife' } },  -- standard_bayonet
  ['ab9e1ad1597d5d9e'] = { 'attachment', { '4ef1256c' } },  -- (part ab9e1ad1597d5d9e)
  ['adc87d576c20ad57'] = { 'attachment', { 'c1c3df5a' } },  -- (part adc87d576c20ad57)
  ['b191a4f26558a9cc'] = { 'attachment', { 'g_muzzlebreak_LOD2', 'g_muzzlebreak_LOD1', 'g_muzzlebreak' } },  -- muzzle_8mm_muzzlebreak
  ['b3bf071f477fc155'] = { 'attachment', { 'g_rocket' } },  -- (part b3bf071f477fc155)
  ['b571e0428ca83b9e'] = { 'attachment', { 'g_muzzle_10g_half_choke_LOD2', 'g_muzzle_10g_half_choke_LOD1', 'g_muzzle_10g_half_choke' } },  -- muzzle_10g_half_choke
  ['b5b4395852e871bc'] = { 'attachment', { 'g_pistol_12mm_long' } },  -- (part b5b4395852e871bc)
  ['b7cd78c71e0a48ed'] = { 'attachment', { '79a465c5' } },  -- (part b7cd78c71e0a48ed)
  ['b9c209b4f99b5335'] = { 'attachment', { 'f61f63d6', 'fd3b6bf3', '49742cd4', '8833df66' } },  -- (part b9c209b4f99b5335)
  ['bc9182001d0312bd'] = { 'attachment', { 'g_muzzle_plasma_standard_LOD2', 'g_muzzle_plasma_standard_LOD1', 'g_muzzle_plasma_standard' } },  -- muzzle_plasma_standard
  ['bcbbe9bb1a49c7fd'] = { 'attachment', { '0873cd93' } },  -- (part bcbbe9bb1a49c7fd)
  ['bd4245dcfd4b832f'] = { 'attachment', { '48b47714', '77b22e9c', '71ad0c48', '7b177187' } },  -- (part bd4245dcfd4b832f)
  ['c70345c3342ca205'] = { 'attachment', { 'g_muzzle_10g_duckbill_LOD2', 'g_muzzle_10g_duckbill_LOD1', 'g_muzzle_10g_duckbill' } },  -- muzzle_10g_duckbill
  ['ccf18b6315a3d67f'] = { 'attachment', { '01c43c80' } },  -- (part ccf18b6315a3d67f)
  ['ce5a33e0063824f1'] = { 'attachment', { 'c8cfb321', 'eb838b2a', '2caf0fec', '35d6c954', '9f0b9507', '1e0bbff1', 'e206ebcc' } },  -- 45degree_verticalgrip
  ['cebd25f8778bfdee'] = { 'attachment', { '856a94fd', 'dcc62bd3', '289adddf', 'd78cb063', '87ca42ee' } },  -- (part cebd25f8778bfdee)
  ['d8cf7fe059b4bf1e'] = { 'attachment', { 'g_muzzle_12g_standard_LOD2', 'g_muzzle_12g_standard_LOD1', 'g_muzzle_12g_standard' } },  -- muzzle_12g_standard
  ['e0e097b347bdfe6c'] = { 'attachment', { '0893e4b7', '2f302a11', 'e43d2c23', '011927a4' } },  -- (part e0e097b347bdfe6c)
  ['e307b6e78b0a8573'] = { 'attachment', { 'b8020048' } },  -- (part e307b6e78b0a8573)
  ['e6b6467135035059'] = { 'attachment', { 'g_standard_flashlight_pistol_LOD2', 'g_standard_flashlight_pistol_LOD1', 'g_standard_flashlight_pistol' } },  -- standard_flashlight_pistol
  ['e98a9be765e0e236'] = { 'attachment', { 'g_syringe_casing' } },  -- (part e98a9be765e0e236)
  ['ec824b9d8b7f7b58'] = { 'attachment', { 'g_compensator_LOD2', 'g_compensator_LOD1', 'g_compensator' } },  -- muzzle_12mm_compensator
  ['f401191f6b5a7879'] = { 'attachment', { 'e58351fa' } },  -- (part f401191f6b5a7879)
  ['f40dea68b213b005'] = { 'attachment', { 'g_trenchgun_bayonet_LOD2', 'g_trenchgun_bayonet_LOD1', 'g_trenchgun_bayonet' } },  -- trenchgun_default_bayonet
  ['f5e1e4bd4ecdc192'] = { 'attachment', { 'g_charge', 'g_lens', 'g_scope_LOD1', 'g_scope' } },  -- optics_railgun
  ['f9c6092b665018b8'] = { 'attachment', { 'g_flashhider_LOD2', 'g_flashhider_LOD1', 'g_flashhider' } },  -- muzzle_8mm_flashhider
  ['f9df21c8e52cac95'] = { 'attachment', { 'g_standard_verticalgrip_LOD2', 'g_standard_verticalgrip_LOD1', 'g_standard_verticalgrip' } },  -- standard_verticalgrip
  ['f9f37dcce764fad6'] = { 'attachment', { 'g_optics_ironsight_LOD2', 'g_optics_ironsight_LOD1', 'g_optics_ironsight' } },  -- optics_ironsight
  ['fa6f926a77b78b55'] = { 'attachment', { 'g_scope_LOD1', 'g_lens', 'g_scope' } },  -- optics_reddot_03
  ['056de1c5e21e723e'] = { 'backpack', { 'g_minigun_backpack_LOD4', 'g_minigun_backpack_LOD3', 'g_minigun_backpack_LOD2', 'g_minigun_backpack_LOD1', 'g_minigun_backpack' } },  -- minigun_backpack
  ['0949eeb3dc920324'] = { 'backpack', { '9f26471c', 'bb62182d', 'aad5763c', 'ffe8bee2', '0cb39fa4', 'b48711bc', 'dff1dd21', '6537c863', 'eb39116a' } },  -- (rack backpack 0949eeb3dc920324)
  ['0a55e504092b981d'] = { 'backpack', { 'g_body_lower_LOD4', 'g_body_lower_LOD3', 'g_body_lower_LOD2', 'g_body_lower_LOD1', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body_lower', 'g_body' } },  -- medic_backpack
  ['12c8d71ac3897a5c'] = { 'backpack', { 'g_shield_generator_backpack_LOD4', 'g_shield_generator_backpack_LOD3', 'g_shield_generator_backpack_LOD2', 'g_shield_generator_backpack_LOD1', 'g_shield_generator_backpack' } },  -- energy_shield_backpack
  ['1a3c51ec3fc5fe99'] = { 'backpack', { 'g_mag_LOD4', 'g_mag_LOD3', 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- drome_mg_magazine
  ['23d09a05d1574ec9'] = { 'backpack', { 'g_heavy_flamethrower_hose_LOD1', 'g_heavy_flamethrower_hose' } },  -- heavy_flamethrower_hose
  ['255ebc5767d7ceec'] = { 'backpack', { 'g_drone_mg_backpack_LOD4', 'g_drone_mg_backpack_LOD3', 'g_drone_mg_backpack_LOD2', 'g_drone_mg_backpack_LOD1', 'g_drone_mg_backpack' } },  -- drone_mg_backpack
  ['2a18f81c44a26771'] = { 'backpack', { '9cfb2b9b', 'd78d9fa5', 'e31d9ccd', '83103290', 'fad1472e', 'c9cee06f', '2b338f9b', '65f7bab9', '2f3ff5dc' } },  -- c4_charge_backpack
  ['3015626aa69f8d4d'] = { 'backpack', { 'g_drone_flamethrower_backpack_LOD4', 'g_drone_flamethrower_backpack_LOD3', 'g_drone_flamethrower_backpack_LOD2', 'g_drone_flamethrower_backpack_LOD1', 'g_ammo', 'g_drone_flamethrower_backpack' } },  -- drone_flamethrower_backpack
  ['43eb1c3c1a1860e0'] = { 'backpack', { 'g_heavy_flamethrower_backpack_LOD4', 'g_heavy_flamethrower_backpack_LOD3', 'g_heavy_flamethrower_backpack_LOD2', 'g_heavy_flamethrower_backpack_LOD1', 'g_heavy_flamethrower_backpack' } },  -- heavy_flamethrower_backpack
  ['4ef9a47109239a58'] = { 'backpack', { 'g_body_lower_LOD4', 'g_body_lower_LOD3', 'g_body_lower_LOD2', 'g_body_lower_LOD1', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body_lower', 'g_body' } },  -- ammo_backpack
  ['51f50d6321f52f3d'] = { 'backpack', { 'g_c4_charge_detonator_LOD4', 'g_c4_charge_detonator_LOD3', 'g_c4_charge_detonator_LOD2', 'g_c4_charge_detonator_LOD1', 'g_c4_charge_detonator' } },  -- c4_charge_detonator
  ['59c5ca839449b379'] = { 'backpack', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- jumppack_backpack
  ['5beec97f4c7f4ae9'] = { 'backpack', { 'g_drone_laser_rifle_LOD4', 'g_drone_laser_rifle_LOD3', 'g_drone_laser_rifle_LOD2', 'g_drone_laser_rifle_LOD1', 'g_drone_laser_rifle' } },  -- drone_laser_rifle
  ['5ec80f4f1cdb66cf'] = { 'backpack', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_meter', 'g_body' } },  -- hover_backpack
  ['5f9aeac72b738298'] = { 'backpack', { '82f779e3', '86bfc9d6', '4ba8eea1', '40da51ae', '7c251487', '067e3f13', '477eac6a', '03f9d0a3', 'g_ballistic_shield_backpack_small_LOD4', 'g_ballistic_shield_backpack_small_LOD3', 'g_ballistic_shield_backpack_small_LOD2', 'g_ballistic_shield_backpack_small_LOD1', '27953ed6', 'g_ballistic_shield_backpack_small' } },  -- ballistic_shield_backpack_small
  ['689bad357793c990'] = { 'backpack', { 'g_gas_projector_LOD4', 'g_gas_projector_LOD3', 'g_gas_projector_LOD2', 'g_gas_projector_LOD1', 'g_gas_projector' } },  -- drone_gas_projector
  ['8ec3026b5f2e579a'] = { 'backpack', { 'f034e244', '1ad52918', '01d2693c', 'fad95cc8', '95561bf1', '942a48e9', '614318d8', 'fb5726b9', 'f1e2c48a', 'da06bb13', '58edaff7', '493d5e51', 'f379c894', 'g_body', 'g_body_LOD1', 'g_body_LOD2', 'g_body_LOD3', 'g_body_LOD4', '362658ff', '7a1c069d', '012b7840', '2972d86b', '3520f764' } },  -- faf_missile_launcher_backpack
  ['967ed15e0bae363b'] = { 'backpack', { 'g_ballistic_shield_broken_LOD4', 'g_ballistic_shield_broken_LOD3', 'g_ballistic_shield_broken_LOD2', 'g_ballistic_shield_broken_LOD1', 'g_ballistic_shield_broken', 'g_ballistic_shield_LOD4', 'g_ballistic_shield_LOD3', 'g_ballistic_shield_LOD2', 'g_ballistic_shield_LOD1', 'g_ballistic_shield' } },  -- ballistic_shield_backpack
  ['96dfc6542aa22980'] = { 'backpack', { 'g_body_extrashot_LOD4', 'g_body_extrashot_LOD3', 'g_body_extrashot_LOD2', 'g_body_extrashot_LOD1', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body_extrashot', 'g_body' } },  -- recoilless_rifle_backpack
  ['9ace8638421abc8e'] = { 'backpack', { 'g_backpack_LOD4', 'g_backpack_LOD3', 'g_backpack_LOD2', 'g_backpack_LOD1', 'g_backpack' } },  -- bomb_backpack
  ['9b75217d8312dd67'] = { 'backpack', { '442bdf62', '367d13b5', '15036f8d', '6c623806', '66ae5e4d', 'e6df3b69', '7db847d8', '32985cca', 'e91252ba' } },  -- c4_charge
  ['9ba9f700137c6325'] = { 'backpack', { 'g_hose_LOD1', 'g_hose' } },  -- minigun_backpack_hose
  ['a0ff2f9a0ca6992a'] = { 'backpack', { 'g_drone_mg_LOD4', 'g_drone_mg_LOD3', 'g_drone_mg_LOD2', 'g_drone_mg_LOD1', 'g_drone_mg' } },  -- drone_mg
  ['a1a026c8bb37a96e'] = { 'backpack', { 'g_drone_generic_backpack_LOD2', 'g_drone_generic_backpack_LOD1', 'g_drone_generic_backpack' } },  -- drone_generic_backpack
  ['a32621e3bde13379'] = { 'backpack', { 'cd0cc184', '3120c1fc', '893f4573', '29fde842', '00a7f137', 'g_gun_LOD4', 'g_gun_LOD3', 'g_gun_LOD2', 'g_gun_LOD1', 'g_gun' } },  -- drone_mg_weapon
  ['a4e796f84801b40a'] = { 'backpack', { 'g_directional_energy_shield_backpack_LOD3', 'g_directional_energy_shield_backpack_LOD2', 'g_directional_energy_shield_backpack_LOD1', 'g_directional_energy_shield_backpack' } },  -- directional_energy_shield_backpack
  ['b49756795d9b0e68'] = { 'backpack', { 'g_displacement_backpack_LOD4', 'g_displacement_backpack_LOD3', 'g_displacement_backpack_LOD2', 'g_displacement_backpack_LOD1', 'g_displacement_backpack' } },  -- displacement_backpack
  ['b56fa3f5510000ab'] = { 'backpack', { 'g_energy_shield' } },  -- directional_energy_shield
  ['b8feb0cc191c1ef3'] = { 'backpack', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- faf_missile_launcher_helghast_backpack
  ['bb4b15b588f974fd'] = { 'backpack', { 'g_belt_fed_grenade_launcher_backpack_LOD4', 'g_belt_fed_grenade_launcher_backpack_LOD3', 'g_belt_fed_grenade_launcher_backpack_LOD2', 'g_belt_fed_grenade_launcher_backpack_LOD1', 'g_belt_fed_grenade_launcher_backpack' } },  -- belt_fed_grenade_launcher_backpack
  ['bf7082f0287c254f'] = { 'backpack', { 'g_hose_LOD1', 'g_hose' } },  -- belt_fed_grenade_launcher_backpack_hose
  ['bffcb4cd971a8eda'] = { 'backpack', { 'g_drone_gas_backpack_LOD4', 'g_drone_gas_backpack_LOD3', 'g_drone_gas_backpack_LOD2', 'g_drone_gas_backpack_LOD1', 'g_ammo', 'g_drone_gas_backpack' } },  -- drone_gas_projector_backpack
  ['c28da712b12e3dfa'] = { 'backpack', { 'g_guard_dog_stun_backpack_LOD2', 'g_guard_dog_stun_backpack_LOD1', 'g_guard_dog_stun_backpack' } },  -- guard_dog_stun_backpack
  ['c6cba4152177ddc5'] = { 'backpack', { 'g_drone_flamethrower_LOD4', 'g_drone_flamethrower_LOD3', 'g_drone_flamethrower_LOD2', 'g_drone_flamethrower_LOD1', 'g_drone_flamethrower' } },  -- drone_flamethrower
  ['cb8d6dbe2ad74be4'] = { 'backpack', { 'g_drone_mg_LOD4', 'g_drone_mg_LOD3', 'g_drone_mg_LOD2', 'g_drone_mg_LOD1', 'g_drone_mg' } },  -- drone_generic
  ['e60ae045e0090f4c'] = { 'backpack', { '9b282329', '452c4e2e', 'ee9489d4', '027839c4', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', '9192fd94', 'b46c6598', 'e48a26fe', '9c55fa7c', '26db9683', 'b43383f7', '0a157dc5', 'g_body' } },  -- automatic_cannon_backpack
  ['e75cd68e858a12ac'] = { 'backpack', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_extra_rockets_LOD4', 'g_extra_rockets_LOD3', 'g_extra_rockets_LOD2', 'g_extra_rockets_LOD1', 'g_body', 'g_extra_rockets' } },  -- air_burst_rocket_backpack
  ['f5c67aed5cb5aca0'] = { 'backpack', { 'd4642d12', '22a2b618', '0f57dd18', '4fd54821', '6c670961', 'f29a5714', '72ba1016', 'efb5a16c', 'g_ballistic_shield_backpack_mk2_LOD4', 'g_ballistic_shield_backpack_mk2_LOD3', 'g_ballistic_shield_backpack_mk2_LOD2', 'g_ballistic_shield_backpack_mk2_LOD1', '44a66610', 'g_ballistic_shield_backpack_mk2' } },  -- ballistic_shield_backpack_mk2
  ['f9d5219640d65ef9'] = { 'backpack', { 'cd0cc184', '3120c1fc', '893f4573', '29fde842', 'g_gun_LOD4', 'g_gun_LOD3', 'g_gun_LOD2', 'g_gun_LOD1', 'g_gun' } },  -- drone_assault_rifle
  ['fd91a6b676a254e0'] = { 'backpack', { 'g_guard_dog_stun_LOD4', 'g_guard_dog_stun_LOD3', 'g_guard_dog_stun_LOD2', 'g_guard_dog_stun_LOD1', 'g_guard_dog_stun' } },  -- guard_dog_stun
  ['005c2262f672caf4'] = { 'magazine', { 'g_mesh_LOD2', 'g_mesh_LOD1', 'g_mesh' } },  -- magnum_pistol_magazine_standard
  ['029cfc4c193211c3'] = { 'magazine', { 'g_jet_rifle_stick_magazine_large_LOD2', 'g_jet_rifle_stick_magazine_large_LOD1', 'g_jet_rifle_stick_magazine_large' } },  -- jet_rifle_stick_magazine_large
  ['076692fd83a83c5c'] = { 'magazine', { 'g_energy_weapon_shark_magazine_LOD2', 'g_energy_weapon_shark_magazine_LOD1', 'g_energy_weapon_shark_magazine' } },  -- energy_weapon_shark_magazine
  ['07d605bd50c98461'] = { 'magazine', { 'g_mag_standard_LOD2', 'g_mag_standard_LOD1', 'g_mag_standard' } },  -- vigilance_magazine_extended
  ['13a5fc03ec21e8fb'] = { 'magazine', { 'c9a1bb8a', 'a44c7159', '38d9da82', '23099a10' } },  -- smg_defender_extended_magazine
  ['16ab263bc03b4f96'] = { 'magazine', { 'g_assault_rifle_karbin_magazine_standard_LOD2', 'g_assault_rifle_karbin_magazine_standard_LOD1', 'g_assault_rifle_karbin_magazine_standard' } },  -- assault_rifle_karbin_magazine_standard
  ['193becdf64aa66a9'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- magazine_plasma_medium_standard
  ['1b1fcc0e025c1f7d'] = { 'magazine', { 'g_smg_flamer_extended_magazine_LOD2', 'g_smg_flamer_extended_magazine_LOD1', 'g_smg_flamer_extended_magazine' } },  -- smg_flamer_extended_magazine
  ['1ec5f54265a91c83'] = { 'magazine', { 'g_jet_rifle_drum_magazine_LOD2', 'g_jet_rifle_drum_magazine_LOD1', 'g_jet_rifle_drum_magazine' } },  -- jet_rifle_drum_magazine
  ['20c03774d6e1d87f'] = { 'magazine', { '430b99a5', 'c60c8398', '78069017', 'a642f8ee' } },  -- assault_rifle_risk_magazine_standard
  ['2d761a80bcbfe792'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- assaultrifle_extended_magazine_fastreload
  ['2e7f91374c0b471c'] = { 'magazine', { '8be2635e', '500f9df3', '3b00ccde', 'e3d56820', '09ea1d4d' } },  -- magazine_mediumheatsink_laserrifle_improvedcooldown
  ['344cbd588a1f8058'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- assaultrifle_standard_magazine_fastreload
  ['369b53e850e72ba9'] = { 'magazine', { 'g_pdw_drum_magazine_LOD2', 'g_pdw_drum_magazine_LOD1', 'g_pdw_drum_magazine' } },  -- pdw_drum_magazine_pepper
  ['37c2891774b38c87'] = { 'magazine', { 'g_marksmanrifle_extended_magazine_LOD2', 'g_marksmanrifle_extended_magazine_LOD1', 'g_marksmanrifle_extended_magazine' } },  -- marksmanrifle_extended_magazine
  ['3ddb9d36da22555d'] = { 'magazine', { 'g_drummag_LOD2', 'g_drummag_LOD1', 'g_drummag' } },  -- assaultshotgun_drum_magazine
  ['43639dc374b75c5f'] = { 'magazine', { 'g_smg_nacho_mag_standard_LOD2', 'g_smg_nacho_mag_standard_LOD1', 'g_smg_nacho_mag_standard' } },  -- smg_nacho_mag_standard
  ['462fc89d4903b33d'] = { 'magazine', { 'g_marksmanrifle_standard_magazine_LOD2', 'g_marksmanrifle_standard_magazine_LOD1', 'g_marksmanrifle_standard_magazine' } },  -- marksmanrifle_standard_magazine
  ['48d2ddc8e9a80b1e'] = { 'magazine', { 'g_magazine_LOD2', 'g_magazine_LOD1', 'g_magazine' } },  -- smg_helghast_magazine
  ['48fd06b465e8b681'] = { 'magazine', { 'g_missile_LOD2', 'g_missile_LOD1', 'g_missile' } },  -- faf_missile_standard
  ['4f839e923046e631'] = { 'magazine', { 'g_pistol_magazine_LOD2', 'g_pistol_magazine_LOD1', 'g_pistol_magazine' } },  -- pistol_magazine
  ['4ffb842ce1093f3f'] = { 'magazine', { 'g_pistol_nacho_mag_standard_LOD2', 'g_pistol_nacho_mag_standard_LOD1', 'g_pistol_nacho_mag_standard' } },  -- pistol_nacho_mag_standard
  ['503c0e01fbafa86a'] = { 'magazine', { '70341ac1', '86ce79d9', '0e75a989', 'abdb8a12', 'railgun_casing' } },  -- railgun_magazine
  ['50cd7e9f909fe5a1'] = { 'magazine', { '55a7aacc', '03f093b5', '472d81e8', 'a737d89e', 'b93bedeb' } },  -- magazine_mediumheatsink_laserrifle_standard
  ['511910c41a70122d'] = { 'magazine', { 'g_canister_LOD3', 'g_canister_LOD2', 'g_canister_LOD1', 'g_canister' } },  -- flamethrower_ripley_canister
  ['5207aee5f447a3e4'] = { 'magazine', { '617f7774', 'e050d422', '5fa35eb3', '2636a778', '35c4f730', 'ee85f404', '7a6ca089', '8b4d64c2' } },  -- grenade_launcher_ammo_box
  ['52ff81fcba0c059d'] = { 'magazine', { 'g_magazine_LOD2', 'g_magazine_LOD1', 'g_magazine' } },  -- plasma_blaster_canister
  ['541eb319127c7484'] = { 'magazine', { 'g_assault_rifle_grenadier_magazine_standard_LOD2', 'g_assault_rifle_grenadier_magazine_standard_LOD1', 'g_assault_rifle_grenadier_magazine_standard' } },  -- assault_rifle_grenadier_magazine_standard
  ['5f4b129d947d79d7'] = { 'magazine', { '8ce373d5', '23299127', '71cefe8c' } },  -- grenade_40mm_frag
  ['612f7f6193fb1b2b'] = { 'magazine', { 'g_battery' } },  -- laser_battery_large
  ['618c00f2f115c1fe'] = { 'magazine', { 'g_volley_gun_magazine_LOD2', 'g_volley_gun_magazine_LOD1', 'g_volley_gun_magazine' } },  -- volley_gun_magazine
  ['619795f79ceda1b3'] = { 'magazine', { 'g_pistol_shark_magazine_LOD2', 'g_pistol_shark_magazine_LOD1', 'g_pistol_shark_magazine' } },  -- pistol_shark_magazine
  ['68b8d040421e8a49'] = { 'magazine', { 'g_assaultshotgun_box_magazine_extended_LOD2', 'g_assaultshotgun_box_magazine_extended_LOD1', 'g_assaultshotgun_box_magazine_extended' } },  -- assaultshotgun_box_magazine_extended
  ['6abddd8224a3328f'] = { 'magazine', { 'g_smg_solvent_extended_magazine_LOD2', 'g_smg_solvent_extended_magazine_LOD1', 'g_smg_solvent_extended_magazine' } },  -- smg_solvent_extended_magazine
  ['6c0b6e983bbfc1f1'] = { 'magazine', { 'g_mag_small_LOD2', 'g_mag_small_LOD1', 'g_mag_small' } },  -- machinegun_box_small
  ['6e165f05a49233f6'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- sniperrifle_standard_magazine
  ['6f5afa606a4400d1'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- pdw_standard_magazine_pepper
  ['7372947782b91123'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- smg_rhino_standard_magazine
  ['73a5ecad32ba599b'] = { 'magazine', { 'g_lmg_box_large_LOD2', 'g_lmg_box_large_LOD1', 'g_lmg_box_large' } },  -- lmg_box_large
  ['77c5d934407114f4'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- pdw_extended_magazine
  ['7be1e04a7738e673'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- assaultrifle_extended_magazine
  ['7f0e355dedbdf3d5'] = { 'magazine', { 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- assault_rifle_helghast_magazine
  ['7f49b46efdd850ef'] = { 'magazine', { 'g_assault_rifle_nacho_mag_standard_LOD2', 'g_assault_rifle_nacho_mag_standard_LOD1', 'g_assault_rifle_nacho_mag_standard' } },  -- assault_rifle_nacho_mag_standard
  ['80e8335ab4042fcf'] = { 'magazine', { '4ec58784', '7c980a51', 'g_heatsink_LOD1', 'g_heatsink' } },  -- hotshot_heatsink
  ['80f0a339e905d2d3'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- magazine_plasma_medium_extended
  ['819ec78bcaf69c49'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- chemgun_cannister
  ['820ac4b5db9b2585'] = { 'magazine', { 'f4831d23', '5347a9c7', '29f759a4', '79750977', '84df6b9e' } },  -- crossbow_greyfax_explosive_magazine
  ['89cce4d15db88aa8'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- assaultrifle_rico_magazine_standard
  ['8a7631bbb4f6f3d8'] = { 'magazine', { 'g_marksman_rifle_shark_magazine_LOD2', 'g_marksman_rifle_shark_magazine_LOD1', 'g_marksman_rifle_shark_magazine' } },  -- marksman_rifle_shark_magazine
  ['8f141212b0f6f515'] = { 'magazine', { 'g_smg_solvent_standard_magazine_LOD2', 'g_smg_solvent_standard_magazine_LOD1', 'g_smg_solvent_standard_magazine' } },  -- smg_solvent_standard_magazine
  ['9237ccec8fe86d22'] = { 'magazine', { 'g_smg_flamer_standard_magazine_LOD2', 'g_smg_flamer_standard_magazine_LOD1', 'g_smg_flamer_standard_magazine' } },  -- smg_flamer_standard_magazine
  ['925b08e8fad4b36b'] = { 'magazine', { 'g_laser_rifle_charge_magazine_small_dmg_LOD4', 'g_laser_rifle_charge_magazine_small_dmg_LOD3', 'g_laser_rifle_charge_magazine_small_dmg_LOD2', 'g_laser_rifle_charge_magazine_small_dmg_LOD1', 'g_laser_rifle_charge_magazine_small_dmg', 'g_laser_rifle_charge_magazine_small_LOD3', 'g_laser_rifle_charge_magazine_small_LOD4', 'g_laser_rifle_charge_magazine_small_LOD2', 'g_laser_rifle_charge_magazine_small_LOD1', 'g_laser_rifle_charge_magazine_small' } },  -- laser_rifle_charge_quick_fire_heatsink
  ['963aca558cd906bc'] = { 'magazine', { 'g_assault_rifle_large_calibre_mag_standard_LOD2', 'g_assault_rifle_large_calibre_mag_standard_LOD1', 'g_assault_rifle_large_calibre_mag_standard' } },  -- assault_rifle_large_calibre_mag_standard
  ['97856895ea7a7b96'] = { 'magazine', { '0ad5e1f7', 'g_smg_flamer_magazine_helical_LOD2', 'g_smg_flamer_magazine_helical_LOD1', 'g_smg_flamer_magazine_helical' } },  -- smg_flamer_magazine_helical
  ['986e6696b34b8902'] = { 'magazine', { 'g_marksmanrifle_short_magazine_LOD2', 'g_marksmanrifle_short_magazine_LOD1', 'g_marksmanrifle_short_magazine' } },  -- marksmanrifle_short_magazine
  ['990b06bf5c26bd01'] = { 'magazine', { 'g_plasmacanister_LOD2', 'g_plasmacanister_LOD1', 'g_plasmacanister' } },  -- magazine_plasma_pistol_extended
  ['9992e382b80955cc'] = { 'magazine', { 'g_boxmag_LOD2', 'g_boxmag_LOD1', 'g_boxmag' } },  -- assaultshotgun_box_magazine
  ['9b30d4ac39ddff10'] = { 'magazine', { 'g_mag_standard_LOD2', 'g_mag_standard_LOD1', 'g_mag_standard' } },  -- vigilance_magazine_standard
  ['9c22a90da9c79de3'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- flamethrower_canister
  ['9d81323b153dc429'] = { 'magazine', { 'g_mag_large_LOD2', 'g_mag_large_LOD1', 'g_mag_large' } },  -- machinegun_box_large
  ['a134e110ef4ef865'] = { 'magazine', { 'g_magazine_LOD1', 'g_magazine' } },  -- flamer_pistol_canister
  ['a4fa3ef43a8cecaf'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- assaultrifle_standard_magazine
  ['aca180fc6f846411'] = { 'magazine', { 'g_plasmacanister_LOD2', 'g_plasmacanister_LOD1', 'g_plasmacanister' } },  -- magazine_plasma_pistol_standard
  ['b1bc2b7252ccbc03'] = { 'magazine', { '11b79ad0', '779e0ecf', '9ef7eab5', '54166987', 'b1e8845b' } },  -- magazine_mediumheatsink_laserrifle_improvedcapacity
  ['b7cd35e0edc15cd7'] = { 'magazine', { 'g_boxmag_LOD4', 'g_boxmag_LOD3', 'g_boxmag_LOD2', 'g_boxmag_LOD1', 'g_boxmag' } },  -- heavy_mg_box_large
  ['b98f2b3d1bde24b0'] = { 'magazine', { 'g_grenade_launcher_ammo_frag_LOD4', 'g_grenade_launcher_ammo_frag_LOD3', 'g_grenade_launcher_ammo_frag_LOD2', 'g_grenade_launcher_ammo_frag_LOD1', 'g_grenade_launcher_ammo_frag' } },  -- grenade_launcher_ammo_frag
  ['bdbefa6543a75942'] = { 'magazine', { 'g_marksmanrifle_standard_drake_magazine_LOD4', 'g_marksmanrifle_standard_drake_magazine_LOD3', 'g_marksmanrifle_standard_drake_magazine_LOD2', 'g_marksmanrifle_standard_drake_magazine_LOD1', 'g_marksmanrifle_standard_drake_magazine' } },  -- marksmanrifle_standard_drake_magazine
  ['be0ac4e655b2e19f'] = { 'magazine', { 'g_magazine_LOD2', 'g_magazine_LOD1', 'g_magazine' } },  -- faf_missile_launcher_helghast_magazine
  ['be4590c2f615c441'] = { 'magazine', { 'g_smg_defender_standard_magazine_LOD2', 'g_smg_defender_standard_magazine_LOD1', 'g_smg_defender_standard_magazine' } },  -- smg_defender_standard_magazine
  ['bfc3a108c853a738'] = { 'magazine', { 'g_mag' } },  -- laser_battery_small
  ['c245c696e80677ed'] = { 'magazine', { 'g_standard_magazine_LOD3', 'g_standard_magazine_LOD2', 'g_standard_magazine_LOD1', 'g_standard_magazine' } },  -- battle_rifle_standard_magazine
  ['c61c59b6b987bc27'] = { 'magazine', { 'g_marksmanrifle_short_drake_magazine_LOD4', 'g_marksmanrifle_short_drake_magazine_LOD3', 'g_marksmanrifle_short_drake_magazine_LOD2', 'g_marksmanrifle_short_drake_magazine_LOD1', 'g_marksmanrifle_short_drake_magazine' } },  -- marksmanrifle_short_drake_magazine
  ['c891acf9e8dbda97'] = { 'magazine', { 'g_mag_extended_LOD2', 'g_mag_extended_LOD1', 'g_mag_extended' } },  -- automatic_pistol_extended_magazine
  ['cc4cd9593abb87be'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- pdw_standard_magazine
  ['d44c25420aa3e2ff'] = { 'magazine', { 'g_laser_rifle_charge_magazine_dmg_LOD4', 'g_laser_rifle_charge_magazine_dmg_LOD3', 'g_laser_rifle_charge_magazine_dmg_LOD2', 'g_laser_rifle_charge_magazine_dmg_LOD1', 'g_laser_rifle_charge_magazine_dmg', 'g_laser_rifle_charge_magazine_LOD4', 'g_laser_rifle_charge_magazine_LOD3', 'g_laser_rifle_charge_magazine_LOD2', 'g_laser_rifle_charge_magazine_LOD1', 'g_laser_rifle_charge_magazine' } },  -- laser_rifle_charge_magazine
  ['d5cb9b5401b261f9'] = { 'magazine', { '0b5c35f4', 'g_smg_flamer_cannister_LOD1', 'g_smg_flamer_cannister' } },  -- smg_flamer_cannister
  ['db50297b40133d12'] = { 'magazine', { 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- recoilless_grenade_standard
  ['dd8cbbac49f7c628'] = { 'magazine', { 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- sniper_rifle_helghast_magazine
  ['e3541de70b7ec1c0'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- laser_battery_medium
  ['e4b63990d1feb4c3'] = { 'magazine', { 'g_laser_rifle_charge_magazine_large_dmg_LOD4', 'g_laser_rifle_charge_magazine_large_dmg_LOD3', 'g_laser_rifle_charge_magazine_large_dmg_LOD2', 'g_laser_rifle_charge_magazine_large_dmg_LOD1', 'g_laser_rifle_charge_magazine_large_dmg', 'g_laser_rifle_charge_magazine_large_LOD4', 'g_laser_rifle_charge_magazine_large_LOD3', 'g_laser_rifle_charge_magazine_large_LOD2', 'g_laser_rifle_charge_magazine_large_LOD1', 'g_laser_rifle_charge_magazine_large' } },  -- laser_rifle_charge_extended_heatsink
  ['e53e4b0c20563d21'] = { 'magazine', { 'g_magazine_heatsink_revolver' } },  -- magazine_heatsink_revolver
  ['e8de5e95b9635c21'] = { 'magazine', { 'g_drummag_LOD2', 'g_drummag_LOD1', 'g_drummag' } },  -- assaultrifle_drum_magazine
  ['ee89d98cbe33e976'] = { 'magazine', { 'g_pdw_drum_magazine_LOD2', 'g_pdw_drum_magazine_LOD1', 'g_pdw_drum_magazine' } },  -- pdw_drum_magazine
  ['fa6c1158a93b8ec4'] = { 'magazine', { 'g_mag_LOD2', 'g_mag_LOD1', 'g_mag' } },  -- pdw_extended_magazine_pepper
  ['fc1f0a3b3fc97238'] = { 'magazine', { 'g_smart_pistol_magazine_standard_LOD2', 'g_smart_pistol_magazine_standard_LOD1', 'g_smart_pistol_magazine_standard' } },  -- smart_pistol_magazine_standard
  ['006e44327bb953fe'] = { 'primary', { 'g_pump_grenade_launcher_LOD4', 'g_pump_grenade_launcher_LOD3', 'g_pump_grenade_launcher_LOD2', 'g_pump_grenade_launcher_LOD1', 'g_pump_grenade_launcher' }, 'GL-15 Evictor' },  -- pump_grenade_launcher
  ['03e67a19b07c6523'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' }, 'R-63 Diligence' },  -- marksman_rifle_vigilance
  ['05d8d8c073b9d502'] = { 'primary', { '8755602b', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-8P Punisher Plasma' },  -- pump_shotgun_plasma
  ['076dd5d4f4360204'] = { 'primary', { 'g_arc_shotgun_LOD4', 'g_arc_shotgun_LOD3', 'g_arc_shotgun_LOD2', 'g_arc_shotgun_LOD1', 'g_arc_shotgun' }, 'ARC-12 Blitzer' },  -- arc_shotgun
  ['0c197bbd8d2c725b'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'AR-23P Liberator Penetrator' },  -- assault_rifle_penetrator
  ['0f83639ab8c86165'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'R-2 Amendment' },  -- battle_rifle_ceremonial
  ['11ec8e2296a3d662'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-20 Halt' },  -- pump_shotgun_02
  ['16051937941bb709'] = { 'primary', { 'g_rhino_default_muzzle_LOD2', 'g_rhino_default_muzzle_LOD1', 'g_rhino_default_muzzle' } },  -- smg_rhino_default_muzzle
  ['186ea95de7306b1a'] = { 'primary', { 'g_smg_solvent_LOD4', 'g_smg_solvent_LOD3', 'g_smg_solvent_LOD2', 'g_smg_solvent_LOD1', 'g_smg_solvent' }, 'SMG-203 Gallant' },  -- smg_solvent
  ['1abbff60d26ba391'] = { 'primary', { 'g_marksman_rifle_shark_LOD4', 'g_marksman_rifle_shark_LOD3', 'g_marksman_rifle_shark_LOD2', 'g_marksman_rifle_shark_LOD1', 'g_marksman_rifle_shark' }, 'R/40-K Hot-Shot Marksman Rifle' },  -- marksman_rifle_shark
  ['2383b0439f0bc465'] = { 'primary', { '294eb1fd', 'c9c1870e', 'bfbd8efc', 'fd59deb1' } },  -- assault_rifle_rico_default_muzzle
  ['27ee1ed8f6fb6356'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'LAS-5 Scythe' },  -- laser_rifle
  ['295beb26dc4f8ff1'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_charge', 'g_body' }, 'LAS-17 Double-Edge Sickle' },  -- laser_rifle_long_hotshot
  ['2b28e17ffed05f7c'] = { 'primary', { 'g_triple_barrel_breakshotgun_LOD4', 'g_triple_barrel_breakshotgun_LOD3', 'g_triple_barrel_breakshotgun_LOD2', 'g_triple_barrel_breakshotgun_LOD1', 'g_triple_barrel_breakshotgun' }, 'SG-22 Bushwhacker' },  -- triple_barrel_breakshotgun
  ['30061f91af477f5e'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'PLAS-39 Accelerator Rifle' },  -- sniper_rifle_helghast
  ['3c86e871923f3970'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'LAS-13 Trident' },  -- laser_shotgun
  ['41eac4a03987faa0'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-8 Punisher' },  -- pump_shotgun
  ['41f2def484634b59'] = { 'primary', { 'abb2940a', '066c6c6f', '390f5d1e', '7f6d531b', 'fb8715b2', '8e522bc2', '034f015e', '9cc55688', '9d82e056' }, 'R-40 Sightliner' },  -- (sseo) R-40 Sightliner
  ['46183b50961d1328'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'SG-225 Breaker' },  -- assault_shotgun
  ['4ba41b6f9f405cc2'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'StA-11 SMG' },  -- smg_helghast
  ['4dbd74f49c8ffc13'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'a94a089d', 'g_screen', 'g_reciever' }, 'MA5C Assault Rifle' },  -- assault_rifle_nacho
  ['4e4a613eb9bf5c24'] = { 'primary', { '22cbeab1', 'a3572540', '51705c29', 'g_pdw_LOD4', 'g_pdw_LOD3', 'g_pdw_LOD2', 'g_pdw_LOD1', 'g_pdw' }, 'SMG-37 Defender' },  -- personal_defense_weapon
  ['4fb0f8c02f55c82b'] = { 'primary', { 'g_flamer_LOD4', 'g_flamer_LOD3', 'g_flamer_LOD2', 'g_flamer_LOD1', 'g_flamer' }, 'FLAM-66 Torcher' },  -- flamethrower_ripley
  ['53eebe75cd6e26df'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-8S Slugger' },  -- pump_shotgun_slug
  ['5fecab819f96a3e8'] = { 'primary', { 'g_battle_rifle_LOD4', 'g_battle_rifle_LOD3', 'g_battle_rifle_LOD2', 'g_battle_rifle_LOD1', 'g_battle_rifle' }, 'BR-14 Adjudicator' },  -- battle_rifle
  ['6228d0242bde56b6'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'SG-225SP Breaker Spray&Pray' },  -- assault_shotgun_sprayandpray
  ['6e68194b95d60145'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' }, 'R-63CS Diligence Counter Sniper' },  -- marksman_rifle_vigilance_counter_sniper
  ['708ea298c82093d0'] = { 'primary', { 'c4846e6b', '1d8a6f58', '66acf2b1', '199d951f', '6651bc24', '8f0fa4be', '713ebe31', '1aa3a27c', 'd5ef6d73' }, 'AR-59 Suppressor' },  -- assault_rifle_whisper
  ['719f42b7d137789c'] = { 'primary', { 'g_jet_rifle_phoenix_default_muzzle_LOD2', 'g_jet_rifle_phoenix_default_muzzle_LOD1', 'g_jet_rifle_phoenix_default_muzzle' } },  -- jet_rifle_phoenix_default_muzzle
  ['72170a55a1f37ff1'] = { 'primary', { 'g_shotgun_double_freedom_LOD4', 'g_shotgun_double_freedom_LOD3', 'g_shotgun_double_freedom_LOD2', 'g_shotgun_double_freedom_LOD1', 'g_shotgun_double_freedom' }, 'DBS-2 Double Freedom' },  -- shotgun_double_freedom
  ['72fe4b13f726c344'] = { 'primary', { '499ab1ad', '89d21542', 'd3caaff6', '4808c321', 'b83e206d', 'acb89e54', 'ee98d9aa', 'db8498d5', 'cb91c978' } },  -- smg_flamer_attachment
  ['7b75e5132ffd4ca6'] = { 'primary', { 'g_bolt_action_rifle_LOD4', 'g_bolt_action_rifle_LOD3', 'g_bolt_action_rifle_LOD2', 'g_bolt_action_rifle_LOD1', 'g_bolt_action_rifle' }, 'R-2124 Constitution' },  -- bolt_action_rifle
  ['7e3145a5baa4b948'] = { 'primary', { 'g_laser_rifle_charge_LOD4', 'g_laser_rifle_charge_LOD3', 'g_laser_rifle_charge_LOD2', 'g_laser_rifle_charge_LOD1', 'g_laser_rifle_charge' }, 'LAS-22 Shear' },  -- laser_rifle_charge
  ['8039834a4b7489b9'] = { 'primary', { '2fe0d6ff', 'd2259a6e', '9e14c212', '21ba31f8' } },  -- assault_rifle_penetrator_default_muzzle
  ['80f1a156d9fa1e36'] = { 'primary', { 'g_jet_rifle_LOD4', 'g_jet_rifle_LOD3', 'g_jet_rifle_LOD2', 'g_jet_rifle_LOD1', 'g_jet_rifle' }, 'JAR-5 Dominator' },  -- jet_rifle
  ['84354339522c932d'] = { 'primary', { 'g_assault_rifle_large_calibre_01_LOD4', 'g_assault_rifle_large_calibre_01_LOD3', 'g_assault_rifle_large_calibre_01_LOD2', 'g_assault_rifle_large_calibre_01_LOD1', 'g_assault_rifle_large_calibre_01' }, 'AR-2 Coyote' },  -- assault_rifle_large_calibre_01
  ['8645f167b3c813a2'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'LAS-16 Sickle' },  -- laser_rifle_long
  ['8a307bd1811a5fe9'] = { 'primary', { 'eb7d2210', 'g_smg_flamer_LOD4', 'g_smg_flamer_LOD3', 'g_smg_flamer_LOD2', 'g_smg_flamer_LOD1', 'g_smg_flamer' }, 'SMG/FLAM-34 Stoker' },  -- smg_flamer
  ['8a35c1dc19f41870'] = { 'primary', { 'g_bolt_action_rifle_default_muzzle_LOD1', 'g_bolt_action_rifle_default_muzzle' } },  -- bolt_action_rifle_default_muzzle
  ['8dc91f277c6096ee'] = { 'primary', { 'g_jet_rifle_LOD4', 'g_jet_rifle_LOD3', 'g_jet_rifle_LOD2', 'g_jet_rifle_LOD1', 'g_jet_rifle' }, 'R-36 Eruptor' },  -- jet_rifle_phoenix
  ['90ddc374f4e3d756'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'M90A Shotgun' },  -- shotgun_nacho
  ['94bd931b5fb4ee95'] = { 'primary', { 'g_rhino_LOD4', 'g_rhino_LOD3', 'g_rhino_LOD2', 'g_rhino_LOD1', 'g_rhino' }, 'SMG-32 Reprimand' },  -- smg_rhino
  ['9571ca51f0daf35b'] = { 'primary', { 'g_smg_defender_LOD4', 'g_smg_defender_LOD3', 'g_smg_defender_LOD2', 'g_smg_defender_LOD1', 'g_smg_defender' }, 'MP-98 Knight' },  -- smg_defender
  ['968211c0033dce64'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'AR-23 Liberator' },  -- assault_rifle
  ['a6a735accb4a327f'] = { 'primary', { 'g_mesh_LOD4', 'g_mesh_LOD3', 'g_mesh_LOD2', 'g_mesh_LOD1', 'g_mesh' }, 'M-105 Stalwart' },  -- lmg_stalwart
  ['a7ee1ebf58fcdf1f'] = { 'primary', { 'g_receiver_LOD4', 'g_receiver_LOD3', 'g_receiver_LOD2', 'g_receiver_LOD1', 'g_receiver' }, 'AR-23A Liberator Carbine' },  -- assault_rifle_patriot
  ['a8a91eb54892b6b2'] = { 'primary', { 'g_assault_rifle_risk_LOD4', 'g_assault_rifle_risk_LOD3', 'g_assault_rifle_risk_LOD2', 'g_assault_rifle_risk_LOD1', 'g_assault_rifle_risk' }, 'AR-11 Arbitrator' },  -- assault_rifle_risk
  ['a955c4ea6f6d4203'] = { 'primary', { 'g_assault_rifle_grenadier_LOD4', 'g_assault_rifle_grenadier_LOD3', 'g_assault_rifle_grenadier_LOD2', 'g_assault_rifle_grenadier_LOD1', 'g_assault_rifle_grenadier' }, 'AR/GL-21 One-Two' },  -- assault_rifle_grenadier
  ['ab2a2b390c539f18'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'AR-23C Liberator Concussive' },  -- assault_rifle_explosive
  ['b80951732a5f58f4'] = { 'primary', { '57984e07', 'ecc5a57d', '33d082d8', '7df4cd2a', '8a614b9a', '2788e6d6', 'a46d12f8', '6a4ec9d9', 'c7681182' }, 'AR-23L Liberator Legacy' },  -- (sseo) AR-23L Liberator Legacy
  ['bc29613666df696b'] = { 'primary', { 'g_assault_rifle_karbin_LOD4', 'g_assault_rifle_karbin_LOD3', 'g_assault_rifle_karbin_LOD2', 'g_assault_rifle_karbin_LOD1', 'g_assault_rifle_karbin' }, 'AR-32 Pacifier' },  -- assault_rifle_karbin
  ['be70ee0d8d44028e'] = { 'primary', { 'g_smg_nacho_LOD4', 'g_smg_nacho_LOD3', 'g_smg_nacho_LOD2', 'g_smg_nacho_LOD1', 'g_lens', 'g_smg_nacho' }, 'M7S SMG' },  -- smg_nacho
  ['bf9504e95c0103a1'] = { 'primary', { 'f7d5424f', '88bbc12f', '220f4306', '57757ff1', 'a729554f' } },  -- battle_rifle_ceremonial_default_muzzle
  ['bfe35746f5084222'] = { 'primary', { '5a6cd994' } },  -- assault_rifle_karbin_default_muzzle
  ['c12a34f375bd5a87'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'SG-225IE Breaker Incendiary' },  -- assault_shotgun_incendiary
  ['c4232a0e62166d91'] = { 'primary', { '22cbeab1', 'a3572540', '51705c29', 'g_pdw_LOD4', 'g_pdw_LOD3', 'g_pdw_LOD2', 'g_pdw_LOD1', 'g_pdw' }, 'SMG-72 Pummeler' },  -- personal_defense_weapon_pepper
  ['c85f576d5e086147'] = { 'primary', { 'g_laser_smg_blaster_LOD4', 'g_laser_smg_blaster_LOD3', 'g_laser_smg_blaster_LOD2', 'g_laser_smg_blaster_LOD1', 'g_laser_smg_blaster' }, 'LAS-12 Sai' },  -- laser_smg_blaster
  ['cdf28be026bb7d84'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'StA-52 Assault Rifle' },  -- assault_rifle_helghast
  ['cdf733b0106a23c3'] = { 'primary', { 'bae8caeb', 'f0e645af', 'a37a5a94', '0f969650' } },  -- assault_shotgun_incendiary_default_muzzle
  ['ce063aa33d95a812'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' }, 'AR-61 Tenderizer' },  -- assault_rifle_rico
  ['d323de60855898ac'] = { 'primary', { 'g_pump_shotgun_dragon_LOD4', 'g_pump_shotgun_dragon_LOD3', 'g_pump_shotgun_dragon_LOD2', 'g_pump_shotgun_dragon_LOD1', 'g_pump_shotgun_dragon' }, 'SG-451 Cookout' },  -- pump_shotgun_dragon
  ['dcd1c835407ef7ba'] = { 'primary', { '65132739', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-97 Sweeper' },  -- pump_shotgun_trench
  ['e5796355a8fd67e0'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' }, 'R-4 Hyena' },  -- marksman_rifle_drake
  ['e6d932be83729076'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' }, 'R-6 Deadeye' },  -- lever_action_rifle_01
  ['eea5e3cef1e12c14'] = { 'primary', { 'g_plasma_LOD4', 'g_plasma_LOD3', 'g_plasma_LOD2', 'g_plasma_LOD1', 'g_plasma' }, 'PLAS-1 Scorcher' },  -- plasma_rifle
  ['efdcef306cea63fe'] = { 'primary', { 'g_plasma_rifle_charge_LOD3', 'g_plasma_rifle_charge_LOD2', 'g_plasma_rifle_charge_LOD1', 'g_plasma_rifle_charge' }, 'PLAS-101 Purifier' },  -- plasma_rifle_charge
  ['f0338468dcdb6a6c'] = { 'primary', { 'g_marksman_rifle_justice_LOD4', 'g_marksman_rifle_justice_LOD3', 'g_marksman_rifle_justice_LOD2', 'g_marksman_rifle_justice_LOD1', 'g_marksman_rifle_justice' }, 'R-72 Censor' },  -- marksman_rifle_justice
  ['f49227a0630a3f7f'] = { 'primary', { 'g_crossbow_LOD4', 'g_crossbow_LOD3', 'g_crossbow_LOD2', 'g_crossbow_LOD1', 'g_crossbow' }, 'CB-9 Exploding Crossbow' },  -- crossbow_greyfax
  ['f992ce97577c8a7f'] = { 'primary', { 'g_volley_gun_LOD4', 'g_volley_gun_LOD3', 'g_volley_gun_LOD2', 'g_volley_gun_LOD1', 'g_volley_gun' }, 'VG-70 Variable' },  -- volley_gun
  ['ffc18b2ce10ca381'] = { 'primary', { 'da6b11ea', '400fb5d6', '86f07750', '455663e2' } },  -- battle_rifle_default_muzzle
  ['027dec442cc26a90'] = { 'secondary', { '55038efe', 'a8f60cdb', 'f95be523', '8f3502c9', '1604e212', 'c8233ab1', '18dcc0ed', '76d280e3', 'f0bcad2b' }, 'P-44 Mist' },  -- (sseo) P-44 Mist
  ['05e4e5c2db6e44a2'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'P-2 Peacemaker' },  -- standard_pistol
  ['0b882808c6f498e8'] = { 'secondary', { 'g_caustic_dart_gun_LOD4', 'g_caustic_dart_gun_LOD3', 'g_caustic_dart_gun_LOD2', 'g_caustic_dart_gun_LOD1', 'g_caustic_dart_gun' }, 'P-35 Re-Educator' },  -- caustic_dart_gun
  ['14d5d4506056c7a4'] = { 'secondary', { 'g_smart_pistol_missile_LOD4', 'g_smart_pistol_missile_LOD3', 'g_smart_pistol_missile_LOD2', 'g_smart_pistol_missile_LOD1', 'g_screen', 'g_smart_pistol_missile' }, 'P-33 Missile Pistol' },  -- smart_pistol_missile
  ['1a437158e1b8d2a1'] = { 'secondary', { 'g_pistol_LOD4', 'g_pistol_LOD3', 'g_pistol_LOD2', 'g_pistol_LOD1', 'g_pistol' }, 'P-113 Verdict' },  -- magnum_pistol
  ['3575aabc5f1f9326'] = { 'secondary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'P-19 Redeemer' },  -- automatic_pistol
  ['3f92ba65ef65cca9'] = { 'secondary', { 'g_flamer_pistol_LOD4', 'g_flamer_pistol_LOD3', 'g_flamer_pistol_LOD2', 'g_flamer_pistol_LOD1', 'g_flamer_pistol' }, 'P-72 Crisper' },  -- flamer_pistol
  ['416d053372c4e433'] = { 'secondary', { 'g_energy_revolver_LOD4', 'g_energy_revolver_LOD3', 'g_energy_revolver_LOD2', 'g_energy_revolver_LOD1', 'g_energy_revolver' }, 'LAS-58 Talon' },  -- energy_revolver
  ['4d58c77087b774c5'] = { 'secondary', { 'g_pistol_nacho_LOD4', 'g_pistol_nacho_LOD3', 'g_pistol_nacho_LOD2', 'g_pistol_nacho_LOD1', 'g_pistol_nacho' }, 'M6C/SOCOM Pistol' },  -- pistol_nacho
  ['52e4334e6a128caf'] = { 'secondary', { 'g_grenade_pistol_LOD4', 'g_grenade_pistol_LOD3', 'g_grenade_pistol_LOD2', 'g_grenade_pistol_LOD1', 'g_grenade_pistol' }, 'GP-31 Grenade Pistol' },  -- grenade_pistol
  ['75816077c139c850'] = { 'secondary', { 'g_hand_axe_LOD4', 'g_hand_axe_LOD3', 'g_hand_axe_LOD2', 'g_hand_axe_LOD1', 'g_hand_axe' }, 'CQC-5 Combat Hatchet' },  -- (sseo) CQC-5 Combat Hatchet
  ['792d5d2a340fd6e6'] = { 'secondary', { 'g_machete_LOD4', 'g_machete_LOD3', 'g_machete_LOD2', 'g_machete_LOD1', 'g_machete' }, 'CQC-42 Machete' },  -- (sseo) CQC-42 Machete
  ['7b06196e90154c88'] = { 'secondary', { 'g_laserpistol_LOD4', 'g_laserpistol_LOD3', 'g_laserpistol_LOD2', 'g_laserpistol_LOD1', 'g_laserpistol' }, 'LAS-7 Dagger' },  -- laser_pistol
  ['7de84a343186671f'] = { 'secondary', { 'g_speedloader_LOD1', 'g_speedloader' } },  -- stim_pistol_speedloader
  ['7e1f76163c667e4b'] = { 'secondary', { 'g_shovel_LOD4', 'g_shovel_LOD3', 'g_shovel_LOD2', 'g_shovel_LOD1', 'g_shovel' }, 'CQC-73 Entrenchment Tool' },  -- (sseo) CQC-73 Entrenchment Tool
  ['8d3d52a3b2f19402'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_casings', 'g_feed_casing', 'g_body_crosshair', 'g_body' }, 'P-4 Senator' },  -- revolver_pistol
  ['9eb160830321bfd6'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'GP-20 Ultimatum' },  -- pistol_cricket
  ['aa69a60d74a3ec54'] = { 'secondary', { 'g_plasma_pistol_LOD4', 'g_plasma_pistol_LOD3', 'g_plasma_pistol_LOD2', 'g_plasma_pistol_LOD1', 'g_plasma_pistol' }, 'PLAS-15 Loyalist' },  -- plasma_pistol
  ['b96cc3b704a76464'] = { 'secondary', { 'g_speedloader' } },  -- revolver_speedloader
  ['bb8e970248330bdb'] = { 'secondary', { 'g_caustic_dart_LOD4', 'g_caustic_dart_LOD3', 'g_caustic_dart_LOD2', 'g_caustic_dart_LOD1', 'g_caustic_dart' } },  -- caustic_dart
  ['bde1f2534280300d'] = { 'secondary', { 'g_barrel_LOD4', 'g_barrel_LOD3', 'g_barrel_LOD2', 'g_barrel_LOD1', 'g_barrel', 'g_body_crosshair', 'g_feed_casing', 'g_casings', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- revolver_pistol_long
  ['c5793b23852109f0'] = { 'secondary', { 'g_electric_baton_LOD4', 'g_electric_baton_LOD3', 'g_electric_baton_LOD2', 'g_electric_baton_LOD1', 'g_electric_baton' }, 'CQC-30 Stun Baton' },  -- (sseo) CQC-30 Stun Baton
  ['c780bcd79547da0f'] = { 'secondary', { 'g_pistol_broomhandle_LOD4', 'g_pistol_broomhandle_LOD3', 'g_pistol_broomhandle_LOD2', 'g_pistol_broomhandle_LOD1', 'g_pistol_broomhandle' }, 'P-69 Veto' },  -- pistol_broomhandle
  ['cf8934ff6567a42d'] = { 'secondary', { 'g_lens', 'g_smart_pistol_LOD4', 'g_smart_pistol_LOD3', 'g_smart_pistol_LOD2', 'g_smart_pistol_LOD1', 'g_smart_pistol' }, 'P-92 Warrant' },  -- smart_pistol
  ['d6b1fb05b9109353'] = { 'secondary', { 'g_stim_pistol_LOD4', 'g_stim_pistol_LOD3', 'g_stim_pistol_LOD2', 'g_stim_pistol_LOD1', 'g_stim_pistol' }, 'P-11 Stim Pistol' },  -- stim_pistol
  ['dbb6c961c59fadc1'] = { 'secondary', { 'g_pistol_shark_LOD4', 'g_pistol_shark_LOD3', 'g_pistol_shark_LOD2', 'g_pistol_shark_LOD1', 'g_pistol_shark' }, 'P/40-K Bolt Pistol' },  -- pistol_shark
  ['e2177e205d9a7a55'] = { 'secondary', { '7cade4c9', 'g_caustic_dart_gun_cylinder_LOD4', 'g_caustic_dart_gun_cylinder_LOD3', 'g_caustic_dart_gun_cylinder_LOD2', 'g_caustic_dart_gun_cylinder_LOD1', 'g_caustic_dart_gun_cylinder' } },  -- caustic_dart_gun_cylinder
  ['e3b6aedd07fcb464'] = { 'secondary', { 'g_stun_spear_LOD4', 'g_stun_spear_LOD3', 'g_stun_spear_LOD2', 'g_stun_spear_LOD1', 'g_stun_spear' }, 'CQC-19 Stun Lance' },  -- (sseo) CQC-19 Stun Lance
  ['e91f569c2ad8af01'] = { 'secondary', { 'g_hornet_pistol_LOD4', 'g_hornet_pistol_LOD3', 'g_hornet_pistol_LOD2', 'g_hornet_pistol_LOD1', 'g_hornet_pistol' }, 'P-34 Breacher' },  -- hornet_pistol
  ['fcd8a6e67eac635a'] = { 'secondary', { 'g_ceremonial_saber_LOD4', 'g_ceremonial_saber_LOD3', 'g_ceremonial_saber_LOD2', 'g_ceremonial_saber_LOD1', 'g_ceremonial_saber' }, 'CQC-2 Saber' },  -- (sseo) CQC-2 Saber
  ['02eecd0b1fa49630'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' }, 'GL-21 Grenade Launcher' },  -- grenade_launcher
  ['11c27d3babb38956'] = { 'support', { 'g_mg_LOD4', 'g_mg_LOD3', 'g_mg_LOD2', 'g_mg_LOD1', 'g_mg' }, 'MG-43 Machine Gun' },  -- machinegun
  ['2152d5147b0ac418'] = { 'support', { 'g_hmg_LOD4', 'g_hmg_LOD3', 'g_hmg_LOD2', 'g_hmg_LOD1', 'g_hmg' }, 'MG-206 Heavy Machine Gun' },  -- heavy_mg
  ['25aa2fd4643cf4ee'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' }, 'FAF-14 Spear' },  -- faf_missile_launcher
  ['26e40437ea275296'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' }, 'RL-77 Airburst Rocket Launcher' },  -- air_burst_rocket_launcher
  ['2e9d0bdc48b09e60'] = { 'support', { 'g_railgun_LOD4', 'g_railgun_LOD3', 'g_railgun_LOD2', 'g_railgun_LOD1', 'g_charge', 'g_railgun' }, 'RS-422 Railgun' },  -- railgun
  ['35a61296619cc47e'] = { 'support', { 'g_laser_pulse_cannon_LOD4', 'g_laser_pulse_cannon_LOD3', 'g_laser_pulse_cannon_LOD2', 'g_laser_pulse_cannon_LOD1', 'g_laser_pulse_cannon', 'g_charge' }, 'LAS-99 Quasar Cannon' },  -- laser_pulse_cannon
  ['3828e2051aa9e897'] = { 'support', { 'g_harpoon_gun_LOD4', 'g_harpoon_gun_LOD3', 'g_harpoon_gun_LOD2', 'g_harpoon_gun_LOD1', 'g_harpoon_gun' }, 'S-11 Speargun' },  -- harpoon_gun
  ['39ab99895147a3bf'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'FLAM-40 Flamethrower' },  -- flamethrower
  ['43a58cb89cfa197c'] = { 'support', { 'g_minigun_LOD4', 'g_minigun_LOD3', 'g_minigun_LOD2', 'g_minigun_LOD1', 'g_minigun' }, 'M-1000 Maxigun' },  -- minigun
  ['43b2d7766120203b'] = { 'support', { 'g_chemgun_LOD3', 'g_chemgun_LOD2', 'g_chemgun_LOD1', 'g_chemgun' }, 'TX-41 Sterilizer' },  -- chemgun
  ['46427f2630a80d88'] = { 'support', { 'g_scope_LOD2', 'g_scope_LOD1', 'g_lens', 'g_scope' } },  -- faf_missile_launcher_helghast_scope
  ['52071f49263415e4'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'SG-88 Break-Action Shotgun' },  -- (sseo) SG-88 Break-Action Shotgun
  ['5990123d142b16cb'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' }, 'MLS-4X Commando' },  -- laser_guided_missile_launcher
  ['5f3ec9bda2bd8553'] = { 'support', { 'g_sledge_hammer_LOD4', 'g_sledge_hammer_LOD3', 'g_sledge_hammer_LOD2', 'g_sledge_hammer_LOD1', 'g_sledge_hammer' }, 'CQC-20 Breaching Hammer' },  -- (sseo) CQC-20 Breaching Hammer
  ['692eb345969d368e'] = { 'support', { 'g_lens' } },  -- lat_oneshot_sight
  ['6cfcc7f8801a0266'] = { 'support', { 'g_energy_weapon_shark_LOD4', 'g_energy_weapon_shark_LOD3', 'g_energy_weapon_shark_LOD2', 'g_energy_weapon_shark_LOD1', 'g_energy_weapon_shark' }, '40-K Meltagun' },  -- energy_weapon_shark
  ['73d84eaae8c75342'] = { 'support', { '3b2de3c6', '7c0dac53', '1847cf80', 'dadb8011', 'dc8fc694', 'c3583542', '7ac5715c', '47f3810b', 'b7a47b6b', '9dcf1324' }, 'LAS-44 Nova' },  -- (sseo) LAS-44 Nova
  ['7617642765ac38c7'] = { 'support', { 'g_expendable_massive_rocket_launcher_LOD4', 'g_expendable_massive_rocket_launcher_LOD3', 'g_expendable_massive_rocket_launcher_LOD2', 'g_expendable_massive_rocket_launcher_LOD1', 'g_expendable_massive_rocket_launcher' }, 'EAT-411 Leveller' },  -- expendable_massive_rocket_launcher
  ['78a8185f63a70795'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'B/FLAM-80 Cremator' },  -- heavy_flamethrower
  ['80932fa0ed6901d3'] = { 'support', { 'g_lat_LOD4', 'g_lat_LOD3', 'g_lat_LOD2', 'g_lat_LOD1', 'g_lat' }, 'EAT-17 Expendable Anti-Tank' },  -- lat_oneshot
  ['8666e5f49f440d44'] = { 'support', { 'g_faf_scope_LOD2', 'g_faf_scope_LOD1', 'g_faf_scope' } },  -- faf_scope
  ['88c2d09ad85a7c9f'] = { 'support', { 'g_belt_fed_grenade_launcher_LOD4', 'g_belt_fed_grenade_launcher_LOD3', 'g_belt_fed_grenade_launcher_LOD2', 'g_belt_fed_grenade_launcher_LOD1', 'g_belt_fed_grenade_launcher' }, 'GL-28 Belt-Fed Grenade Launcher' },  -- belt_fed_grenade_launcher
  ['89c5493e08ca4207'] = { 'support', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' }, 'APW-1 Anti-Materiel Rifle' },  -- sniper_rifle
  ['96de9cd50f7306e6'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'ARC-3 Arc Thrower' },  -- arc_thrower
  ['9bc319730887bdd8'] = { 'support', { 'g_clip' } },  -- autocannon_clip
  ['9f80d67a12a7e40f'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'GR-8 Recoilless Rifle' },  -- recoilless_rifle
  ['a841cb05f3fd938b'] = { 'support', { 'g_mini_missile_LOD3', 'g_mini_missile_LOD2', 'g_mini_missile_LOD1', 'g_mini_missile' }, 'MS-11 Solo Silo' },  -- (sseo) MS-11 Solo Silo
  ['a8cffb316f0b5c5f'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'AC-8 Autocannon' },  -- automatic_cannon
  ['b0f1b354ba1d38d8'] = { 'support', { 'g_flag', 'g_pole_LOD3', 'g_pole_LOD2', 'g_pole_LOD1', 'g_pole' }, 'CQC-1 One True Flag' },  -- (sseo) CQC-1 One True Flag
  ['b16c9d490aa59b77'] = { 'support', { 'g_expendable_machinegun_LOD4', 'g_expendable_machinegun_LOD3', 'g_expendable_machinegun_LOD2', 'g_expendable_machinegun_LOD1', 'g_expendable_machinegun' }, 'MGX-42 Bullet Storm' },  -- expendable_machinegun
  ['b2b5e0d185605f9e'] = { 'support', { 'g_expendable_napalm_launcher_LOD4', 'g_expendable_napalm_launcher_LOD3', 'g_expendable_napalm_launcher_LOD2', 'g_expendable_napalm_launcher_LOD1', 'g_expendable_napalm_launcher' }, 'EAT-700 Expendable Napalm' },  -- expendable_napalm_launcher
  ['b814eece17533bc4'] = { 'support', { '4834a0fb', 'abec8954', '22569bd8', '79649ca8', '0168b0fa', 'a52c2602', '2189b218', 'b3f8ac5c', '2a2a02c7' }, 'AMW-20 Apex' },  -- (rack support b814eece17533bc4)
  ['bf4cfd2aeabfb5a4'] = { 'support', { 'g_sword_LOD4', 'g_sword_LOD3', 'g_sword_LOD2', 'g_sword_LOD1', 'g_sword' }, 'CQC-9 Defoliation Tool' },  -- (sseo) CQC-9 Defoliation Tool
  ['cc786f6491fe7e65'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'StA-X3 W.A.S.P. Launcher' },  -- faf_missile_launcher_helghast
  ['d54b9505c0f72873'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' }, 'LAS-98 Laser Cannon' },  -- laser_cannon
  ['e85e623f93f96fb3'] = { 'support', { 'g_shovel_LOD4', 'g_shovel_LOD3', 'g_shovel_LOD2', 'g_shovel_LOD1', 'g_shovel' }, 'CQC-72 Entrenchment Tool' },  -- (sseo) CQC-72 Entrenchment Tool
  ['e8d5f49ad7780e54'] = { 'support', { 'g_plasma_blaster_LOD4', 'g_plasma_blaster_LOD3', 'g_plasma_blaster_LOD2', 'g_plasma_blaster_LOD1', 'g_charge', 'g_plasma_blaster' }, 'PLAS-45 Epoch' },  -- plasma_blaster
  ['e8ffad77b73c221c'] = { 'support', { 'g_railgun_sabot' } },  -- railgun_sabot
  ['fe3b29b2cfa63f9b'] = { 'support', { 'g_grenade_launcher_tactical_LOD4', 'g_grenade_launcher_tactical_LOD3', 'g_grenade_launcher_tactical_LOD2', 'g_grenade_launcher_tactical_LOD1', 'g_grenade_launcher_tactical' }, 'GL-52 De-Escalator' },  -- grenade_launcher_tactical
}
-- GUNS END
local GUN_KINDS = {}
local SHIELD_KIND = '967ed15e0bae363b'                         -- ballistic_shield_backpack, in a hand
for k in pairs(GUNS) do GUN_KINDS[k] = true end
local gun_watch = chef.watch and chef.watch(GUN_KINDS, 1) or nil
-- where the diver carries each kind of gun when it isn't in a hand
local SLOTS = { primary = { 'sling' }, secondary = { 'pistol' }, support = { 'support_mg', 'support' }, backpack = { 'backpack' } }
local function dist(a, b) return (a and b) and sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) or 9 end
-- bone indices and which meshes a unit has never change for that unit: asked once (weak keys, gone with the unit)
local node_ix, has_m = setmetatable({}, { __mode = 'k' }), setmetatable({}, { __mode = 'k' })
local function node_at(u, name)
  local c = node_ix[u] or {}
  node_ix[u] = c
  if c[name] == nil then c[name] = chef.unit_node(u, name) or false end
  local i = c[name]
  if i then local x, y, z = upos(u, i); if x then return { x, y, z } end end
end
-- a mesh by name, or by its 8-digit hash when the name is unknown (a fresh engine key each time, never kept)
local function mesh_key(u, m)
  local c = has_m[u] or {}
  has_m[u] = c
  if c[m] == false then return end
  local key = m
  if #m == 8 and m:match('^%x+$') then
    local k, why = chef.call('IdString32.from_hex', m)
    if why or k == nil then once('idhex', 'unnamed gun meshes left alone: %s', tostring(why)); return end
    key = k
  end
  if c[m] == nil then c[m] = call('Unit.has_mesh', u, key) == true end
  if c[m] then return key end
end
local function gun_meshes(u, list, on)
  local h = S.ghid[u]
  if not on then
    if h and h.whole then call('Unit.set_unit_visibility', u, true)
    elseif h then for m in pairs(h) do local key = mesh_key(u, m); if key then call('Unit.set_mesh_visibility', u, key, true, 'default') end end end
    S.ghid[u] = nil
    return
  end
  if not h then  -- first time: only what the game shows now, so a LOD it keeps hidden stays its business
    h = {}
    for _, m in ipairs(list) do
      local key = mesh_key(u, m)
      if not key and m:match('^%x+$') and #m == 8 then h = { whole = true }; break end  -- a mesh we can't name: the whole part
      if key and call('Mesh.visibility', call('Unit.mesh', u, key)) == true then h[m] = true end
    end
    S.ghid[u] = h
  end
  if h.whole then call('Unit.set_unit_visibility', u, false); return end
  -- again every frame: the game shows them again on a swap or reload
  for m in pairs(h) do local key = mesh_key(u, m); if key then call('Unit.set_mesh_visibility', u, key, false, 'default') end end
end
local hide_guns
do
local LINK_NODES = { 'attach_hand_l', 'attach_hand_r' }
for _, l in pairs(SLOTS) do for _, n in ipairs(l) do LINK_NODES[#LINK_NODES + 1] = n end end
-- which of your Helldiver's nodes a gun hangs on, from the engine's own link: a linked unit's root position is kept
-- relative to the node it hangs on, so that node's spot plus the offset turned with the node is exactly the gun's
-- spot. The node's name; false = linked to a node not listed (aiming, reloading) or to someone else; nil = loose
-- a node's right, forward and up axes in the world, read only for a node a gun could hang on, once a frame: from its
-- quaternion (2 engine calls instead of 7). The first read also asks the 3 axes and compares; a mismatch keeps the axes
local QAX  -- nil: not compared yet, true: the quaternion matches, false: axes only
local AXES = { 'Quaternion.right', 'Quaternion.forward', 'Quaternion.up' }
local function axes(n)
  if n.a ~= nil then return n.a end
  n.a = false
  local q = call('Unit.world_rotation', n.u, n.i)
  if not q then return false end
  local a
  if QAX ~= false then
    local x, y, z, w = call('Quaternion.to_elements', q)
    if finite(x) and finite(y) and finite(z) and finite(w) then
      a = { 1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y),
            2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x),
            2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y) }
    end
  end
  if QAX ~= true then
    local b = {}
    for _, ax in ipairs(AXES) do
      local x, y, z = xyz(call(ax, q))
      if x then b[#b + 1] = x; b[#b + 1] = y; b[#b + 1] = z end
    end
    if #b ~= 9 then return false end
    if QAX == nil and a then
      local e = 0
      for i = 1, 9 do e = max(e, abs(a[i] - b[i])) end
      QAX = e < 1e-3
      log('gun links: node turn from its quaternion %s (off by up to %.5f)', QAX and 'matches its axes, used from now on' or 'does NOT match its axes, axes kept', e)
    end
    a = b
  end
  n.a = a or false
  return n.a
end
local function hung_on(u, p, nodes)
  local lx, ly, lz = xyz(call('Unit.local_position', u, 1))
  if not lx then once('lpos', 'gun links unreadable: no local position'); return nil end
  if abs(lx - p[1]) + abs(ly - p[2]) + abs(lz - p[3]) < 1e-4 then return nil end
  local L = sqrt(lx * lx + ly * ly + lz * lz)
  for _, n in ipairs(nodes) do
    -- turning keeps the offset's length: only a node that far from the gun can hold it (most nodes need no axes)
    local a = abs(dist(p, n.p) - L) < 0.0035 and axes(n)
    if a then
      local x = n.p[1] + a[1] * lx + a[4] * ly + a[7] * lz
      local y = n.p[2] + a[2] * lx + a[5] * ly + a[8] * lz
      local z = n.p[3] + a[3] * lx + a[6] * ly + a[9] * lz
      if abs(x - p[1]) + abs(y - p[2]) + abs(z - p[3]) < 0.003 then return n.name end
    end
  end
  return false
end
-- every frame: which of your guns is in a hand or stowed (the node it hangs on), and hide those the settings ask
-- for, with their magazines
function hide_guns()
  local want = {}
  local d = S.head and S.head.u
  if S.shown and d and gun_watch and alive(d) then
    local refs, nodes = {}, {}
    for _, n in ipairs(LINK_NODES) do
      refs[n] = node_at(d, n)
      if refs[n] then nodes[#nodes + 1] = { name = n, p = refs[n], u = d, i = node_ix[d][n] } end  -- axes: on demand
    end
    refs.left, refs.right = refs.attach_hand_l, refs.attach_hand_r
    local rx, ry, rz = upos(d)
    if not rx then return end  -- no position this frame (NaN): the guns as they are, not all shown at once
    local parts, carried, moved = {}, {}, false
    for _, it in ipairs(rx and gun_watch.items or {}) do
      if (it.x - rx) ^ 2 + (it.y - ry) ^ 2 < 100 and alive(it.unit) then  -- the list's spots are up to 1 s old
        local g = GUNS[it.kind]
        local x, y, z = upos(it.unit)
        local p = x and { x, y, z }
        local st = S.gst[it.unit] or {}
        S.gst[it.unit] = st
        if g[1] == 'magazine' or g[1] == 'attachment' then parts[#parts + 1] = { u = it.unit, p = p, list = g[2], k = it.kind }
        elseif p then
          local was = st.state
          local on = hung_on(it.unit, p, nodes)
          local left = on == 'attach_hand_l' or dist(p, refs.left) < 0.002
          if left or on == 'attach_hand_r' or dist(p, refs.right) < 0.002 then
            st.state = 'held'
            if it.kind == SHIELD_KIND then S.shield_t, S.shu = S.t, it.unit
            else S.gheld = { u = it.unit, p = p, o = left and refs.right or refs.left, t = S.t } end
            -- the weapon whose own settings apply (kept with nothing in your hands: a throw doesn't switch them)
            if g[3] and S.wheld ~= it.kind then S.wheld = it.kind; log('weapon in your hands: %s', g[3]) end
          else
            local slot = false
            for _, n in ipairs(SLOTS[g[1]] or {}) do if n == on then slot = true end end
            if slot then st.state = 'stowed'
            -- a held gun linked on to a node not listed stays held: scoping and reloading move it there (the Apex,
            -- 2026-11-13: measured by distance it passed as stowed and flashed)
            elseif not (on == false and st.state == 'held') then st.state = nil end
          end
          if st.state ~= was then moved = true end
          if st.state then
            -- the FRV driver keeps the held gun in the right hand on the wheel, where it clips: hidden while driving
            local on = V['hide_' .. st.state .. '_' .. g[1]] or (st.state == 'held' and S.frv == 'driver')
            carried[it.unit] = { p = p, on = on, what = st.state .. ' ' .. g[1] }
            if on then want[it.unit] = g[2] end
          else parts[#parts + 1] = { u = it.unit, p = p, list = g[2], k = it.kind } end  -- a scope or sight that is its own unit
          local said = (st.state or 'not yours') .. (on and ' on ' .. on or on == false and ' on another node' or '')
          if said ~= S.gsaid[it.unit] then
            S.gsaid[it.unit] = said
            log('gun %s (%s): %s', it.kind, g[1], said)
          end
        end
      end
    end
    -- magazines, scopes, muzzles, launchers: they go with the nearest gun you carry within 0.8 m, and keep that gun
    -- while their distance to it holds (mounted on it): scoped in, the raised rifle's scope came nearer the support
    -- weapon on your back than its own gun's root and flashed with the stowed support's hiding (2026-11-14).
    -- Any gun taken out or put away: all matched afresh, so one lent to the backpack mid-swap comes home
    for _, m in ipairs(parts) do
      local st = S.gst[m.u]
      local best = not moved and st.with and carried[st.with]
      if not (best and abs(dist(m.p, best.p) - st.wd) < 0.005) then
        local was, bd = st.with, 0.8
        best, st.with = nil, nil
        for u, c in pairs(carried) do local dd = dist(m.p, c.p); if dd < bd then best, bd, st.with = c, dd, u end end
        st.wd = bd
        if st.with ~= was and st.with then log('part %s goes with your %s (%.2f m)', m.k, best.what, bd) end
      end
      if best and best.on then want[m.u] = m.list end
    end
  end
  for u in pairs(S.ghid) do if not want[u] then if alive(u) then gun_meshes(u, nil, false) else S.ghid[u] = nil end end end
  for u, list in pairs(want) do gun_meshes(u, list, true) end
end
end
-- every gun we hid shown again at once (the mod stopping, the reset key, an error): the start-again that follows
-- forgets S.ghid, and a mesh we hid reads as hidden, so nothing would ever show it again
local function show_guns()
  for u in pairs(S.ghid) do if alive(u) then gun_meshes(u, nil, false) end end
  S.ghid = {}
end
-- per unit kind, kept across missions (one resource = one skeleton, one set of meshes): its first bone of BONES and
-- node index (false: none), and which of a row's mesh names it has
local bone_of, groups_of = {}, {}
local cam_watch = chef.watch({ [CAMERA_KIND] = true }, 2)

-- which of a row's mesh names this unit has (by name: asking meshes by number can crash the engine)
local function probe(u)
  local found = {}
  for id, stems in pairs(GROUPS) do
    local list = {}
    for _, stem in ipairs(stems) do
      for _, sex in ipairs({ '', '_male', '_female' }) do
        local base = stem .. sex
        -- some pieces name their first LOD _LOD0 instead of the bare name
        local has0 = call('Unit.has_mesh', u, base) == true
        if has0 then list[#list + 1] = base end
        if call('Unit.has_mesh', u, base .. '_LOD0') == true then list[#list + 1] = base .. '_LOD0'; has0 = true end
        if has0 then
          for l = 1, 5 do
            if call('Unit.has_mesh', u, base .. '_LOD' .. l) == true then list[#list + 1] = base .. '_LOD' .. l end
          end
        end
      end
    end
    if #list > 0 then found[id] = list end
  end
  return found
end

-- camera units from the loader's lookup by resource (no scan of our own); only rebuilt on a new list
local function refresh_cams()
  if cam_watch.generation == S.cam_gen then return end
  S.cam_gen = cam_watch.generation
  local cams = {}
  for _, it in ipairs(cam_watch.items) do
    local n = call('Unit.num_cameras', it.unit)
    for slot = 1, min(tonumber(n) or 1, 4) do
      local keep
      for _, o in ipairs(S.cams) do if o.u == it.unit and o.slot == slot then keep = o end end
      cams[#cams + 1] = keep or { u = it.unit, slot = slot }
    end
  end
  S.cams = cams
  once('cams' .. #cams, 'camera units: %d', #cams)
end

-- multiplayer: your own Helldiver only ever changes by coming down in a hellpod, with the game camera falling along.
-- Any other Helldiver than the one you had (S.mine) is a teammate the camera follows (joining, spectating after a
-- death) unless a drop was just seen; each drop allows one pick. The game's network session gives no unit
-- owners (2026-11-07 log)
local function drop_seen() return S.drop_t and S.t - S.drop_t < 30 end
local function others_here() return chef.in_mission() and (chef.players and chef.players() or 1) > 1 end

-- which Helldiver is yours, by where the game's camera sits (numbers measured in game): the game's third-person
-- camera keeps your head 3.2 m in front of it, the camera 0.55 m to the head's right; on the ship much closer, 1.3 m
-- and 0.67 m (2026-11-13 logs: 10 kept ship picks 1.2-1.5 m, 0.56-0.78 m; the 3.2 m spot took a teammate walking
-- ~2 m ahead of you, score 0.25). Score = metres off that spot (sideways counts 1.5x); also the distance, how far
-- right, and how straight ahead the head is (1 = dead ahead)
local function cam_fit(g, hx, hy, hz)
  local dx, dy, dz = hx - g.x, hy - g.y, hz - g.z
  local d, hl = sqrt(dx * dx + dy * dy + dz * dz), sqrt(g.fx * g.fx + g.fy * g.fy)
  if d < 0.05 or hl < 1e-3 then return nil end
  local r = (dy * g.fx - dx * g.fy) / hl
  local mis = chef.in_mission()
  return abs(d - (mis and 3.2 or 1.3)) + 1.5 * abs(r - (mis and 0.55 or 0.67)), d, r, (dx * g.fx + dy * g.fy + dz * g.fz) / d
end

-- the best fit is yours when it clearly is: within 2.5 of the spot and 0.8 ahead of the next (0.4 when under 1.0).
-- A lone Helldiver off the spot (the ship's walk-in camera) is taken once it has been the only one for 5 s with the
-- camera still. Each pick is then checked by cam_confirm
local function cam_pick(list, c)
  table.sort(list, function(a, b) return a.s < b.s end)
  local b, n2 = list[1], list[2]
  local v = S.pcam and S.t - S.pcam.t <= 1 and sqrt((c.x - S.pcam.x) ^ 2 + (c.y - S.pcam.y) ^ 2 + (c.z - S.pcam.z) ^ 2) / max(S.t - S.pcam.t, 1e-3) or 0
  S.pcam = { x = c.x, y = c.y, z = c.z, t = S.t }
  local why
  if not b then why = 'no Helldiver in front of the camera'
  elseif b.s > 2.5 and n2 then why = 'the camera is not where it sits for any of them yet'
  elseif b.s > 2.5 and v > 1.5 then why = 'the camera is still moving'
  elseif b.s > 2.5 and (S.lone ~= b.h.u or S.t - S.lone_t < 5) then
    if S.lone ~= b.h.u then S.lone, S.lone_t = b.h.u, S.t end
    why = 'the camera is still settling'
  elseif n2 and n2.s - b.s < 0.8 and not (b.s < 1 and n2.s - b.s >= 0.4) then why = 'two Helldivers fit about as well' end
  if why then
    if S.t >= (S.why_t or 0) then
      S.why_t = S.t + 3
      log('looking for your Helldiver: %s (%d in front, best %.2f, next %.2f)', why, #list, b and b.s or -1, n2 and n2.s or -1)
    end
    return nil, 6
  end
  S.confirm = { moved = 0, limit = n2 and min(2.5, b.s + 1) or max(2.5, b.s + 1.5) }
  local _, d, r = cam_fit(c, b.h.x, b.h.y, b.h.z)
  log('your Helldiver found, %.2f m in front of the camera, the camera %.2f m to its right (score %.2f, %d in front)', d, r, b.s, #list)
  return b.h, b.d
end

-- the end of a scan, all in one frame on the few units near the view: the Helldiver whose head is nearest, and the
-- pieces worn on him (the same spot of the same bone)
local function scan_done(near)
  local c = chef.camera()
  if not c then return end
  prune_corpses()
  local best, bd = nil, 6
  -- a corpse standing again (head over its feet at 90 % of how tall it stood alive, and at least 1.4 m) with its
  -- animation isn't one: a guess was alive after all; a proven one's handle was handed out to a new unit (or the
  -- engine's answer was wrong). The height and the animation rule out a corpse propped up on a slope or a rock.
  -- Asked only of a standing body near the camera, at scan rate, never in a hellpod
  local function back_up(h)
    if S.nopod or not is_corpse(h.u) or not h.z then return false end
    local fz = select(3, upos(h.u, chef.unit_node(h.u, 'root') or 1))
    local need = max(1.4, 0.9 * (S.corpse_h and S.corpse_h[h.u] or 0))
    if not (fz and h.z - fz > need) then return false end
    return call('Unit.has_animation_state_machine', h.u) == true
  end
  -- ship: your Helldiver (S.mine) while it's there, never a teammate's (nothing on the ship gives you a new one)
  local gate = others_here() and not drop_seen()
    or not chef.in_mission() and S.mine ~= nil and alive(S.mine)
  -- right after your drop: your Helldiver is the one that came down with the pod (30+ m below its highest point;
  -- it exists from the mission load, 2026-11-07 log), so a teammate standing where you land is never taken. None
  -- fell = nearest, as before. Solo too: a corpse the mod doesn't know as one (a death before an F11 reload) lying
  -- where your reinforcement lands was taken as the nearest, then dropped as dead 6 s later (1.2.9 log)
  local function fell(h) return h.z and S.avtop[h.u] and S.avtop[h.u] - h.z > 30 end
  local fresh = nil
  if drop_seen() then
    for _, h in ipairs(near) do
      h.x, h.y, h.z = upos(h.u, h.node)
      if h.bone == 'head' and h.kind == AVATAR_KIND and h.u ~= S.mine and fell(h) then fresh = true end
    end
  end
  -- a new Helldiver of yours (a ship with none yet: the old handle went with the world; a mission after your hellpod
  -- drop): the one whose head sits where the game camera keeps yours, never the nearest or the one the falling camera
  -- passed most (2026-11-12: a teammate beside you after a mission; a teammate's pod still falling at 44 m/s past the
  -- camera on a 4-player drop, which then locked yours out as a 'teammate' until the next drop)
  local fitting = c.fx and not gate and not S.head and (not chef.in_mission() or drop_seen()) and {}
  for _, h in ipairs(near) do
    h.x, h.y, h.z = upos(h.u, h.node)
    local teammate = gate and h.u ~= S.mine
    if teammate and others_here() and h.bone == 'head' and h.kind == AVATAR_KIND then
      once('podwait' .. tostring(h.u), 'a teammate near the camera: waiting for your hellpod (%d players, fastest camera fall so far %.0f m/s)',
        chef.players(), S.fall_max or 0)
    end
    if fresh and not fell(h) then teammate = true end
    if h.x and h.bone == 'head' and h.kind == AVATAR_KIND and (not is_corpse(h.u) or back_up(h)) and not teammate then  -- never back into a dead body
      local d = sqrt((h.x - c.x) ^ 2 + (h.y - c.y) ^ 2 + (h.z - c.z) ^ 2)
      -- several pods at once (a group reinforcement): the one the camera followed down most wins, then the nearest
      local f = fresh and (S.avfollow[h.u] or 0) or 0
      h.f = f
      if fitting then
        local s, _, _, ahead = cam_fit(c, h.x, h.y, h.z)
        if s and ahead > 0.5 and not (S.reject[h.u] and S.t < S.reject[h.u]) then fitting[#fitting + 1] = { h = h, s = s, d = d } end
      elseif d < 6 and (not best or f > best.f or f == best.f and d < bd) then best, bd = h, d end
    end
  end
  if fitting then best, bd = cam_pick(fitting, c) end
  if not best then
    -- a seat whose game camera sits far off (tank crew, the Gator, the Pelican): a rescan finding nobody near that
    -- camera keeps the Helldiver you have
    if S.head and (S.tank or S.gator or S.pel or S.tl14) and alive(S.head.u) then return end
    S.head, S.parts = nil, {}; return
  end
  if not (S.head and S.head.u == best.u) then
    if best.u ~= S.mine and others_here() then
      log('your hellpod came down: taking that Helldiver (%s, came down %.0f m, followed by the camera %d times)',
        fresh and 'the one that fell' or 'nearest, none fell', S.avtop[best.u] and best.z and S.avtop[best.u] - best.z or 0,
        S.avfollow[best.u] or 0)
      S.avfollow = {}
      S.drop_t = nil
    end
    if is_corpse(best.u) then
      log('the body taken for dead is standing%s: yours again', proven(best.u) and ' with an animation' or '')
      unmark(best.u)
    end
    S.mine = best.u
    S.head = { u = best.u, node = best.node, root = chef.unit_node(best.u, 'root') or 1 }
    S.hmax, S.stance, S.down, S.rising, S.pidle = nil, nil, false, false, nil
    -- the same body after a restart: its tallest as measured (a prone body would read as standing at its own height),
    -- and prone or down only while it's still lying now (it may have got up since the restart)
    local b = S.body_kept
    if b and b.u == best.u and b.hmax and b.hmax > 0 then
      S.hmax = b.hmax
      local hz, fz = select(3, upos(best.u, best.node)), select(3, upos(best.u, S.head.root))
      if hz and fz and (hz - fz) / b.hmax < 0.45 then S.stance, S.down = b.stance, b.down or false end
    end
    S.body_kept = nil
    S.rescans = { S.t + 5, S.t + 15 }                -- pieces that load late
  end
  local at = {}
  for _, nn in ipairs(BONES) do
    local i = chef.unit_node(best.u, nn)
    local x, y, z
    if i then x, y, z = upos(best.u, i) end
    if x then at[nn] = { x, y, z } end
  end
  local parts, old = {}, {}
  for _, p in ipairs(S.parts) do old[p.u] = p end
  for _, h in ipairs(near) do
    local a = h.x and at[h.bone]
    if a and abs(h.x - a[1]) + abs(h.y - a[2]) + abs(h.z - a[3]) < 0.05 then
      parts[#parts + 1] = old[h.u] or { u = h.u, kind = h.kind, bone = h.bone, groups = groups_of[h.kind] }
    end
    -- PDA / sample container: the one hanging within 1 m of this Helldiver's hips
    local hp = at.hips
    if h.gear and h.x and hp and (h.x - hp[1]) ^ 2 + (h.y - hp[2]) ^ 2 + (h.z - hp[3]) ^ 2 < 1 then
      parts[#parts + 1] = old[h.u] or { u = h.u, kind = h.kind, bone = 'hips', gear = h.gear, groups = {} }
      once('gear' .. h.kind, '%s found on the hips', h.gear:sub(6))
    end
  end
  S.parts = parts
end

-- a scan of the world's units, a thousand a frame: per unit only cached lookups, plus one position for kinds that
-- have a bone we want; keeps the ones within 10 m of the view
local function start_scan(w)
  if S.scan then return end
  local list = call('World.units', w)
  if type(list) ~= 'table' then return end
  S.last_scan = S.t
  local near = {}
  local follow, fd = nil, 1e9  -- during a drop: the Helldiver nearest the falling camera (your pod: it chases it)
  S.scan = true
  local job = chef.spread(list, 1000, function(u)
    local k = chef.unit_kind(u)
    if not k or k == CAMERA_KIND then return end
    local b = bone_of[k]
    if b == false and not GEAR[k] then return end  -- known to have none of our bones: no engine call (most of the map)
    -- no new kinds while down or dead (ragdoll, gibs, dropped gear): they're asked once you're up
    if b == nil and S.down_any and chef.in_mission() then return end
    if b == nil then
      if chef.in_mission() then once('kind' .. k, 'new kind %s: asking its bones', k) end
      b = false
      for _, nn in ipairs(BONES) do
        local i = chef.unit_node(u, nn)
        if i then b = { bone = nn, node = i }; break end
      end
      bone_of[k] = b
    end
    if GEAR[k] then b = { gear = GEAR[k] } end
    if not b then return end
    local c = chef.camera()
    local x, y, z = upos(u)
    if k == AVATAR_KIND and z and z > (S.avtop[u] or -1e9) then S.avtop[u] = z end  -- each Helldiver's highest point, anywhere
    if k == AVATAR_KIND and c and x and (S.fall_t or 0) > 0 then
      local d = (x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2
      if d < fd then follow, fd = u, d end
    end
    if c and x and (x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2 < 100 then
      near[#near + 1] = { u = u, kind = k, bone = b.bone, node = b.node, gear = b.gear }
    end
  end, function(ok)
    S.scan = nil
    if follow then S.avfollow[follow] = (S.avfollow[follow] or 0) + 1 end
    if ok then scan_done(near) end
  end)
  if S.scan then S.scan = job end  -- unless it already finished
end

-- every half second: lost the Helldiver (gone, or the game's camera is far from him and none is ours)? find him again

local function check_player(w)
  local h = S.head
  if h then
    local lost = not alive(h.u)
    if not lost then
      local ours = false
      for _, k in ipairs(S.cams) do if k.state == 'ours' or k.state == 'scope' then ours = true end end
      local c = chef.camera()
      local x, y, z = upos(h.u, h.node)
      -- ship: kept while it's there (the cutscene camera framing a teammate's pod made the old check let go and
      -- take the teammate's Helldiver); S.away hands the view to the game instead
      -- a tank's crew camera (about 11 m back), the Gator's and the Pelican's outside shots sit far from the head
      local seatcam = S.tank or S.gator or S.pel or S.tl14
      -- a camera pick still being checked (cam_confirm) isn't let go by distance: the check decides, else a wrong one
      -- stays S.mine and gates yours out
      local checking = S.confirm and not S.dead
      lost = (not x and not bad_now(h.u)) or (x and chef.in_mission() and not ours and not S.galaxy and not seatcam and not checking and c and (x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2 > 36)
    end
    if lost then
      -- only the body that died (the head can already be your reinforcement, picked while that death is still held
      -- through the fall and the pod) or a body lying: proven, or a guess the body standing up can undo
      local died = S.dead and h.u == S.dead_u
      if died and S.dsure == 'anim' then mark_corpse(h.u)
      elseif died or S.stance == 'prone' or S.down or S.dive then mark_guess(h.u) end
      S.head, S.parts = nil, {}
    end
  end
  -- a piece swapped out (new helmet or armour): drop it and look for the new one soon
  local live = {}
  for _, p in ipairs(S.parts) do if alive(p.u) then live[#live + 1] = p end end
  if #live < #S.parts then S.parts = live; table.insert(S.rescans, 1, S.t + 1) end
  -- in a hellpod on the ship, or its cutscene: no scans (the launch makes and removes units all at once). Nor at the
  -- galactic table: a scan from its far camera found nobody, lost the Helldiver, and S.away could never clear again
  if (S.nopod or S.away or S.galaxy) and not chef.in_mission() then return end
  if not S.head then
    -- right after your hellpod is seen, or on the ship (the pick waits for the camera to settle): every half second
    local every = (drop_seen() or not chef.in_mission()) and 0.5 or 3
    if not S.last_scan or S.t - S.last_scan >= every then start_scan(w) end
  elseif S.rescans[1] and S.t >= S.rescans[1] then
    table.remove(S.rescans, 1); start_scan(w)
  end
end

-- one new piece a frame: its kind's mesh names (asked once per kind, ever)
local function probe_one()
  if S.down_any and chef.in_mission() then return end
  if S.nopod and not chef.in_mission() then return end
  for _, p in ipairs(S.parts) do
    if not p.groups then
      local g = groups_of[p.kind] or probe(p.u)
      groups_of[p.kind], p.groups = g, g
      local got = {}
      for id, l in pairs(g) do got[#got + 1] = id:sub(6) .. ' ' .. table.concat(l, ',') end
      table.sort(got)
      once('part' .. p.kind, 'part %s (%s%s): %s', p.kind, p.bone or '?', p.u == (S.head and S.head.u) and ', the Helldiver' or '', #got > 0 and table.concat(got, ' | ') or 'no known meshes')
      return true
    end
  end
  -- every piece probed: one line per outfit saying which hide switches found nothing (a game patch renamed meshes)
  if #S.parts == 0 or S.checked == S.parts then return end
  S.checked = S.parts  -- a new table after every scan or swap
  local kinds, found = {}, {}
  for _, p in ipairs(S.parts) do
    kinds[#kinds + 1] = tostring(p.kind)
    for id in pairs(p.groups or {}) do found[id] = true end
  end
  table.sort(kinds)
  local miss = {}
  for id in pairs(GROUPS) do if not found[id] then miss[#miss + 1] = id:sub(6) end end
  table.sort(miss)
  once('check' .. table.concat(kinds, ','), #miss == 0 and 'mesh check: all parts found' or 'mesh check: nothing found for %s', table.concat(miss, ', '))
end

-- meshes: hide what the settings ask for (again each time: the game can show them), show again only what we hid
local function apply_hiding()
  local want, on = {}, S.shown or S.tpkeep
  if on then
    for _, p in ipairs(S.parts) do
      for id, list in pairs(p.groups or {}) do
        if V[id] or (SCOPED[id] and (V.hide_armor and S.scoped or S.divehide)) then
          want[p.u] = want[p.u] or {}
          -- hide_neck's undersuit torso is also the belly: shown while lying on your back (gap at the belly, 2026-11-07)
          for _, nm in ipairs(list) do if not (S.belly and nm:find('torso_undergarment', 1, true)) then want[p.u][nm] = true end end
        end
      end
    end
  end
  for u, names in pairs(S.hidden) do
    for nm in pairs(names) do
      if not (want[u] and want[u][nm]) then call('Unit.set_mesh_visibility', u, nm, true, 'default'); names[nm] = nil end
    end
    if next(names) == nil then S.hidden[u] = nil end
  end
  for u, names in pairs(want) do
    local h = S.hidden[u] or {}
    for nm in pairs(names) do
      -- a LOD the game keeps hidden right now is left alone, so showing it again later can't break the LOD switch
      if h[nm] or call('Mesh.visibility', call('Unit.mesh', u, nm)) == true then
        local _, why = call('Unit.set_mesh_visibility', u, nm, false, 'default')
        if why then once('hide' .. tostring(why), 'mesh hide refused: %s', tostring(why)) else h[nm] = true end
      end
    end
    if next(h) then S.hidden[u] = h end
  end
  -- unnamed pieces (no known mesh): numbered in the order found, hidden whole
  -- shortcut: switches follow the number, not the piece, so a new outfit can renumber them; key by kind if that bites
  local n, uw = 0, {}
  for _, p in ipairs(S.parts) do
    if p.gear then
      if on and V[p.gear] then uw[p.u] = true end
    elseif p.groups and next(p.groups) == nil and p.u ~= (S.head and S.head.u) then
      n = n + 1
      local r = ROW['extra' .. n]
      if r then r.label = 'Piece ' .. n .. ' (on ' .. (p.bone or '?') .. ')' end
      if on and V['extra' .. n] then uw[p.u] = true end
    end
  end
  for i = n + 1, 4 do if ROW['extra' .. i] then ROW['extra' .. i].label = 'Piece ' .. i .. ' (none)' end end
  for u in pairs(S.uhid) do if not uw[u] then call('Unit.set_unit_visibility', u, true); S.uhid[u] = nil end end
  -- the engine call returns nothing on success, so only a refusal (second value) counts as failed
  for u in pairs(uw) do
    if not S.uhid[u] then local _, why = call('Unit.set_unit_visibility', u, false); if not why then S.uhid[u] = true end end
  end
end

-- the head inside one of the watch's units (its box above and below the head, along the unit's own up); with top,
-- also the head up to 2.5 m over the box (the FRV gun: the gunner's head sits above the car's box), fifth value true
-- A vehicle is only asked about (rotation, box) once it has settled: seen 3 s and not moving up or down fast. A car or
-- tank still dropping in, or tumbling, is left alone unless you already sit in it (cur). Its position is the watch's
-- own, which costs no engine call.
local seen = setmetatable({}, { __mode = 'k' })
local function settled(it)
  local v = seen[it.unit]
  if not v then v = { t = S.t, z = it.z }; seen[it.unit] = v end
  local still = abs((it.z or 0) - (v.z or 0)) < 0.5
  v.z = it.z
  if not still then v.t = S.t end
  return S.t - v.t >= 3
end
local function inside(watch, top, cur)
  if not (watch and S.head and chef.ray_box) then return false end
  local x, y, z = upos(S.head.u, S.head.node)
  if not x then return false end
  for _, it in ipairs(watch.items) do
    -- the car you sit in skips the distance check: the watch's position is up to 2 s old, a car driving off leaves it
    if it.unit == cur or (abs(it.x - x) + abs(it.y - y) < 8 and settled(it)) then
      local from = { x = x, y = y, z = z }
      local ux, uy, uz = xyz(call('Quaternion.up', call('Unit.world_rotation', it.unit, 1)))
      if not ux then ux, uy, uz = 0, 0, 1 end
      local down = chef.ray_box(from, { x = -ux, y = -uy, z = -uz }, it.unit)
      if down then
        if chef.ray_box(from, { x = ux, y = uy, z = uz }, it.unit) then return it, x, y, z end
        if top and down < 2.5 then return it, x, y, z, true end
      end
    end
  end
  return false
end

-- FRV seat from the diver's animation: every seat plays its own, whatever the car does (log 2026-11-06: 108 driver,
-- 112 passenger, 104 gun). A head held over the car also counts as the gun (backup for a car with another gun animation)
-- the gun is ALWAYS 104 (both logs); the Gunner FRV's passenger seat sits over the car box and plays other numbers
-- each round (105/106, then 109/110), so a head over the car with any other animation is the passenger seat
local FRV_ANIM = { [108] = 'driver', [112] = 'passenger', [104] = 'gunner', [110] = 'passenger' }  -- 110: Supply FRV (log 2026-11-11)
local function seat_anim()
  -- asked once per update: the animation can't change within one
  if S.sa_t == S.t then return S.sa end
  S.sa_t, S.sa = S.t, nil
  -- only next to a car or tank: no animation question anywhere else (see anim)
  if not S.head then return nil end
  local x, y = upos(S.head.u, S.head.node)
  if not x then return nil end
  local near = S.frv_u ~= nil  -- the car you sit in counts as near however old the watch's position is
  for _, w in ipairs({ frv_watch, tank_watch }) do
    for _, it in ipairs(w and w.items or {}) do if abs(it.x - x) + abs(it.y - y) < 8 then near = true end end
  end
  if not near then return nil end
  local a = anim(S.head.u)
  S.sa = type(a) == 'number' and a or nil
  return S.sa
end
local function frv_seat(it, x, y, z, gun)
  local anim = seat_anim()
  local seat = FRV_ANIM[anim] or gun and 'passenger'
  if seat == 'gunner' and not FRV_GUN[it.kind] then seat = nil end
  if not seat then  -- not a seat animation (getting in or out): keep the last seat, else by the side you sit on
    local fx, fy = chef.unit_rotation(it.unit)
    local rx, ry = upos(it.unit)
    local along = fx and rx and (x - rx) * fx + (y - ry) * fy or 1
    seat = S.seat or (along > 0 and 'driver' or 'passenger')
  end
  if seat ~= S.seat then
    S.seat = seat
    log('FRV %s seat %s (animation %s)', it.kind, seat, tostring(anim))
  end
  return seat
end
-- a seat animation within 5 m of an FRV is that seat: keeps it out of the box (tumbling, flipped) and starts it while
-- the head is still climbing in (log 0.3.145: seat animation 0.6 s before the head was inside the car's box)
local function frv_near()
  local a = seat_anim()
  if not (FRV_ANIM[a] and frv_watch and S.head) then return false end
  local x, y = upos(S.head.u, S.head.node)
  for _, it in ipairs(x and frv_watch.items or {}) do
    if abs(it.x - x) + abs(it.y - y) < 5 and (FRV_ANIM[a] ~= 'gunner' or FRV_GUN[it.kind]) then return it end
  end
  return false
end
-- how far the game's own camera is from your head: the shown camera while it's the game's, else the main camera's own
-- last spot (first person writes over the shown one)
local function game_cam_far()
  local hx, hy, hz
  if S.head then hx, hy, hz = upos(S.head.u, S.head.node) end
  if not hx then return nil end
  local px, py, pz
  local c = not S.act and chef.camera()
  if c then px, py, pz = c.x, c.y, c.z
  else
    -- the main camera's spot; before one is known as main (a far camera is never written first), the first one seen
    for _, k in ipairs(S.cams) do
      if k.gp and (k.main or not px) then px, py, pz = k.gp[1], k.gp[2], k.gp[3] end
    end
  end
  if not (finite(px) and finite(py) and finite(pz)) then return nil end
  return sqrt((px - hx) ^ 2 + (py - hy) ^ 2 + (pz - hz) ^ 2)
end
local function tank_seat(it)
  local anim = seat_anim()
  local seat = TANK_ANIM[anim]
  -- the seat layer: 96/97 the gunner; 102 the driver when the game camera sits more than 7 m back (a passenger's sits
  -- about 4 m back), kept while it stays 102 (first person writes over the shown camera)
  local l = S.l14 and L14.TANK[S.l14]
  if l == 'crew' then seat = 'crew'
  elseif l == 'driver' and seat ~= 'passenger' and seat ~= 'crew' then
    local far = game_cam_far()
    if S.tseat == 'driver' or (far and far > 7) then seat = 'driver' elseif not seat then seat = 'passenger' end
  end
  if seat ~= S.tseat then S.tseat = seat; log('%s seat %s (animation %s)', TANKS[it.kind].name, seat, tostring(anim)) end
  return seat
end
local SEAT = { driver = { 'frv_fwd', 'frv_up', 'frv_side' }, passenger = { 'frvp_fwd', 'frvp_up', 'frvp_side' },
  gunner = { 'frvg_fwd', 'frvg_up', 'frvg_side' }, mech = { 'mech_fwd', 'mech_up', 'mech_side' }, empl = { 'empl_fwd', 'empl_up', 'empl_side' },
  bastion = { 'bastion_fwd', 'bastion_up', 'bastion_side' }, maelstrom = { 'maelstrom_fwd', 'maelstrom_up', 'maelstrom_side' },
  tgun = { 'tgun_fwd', 'tgun_up', 'tgun_side' }, tdrv = { 'tdrv_fwd', 'tdrv_up', 'tdrv_side' } }

-- manning an emplacement: your feet stay within 1.2 m of its base (the head isn't inside its box)
-- the exosuit's settings prefix: from the arm whose box holds the head, else the arm nearest the body (within 6 m)
local function mech_model(it)
  if MECH_ARMS[it.kind] then return MECH_ARMS[it.kind] end
  local best, pre = 6, ''
  for _, o in ipairs(mech_watch.items) do
    local d = MECH_ARMS[o.kind] and abs(o.x - it.x) + abs(o.y - it.y)
    if d and d < best then best, pre = d, MECH_ARMS[o.kind] end
  end
  return pre
end
local function at_emplacement()
  if not (empl_watch and S.head) then return false end
  local x, y, z = upos(S.head.u, S.head.root)
  if not x then return false end
  local near, at
  for _, it in ipairs(empl_watch.items) do
    local d = sqrt((it.x - x) ^ 2 + (it.y - y) ^ 2)
    if d < 3 and (not near or d < near) then near = d; at = it end
  end
  if not near then S.empl_d, S.empl_still = nil, 0; return false end
  -- called every 0.25 s. Manning keeps your distance to the gun even while it turns; walking up, away or
  -- climbing on it changes it. shortcut: 0.35 m feet height is a guess, check the log's 'manned' lines
  local step = abs(near - (S.empl_d or 99))
  S.empl_d = near
  local ring, dz = EMPL_DIST[at.kind] or { 0, 1.2 }, z - (at.z or z)
  local spot = near >= ring[1] and near <= ring[2] and abs(dz) < 0.35
  S.empl_still = (spot and step < 0.05) and (S.empl_still or 0) + 1 or 0
  local on = S.empl and spot and step < 0.1 or S.empl_still >= 2
  S.empl_pre = PRE[at.kind] or ''
  if on ~= S.empl then
    log('emplacement %s %s (%.2f m from its base, feet %.2f m above it)', at.kind, on and 'manned' or 'left', near, dz)
  end
  return on
end

-- stance from the head's height over the feet against the tallest seen; knocked down = lying with the head not
-- ahead of the view (prone and dives keep it ahead)
local STANCES = { stand = { 0, 0, 0 }, crouch = { 'crouch_fwd', 'crouch_up', 'crouch_side' }, prone = { 'prone_fwd', 'prone_up', 'prone_side' } }
-- the get-up's own animations (logs 2026-11-06): a quick get-up starts before 'settled prone' is ever seen
local GETUP_ANIM = { [43] = true, [70] = true, [71] = true, [72] = true }
-- still flat: crawling/turning (41, 50), dive landings (45, 47), lying idle (42, 48). Counted as getting up they held
-- the get-up's stay-ahead for seconds, so looking back put the view out over the legs (log 2026-11-11)
local LIE_ANIM = { [41] = true, [42] = true, [45] = true, [47] = true, [48] = true, [50] = true }
local function stance(dt, ox, oy, oz, rx, ry)
  -- tallest standing height: on foot only (the FRV gun read 2.1 m and made standing look like a crouch)
  if not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) then S.hmax = max(S.hmax or 1.2, min(oz, 1.85)) end
  local r = oz / S.hmax
  -- feet speed, smoothed (a jump over 2 m in one frame is a respawn or teleport, not speed)
  if S.prx and dt > 0 and abs(rx - S.prx) + abs(ry - S.pry) < 2 then
    local k = 1 - exp(-dt * 8)
    S.vx, S.vy = S.vx + ((rx - S.prx) / dt - S.vx) * k, S.vy + ((ry - S.pry) / dt - S.vy) * k
  else S.vx, S.vy = 0, 0 end
  S.prx, S.pry = rx, ry
  -- a dive throws you head first the way you were moving as you started going down: such a lie is not a knockdown
  -- (a real dive read 4.7 m/s, head along it 0.98 in the log, 2026-11-06)
  local l = sqrt(ox * ox + oy * oy)
  -- how fast the head rises over the feet, eased (a get-up rises, a dive drops)
  local hv = S.poz and dt > 0 and (oz - S.poz) / dt or 0
  S.poz, S.ozv = oz, (S.ozv or 0) + (hv - (S.ozv or 0)) * (1 - exp(-dt * 20))
  if r > 0.75 then S.fall, S.dive = nil, nil
  elseif not S.fall and not S.slide then  -- a slide drops the head to 0.57-0.9 m at 4-6 m/s: read as a dive (log 2026-11-14)
    local v = sqrt(S.vx * S.vx + S.vy * S.vy)
    -- not while still low in a get-up or lying: the get-up animation and fast crawling move the feet 1.5+ m/s, and
    -- that 'fall' cut the get-up and started a dive half way up (log 2026-11-11, 95.9 s and 121.8 s)
    -- the last step of a get-up moves them 1.5+ m/s too, head still rising: no dive until the head drops
    S.fall = v > 1.5 and not (S.rising and (r < 0.6 or S.ozv > 0.3)) and { S.vx / v, S.vy / v, v } or false
    -- diving out of a get-up ends the get-up: its stay-ahead held the view over your legs (2026-11-07)
    if S.fall and S.rising then S.rising, S.pidle, S.prone_t = false, nil, 0; log('get-up cut by a dive') end
    -- 4th value: the way you go down along the view (1 forward, 0 sideways, -1 backward)
    local c = S.fall and chef.camera()
    local hl = c and sqrt(c.fx * c.fx + c.fy * c.fy) or 0
    if S.fall then S.fall[4] = hl > 1e-4 and (S.fall[1] * c.fx + S.fall[2] * c.fy) / hl or 1 end
  end
  if S.fall and S.dive == nil and r < 0.5 and l > 0.3 then
    local lead = (ox * S.fall[1] + oy * S.fall[2]) / l
    S.dive = lead > 0.5
  end
  -- diving: known lie after a dive, or already mid-air (going down fast with the head out ahead along the motion)
  local dv = S.dive == true and S.fall and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
  -- not while lying or getting up: the fall left from going down started a 'dive' mid get-up (log 2026-11-11)
  -- and the head 0.45 m out: landing from a step or ledge while moving dips the head to 1.03-1.10 m, 0.30-0.31 m
  -- out (a dive there: 0.37 m, and 0.64+ by the time it's low), and that 'dive' pushed the view forward and back
  -- (report 2026-11-11: snaps on every small drop). Head-drop speed didn't tell them apart (landings 2.7-5.9 m/s)
  if not dv and S.fall and not S.rising and not S.nodive and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) and r < 0.75 and l > 0.3 and (ox * S.fall[1] + oy * S.fall[2]) / l > 0.5 then
    dv = l > 0.45
  end
  -- S.diving = the hide switch for this dive's direction, or false
  dv = dv and (S.fall[4] > 0.5 and 'dive_hide' or S.fall[4] < -0.5 and 'dive_hide_back' or 'dive_hide_side')
  -- a dive lasts until you stand (standing height held 0.3 s), so its hiding and forward push hold while you get up
  local seated = S.frv or S.mech or S.empl or S.tank or S.gator or S.pel
  S.up_t = (S.stance == 'stand' or r > 0.8) and (S.up_t or 0) + dt or 0
  -- up into a crouch and the head still for 0.3 s: the get-up and its dive are over (they held the view 0.3 m up and
  -- ahead for 3 s, then dropped it, log 2026-11-11); S.crup = when, until you lie down again
  S.set_t = S.rising and S.stance == 'crouch' and abs(S.ozv) < 0.2 and (S.set_t or 0) + dt or 0
  if S.set_t >= 0.3 and not S.crup then S.crup, S.fall, S.dive = S.t, nil, nil; log('settled in a crouch') end
  if not dv and S.diving and not seated and S.up_t < 0.3 and not S.crup then dv = S.diving end
  -- real dives are low within 0.5 s (21 logged); crouch-walking with the head 0.45+ m out passed the head-out rule and
  -- held the dive push until you stood (up to 21 s crouched, user 2026-11-14): not low by 0.7 s ends it, and that rule
  -- stays off until the head is back over the feet or low (a real dive from there is still caught once low)
  if dv and not S.diving then S.dive_t, S.dlow = S.t, false end
  if r < 0.5 then S.dlow, S.nodive = true, nil elseif l < 0.3 then S.nodive = nil end
  if dv and not S.dlow and S.t - (S.dive_t or S.t) > 0.7 then dv, S.nodive = false, true; log('not a dive: head still %.2f m over the feet after 0.7 s (%s)', oz, S.stance or 'stand') end
  -- getting up: risen out of prone, until standing the same way
  S.rise_t = S.rising and (S.rise_t or 0) + (r > 0.5 and dt or 0) or 0
  if S.stance == 'prone' and oz > 0.1 and not seated and S.rise_t < 3 then S.rising, S.crup = true, nil elseif seated or S.up_t >= 0.3 or S.rise_t >= 3 or S.crup then S.rising, S.pidle, S.prone_t = false, nil, 0 end
  -- the get-up starts while the head is still low: anything but the animation you settled prone in counts
  -- (log 2026-11-06: head goes 0.73 -> 1.39 m in 0.2 s, the clipping comes before that)
  local an
  if S.rising and chef.in_mission() then
    an = anim(S.head.u)
    if an ~= S.an then log('anim %s (%s, head %.2f m over feet)', tostring(an), S.stance or 'stand', oz); S.an = an end
    S.prone_t = S.stance == 'prone' and (S.prone_t or 0) + dt or 0
    if S.prone_t > 0.6 and S.pidle == nil and an ~= nil and not GETUP_ANIM[an] then S.pidle = an; log('settled prone, anim %s', tostring(an)) end
  end
  -- rising from prone into a crouch (anim 11, then 16): the head stays 0.3-0.7 m ahead of the hips all the way, so the
  -- get-up lift and push have nothing to clear; the lift held the view 0.4 m over the crouched head for ~1.5 s (report
  -- 2026-11-11). Carrying on up to standing (70-73) brings them back
  if not S.rising then S.cup = nil elseif an == 11 or an == 16 then S.cup = true elseif GETUP_ANIM[an] or an == 73 then S.cup = nil end
  local gu = S.rising and (r > 0.5 or GETUP_ANIM[an] or S.pidle ~= nil and an ~= S.pidle and not LIE_ANIM[an]) or false
  if gu ~= (S.getup or false) then S.getup = gu; log('getting up %s', gu and 'start' or 'end') end
  if dv ~= (S.diving or false) then
    S.diving = dv; log('dive %s (head %.2f m over feet, %.2f m out, dropping %.1f m/s)', dv or 'end', oz, l, -(S.ozv or 0)); apply_hiding()
    if dv then S.crup = nil end  -- a new dive holds through its own get-up again
  end
  -- the game can show pieces again mid-dive: re-hide every frame while it lasts
  if dv and V[dv] then S.rehide = max(S.rehide or 0, S.t + 0.2) end
  local cur = S.stance or 'stand'
  local new = cur
  if cur == 'stand' and r < 0.75 or cur == 'prone' and r > 0.5 then new = 'crouch' end
  if r < 0.45 and not S.slide then new = 'prone' elseif r > 0.85 then new = 'stand' end
  if new ~= cur then S.stance = new; log('stance %s (head %.2f m over feet, tallest %.2f, moving %+.1f m/s)', new, oz, S.hmax, S.ozv or 0) end
  local st = STANCES[S.stance or 'stand']
  -- lying (dive or prone) and looking back along your own body: lift the view over the back and the gun on it
  local c = chef.camera()
  local back = 0
  -- also while getting up: the head is still out over the body, so looking back shows your own back
  if c and r < 0.6 and not S.getup and l > 0.2 then
    local hl = sqrt(c.fx * c.fx + c.fy * c.fy)
    if hl > 1e-4 then back = max(0, -(ox * c.fx + oy * c.fy) / (l * hl)) end
  end
  -- looking back along the body after a dive: show the hidden pieces again (on past ~105 deg, off under ~100)
  local lb = S.lback and back > 0.17 or back > 0.25
  if lb ~= (S.lback or false) then S.lback = lb; log('looking back %s (%s)', lb and 'start' or 'end', S.getup and 'getting up' or S.stance or 'stand') end
  -- getting up keeps them hidden even looking back (the lift handles the view)
  local db = S.diving and not S.getup and lb or false
  -- dives hide the collar and shoulders (see apply_hiding)
  local dh = (S.diving and V[S.diving] and not db) and true or false
  if dh ~= (S.divehide or false) then S.divehide = dh; apply_hiding() end
  -- for 1 s after settling in a crouch the get-up's lift and push glide out over ~0.3 s, not 0.1 s (the body is still,
  -- so a quick drop showed as the head snapping back into place, 2026-11-11)
  S.gslow = S.crup and S.t - S.crup < 1 and S.stance == 'crouch'
  local a = 1 - exp(-dt * (S.gslow and 3 or 10))
  -- the dive's forward push only before you're down: the face view zeroes it while lying, so it came on at the
  -- get-up's start and went as you rose (0.26 m forward and back; plain prone get-ups have none and felt fine, 2026-11-11)
  local rise = min(1, max(0, (0.8 - r) / 0.25))
  -- lying: the lift fades out as you look down (none past ~45 deg down), so looking down at your back never shows the neck
  local dk = S.stance == 'prone' and c and min(1, max(0, 1 - (-c.fz - 0.3) / 0.4)) or 1
  local na = 1 - (S.sideaim or 0)
  local wf, wu = (st[1] == 0 and 0 or V[st[1]]) + (S.diving and S.diving ~= 'dive_hide_back' and V.dive_fwd * (1 - back) * na * (S.rising and 0 or 1) or 0), (st[2] == 0 and 0 or V[st[2]] * dk) + V.back_lift * back * dk * na + (S.getup and V.getup_cam and not S.cup and V.getup_lift * rise or 0)
  local ws = st[3] == 0 and 0 or V[st[3]]
  -- backward dive in the air (until S.oblie = lying still on your back)
  if S.diving == 'dive_hide_back' and not S.getup and not S.oblie then wf = wf + V.bdive_fwd end
  -- face view: the face already places the view, so no guessed pushes or lifts while down
  S.eyes = V.eyes and (S.diving or S.stance == 'prone') and not S.getup and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  if S.eyes then wf, wu, ws = 0, 0, 0 end
  S.sf, S.su = (S.sf or 0) + (wf - (S.sf or 0)) * a, (S.su or 0) + (wu - (S.su or 0)) * a
  S.ss = (S.ss or 0) + (ws - (S.ss or 0)) * a
  -- knocked down: held 0.2 s to enter, up again (crouch height or more) for 0.4 s to leave
  local away = false
  if c and l > 0.3 then
    local hl = sqrt(c.fx * c.fx + c.fy * c.fy)
    away = hl < 1e-4 or (ox * c.fx + oy * c.fy) / (l * hl) < 0.5
  end
  if not S.down then
    S.down_t = (r < 0.5 and away and not S.dive and not S.slide) and (S.down_t or 0) + dt or 0
    if S.down_t > 0.2 then S.down, S.down_t = true, 0; log('knocked down (head %.2f m, %.2f m off the feet)', oz, l) end
  else
    S.down_t = r > 0.6 and (S.down_t or 0) + dt or 0
    if S.down_t > 0.4 then S.down, S.down_t = false, 0; log('up again') end
  end
end

-- how much the belly points at the sky (1 = flat on your back), from bone positions (bone rotations are unreliable
-- across poses): spine x hip axis. Its sign is learnt once standing, against the way the body faces
local function belly_up(h)
  h.lt = h.lt or chef.unit_node(h.u, 'l_thigh') or false
  h.rt = h.rt or chef.unit_node(h.u, 'r_thigh') or false
  h.chest = h.chest or chef.unit_node(h.u, 'chest') or false
  if not (h.lt and h.rt and h.chest) then return nil end
  local lx, ly, lz = upos(h.u, h.lt)
  local qx, qy, qz = upos(h.u, h.rt)
  local cx, cy, cz = upos(h.u, h.chest)
  if not (lx and qx and cx) then return nil end
  local ax, ay, az = qx - lx, qy - ly, qz - lz
  local sx, sy, sz = cx - (lx + qx) / 2, cy - (ly + qy) / 2, cz - (lz + qz) / 2
  local bx, by, bz = sy * az - sz * ay, sz * ax - sx * az, sx * ay - sy * ax
  local bl = sqrt(bx * bx + by * by + bz * bz)
  if bl < 1e-4 then return nil end
  if not S.bsign and S.stance == 'stand' and not S.diving then
    local fx, fy = chef.unit_rotation(h.u)
    if fx then
      local d = (bx * fx + by * fy) / bl
      S.bsign = d >= 0 and 1 or -1; log('belly sign %d (%.2f along the facing)', S.bsign, d)
    end
  end
  -- 2nd/3rd: the belly's direction across the floor (where the chest faces)
  if S.bsign then return S.bsign * bz / bl, S.bsign * bx / bl, S.bsign * by / bl end
end

-- a 2-40 m jump of the body in one frame = a warp (warp pack): the game's camera trails ~0.3 s behind it, which place()
-- took for a far camera and handed the view to it (report 2026-11-09)
local function warp_check(dx, dy, dz)
  local j = abs(dx) + abs(dy) + abs(dz)
  if j < 2 or j >= 40 then return end
  if not (S.warp and S.t - S.warp < 0.2) then log('warp %.1f m', j) end
  S.warp, S.snap = S.t, true
end

-- the view position for this frame: head (its offset from the root smoothed), then the offsets along the view
-- a row at its top slot (SAME): values are snapped to steps, so compare within half a step
local function at_top(id) local r = ROW[id]; return V[id] > r.max - r.step / 2 end
local function ease_to(cur, want, st) return want > cur and min(want, cur + st) or max(want, cur - st) end
local function target(dt)
  local h = S.head
  local hx, hy, hz = upos(h.u, h.node)
  local rx, ry, rz = upos(h.u, h.root)
  if not (hx and rx) then if not bad_now(h.u) then S.head = nil end; return end
  if S.prx and S.prz and S.wu == h.u then warp_check(rx - S.prx, ry - S.pry, rz - S.prz) end
  S.wu = h.u  -- a new body (reinforced) is no warp
  -- rising speed, eased over 0.05 s (a single-frame jump is a respawn or teleport)
  if S.prz and dt > 0 and abs(rz - S.prz) < 2 then S.vz = S.vz + ((rz - S.prz) / dt - S.vz) * (1 - exp(-dt * 20)) else S.vz = 0 end
  S.prz = rz
  local ox, oy, oz = hx - rx, hy - ry, hz - rz
  -- the root jumping alone (0.75 m in one frame, head still, after a dive: log 2026-11-11) is no move of yours: the
  -- smoothed offset takes the jump at once, so the view stays with the head
  local lh = S.lhr
  if S.sm and lh and lh[7] == h.u then
    local jx, jy, jz = rx - lh[4] - (hx - lh[1]), ry - lh[5] - (hy - lh[2]), rz - lh[6] - (hz - lh[3])
    if abs(rx - lh[4]) + abs(ry - lh[5]) + abs(rz - lh[6]) > 0.15 and abs(jx) + abs(jy) + abs(jz) > 0.15 then S.sm[1], S.sm[2], S.sm[3] = S.sm[1] - jx, S.sm[2] - jy, S.sm[3] - jz end
  end
  S.lhr = { hx, hy, hz, rx, ry, rz, h.u }
  -- lying on your back, whatever got you there (backward or side dive, rolling over)
  local bu = (S.diving or S.stance == 'prone' or not S.bsign) and belly_up(h)
  local ob = (S.diving or S.stance == 'prone') and bu and (S.onback and bu > 0.3 or bu > 0.5) or false
  if ob ~= (S.onback or false) then S.onback = ob; log('on your back %s (belly up %.2f)', ob and 'start' or 'end', bu or -9) end
  -- aiming while lying on your side or back: the head is at the sights, so the dive's forward push (still on after
  -- a side dive), the look-back lift and the on-your-back limits fade out with the aim (they put the view inside
  -- the gun aiming sideways after a side dive, screenshots 2026-11-11, belly up 0.50)
  -- blended over belly up -0.7..-0.4, not cut at -0.4: aiming down-right after a backward dive sits right at -0.4,
  -- the on-your-back reach (0.2 m) flipped on and off frame to frame and the view jittered (log 2026-11-12)
  S.sideaim = S.stance == 'prone' and LIE_ANIM[S.an or 0] and not S.getup and bu and min(1, max(0, (bu + 0.7) / 0.3)) * (S.aimw or 0) or 0
  if S.sideaim > 0.5 and not S.salog then
    S.salog = true
    log('aiming lying on your side/back (belly up %.2f): head %.2f m over the hips, %.2f m from them; dive push %.2f m and lifts dropped', bu, oz, sqrt(ox * ox + oy * oy), S.diving and S.diving ~= 'dive_hide_back' and V.dive_fwd or 0)
  elseif S.sideaim == 0 then S.salog = nil end
  stance(dt, ox, oy, oz, rx, ry)
  -- getting up: the head swings 0.3-0.6 m BEHIND the hips along the view (log 2026-11-06), so the view would look
  -- through your own back. Keep it at least getup_ahead in front of the root along the view; S.gk eases the clamp in
  -- and out so there is never a jump (the lift is in stance's wu)
  -- on at once (the head is already behind the hips on the get-up's first frame), eased out after
  if S.getup and V.getup_cam then S.gk = 1 else S.gk = (S.gk or 0) * exp(-dt * 15) end
  -- and let go as the head rises: full up to 55% of standing height, none from 80%, so the view comes back with it
  local rise = min(1, max(0, (0.8 - oz / S.hmax) / 0.25))
  -- on your back the head sits in the collar (black looking down); aiming fixes it by moving the head 0.24 m toward the
  -- hips and 0.17 m up (log 2026-11-07), so hold the view at that pose: limits, never extra lifts (stacked = too high)
  -- only once landed (lying idle 48): in the air it pulled the view 0.3 m toward the legs (2026-11-07)
  -- turning or crawling while down (41, 50) keeps it: dropping it there flicked the look limit and the backward-dive
  -- push on and off as you looked around (log 2026-11-11)
  local onb = (S.onback or S.diving == 'dive_hide_back') and (S.an == 48 or S.oblie and LIE_ANIM[S.an]) and not S.getup and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
  S.oblie = onb
  -- the belly shows for the whole time on your back, the dive's air part too (0.3.57 only showed it once landed)
  local bl = (S.onback or S.diving == 'dive_hide_back') and not S.getup and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  if bl ~= (S.belly or false) then S.belly = bl; apply_hiding() end
  S.obk = (S.obk or 0) + ((onb and 1 or 0) - (S.obk or 0)) * (1 - exp(-dt * 10))
  local obk = S.obk * (1 - S.sideaim)
  if obk > 0.005 then
    local hl = sqrt(ox * ox + oy * oy)
    if V.onback_reach > 0 and hl > V.onback_reach then
      local k = 1 - obk * (1 - V.onback_reach / hl); ox, oy = ox * k, oy * k
    end
    if V.onback_height > 0 and oz < V.onback_height then oz = oz + obk * (V.onback_height - oz) end
  end
  -- S.gw = how much the clamp holds (1 while getting up, then eased out over ~0.3 s): a blend, so letting go never
  -- snaps (a max() with a shrinking distance jumped 0.5 m in one frame, 2026-11-07). S.ga = the clamp's reach now
  -- get-ups only: in a backward dive the head ends 0.7 m behind the hips, so letting go at lying slid the view back
  -- through the chest (black screen, log 2026-11-07)
  local low = V.getup_cam and S.getup and not S.cup and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
  local want = low and V.getup_ahead * rise or 0
  if low then S.gw, S.gr = 1, want else S.gw = (S.gw or 0) * exp(-dt * (S.gslow and 3 or 10)) end
  S.ga = S.gw * (S.gr or 0)
  local c0 = S.ga > 0.005 and chef.camera()
  if not c0 then S.gpush = 0 end
  local h0 = c0 and sqrt(c0.fx * c0.fx + c0.fy * c0.fy) or 0
  if h0 > 1e-4 then
    local ux, uy = c0.fx / h0, c0.fy / h0
    local f, sd = ox * ux + oy * uy, ox * uy - oy * ux
    -- the push grows at most 8 m/s (shrinks at once): switched on in one frame it jumped the view 0.6-0.67 m when a
    -- get-up started looking back or from your back (log 2026-11-11)
    S.gpush = min(S.gw * max(0, S.gr - f), (S.gpush or 0) + 8 * dt)
    f = f + S.gpush
    ox, oy = f * ux + sd * uy, f * uy - sd * ux
  end
  if S.eyes then
    -- out past the top of the head (chest -> head): outside the body in any pose; the head bone's own rotation
    -- pointed at the feet once lying (log 2026-11-06)
    h.chest = h.chest or chef.unit_node(h.u, 'chest') or false
    local cx, cy, cz
    if h.chest then cx, cy, cz = upos(h.u, h.chest) end
    local ex, ey, ez = cx and hx - cx, cx and hy - cy, cx and hz - cz
    local l = ex and sqrt(ex * ex + ey * ey + ez * ez) or 0
    if l > 0.05 then
      local k = V.eye_fwd / l
      ox, oy, oz = ox + ex * k, oy + ey * k, oz + ez * k
    end
  end
  -- stepping into or out of a vehicle seat teleports the body 2-3 m (log 2026-11-10: 'warp 2.4 m' at every FRV exit):
  -- smoothing across that trailed the view behind the body (report 2026-11-11). Start over from the head and track
  -- it tight for 0.6 s while the pose settles; leaving a seat without a warp gets the tight 0.6 s too
  local inseat = (S.frv or S.tank or S.gator) and true or false
  if S.inseat and not inseat then S.snap_t = S.t end
  S.inseat = inseat
  if S.snap then S.snap, S.sm, S.snap_t = nil, nil, S.t end
  if not S.sm then S.sm = { ox, oy, oz } end
  local a = V.smooth_side > 0 and 1 - exp(-dt * 30 / V.smooth_side) or 1
  local b = V.smooth > 0 and 1 - exp(-dt * 30 / V.smooth) or 1
  if S.gk > 0.01 then
    local g = 1 - exp(-dt / (0.05 * S.gk))
    a, b = max(a, g), max(b, g)  -- getting up tracks the head tighter than the normal smoothing, never looser
  end
  if S.eyes then local g = 1 - exp(-dt / 0.03); a, b = max(a, g), max(b, g) end
  -- dives track the head tight too: the smoothing trailed it by up to 0.3 m (toward the legs in a backward dive,
  -- over the belly so it vanished; in a forward dive it ate the 0.2 m forward push, log 2026-11-07)
  if S.diving and not S.oblie then local g = 1 - exp(-dt / 0.03); a, b = max(a, g), max(b, g) end
  -- flying (jump pack: over 8 m/s along the floor or rising 5+ m/s, on foot) tracks the head tight too (report 2026-11-09)
  local fast = sqrt(S.vx * S.vx + S.vy * S.vy)
  local fly = (fast > 8 or S.vz > 5) and not (S.frv or S.mech or S.empl or S.tank)
  if fly or S.t - (S.snap_t or -9) < 0.6 then local g = 1 - exp(-dt / 0.03); a, b = max(a, g), max(b, g) end
  -- peeking out of a passenger seat (holding right click) swings the head out of the car in a moment: the smoothing
  -- trailed it (0.17 s, up to 0.12 m), so the view lagged back toward the collar (user 2026-11-11). No smoothing
  -- while peeking and 0.5 s after (leaning back in)
  if S.aim and (S.frv == 'passenger' or S.tpass) then S.peek_t = S.t end
  local peek = S.t - (S.peek_t or -9) < 0.5
  if peek then a, b = 1, 1 end
  S.sm[1], S.sm[2], S.sm[3] = S.sm[1] + (ox - S.sm[1]) * a, S.sm[2] + (oy - S.sm[2]) * a, S.sm[3] + (oz - S.sm[3]) * b
  -- never more than smooth_max behind the head: sideways as one distance, up-down on its own (the bob it smooths is
  -- a few cm; a lag of tens of cm is a quick move the view should keep up with)
  local lim = V.smooth_max
  if lim > 0 then
    local ex, ey, ez = S.sm[1] - ox, S.sm[2] - oy, S.sm[3] - oz
    local el = sqrt(ex * ex + ey * ey)
    if el > lim then local k = lim / el; S.sm[1], S.sm[2] = ox + ex * k, oy + ey * k end
    if ez > lim then S.sm[3] = oz + lim elseif ez < -lim then S.sm[3] = oz - lim end
  end
  -- Bigger head bob: the head's movement around its slow average (0.4 s) made bigger, on foot only
  local bbx, bby, bbz = 0, 0, 0
  local bfoot = not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel or S.diving or S.getup or S.down or S.eyes)
  if V.bob_boost > 0 and bfoot then
    local bo = S.bob
    -- (a stance change moves the head far more than a step: the average starts again there, so it isn't boosted)
    if not bo or bo[4] ~= (S.stance or 'stand') then bo = { ox, oy, oz, S.stance or 'stand' }; S.bob = bo
    else
      local g = 1 - exp(-dt / 0.4)
      bo[1], bo[2], bo[3] = bo[1] + (ox - bo[1]) * g, bo[2] + (oy - bo[2]) * g, bo[3] + (oz - bo[3]) * g
    end
    local kb = V.bob_boost / 100
    local function cl(v) return max(-0.05, min(0.05, v)) end
    bbx, bby, bbz = cl((ox - bo[1]) * kb), cl((oy - bo[2]) * kb), cl((oz - bo[3]) * kb)
  else S.bob = nil end
  local c = chef.camera()
  local fx, fy, fz = 0, 1, 0
  -- a look that isn't a number this frame: placed as if looking straight ahead, so first person holds
  if c and finite(c.fx) and finite(c.fy) and finite(c.fz) then fx, fy, fz = c.fx, c.fy, c.fz end
  local hl = sqrt(fx * fx + fy * fy); if hl < 1e-4 then hl = 1 end
  local seat = SEAT[S.frv or S.mech and 'mech' or S.empl and 'empl' or S.tpass or S.tcrew or S.gator or '']
  local pre = S.frv and S.frv_pre or S.mech and S.mech_pre or S.empl and S.empl_pre or ''
  local f = V.fwd + (seat and V[pre .. seat[1]] or S.sf or 0)
  local up = V.up + (seat and V[pre .. seat[2]] or S.su or 0)
  local sd = V.side + (seat and V[pre .. seat[3]] or S.ss or 0)
  -- a tank passenger seat or an FRV's driver or passenger seat: the seat's own Forward and Sideways go along the
  -- vehicle (its facing), so looking round turns the view in place instead of swinging it round the seat. The eye's
  -- offsets still follow the look; the gun turns with your aim, so the gunner seat stays with the look.
  local vu = (S.tpass or S.tcrew == 'tdrv') and S.tank and S.tank.still and S.tank.u or (S.frv == 'driver' or S.frv == 'passenger') and S.frv_u or nil
  local vf, vs, vx, vy = 0, 0, 0, 1
  local hull = false
  if vu and seat then
    local a, b = chef.unit_rotation(vu)
    local l = (finite(a) and finite(b)) and sqrt(a * a + b * b) or 0
    if l > 1e-4 then hull, vx, vy = true, a / l, b / l; S.hullf = { vx, vy, S.t, vu }
    elseif S.hullf and S.hullf[4] == vu and S.t - S.hullf[3] < 0.25 then hull, vx, vy = true, S.hullf[1], S.hullf[2] end
  end
  -- the hull's frame eased in when it only becomes usable mid-seat (a tank settling after you climbed in): the
  -- offsets moved from the look's frame to the hull's in one frame, up to the whole offset. Entering a seat whose
  -- frame is there at once takes it at once
  local seatkey = seat and (S.tpass or S.tcrew or S.frv) or nil
  if seatkey ~= S.hullk then S.hullk, S.hullw = seatkey, hull and 1 or 0 end
  S.hullw = hull and min(1, (S.hullw or 0) + dt / 0.5) or 0
  if hull then
    local w = S.hullw * S.hullw * (3 - 2 * S.hullw)
    vf, vs = w * V[pre .. seat[1]], w * V[pre .. seat[3]]
    f, sd = f - vf, sd - vs
  end
  -- aiming on foot: the VIEW WHILE AIMING offsets, eased in and out with the aim (S.aimw 0..1)
  local aiming = S.aim and S.act and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  local at = V.aimpos_time
  S.aimw = at > 0 and max(0, min(1, (S.aimw or 0) + (aiming and dt or -dt) / at)) or (aiming and 1 or 0)
  if S.aimw > 0 then
    local e = S.aimw * S.aimw * (3 - 2 * S.aimw)   -- eased: starts and ends gently
    f, up, sd = f + e * V.aimpos_fwd, up + e * V.aimpos_up, sd + e * V.aimpos_side
  end
  -- a stationary reload (support weapons that hold you in place): the STATIONARY RELOAD offsets, eased in and out
  -- (S.srl is set in seat_layer_step)
  local srl = S.srl and S.act and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  S.srlw = max(0, min(1, (S.srlw or 0) + (srl and dt or -dt) / 0.25))
  if S.srlw > 0 then
    -- only while looking back (user 2026-11-14): none up to 90 deg off the body's facing, full from 120 deg
    local bfx, bfy
    if S.head then bfx, bfy = chef.unit_rotation(S.head.u) end
    local fc = bfx and bfy and finite(bfx) and finite(bfy) and (bfx * fx + bfy * fy) / hl or 1
    local b = max(0, min(1, -fc / 0.5))
    if (b > 0) ~= (S.srlb or false) then S.srlb = b > 0; log('stationary reload: looking back %s (facing %.2f)', S.srlb and 'on' or 'off', fc) end
    local e = S.srlw * S.srlw * (3 - 2 * S.srlw) * b * b * (3 - 2 * b)
    f, up, sd = f + e * V.srl_fwd, up + e * V.srl_up, sd + e * V.srl_side
  end
  -- sliding: the SLIDING offsets, eased in and out (S.slide is set in seat_layer_step)
  local sl = S.slide and S.act and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  S.slidew = max(0, min(1, (S.slidew or 0) + (sl and dt or -dt) / 0.2))
  if S.slidew > 0 then
    local e = S.slidew * S.slidew * (3 - 2 * S.slidew)
    f, up, sd = f + e * V.slide_fwd, up + e * V.slide_up, sd + e * V.slide_side
  end
  -- the ballistic shield in your hand (seen in a hand within 0.3 s); its window view is set at the end
  S.shield = S.shield_t ~= nil and S.t - S.shield_t < 0.3 and S.act and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) or false
  local foot = not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel or S.diving or S.onback or S.getup or S.down)
  local cl = 0
  -- Walking backward: the body turned to face the camera (facing below -0.15 along the look) and moving back toward
  -- it faster than 1.8 m/s slides the view forward, past the head; ends once the body faces 0.45 along the look again.
  -- Never aiming or prone (a backward dive is fast backward movement too: lying there it showed only your legs).
  -- In an FRV seat (its own rows, per model): looking back past your shoulder (facing below -0.15, off above 0.1)
  local bk_on, bkfacing = false, nil
  local fp = S.frv and (S.frv_pre or '')
  if (S.frv and V[fp .. 'frv_back'] or V.back_shift and foot and S.stance ~= 'prone') and not S.aim and S.act then
    local bfx, bfy = chef.unit_rotation(S.head.u)
    if finite(bfx) and finite(bfy) then
      local hx_, hy_ = fx / hl, fy / hl
      local facing = bfx * hx_ + bfy * hy_
      bkfacing = facing
      if S.frv then
        bk_on = facing < (S.bkon and 0.1 or -0.15)
        if S.bkseat ~= S.frv and S.frv_u then  -- once per seat: does the body's facing follow the car?
          local cx, cy = chef.unit_rotation(S.frv_u)
          if finite(cx) and finite(cy) then S.bkseat = S.frv; log('FRV look back: %s seat, body vs car facing %.2f', S.frv, bfx * cx + bfy * cy) end
        end
      else
      local m, sp, ss = S.bkm, nil, nil
      if m and S.t - m.t > 0.02 and S.t - m.t < 0.3 then
        sp = ((rx - m.x) * hx_ + (ry - m.y) * hy_) / (S.t - m.t)
        ss = ((rx - m.x) * hy_ - (ry - m.y) * hx_) / (S.t - m.t)
      end
      if not m then m = {}; S.bkm = m end
      if not m.t or S.t - m.t > 0.02 then m.x, m.y, m.t = rx, ry, S.t end
      -- sideways too: A/D while looking back turns the body across the view (crouched it clipped, user 2026-11-13)
      if not S.bkon then bk_on = facing < -0.15 and sp ~= nil and (sp < -1.8 or abs(ss) > 1.8)
        if bk_on then log('walking backward: %.1f m/s toward the camera, %.1f m/s sideways (%s)', -sp, abs(ss), S.stance or 'stand') end
      else bk_on = facing <= 0.45 end
      end
    end
  end
  if not S.frv then S.bkseat = nil end
  if bk_on ~= (S.bkon or false) then
    log('%s: %s (facing %.2f, head ahead of the root %.2f m)', S.frv and 'FRV look back' or 'walking backward', bk_on and 'view forward' or 'off',
      bkfacing or 0, S.sm[1] * fx / hl + S.sm[2] * fy / hl)
  end
  S.bkon = bk_on
  do
    local along = S.sm[1] * fx / hl + S.sm[2] * fy / hl
    -- glides there over 0.4 s, eased at both ends (4 m/s was a snap: FRV user 2026-11-11, on foot 2026-11-13)
    S.bkw = max(0, min(1, (S.bkw or 0) + (bk_on and dt or -dt) / 0.4))
    local e = S.bkw * S.bkw * (3 - 2 * S.bkw)
    if S.frv then
      -- an FRV slides its own fixed distance (the on-foot 0.39 m from the root put the passenger into the seat). Its Height adds
      S.bk, S.bkf, S.bkh = e * (V[fp .. 'frv_back_fwd'] or 0), 0, e * (V[fp .. 'frv_back_up'] or 0)
    else
      S.bk = e * min(0.54, max(0, 0.39 - along))
      -- its own Forward and Height replace the normal ones while slid (SAME keeps them), eased like the slide
      S.bkf = e * (at_top('back_fwd') and 0 or V.back_fwd - V.fwd)
      S.bkh = e * (at_top('back_up') and 0 or V.back_up - V.up)
    end
    cl = cl + S.bk / hl
    f, up = f + S.bkf, up + S.bkh
  end
  -- the ground under you, for the crosshair fix looking down: your feet while they're steady, held through a jump or
  -- a fall (the ground you left isn't the ground below you) until 0.3 s after they settle
  local vz = (S.fzp and dt > 0) and (rz - S.fzp) / dt or 0
  S.fzp = rz
  if not foot or abs(vz) > 2 then S.gnd_t = S.t end
  if foot and abs(vz) > 2 then S.air_t = S.t end  -- feet falling or climbing (on foot only)
  -- glides there (0.15 s): set in one frame, every step down turned the view at once 0.3 s after landing (2026-11-11)
  S.gwt = (S.gwt or 0) + ((foot and 1 or 0) - (S.gwt or 0)) * (1 - exp(-dt / 0.2))
  -- follows the feet through drops too: held, it stepped down 0.3 s after every landing and turned the view looking
  -- down (2026-11-11); falling, the game camera drops with the feet, so the aim line barely moves
  if S.frv or S.mech or S.empl or S.tank or S.gator or S.pel then S.gnd = nil elseif foot then S.gnd = S.gnd and S.gnd + (rz - S.gnd) * (1 - exp(-dt / 0.15)) or rz end
  -- offsets along the level view, height straight up: looking up or down no longer carries the view up into the gun
  -- or down into the chest; on foot, looking down pushes it forward instead
  local ux, uy = fx / hl, fy / hl
  if not seat then f = f + max(0, -fz) * V.look_down end
  S.tx = rx + S.sm[1] + bbx + ux * f + uy * sd + vx * vf + vy * vs + fx * cl
  S.ty = ry + S.sm[2] + bby + uy * f - ux * sd + vy * vf - vx * vs + fy * cl
  S.tz = rz + S.sm[3] + bbz + up
  -- the view sinks at most 2 m/s over the feet (rising is free, so nothing ever pops): landing off a ledge dipped the
  -- head 0.6 m in 0.1 s and back, and 1.2.24's landing hold, catching it late, popped the view 0.34 m (log 2026-11-11).
  -- A head dropping faster than 2.5 m/s over the feet right after landing (dips 2.7-5.9, knocked flat ~10) holds the
  -- height until the head has been back up 0.5 s, at most 2.5 s: the game dips the head again 0.2 s after you're
  -- back up, and 0.1 s let the view follow that second dip (log 2026-11-11, 1170.8 s). Dives sink at 8 m/s
  -- (they track the head tight); seats and big jumps start over
  local seated = S.frv or S.mech or S.empl or S.tank or S.gator or S.pel
  local z, hh, p = S.tz - rz, hz - rz, S.vh
  -- a warp too (getting into a car: the head drops 0.4 m in the warp frame, the hold kept the view at standing height
  -- for 2.2 s, user 2026-11-11)
  if p and not seated and S.t - p.t < 0.2 and abs(z - p.z) < 2 and S.t - (S.warp or -9) > 0.6 then
    p.hm = max(hh, p.hm - dt)  -- the head's height a moment ago (falls 1 m/s, so a fast drop leaves it behind)
    local hs = dt > 0 and (hh - p.hh) / dt or 0  -- raw: the eased speed caught the dip 0.25 m late
    if not p.hold and not S.diving and hs < -2.5 and S.t - (S.gnd_t or -9) < 0.4 then  -- just landed: not going prone
      p.hold, p.href = S.t, p.hm; log('view held: head dropping %.1f m/s (%.2f -> %.2f m)', -hs, p.hm, hh)
    end
    if p.hold then
      p.up = hh > p.href - 0.1 and (p.up or 0) + dt or 0
      p.back = p.back or p.up > 0
      -- back up once, then low and still 0.12 s: you crouched (it held the view 1.4 s, log 1421.3 s); the game's dips don't stop
      p.lo = p.back and p.up == 0 and abs(S.ozv or 0) < 0.3 and (p.lo or 0) + dt or 0
      if p.up > 0.5 or p.lo > 0.12 or S.t - p.hold > 2.5 or S.diving then log('view free (%.1f s%s)', S.t - p.hold, p.lo > 0.12 and ', crouched' or ''); p.hold, p.up, p.back, p.lo = nil, nil, nil, nil end
    end
    -- held at your standing height, not the higher in-air one: holding that, the view dropped 0.13 m when it let
    -- go 1-2 s after landing (log 2026-11-11); it settles there during the landing instead
    if not p.hold and S.stance == 'stand' and S.t - (S.air_t or -9) > 0.5 then p.zs = p.zs and p.zs + (z - p.zs) * (1 - exp(-dt / 0.3)) or z end
    local held = p.hold and (p.zs and p.z > p.zs and p.zs + (p.z - p.zs) * exp(-dt / 0.2) or p.z)
    local zc = max(z, held or p.z - (S.diving and 8 or 2) * dt)
    -- each dip the view stays above, logged once at its end (the gun dips with the body, so it drops on screen)
    if zc - z > 0.03 then p.dip = max(p.dip or 0, zc - z)
    elseif p.dip then log('view kept above a head dip: up to %.2f m%s', p.dip, p.hold and ' (landing hold)' or ''); p.dip = nil end
    z = zc
  else p = { hm = hh }; S.vh = p end
  p.z, p.t, p.hh = z, S.t, hh
  S.tz = rz + z
  -- aiming with the ballistic shield raised: the view goes into its window, whatever the other offsets. The shield
  -- model's own 'look_hole' point is the middle of the slot (12 x 5.5 cm); the view sits Distance behind it along the
  -- look, so the slot is always centred. Raised = the window ahead of the head and near its height. Eased 0.25 s
  local hp = S.shield and alive(S.shu) and node_at(S.shu, 'look_hole')
  if S.shield and not hp then once('nohole', 'shield: no window point (look_hole) found on it') end
  local raised = false
  if hp then
    local ax, ay, az = hp[1] - hx, hp[2] - hy, hp[3] - hz
    local ahead, side = (ax * fx + ay * fy) / hl, (ax * fy - ay * fx) / hl
    raised = aiming and ahead > 0.05 and ahead < 0.8 and abs(az) < 0.25
    S.shr = { hp[1] - rx, hp[2] - ry, hp[3] - rz }  -- from the root, so an ease out follows the body
  end
  if raised ~= (S.shup or false) then S.shup = raised; log('shield window view: %s', raised and 'on' or 'off') end
  S.shw = max(0, min(1, (S.shw or 0) + (raised and dt or -dt) / 0.25))
  if S.shw > 0 and S.shr then
    local e, d = S.shw * S.shw * (3 - 2 * S.shw), V.shield_back
    local wx, wy, wz = rx + S.shr[1] - fx * d, ry + S.shr[2] - fy * d, rz + S.shr[3] - fz * d
    S.tx, S.ty, S.tz = S.tx + (wx - S.tx) * e, S.ty + (wy - S.ty) * e, S.tz + (wz - S.tz) * e
    S.she = { e, wx, wy, wz, fx * d, fy * d, fz * d }  -- the draw pass re-aims it at where the slot is by then
  else S.she = nil end
  S.trx, S.try, S.trz = rx, ry, rz  -- the root this view was built from (the draw pass moves it along)
  S.thx, S.thy, S.thz = hx, hy, hz
end

-- the game's own camera rotation this frame: the one we wrote last frame (k.last) is still ours, anything else is the
-- game's (the mouse). Shared by the look limit and the crosshair fix, so neither takes the other's turn for the mouse.
local function game_rot(k, cam)
  local a, b, c, d = call('Quaternion.to_elements', call('Camera.local_rotation', cam))
  if not (finite(a) and finite(b) and finite(c) and finite(d)) then once('qr', 'camera rotation: none (%s)', tostring(b)); return end
  local l = k.last
  local mine = l and abs(a - l[1]) + abs(b - l[2]) + abs(c - l[3]) + abs(d - l[4]) < 1e-5
  if not mine or not k.qb then k.qb = { a, b, c, d } end
  return call('Quaternion.from_elements', k.qb[1], k.qb[2], k.qb[3], k.qb[4]), mine
end

local function wrote(k, q)
  local e1, e2, e3, e4 = call('Quaternion.to_elements', q)
  k.last = { e1, e2, e3, e4 }
  k.pre, k.pre_n = q, S.pn  -- what this pass wrote, for the sprint tilt to lean (MECH.tilt)
end

-- enemies (unit kinds from the game's enemy list) to range the crosshair on; positions read live
local ENEMY_KINDS = {}
for kd in (
  '0002ba767df856f3 089833d2880d9e06 08e6ffc2474287bd 09dfb04b2e578bc3 09fe0be51a23396c 0ab7b92b131c228c ' .. 
  '0adc9f9173ad8e1d 10081acef6163ef6 137988cea16458f7 16023e554fee830e 1897bdd32105d2dc 19e18b46ec55d94a ' .. 
  '1a7fcdff98c664b0 1b5b9ac4f96b36e5 1e66ee1f6f7fd00e 1f0a91729c0004e0 20b9c7734daead65 215ce160a17be4cd ' .. 
  '257d805caa7e10c0 262351741c53ff0c 282eb766c1ffa6a1 2a12104f2853ae16 2cf3488c4845f8bd 30cf04b2ec8c9bd4 ' .. 
  '30f2dee2333f227a 31bae74d2f064d8d 32541fc4ec7c9cdc 32cdeada234fb8df 33b3e0ce8d179eec 36aa99cce5e60146 ' .. 
  '3aff5fd7d5450b99 3d0e03e2d574e1ca 3e0537d606438fea 4019623142351cb6 426b3df007be9f18 44458a2c52b002fb ' .. 
  '453fe22c634eb30f 49674794a165eda8 4e342031a9d5c4f9 4e97fb073bdc7a4b 51eea86bf6997e4e 52018deb9ab6827e ' .. 
  '53d8919d7b8abd67 54e107dacf6929cb 57eed0eac346cd9d 58b2b86c11369241 5ca832447445c0ba 5d142c3a73ebc634 ' .. 
  '6021e22338333d88 604a794ec45bb820 611ba777783b08a2 63df3d07b7424588 64090088502435dd 64ba5f030b114ec1 ' .. 
  '672f7da17f3ba34a 67dc32dca4f02d33 6b202392f4ab605e 6dab2eadf5d8b692 728421351d440ebc 72a83e49ced6db3d ' .. 
  '746a7f3beda32699 74e2285c01da4f71 78e1497571012c47 7acb4bd753b71de0 7b48cacdbacb3881 7ece5304f868f6b3 ' .. 
  '82a87ad8d595b2ba 843d18d4b5512b63 856e9710e45e760f 883401af2a98a5f6 8fb47dd28b398cf7 8fc2784308e9ba99 ' .. 
  '8ff0a839830a7692 905809a4c28d8a45 9076eeed17fcee35 91ebd77931110afc 960b48a421a3faaa 96110f9d6b010e02 ' .. 
  '9647b00cc3a9d36f 965eae5a51acdd4a 96ba14c9ebb49ce1 9926876b2375a1bb 9a8a3aae287b230c 9d8827fed763650e ' .. 
  '9e2e17f2ccccafdd 9f57782f00e6ed20 a05bd1ec67b3ac4c a1f37bf2a40fbde4 a35207c6f2150806 a381a11c07d3eb94 ' .. 
  'a4552f97033392f4 a6a68d8af177f3a1 a71aafd82c6ebc92 aab438596f5e8fd9 abdb2e2a0479d8ca ac60e78435098c9d ' .. 
  'ae57fcdb49f74e98 ae63e525853d7044 aeaef7a1851e6c9d af0f9b3a163787a5 af8529d541954e88 b056f8fc74aba02d ' .. 
  'b2a6fa1e4284c7e6 b4ed319b39f5457b b5dbc0c240c921ad b8580cac32214fc0 b92435fbf60f0748 b940c889d77f8219 ' .. 
  'bc242702fb46b7e7 be39e313a1e46bb9 be743b2faa3a6e26 c0df2a134bd15ad5 c2b9eb21b06f8378 c626d2bb495a202d ' .. 
  'c6449ffd9ea3779c c9bcccb0a54a82a4 cbb1ba3366009c3a cc188f0c80505c6c cc7022fdd172089b ccae5264acd591b7 ' .. 
  'cd28a27a79be53d5 d1e990baf22d5a52 d37e8d120d2836e3 d465d9c7f77a07cb d522fd4748d443a5 d5792f6856b06ba4 ' .. 
  'd63fcbff0851b7af d8cbc4a807a6d035 d9511e9f6bd62e3f da40bb347c7447f2 dac7d53fe0749f5f db90077e76faa025 ' .. 
  'db964631be1cf501 dcf8e74212fbee3b dfbacbd977a948dc e0353177f1329573 e2e62fdd39407fe3 e44ec9f9b3fe1d2a ' .. 
  'e683d2ca5618d74a e8f19a0aa958e46d eacee39fa017b495 ef04cb84d097a497 ef570293245a17c2 f0b26fa9258128d3 ' .. 
  'f1610ac48cdc5240 f196069e7e14c497 f22d027b37bef107 f540ca9d9d4a422e f66d0bad8693779a f79cd8bb654397df ' .. 
  'f8131632aa867107 f8b5a81a86d5d4eb f96257fcae258caa fb9937035d652c43 fc8dec78be8ab47d fd5247653c897803 ' .. 
  'feb484ee972469f7 ff5cc825b9571052 '):gmatch('%x+') do ENEMY_KINDS[kd] = true end
-- more kinds from the game's generated_entities: enemies the list above lacks, plus fabricators, bunkers, emplacements, the jammer and
-- scrambler, spore spewers and lungs, shrieker nests, eggs, bug holes and the illegal broadcast's parts
for kd in (
  '06d3c4720e642fc1 0883366204e1ccc5 095686275a113614 1448d494665d01a0 1baeef36a88ae579 298c464f7f4261e3 ' ..
  '2c1a7790c435fd67 3478839c3c9b6646 480445a33039ce5e 485c04e03ccc969e 57db57121f3e7ed2 5b968cd78f8bc7a0 ' ..
  '6293d7ab6e681855 6e499c5c95b019fc 7d96c57604e61c3a 87dad37dd7c888da 9f44121c554dae89 a2a86454f67fbc47 ' ..
  'a57ae2a703c02899 a83587cbff25c79e a98f8b559c7993d8 aa28caf964d05500 b29af893b9c188a9 b8fe3a0fe1a58465 ' ..
  'c28b3482e73d1ea9 cdb573e646581547 cecd6979cf7bb0f2 d7abb6b791e48e16 d7e2c78b1ef4a8e1 dd2dac48bc52d2be ' ..
  'e405918464bcdb07'):gmatch('%x+') do ENEMY_KINDS[kd] = true end
local enemy_watch = chef.watch and chef.watch(ENEMY_KINDS, 1) or nil

-- kinds that are characters. A dead character has no animation state machine; a structure
-- never has one. So a unit counts as dead once it lost the state machine it had, or, for one first seen already
-- dead, when it's a character kind without one.
local CHAR_KINDS = {}
for kd in (
  'a381a11c07d3eb94 cc7022fdd172089b ccae5264acd591b7 3aff5fd7d5450b99 0ab7b92b131c228c 64ba5f030b114ec1 ' ..
  '9f57782f00e6ed20 e2e62fdd39407fe3 0adc9f9173ad8e1d 44458a2c52b002fb 746a7f3beda32699 9f44121c554dae89 ' ..
  '33b3e0ce8d179eec c28b3482e73d1ea9 d7e2c78b1ef4a8e1 b940c889d77f8219 db964631be1cf501 72a83e49ced6db3d ' ..
  '5b968cd78f8bc7a0 ef04cb84d097a497 f79cd8bb654397df a35207c6f2150806 1baeef36a88ae579 a1f37bf2a40fbde4 ' ..
  'be39e313a1e46bb9'):gmatch('%x+') do CHAR_KINDS[kd] = true end
-- A body found dead is believed for 1 s (same unit and kind) without asking again: a crowd of bodies near the line
-- cost an engine call each, every frame. Not for good: a handle handed out again to a live one must count soon.
local function corpse(it)
  local dead = S.adead
  if not dead then dead = {}; S.adead = dead end
  local d = dead[it.unit]
  if d and d.kind == it.kind and S.t < d.till then return d.dead end
  local has = call('Unit.has_animation_state_machine', it.unit)
  if has == nil then return false end  -- the call failed: no verdict
  local seen = S.asm
  if not seen then seen = {}; S.asm = seen end
  if has == true then seen[it.unit] = it.kind or true end
  local is = has == false and (seen[it.unit] == (it.kind or true) or CHAR_KINDS[it.kind] == true)
  -- the answer kept a while (a crowd in the cone costs one call each, not one each frame): dead 1 s, alive 0.5 s
  if not d then d = {}; dead[it.unit] = d end
  d.kind, d.dead, d.till = it.kind, is, S.t + (is and 1 or 0.5)
  return is
end

-- the game shoots along its own camera line (over your shoulder). While aiming, the view turns a little toward the
-- point that line reaches at the target distance, so the crosshair and the shots meet there: the distance of the
-- enemy under the crosshair (box test along the game's line), else aim_dist. Only the mouse moves that line, so no
-- jitter (0.3.66/67 used the gun: it sways 2-11 deg off the aim).
-- A box the line goes through wins; else the enemy nearest the line within aim_cone deg (small or far targets the
-- line just misses). Dead bodies are skipped (aim_corpse), and nothing counts as nearer than aim_near.
local RB_FROM, RB_DIR = {}, {}
local aim_range
do
-- the enemies that pass the cone, box-tested nearest first (POOL keeps the small tables from frame to frame)
local POOL, LIST = {}, {}
-- our last read of each listed enemy, { unit, mod time, x, y, z }: weak keys, so it goes with the list's entry.
-- shortcut: the mod clock stops while an error pause holds the mod, so for under 1 s after one an enemy that moved
-- meanwhile can be missed (the 'no enemy' distance meanwhile); a wall clock if that ever shows
local SEEN = setmetatable({}, { __mode = 'k' })
local function by_lb(a, b) return a.lb < b.lb end
-- how far an enemy's box reaches from its root (box middle's offset + half diagonal, 1 m to spare), read once per unit
-- (S.reach, new each world; the kind guards a handle handed out again). Its box test can't hit nearer than its distance
-- along the line minus that. false: no box to read, so always tested
local function reach(it, x, y, z)
  local all = S.reach
  if not all then all = {}; S.reach = all end
  local r = all[it.unit]
  if r and r.kind == it.kind then return r.d end
  local d = false
  local pose, ext = call('Unit.box', it.unit)
  if pose then
    local ex, ey, ez = xyz(ext)
    local cx, cy, cz = xyz(call('Matrix4x4.translation', pose))
    if ex and cx then d = sqrt((cx - x) ^ 2 + (cy - y) ^ 2 + (cz - z) ^ 2) + sqrt(ex * ex + ey * ey + ez * ez) + 1 end
  end
  once(d and 'reach1' or 'reach0', 'enemy sizes: %s', d and 'read from their boxes (nearest first, farther box tests skipped)'
    or 'one unreadable, its box always tested')
  all[it.unit] = { kind = it.kind, d = d }
  return d
end
function aim_range(G, dx, dy, dz)
  if not (enemy_watch and chef.ray_box) then return nil, 'no enemy list' end
  if enemy_watch.generation == S.ew_gen then return nil, 'enemy list coming' end  -- the list from before a pause: stale units
  local from, dir = RB_FROM, RB_DIR
  from.x, from.y, from.z, dir.x, dir.y, dir.z = G[1], G[2], G[3], dx, dy, dz
  local cone = math.rad(V.aim_cone)
  local best, bu, ca, cd, cu
  local n = 0
  -- the list's own spots (up to 1 s old, so 30 m to spare) rule out the far before any engine call: a bug mission lists
  -- hundreds. Exact: one over 200 m away and under 200 m along the line is 113+ m off it, past the 21 m side limit
  for _, it in ipairs(enemy_watch.items) do
    local ex, ey = (it.x or G[1]) - G[1], (it.y or G[2]) - G[2]
    local x, y, z
    if ex * ex + ey * ey < 230 * 230 then
      -- and the spot within 30 m of the box-test cone below (moving 30 m changes along and off the line by 30 m at most).
      -- Our own read of it under 1 s ago is used instead, with 30 m a second to spare: one read 0.1 s ago needs 3 m, so
      -- an enemy clearly off the line isn't read again until it could have reached it (timer 2026-11-14: these reads
      -- were most of the enemy check, 20-40 a frame in a fight)
      local near, sx, sy, sz, m = true, it.x, it.y, it.z, 30
      local s = SEEN[it]
      if s and s.u == it.unit and S.t - s.t < 1 then sx, sy, sz, m = s[1], s[2], s[3], 30 * (S.t - s.t) end
      if sz then
        local qx, qy, qz = sx - G[1], sy - G[2], sz - G[3]
        local qa = qx * dx + qy * dy + qz * dz
        local qs = sqrt(max(0, qx * qx + qy * qy + qz * qz - qa * qa))
        near = qa > 2 - m and qa < 200 + m and qs - m < max(3, min(200, qa + m) * 0.105)
      end
      if near then
        x, y, z = upos(it.unit)
        if x then
          if not s then s = {}; SEEN[it] = s end
          s.u, s.t, s[1], s[2], s[3] = it.unit, S.t, x, y, z
        end
      end
    end
    if x then
      local vx, vy, vz = x - G[1], y - G[2], z - G[3]
      local along = vx * dx + vy * dy + vz * dz
      if along > 2 and along < 200 then
        local side = sqrt(max(0, vx * vx + vy * vy + vz * vz - along * along))
        -- only enemies within 6 deg (or 3 m) of the line get the box test
        if side < max(3, along * 0.105) and not (V.aim_corpse and corpse(it)) then
          local a = math.atan2(side, along)
          if a < cone and (not ca or a < ca) then ca, cd, cu = a, along, it.unit end
          local r = reach(it, x, y, z)
          n = n + 1
          local c = POOL[n] or {}
          POOL[n], LIST[n] = c, c
          c.u, c.lb = it.unit, r and along - r or -math.huge
        end
      end
    end
  end
  for i = #LIST, n + 1, -1 do LIST[i] = nil end
  table.sort(LIST, by_lb)
  for i = 1, n do
    local c = LIST[i]
    if best and c.lb >= best then break end  -- this one and every one after can't be nearer than the hit found
    local hit = chef.ray_box(from, dir, c.u)
    if type(hit) == 'number' and hit > 2 and (not best or hit < best) then best, bu = hit, c.u end
  end
  if best then return max(best, V.aim_near), 'enemy', bu end
  if cd then return max(cd, V.aim_near), 'near miss', cu end
  return nil, 'no enemy'
end
end

-- Measure from the gun: the game points your gun at what its camera line hits, so the two lines cross there, and how
-- far along the camera line they pass closest is how far away the shot lands. Read
-- only from a gun in both hands, steady, along the aim, not while the view turns fast, a reload tilts it or the
-- stratagem key is down; with nothing read the last distance holds. Followed in 1/distance at one even pace: the turn
-- the crosshair fix makes goes with 1/distance, so every change looks the same speed (paced in meters, 100 to
-- 10 m would crawl at the start and rush at the end).
local GR = { st = {} }
-- the enemy list only while something ranges on it (the loader asks the engine for every enemy kind each second)
function GR.watch()
  if not enemy_watch then return end
  local need = (V.aim_range or V.hip_range or S.mech) and true or false
  if need == enemy_watch.active then return end
  if need then enemy_watch.resume(); S.ew_gen = enemy_watch.generation else enemy_watch.pause() end
  log('enemy list %s', need and 'on' or 'paused (nothing ranges on it)')
end
function GR.range_of(d, mn) return d < 15.8 and mn or (d < 37 and 25 or (d < 70 and 50 or 100)) end
-- one reading along the game's line from (S.gcx, S.gcy, S.gcz): meters, 100 (the lines parallel: far), or nil
function GR.read(fx, fy, fz, dt)
  local st = GR.st
  local fire = chef.mouse_down('left')
  if chef.key_pressed('r') then st.rld = S.t end
  if st.rld and S.t - st.rld > 0.3 and ((fire and not st.fw) or (S.aim and not st.aw)) then st.rld = nil end
  st.fw, st.aw = fire, S.aim
  local reloading = st.rld and S.t - st.rld < V.reload_hold
  -- firing: recoil kicks the gun off the camera line, so no reading while the trigger is down and 0.3 s after
  if fire then st.shot, st.fire_t = st.shot or S.t, S.t
  elseif st.shot and S.t - st.fire_t > 0.3 then
    if (st.nlog or 0) < 10 then st.nlog = (st.nlog or 0) + 1; log('firing: gun distance held %.1f s at %.0f m', S.t - st.shot, st.cur or V.aim_dist) end
    st.shot = nil
  end
  local pf = st.f
  if pf and dt > 0 and math.deg(math.acos(max(-1, min(1, pf[1] * fx + pf[2] * fy + pf[3] * fz)))) / dt > 40 then st.turn = S.t end
  st.f = { fx, fy, fz }
  if S.shield then return V.aim_dist, true end  -- the shield's one-handed gun crosses the view a few meters out: fixed
  local g = S.gheld
  if not (g and S.t - g.t < 0.3 and g.o and alive(g.u)) then st.calm = nil; return end
  local q = call('Unit.world_rotation', g.u, 1)
  if not q then return end
  -- the gun's long axis: whichever of its three points along the aim (a held gun points within ~30 deg of it)
  local lx, ly, lz, best = nil, nil, nil, 0.85
  for _, ax in ipairs({ 'Quaternion.forward', 'Quaternion.up', 'Quaternion.right' }) do
    local x, y, z = xyz(call(ax, q))
    local c = x and finite(x) and (x * fx + y * fy + z * fz) or 0
    if abs(c) > best then best, lx, ly, lz = abs(c), c < 0 and -x or x, c < 0 and -y or y, c < 0 and -z or z end
  end
  if not lx then st.calm = nil; return end
  local p, o = g.p, g.o
  -- both hands on it: the other hand within 0.2 m of the gun's line
  local ox, oy, oz = o[1] - p[1], o[2] - p[2], o[3] - p[3]
  local al = ox * lx + oy * ly + oz * lz
  local px, py, pz = ox - al * lx, oy - al * ly, oz - al * lz
  if px * px + py * py + pz * pz > 0.04 or abs(al) > 0.8 then st.calm = nil; return end
  st.calm = st.calm or S.t
  if S.t - st.calm < 0.1 or reloading or st.shot or chef.key_down('left ctrl') or S.t - (st.turn or -9) < 0.25 then return end
  -- the gun's direction in the camera's frame, smoothed twice: quick (0.25 s) for the distance, slow (0.8 s) to tell
  -- a lasting angle (a wall) from the idle sway, which swings to and fro around the true direction
  local cl = sqrt(fx * fx + fy * fy)
  local rx, ry = cl > 1e-3 and fy / cl or 1, cl > 1e-3 and -fx / cl or 0
  local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
  local o_r, o_u, o_f = lx * rx + ly * ry, lx * ux + ly * uy + lz * uz, lx * fx + ly * fy + lz * fz
  local sm = st.sm
  if not sm or S.t - sm[5] > 0.5 then sm = { o_r, o_u, o_r, o_u, S.t } end
  local a1, a2 = 1 - exp(-dt / 0.25), 1 - exp(-dt / 0.8)
  sm[1], sm[2], sm[3], sm[4], sm[5] = sm[1] + (o_r - sm[1]) * a1, sm[2] + (o_u - sm[2]) * a1, sm[3] + (o_r - sm[3]) * a2, sm[4] + (o_u - sm[4]) * a2, S.t
  st.sm = sm
  local function line(r, u)
    local x, y, z = fx * o_f + rx * r + ux * u, fy * o_f + ry * r + uy * u, fz * o_f + uz * u
    local l = sqrt(x * x + y * y + z * z)
    return x / l, y / l, z / l
  end
  local w0x, w0y, w0z = S.gcx - p[1], S.gcy - p[2], S.gcz - p[3]
  local dd = fx * w0x + fy * w0y + fz * w0z
  -- where the camera line and a gun line pass closest: meters along the camera line, or false (they don't meet)
  local function cross(gx, gy, gz)
    local b = fx * gx + fy * gy + fz * gz
    local den = 1 - b * b
    local e = gx * w0x + gy * w0y + gz * w0z
    local sc, sg = (b * e - dd) / den, (e - b * dd) / den
    local cx, cy, cz = w0x + fx * sc - gx * sg, w0y + fy * sc - gy * sg, w0z + fz * sc - gz * sg
    if sc > 1 and sg > -0.5 and sqrt(cx * cx + cy * cy + cz * cz) < 0.12 + 0.01 * sc then return max(1.5, min(100, sc)) end
    return false
  end
  local qx, qy, qz = line(sm[1], sm[2])
  local sx, sy, sz = line(sm[3], sm[4])
  local b, bs = fx * qx + fy * qy + fz * qz, fx * sx + fy * sy + fz * sz
  local d
  if 1 - b * b > 0.0019 and 1 - bs * bs > 0.0019 then  -- a clear angle (2.5 deg and more): the lines must truly meet
    d = cross(qx, qy, qz) or nil
  elseif 1 - b * b < 0.00069 or 1 - bs * bs < 0.00069 then  -- nearly parallel (1.5 deg): far, unless the slow line meets
    d = 1 - bs * bs > 0.00005 and cross(sx, sy, sz) or 100
  end  -- (between the two: no reading, so mid range never swings between 15 and 100 m)
  if d and d < 12 then
    local n = st.near
    if not n or S.t - n.last > 0.3 then n = { since = S.t, d = d } end
    n.last, n.d = S.t, n.d + (d - n.d) * 0.3
    st.near = n
  elseif d then st.near = nil end
  return d
end
-- the distance to line up at, from a reading (nil: hold): Nearest and the ranges applied, then glided
function GR.dist(d, dt, fixed)
  local st, mn = GR.st, V.gun_nearest
  if d then d = max(mn, min(100, d)) end
  if d and V.gun_steps and not fixed then
    local s = st.step or GR.range_of(d, mn)
    local function down_to(x) return x < 13.5 and mn or (x < 32 and 25 or 50) end
    -- up: from Nearest at 18 m, 25 -> 50 at 38, 50 -> 100 at 75; down: below 13.5, 32 and 62 m
    if s == mn and d >= 18 then s = d >= 75 and 100 or (d >= 38 and 50 or 25)
    elseif s == 25 and d < 13.5 then s = mn
    elseif s == 25 and d >= 38 then s = d >= 75 and 100 or 50
    elseif s == 50 and d < 32 then s = down_to(d)
    elseif s == 50 and d >= 75 then s = 100
    elseif s == 100 and d < 62 then s = down_to(d) end
    st.step, d = s, s
  end
  local cur = st.cur or d or V.aim_dist
  local tgt = st.tgt or cur
  if d and V.gun_glide > 0 then tgt = d
  elseif d then  -- QUICK: a new distance must hold (within 15 %) 0.35 s, and be a change the view would show
    local c = st.cand
    if c and abs(math.log(d) - math.log(c[1])) < 0.15 then
      if S.t - c[2] >= 0.35 and (V.gun_steps and d ~= tgt or abs(1 / d - 1 / tgt) > 0.0107) then tgt = d end
    else st.cand = { d, S.t } end
  end
  st.tgt = tgt
  if V.gun_glide > 0 then
    -- a new move only for a target 15 % or more from the one under way (a wandering reading keeps the same pace)
    if not st.gt or abs(math.log(tgt) - math.log(st.gt)) > 0.15 then st.gfrom = cur end
    st.gt = tgt
    local k, kt = 1 / cur, 1 / tgt
    local step = max(abs(kt - 1 / st.gfrom) / V.gun_glide, 0.002) * dt
    if abs(kt - k) <= step then k = kt elseif kt > k then k = k + step else k = k - step end
    cur = 1 / k
  else
    cur = 1 / (1 / cur + (1 / tgt - 1 / cur) * (1 - exp(-(tgt < cur and 12 or 4) * dt)))
  end
  st.cur = cur
  return cur
end
-- an enemy's range just lost: go on from the nearest range to where the view is, not back to the old one
function GR.lost(cur)
  local st = GR.st
  if not (cur and V.gun_steps) then return end
  local r = GR.range_of(cur, V.gun_nearest)
  st.step, st.tgt, st.cur, st.gt, st.cand = r, r, cur, nil, nil
  log('measured from the gun: enemy lost at %.1f m, on to %d m', cur, r)
end

-- the distance the view converges at, held steady: re-picking the nearest enemy every frame flipped between enemies
-- in a crowd (0.3.108 'jumpy'). A new enemy or distance counts only once it stayed 0.15 s (0.25 s to switch enemy),
-- changes under 1.5 m (or 5%) are ignored, and a lost target is kept 1.25 s before going back to aim_dist.
local function held_range(D, u)
  local h = S.hr or {}
  S.hr = h
  if D then
    h.lost = nil
    -- the same enemy is followed at once (a charging one outran the 0.15 s wait and the 1.5 m step: shots up close
    -- landed right, 2.1.43 log); only a new enemy waits, so a crowd doesn't flip the view between them
    if h.cu ~= u or not h.cd then h.cu, h.since = u, S.t end
    h.cd = D
    if h.u == u or S.t - h.since >= (h.u and 0.25 or 0.15) then
      if not h.d or h.u ~= u or abs(h.cd - h.d) >= max(0.3, h.d * 0.05) then h.d = h.cd end
      h.u = u
    end
  else
    h.cu, h.cd = nil, nil
    h.lost = h.lost or S.t
    if S.t - h.lost >= 1.25 then h.d, h.u = nil, nil end
  end
  return h.d
end

-- the fixed distance: its own on the FRV gun and on emplacements when set, else aim_dist
local function fixed_dist()
  if S.runaim then return V.run_dist end
  if GR.d then return GR.d end
  return S.frv == 'gunner' and V.gun_dist > 0 and V.gun_dist or S.empl and V.empl_dist > 0 and V.empl_dist or V.aim_dist
end
-- where the game's line (looking down, dz < 0) meets the flat ground at your feet, if that comes before D m
local function ground_dist(dz, D)
  if V.aim_ground and S.gnd and dz < -0.01 then
    local tg = (S.gnd - S.gcz) / dz
    if tg > 0.5 and tg < D then return tg end
  end
end
local function aim_fix(k, cam, dt)
  local base, mine = game_rot(k, cam)
  if not base then return end
  local dx, dy, dz = xyz(call('Quaternion.forward', base))
  local on = V.aim_fix and (S.aim or V.aim_hip) and dx and S.gcx and k.wx
  local D, src
  if on and not S.draw then
    local gm = V.gun_measure and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
    if gm then local gd, gfix = GR.read(dx, dy, dz, dt); GR.d = GR.dist(gd, dt, gfix)
    elseif GR.d then GR.d, GR.st = nil, {} end
    S.gund = GR.d
    -- fixed distance unless aim_range (aiming) or hip_range (hip; enemy ranging there turned the view far too hard, 0.3.109)
    local raw, u, _
    if (S.aim and V.aim_range) or (not S.aim and V.hip_range) then raw, _, u = aim_range({ S.gcx, S.gcy, S.gcz }, dx, dy, dz) end
    -- near walls first: the gun steadily measures something near, well short of the enemy (behind a rock)
    local n = GR.st.near
    if raw and gm and V.wall_first and n and S.t - n.last < 0.6 and S.t - n.since >= 0.25 and n.d < 0.6 * raw then
      if not GR.st.wsaid then log('measured from the gun: %.1f m in front of the enemy (%.0f m), the near distance wins', n.d, raw) end
      GR.st.wsaid, raw, u = true, nil, nil
    elseif raw then GR.st.wsaid = nil end
    S.araw = raw
    local had = S.hr and S.hr.d
    D = held_range(raw, u)
    if gm and had and not D then GR.lost(S.ad) end
    src = D and 'enemy' or 'no enemy'
    -- from the hip hip_strength scales only the extra turn toward the enemy (in 1/distance), the base aim_dist turn
    -- stays whole so shots at range still land
    local fd = fixed_dist()
    if D and not S.aim then D = 1 / (1 / fd + V.hip_strength / 10 * (1 / D - 1 / fd)) end
    D = D or fd
    -- eased in 1/distance (up close the turn goes with 1/distance, so equal steps feel equal): a held enemy over at
    -- most 0.25 s, back to aim_dist over aim_ease; from the hip both over hip_ease
    -- in a seat a held enemy is followed over seat_ease (slower: the seat turns the whole view)
    local seat = (S.frv == 'gunner' or S.empl or S.mech) and S.hr.d
    local te = max(seat and V.seat_ease or not S.aim and V.hip_ease or S.hr.d and min(V.aim_ease, 0.25) or V.aim_ease, 0.01)
    S.ad = S.ad and 1 / (1 / S.ad + (1 / D - 1 / S.ad) * (1 - exp(-dt / te))) or D
  end
  local rate = 1 / max(V.aim_ease, 0.05)
  S.aw = on and min(1, (S.aw or 0) + dt * rate) or max(0, (S.aw or 0) - dt * rate)
  -- how far into the aim (0 hip, 1 aiming), eased the same way: strength, limit and ground point switched in one
  -- frame at the click and the view snapped (strength 3 = 70% of the turn at once)
  S.ab = S.aim and min(1, (S.ab or 0) + dt * rate) or max(0, (S.ab or 0) - dt * rate)
  local ab = S.ab
  if S.aw <= 0 or not (S.ad and S.gcx and dx) then
    if S.aw <= 0 then S.ad, S.hr, GR.d, GR.st, S.gund, S.ce = nil, nil, nil, {}, nil, nil end
    if mine then call('Camera.set_local_rotation', cam, k.u, base) end
    k.last = nil
    return
  end
  -- from where the camera really is this frame (head + the forward/side offsets), not the bare head: up close the
  -- offsets left the turn short (0.3.107: hip shots right of the crosshair)
  -- looking down on foot, the game's line meets the ground (flat, at your feet) before S.ad: the up-down turn lines
  -- up where the shots land. Left-right stays with the far point from the hip (the game camera sits to your right,
  -- so a near point turned the view right whenever you looked down); aiming, it follows the ground point too, so a
  -- shot at your feet lands on the crosshair. An enemy's range held wins: it's measured, the flat ground is a guess
  -- (on a ledge over an enemy, the feet's level is mid-air)
  local dv, dh = S.ad, S.ad
  local tg = not (S.hr and S.hr.d) and ground_dist(dz, S.ad)
  -- S.gwt: the ground point's pull, faded in and out (switched in one frame it turned the view 7 deg as a dive ended)
  if tg then local gw = S.gwt or 0; dv = 1 / (1 / S.ad + gw * (1 / tg - 1 / S.ad)); dh = 1 / (1 / S.ad + ab * gw * (1 / tg - 1 / S.ad)) end
  local vx, vy, vz = S.gcx + dv * dx - k.wx, S.gcy + dv * dy - k.wy, S.gcz + dv * dz - k.wz
  local vl = sqrt(vx * vx + vy * vy)
  if vl * vl + vz * vz < 0.25 then return end
  local qx, qy = S.gcx + dh * dx - k.wx, S.gcy + dh * dy - k.wy
  local ql = sqrt(qx * qx + qy * qy)
  if ql < 1e-3 then return end
  local el = math.atan2(vz, vl)
  local hx, hy, hz = qx / ql * math.cos(el), qy / ql * math.cos(el), math.sin(el)
  -- never more than aim_max deg off the game's look (at least 20 from the hip with hip_range: the game camera sits ~0.9 m to the side, so an enemy
  -- at 3 m needs ~17 deg)
  local c = hx * dx + hy * dy + hz * dz
  local hlim = V.hip_range and max(V.aim_max, 20) or V.aim_max
  local lim = math.cos(math.rad(hlim + ab * (V.aim_max - hlim)))
  if c < lim then
    local px, py, pz = hx - c * dx, hy - c * dy, hz - c * dz
    local pl = sqrt(px * px + py * py + pz * pz)
    local sn = sqrt(1 - lim * lim)
    hx, hy, hz = dx * lim + px / pl * sn, dy * lim + py / pl * sn, dz * lim + pz / pl * sn
  end
  -- the strength slider only while aiming: from the hip the game camera sits far back, so anything less than the
  -- full turn leaves the shots far off the crosshair (0.3.103 at strength 5)
  local w = S.aw * (1 + ab * (V.aim_strength / 10 - 1))
  local fx, fy, fz = dx + w * (hx - dx), dy + w * (hy - dy), dz + w * (hz - dz)
  -- the turn itself (across and up from the game's look) changes at most 30 deg/s: the ground point, an enemy or
  -- the camera hold switching made it jump up to 7 deg in one frame on landings and get-ups (log 2026-11-11).
  -- The mouse still moves the view at once (it moves the game's look this turn is measured from)
  local hd = sqrt(dx * dx + dy * dy)
  if hd > 1e-3 then
    local rx, ry = dy / hd, -dx / hd
    local ux, uy, uz = ry * dz, -rx * dz, rx * dy - ry * dx
    -- over the along-look part, so rebuilding d + er*r + eu*u points exactly where f did (a 17 deg turn came out 16.3)
    local fd = max(1e-3, fx * dx + fy * dy + fz * dz)
    local er, eu = (fx * rx + fy * ry) / fd, (fx * ux + fy * uy + fz * uz) / fd
    local ce = S.ce or { er, eu }
    local mr, mu = er - ce[1], eu - ce[2]
    -- held still from the moment your feet drop until the landing hold lets go: the game camera's bounce turned the
    -- view looking down, and frozen only from the landing it kept the falling value and moved 1-2 s later (2026-11-11)
    -- then eased out over ~0.5 s: at 30 deg/s the 0.2 deg it was off snapped up in 0.05 s when the hold let go (1800.2 s)
    local frz = (S.vh and S.vh.hold) or S.t - (S.air_t or -9) < 0.4
    if frz then S.cfz = S.t end
    local ml, st = sqrt(mr * mr + mu * mu), frz and 0 or math.rad(30) * dt
    if not frz and S.t - (S.cfz or -9) < 1 then st = min(st, ml * (1 - exp(-dt / 0.3))) end
    if ml > st then ce[1], ce[2] = ce[1] + mr * st / ml, ce[2] + mu * st / ml else ce[1], ce[2] = er, eu end
    S.ce = ce
    fx, fy, fz = dx + ce[1] * rx + ce[2] * ux, dy + ce[1] * ry + ce[2] * uy, dz + ce[2] * uz
  end
  local nq = call('Quaternion.look', Vec(fx, fy, fz), Vec(0, 0, 1))
  local _, err = call('Camera.set_local_rotation', cam, k.u, nq)
  if err then once('aw' .. tostring(err), 'aim fix: rotation write refused: %s', tostring(err)) else wrote(k, nq) end
end

-- backward dive: the view tilts no further down than dive_look, eased in and out, so it never looks through the open
-- collar into the hollow body (log 2026-11-07: head 0.11 m from the chest). Turns the view only, never moves it.
-- Every FRV seat too (frv_look per model: looking down showed the headless collar, the look_down push didn't clear it)
local function pitch_limit(k, cam, dt)
  local L = S.frv and V[(S.frv_pre or '') .. 'frv_look']
    or S.diving == 'dive_hide_back' and not S.oblie and not S.getup and V.dive_look or 0
  local on = L > 0 and not S.aim
  if on then S.pll = L else L = S.pll or L end  -- easing out keeps the last limit
  S.pw = on and min(1, (S.pw or 0) + dt * 8) or max(0, (S.pw or 0) - dt * 6)
  if S.pw <= 0 and not k.qw then return end
  local base, mine = game_rot(k, cam)
  if not base then return end
  if S.pw <= 0 then
    if mine then call('Camera.set_local_rotation', cam, k.u, base) end
    k.qw, k.last = nil, nil; log('look limit off (game look went to %.0f deg down)', S.pdm or 0); S.pdm = nil; return
  end
  local fx, fy, fz = xyz(call('Quaternion.forward', base))
  if not fx then return end
  -- heading: looking down, the camera's up leans the way you face, so forward + up keeps it at and past straight
  -- down (forward alone shrinks to nothing there: the limit skipped those frames and showed the collar, 2026-11-11)
  local hx, hy = fx, fy
  if fz < 0 then
    local ux, uy = xyz(call('Quaternion.up', base))
    if ux then hx, hy = fx + ux, fy + uy end
  end
  local hl = sqrt(hx * hx + hy * hy)
  if hl < 1e-3 then return end
  hx, hy = hx / hl, hy / hl
  local down = math.deg(math.atan2(-fz, fx * hx + fy * hy))  -- over 90 = past straight down
  S.pdm = max(S.pdm or 0, down)
  local soft = 10
  local t = down
  if down > L - soft then t = L - soft + soft * (1 - exp(-(down - (L - soft)) / soft)) end
  t = down + S.pw * (t - down)
  local cr, sr = math.cos(math.rad(t)), math.sin(math.rad(t))
  local nq = call('Quaternion.look', Vec(hx * cr, hy * cr, -sr), Vec(0, 0, 1))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('qw' .. tostring(why), 'look limit: rotation write refused: %s', tostring(why)); return end
  k.qw = true; wrote(k, nq)
  if not k.qlog then log('look limit on (%s, %d deg)', S.frv or 'backward dive', L) end
  k.qlog = true
end

-- immersive mode: the view may turn only neck_yaw off the body's facing; past that the body is turned to follow.
-- While aiming the game faces the body to the gun itself (0.3.125 log: our writes there were undone, ~13 deg off), so
-- we leave it alone then. teleport_local_rotation did nothing at all (0.3.125), set_local_rotation is kept.
local function wrap(a) return (a + 180) % 360 - 180 end
-- free look: put the body back to the facing held at the key press. Also run at draw time (M.render): past ~60 deg the
-- game's turn-in-place animation (anim 17 crouched, 60 standing) turned the body after our update write (0.3.131 log).
-- n.rk/n.rn: draw-time frames the body was still on the held facing / all of them.
local function hold_body(w, at_draw)
  local n, u = S.nk, S.head and S.head.u
  if not (n and n.fl and n.fly and u) then return end
  if at_draw then
    local bx, by = chef.unit_rotation(u)
    if bx then
      n.rn = (n.rn or 0) + 1
      if abs(wrap(math.deg(math.atan2(by, bx)) - n.fly)) < 3 then n.rk = (n.rk or 0) + 1 end
    end
  end
  local t = math.rad(n.fly)
  local _, why = call('Unit.set_local_rotation', u, 1, call('Quaternion.look', Vec(math.cos(t), math.sin(t), 0), Vec(0, 0, 1)))
  if not why then call('World.update_unit', w, u) end
end
local function neck(w)
  local n = S.nk or {}
  S.nk = n
  local u = S.head and S.head.u
  -- S.stance is nil until the first stance change (0.3.130: nothing worked until the first crouch): nil = standing
  local ok = V.imm_on and S.shown and u and (S.stance or 'stand') ~= 'prone'
    and not (S.aim or S.diving or S.getup or S.frv or S.mech or S.empl or S.tank or S.gator or S.pel or S.pod or S.down or S.dead)
  if not ok then n.want, n.run, n.rt, n.px = nil, false, 0, nil; return end
  local c = chef.camera()
  local bx, by = chef.unit_rotation(u)
  if not (c and c.fx and bx) or abs(c.fx) + abs(c.fy) < 1e-3 then return end
  local vy, by_ = math.deg(math.atan2(c.fy, c.fx)), math.deg(math.atan2(by, bx))
  -- running: feet speed over the floor, eased over ~0.15 s
  local rx, ry, rz = upos(u, S.head.root)
  local dt = S.dt or 0.016
  if rx and n.px and dt > 0 then
    local vx, vy2 = (rx - n.px) / dt, (ry - n.py) / dt
    local a = 1 - exp(-dt / 0.15)
    n.vx, n.vy = (n.vx or 0) + (vx - (n.vx or 0)) * a, (n.vy or 0) + (vy2 - (n.vy or 0)) * a
  end
  n.px, n.py = rx, ry
  local spd = sqrt((n.vx or 0) ^ 2 + (n.vy or 0) ^ 2)
  -- running (move keys + feet over 3.8 m/s for 0.3 s, so a dive's slide doesn't count; 0.3.129 log: walking 2-3.3 m/s,
  -- sprinting 4.4-5.3): the game faces the body along the
  -- run and undoes our turns (0.3.126), and the diver can't be held still (0.3.128: position writes move only the mesh,
  -- the real position runs on and the view flipped to third person). So the VIEW keeps within look_back of the body.
  -- shortcut: move keys are read as W/A/S/D; rebinds would need a KEYS row
  local keys = chef.key_down('w') or chef.key_down('a') or chef.key_down('s') or chef.key_down('d')
  -- free look key held: the body stays put and no running limit; let go and the neck limit turns the body to catch up
  local fl = binds.freelook and binds.freelook.down() or false
  if fl ~= (n.fl or false) then log('free look %s', fl and 'on' or 'off') end
  n.fl = fl
  -- the game turns a still body itself once the view is ~60 deg off (0.3.130 log), so free look holds the facing it
  -- had at the press (set_local_rotation sticks on a still body)
  if fl then
    n.fly = n.fly or by_
    hold_body(w)
    n.flk = abs(wrap(by_ - n.fly)) < 3 and (n.flk or 0) + 1 or (n.flk or 0)
  else n.fly = nil end
  n.rt = (V.look_back > 0 and spd > 3.8 and keys and not fl) and (n.rt or 0) + dt or 0
  if (n.rt >= 0.3) ~= (n.run or false) then log('running look limit %s (%.1f m/s)', n.rt >= 0.3 and 'on' or 'off', spd) end
  n.run, n.by = n.rt >= 0.3, by_
  -- did the game keep last frame's write?
  if n.want then
    local off = abs(wrap(by_ - n.want))
    if off < 3 then n.kept = (n.kept or 0) + 1 end
    n.lastoff = off
  end
  n.want = nil
  local d = wrap(vy - by_)
  local lim = V.neck_yaw
  if abs(d) > lim + 0.5 and not n.run and not fl then
    local t = math.rad(vy - (d > 0 and lim or -lim))
    local q = call('Quaternion.look', Vec(math.cos(t), math.sin(t), 0), Vec(0, 0, 1))
    local _, why = call('Unit.set_local_rotation', u, 1, q)
    if why then once('nk' .. tostring(why), 'neck: body turn refused: %s', tostring(why))
    else call('World.update_unit', w, u); n.want = math.deg(t); n.writes = (n.writes or 0) + 1 end
  end
end

-- running look limit: the view's yaw kept within look_back of the body's facing (S.nk.by), eased in and out; pitch
-- untouched. Turns the view only, like pitch_limit.
local function view_limit(k, cam, dt)
  local n = S.nk
  local on = n and n.run and n.by and V.imm_on
  S.yw = on and min(1, (S.yw or 0) + dt * 6) or max(0, (S.yw or 0) - dt * 4)
  if S.yw <= 0 and not k.yq then return end
  local base, mine = game_rot(k, cam)
  if not base then return end
  if S.yw <= 0 then
    if mine then call('Camera.set_local_rotation', cam, k.u, base) end
    k.yq, k.last = nil, nil; return
  end
  local fx, fy, fz = xyz(call('Quaternion.forward', base))
  local hl = fx and sqrt(fx * fx + fy * fy) or 0
  if hl < 1e-3 then return end
  local d = wrap(math.deg(math.atan2(fy, fx)) - n.by)
  local L = V.look_back
  local y = math.rad(n.by + d + S.yw * (max(-L, min(L, d)) - d))
  local nq = call('Quaternion.look', Vec(math.cos(y) * hl, math.sin(y) * hl, fz), Vec(0, 0, 1))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('yq' .. tostring(why), 'running look limit: rotation write refused: %s', tostring(why)); return end
  k.yq = true; wrote(k, nq)
end

-- Face the terminal and Hold through camera swings: both turn the view only, like the limits above. The terminal: when
-- the game's view is turned away from the way your Helldiver faces (the extraction terminal), it eases to face the
-- body (4 per second). The swing: a game look more than 60 deg off the last frame's is not followed for up to 0.4 s
-- (until the game's look comes back within 45 deg of the held one); never in a seat or a vehicle
local function turn_hold(k, cam, dt)
  local base, mine = game_rot(k, cam)
  if not base then return end
  local fx, fy, fz = xyz(call('Quaternion.forward', base))
  if not (finite(fx) and finite(fy) and finite(fz)) then return end
  local seat = S.frv or S.mech or S.empl or S.tank or S.gator or S.pel
  local held = nil
  if V.swing_hold and not seat then
    local hf, pf = k.hf, k.pf
    if hf and S.t < k.hu then
      if hf[1] * fx + hf[2] * fy + hf[3] * fz < 0.7 then held = hf else k.hf = nil end
    else
      k.hf = nil
      if pf and S.t - pf[4] < 0.1 and pf[1] * fx + pf[2] * fy + pf[3] * fz < 0.5 then
        k.hf, k.hu = { pf[1], pf[2], pf[3] }, S.t + 0.4
        held = k.hf
        log('the game camera swung suddenly: holding the view for 0.4 s')
      end
    end
    pf = pf or {}
    pf[1], pf[2], pf[3], pf[4] = fx, fy, fz, S.t
    k.pf = pf
  else k.hf, k.pf = nil, nil end
  if held then fx, fy, fz = held[1], held[2], held[3] end
  local face = V.term_face and S.term and not V.tp_term and S.head
  local hl = sqrt(fx * fx + fy * fy)
  local bx, by
  if (face or (k.tw or 0) > 0) and S.head then bx, by = chef.unit_rotation(S.head.u) end
  local bl = (finite(bx) and finite(by)) and sqrt(bx * bx + by * by) or 0
  local want_t = face and bl > 0.5 and hl > 0.2 and (fx * bx + fy * by) / (hl * bl) < 0.9
  k.tw = want_t and min(1, (k.tw or 0) + dt * 4) or max(0, (k.tw or 0) - dt * 4)
  if k.tw > 0 and bl > 0.5 and hl > 0.2 then
    local w = k.tw * k.tw * (3 - 2 * k.tw)
    local nx, ny = fx / hl + (bx / bl - fx / hl) * w, fy / hl + (by / bl - fy / hl) * w
    local nl = sqrt(nx * nx + ny * ny)
    if nl > 1e-3 then fx, fy = nx / nl * hl, ny / nl * hl end
  elseif not held then
    if k.tq then
      if mine then call('Camera.set_local_rotation', cam, k.u, base) end
      k.tq, k.last = nil, nil
    end
    return
  end
  local nq = call('Quaternion.look', Vec(fx, fy, fz), Vec(0, 0, 1))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('tq' .. tostring(why), 'view turn: rotation write refused: %s', tostring(why)); return end
  k.tq = true; wrote(k, nq)
end

local function restore(k, cam)
  if cam and k.near0 then call('Camera.set_near_range', cam, k.near0) end
  if cam and k.fov0 then call('Camera.set_vertical_fov', cam, k.fov0) end
  k.near0, k.fov0, k.fvw = nil, nil, nil
end

-- the Pelican seat: the view looks the seat's way plus the mouse's turn (the game's outside shot doesn't follow it)
-- first person in a mech (MECHS tab). The game's mech camera sits far behind and shoots along its own line; worked in
-- the camera's own frame (the mech's when the camera is linked to it, the world's otherwise), so the same numbers hold
-- either way. mech_line: the game's line this frame, and with GUN LINE the spot on it nearest your head (the mech's
-- Forward along the line itself so the aim stays exact, Height plus 12 cm: 5 cm clipped
-- into the shoulder walking uphill). mech_look: COCKPIT turns the view so the crosshair meets the line at Line up at
-- (an enemy's range with Correct for enemies, never nearer than Nearest enemy distance, glided in 1/distance).
local MECH = { k = {}, g = {} }

-- Sprint tilt (CAMERA tab, TILT; lives on MECH only because place() already holds it, step/place are at Lua's
-- upvalue limit): rolls the view about its own line by S.tilt degrees (+ = right, from HUD.lean), on top of what a
-- limit or the crosshair fix wrote this pass (k.pre), else on the game's own rotation. The line never moves, so the
-- aim stays exact. Straight up or down it levels (no 'right' to lean toward there)
function MECH.tilt(k, cam)
  local pre = k.pre_n == S.pn and k.pre or nil
  local a = S.tilt or 0
  if abs(a) < 0.05 and not k.rq then return end
  local mine
  if not pre then pre, mine = game_rot(k, cam); if not pre then return end end
  local fx, fy, fz = xyz(call('Quaternion.forward', pre))
  local hl = fx and sqrt(fx * fx + fy * fy) or 0
  if abs(a) < 0.05 or hl < 0.05 then
    -- level again: only our own leaned write is still on the camera (a writer this pass or the game replaced it)
    if k.rq and mine then call('Camera.set_local_rotation', cam, k.u, pre); k.last = nil end
    k.rq = nil; return
  end
  local rx, ry = fy / hl, -fx / hl                              -- the view's right, level
  local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx       -- its up (right x forward)
  local r = math.rad(a)
  local cs, sn = math.cos(r), math.sin(r)
  local nq = call('Quaternion.look', Vec(fx, fy, fz), Vec(ux * cs + rx * sn, uy * cs + ry * sn, uz * cs))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('rq' .. tostring(why), 'sprint tilt: rotation write refused: %s', tostring(why)); return end
  if not k.rq then once('rq', 'sprint tilt: first lean written (%.1f deg)', a) end
  k.rq = true; wrote(k, nq); k.pre = nil
end
-- a hand-off to the scope or a far camera: a lean or free look turn still on it goes (the game only rewrites it when
-- the mouse moves)
function MECH.untilt(k, cam)
  if not ((k.rq or k.fq) and cam) then return end
  local base, mine = game_rot(k, cam)
  if base and mine then call('Camera.set_local_rotation', cam, k.u, base) end
  k.rq, k.fq, k.last = nil, nil, nil
end
-- free look's turn (S.fl.x yaw, .y pitch, deg; set by HUD.free_step) on top of what this pass wrote, else the game's
-- look. Written before the sprint tilt so the lean still applies.
function MECH.free_look(k, cam)
  local F = S.fl
  local on = F and (F.x ~= 0 or F.y ~= 0)
  if not (on or k.fq) then return end
  local pre, mine = k.pre_n == S.pn and k.pre or nil, nil
  if not pre then pre, mine = game_rot(k, cam); if not pre then return end end
  if not on then
    if k.fq and mine then call('Camera.set_local_rotation', cam, k.u, pre); k.last = nil end
    k.fq = nil; return
  end
  local fx, fy, fz = xyz(call('Quaternion.forward', pre))
  if not (finite(fx) and finite(fy) and finite(fz)) then return end
  F.ap = math.deg(math.asin(max(-1, min(1, fz))))  -- the aim's pitch, so the step keeps the total within 85 deg
  local y, p = math.atan2(fy, fx) + math.rad(F.x), math.rad(max(-85, min(85, F.ap + F.y)))
  local cp = math.cos(p)
  local nq = call('Quaternion.look', Vec(cp * math.cos(y), cp * math.sin(y), math.sin(p)), Vec(0, 0, 1))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('fq' .. tostring(why), 'free look: rotation write refused: %s', tostring(why)); return end
  if not k.fq then once('fq', 'free look: first turn written (%.0f deg side, %.0f up)', F.x, F.y) end
  k.fq = true; wrote(k, nq)
end
function MECH.line(k, cam, state, hx, hy, hz, mx, my, mz, mfx, mfy)
  local base = game_rot(k, cam)
  local fx, fy, fz = xyz(base and call('Quaternion.forward', base))
  if not fx then return end
  local gx, gy, gz = k.gp[1], k.gp[2], k.gp[3]
  if state == 'mech' then
    local dx, dy = hx - mx, hy - my
    hx, hy, hz = dx * mfy - dy * mfx, dx * mfx + dy * mfy, hz - mz
  end
  local p, MK = S.mech_pre, MECH.k
  MK.base, MK.fx, MK.fy, MK.fz, MK.gx, MK.gy, MK.gz = base, fx, fy, fz, gx, gy, gz
  MK.gun = V[p .. 'mech_view'] == 2
  if MK.gun then
    local t = (hx - gx) * fx + (hy - gy) * fy + (hz - gz) * fz + V[p .. 'mech_fwd']
    MK.qx, MK.qy, MK.qz = gx + fx * t, gy + fy * t, gz + fz * t + V[p .. 'mech_up'] + 0.12
  end
  return MK
end
function MECH.look(k, cam, dt, state, mx, my, mz, mfx, mfy)
  local m, p, MG = MECH.k, S.mech_pre, MECH.g
  local D0 = V[p .. 'mech_dist']
  if m.gun or D0 <= 0 then
    -- the game's own look: put back once if we turned it
    if k.last then call('Camera.set_local_rotation', cam, k.u, m.base); k.last = nil end
    S.md, S.mg = nil, nil
    return
  end
  local fx, fy, fz = m.fx, m.fy, m.fz
  local Dr
  if V.aim_range then
    -- the enemy list is in the world: the line taken there
    local gx, gy, gz, wx, wy = m.gx, m.gy, m.gz, fx, fy
    if state == 'mech' then
      gx, gy, gz = mx + m.gx * mfy + m.gy * mfx, my - m.gx * mfx + m.gy * mfy, mz + m.gz
      wx, wy = fx * mfy + fy * mfx, -fx * mfx + fy * mfy
    end
    MG[1], MG[2], MG[3] = gx, gy, gz
    local raw, _, u = aim_range(MG, wx, wy, fz)
    Dr = held_range(raw, u)
    if Dr then Dr = max(Dr, V[p .. 'mech_near']) end
  end
  local want, gl = Dr or D0, V[p .. 'mech_glide']
  local cur = S.md or want
  if gl > 0 then
    local G = S.mg
    if not G or abs(want - G.to) > G.to * 0.15 then G = { from = cur, to = want, t0 = S.t }; S.mg = G else G.to = want end
    local s = min(1, (S.t - G.t0) / gl)
    s = s * s * (3 - 2 * s)
    cur = 1 / ((1 - s) / max(1, G.from) + s / max(1, G.to))
  else
    S.mg = nil
    cur = 1 / (1 / cur + (1 / want - 1 / cur) * (1 - exp(-dt / 0.25)))
  end
  S.md = cur
  local vx, vy, vz = m.gx + fx * cur - k.wx, m.gy + fy * cur - k.wy, m.gz + fz * cur - k.wz
  local l = sqrt(vx * vx + vy * vy + vz * vz)
  if l < 0.5 then return end
  vx, vy, vz = vx / l, vy / l, vz / l
  local nq = call('Quaternion.look', Vec(vx, vy, vz), Vec(0, 0, 1))
  local _, err = call('Camera.set_local_rotation', cam, k.u, nq)
  if err then once('mw' .. tostring(err), 'mech: rotation write refused: %s', tostring(err)); return end
  wrote(k, nq)
end

local function place(w)
  S.pn = (S.pn or 0) + 1  -- this pass (update or draw), for wrote()/MECH.tilt
  -- hellpod hand-off: each frame write the game's own camera spot moved toward first person by what's left of 0.25 s
  local bw = not S.act and S.pout and S.tx and 1 - (S.t - S.pout) / 0.25 or 0
  if bw > 0 then
    for _, k in ipairs(S.cams) do
      local cam = k.main and cam_of(k)
      local cx, cy, cz = xyz(cam and call('Camera.local_position', cam))
      if cx then
        call('Camera.set_local_position', cam, k.u, Vec(cx + (S.tx - cx) * bw, cy + (S.ty - cy) * bw, cz + (S.tz - cz) * bw))
        call('World.update_unit', w, k.u)
      end
    end
  end
  if not S.act and S.bw <= 0 then
    -- third person: only a vehicle's own field of view, else the game's
    for _, k in ipairs(S.cams) do
      local cam = (S.fv or k.fov0) and cam_of(k)
      if cam and S.fv then
        k.fov0 = k.fov0 or call('Camera.vertical_fov', cam)
        k.fvw = math.rad(S.fv)
        call('Camera.set_vertical_fov', cam, k.fvw)
      elseif cam then call('Camera.set_vertical_fov', cam, k.fov0); k.fov0, k.fvw = nil, nil end
    end
    return
  end
  if not (S.head and S.tx) then return end
  local hx, hy, hz = upos(S.head.u, S.head.node)
  -- a frame whose position isn't a number: the last good head, so first person holds
  if not hx and bad_now(S.head.u) and S.ph and S.ph.u == S.head.u then hx, hy, hz = S.ph[1], S.ph[2], S.ph[3] end
  if not hx then return end
  local ph = S.ph or {}
  ph[1], ph[2], ph[3], ph.u, S.ph = hx, hy, hz, S.head.u, ph
  local scoped = false
  -- in a mech the game's camera sits in the mech's own frame (x right, y forward, z up from its root)
  local mx, my, mz, mfx, mfy
  if S.mech and not V[S.mech_pre .. 'tp_mech'] then
    mx, my, mz = upos(S.mech)
    mfx, mfy = chef.unit_rotation(S.mech)
    local l = mfx and sqrt(mfx * mfx + mfy * mfy) or 0
    if l > 1e-4 and mx then mfx, mfy = mfx / l, mfy / l else mfx = nil end
  end
  for ci, k in ipairs(S.cams) do
    -- a camera the game never moves, already put back: nothing more to read (41 of them on the ship, every pass)
    local cam = (not k.static or k.wx) and cam_of(k) or nil
    -- the game's own pose this frame (unless it's still ours from last frame): skip a camera the game already put at
    -- the head (its scope) or one far away (linked to something, so a world position would fling it)
    local cx, cy, cz = xyz(cam and call('Camera.local_position', cam))
    if cx and not k.home and not k.wx then k.home = { cx, cy, cz } end  -- where the game keeps it, before we ever wrote
    local state = k.state == 'mech' and (mfx and 'mech' or 'far') or 'ours'  -- left the mech: never a world write on it
    if cx and not (k.wx and abs(cx - k.wx) + abs(cy - k.wy) + abs(cz - k.wz) < 0.001) then
      local d = sqrt((cx - hx) ^ 2 + (cy - hy) ^ 2 + (cz - hz) ^ 2)
      k.gp = { cx, cy, cz }  -- the game's own spot, put back at a hand-off
      if k.wx and not k.main then k.main = true; log('camera %d is the game view camera', ci) end
      -- a scope sits in front of the eye; a third-person camera squeezed in by the ground (aiming on your back,
      -- looking sideways) sits beside or behind the head (-0.38 to +0.05 m ahead, logs to 1.0.31); real scopes 0.2-0.3 m ahead
      local al = 1
      if d < 0.4 then
        local fx, fy, fz = xyz(call('Quaternion.forward', call('Camera.local_rotation', cam)))
        if fx then al = (cx - hx) * fx + (cy - hy) * fy + (cz - hz) * fz end
      end
      local warp = S.warp and S.t - S.warp < 1 and (S.fall_t or 0) == 0 and not (S.frv or S.mech or S.empl or S.tank)
      -- in a backward dive's air part it is always the squeezed one (0.12-0.14 m ahead, 1.0.32 log), never a scope
      local air = S.diving == 'dive_hide_back' and not S.oblie
      state = d < 0.4 and al > 0.1 and not air and 'scope' or d > 8 and not warp and 'far' or 'ours'
      -- a tank crew seat: its game camera sits far off; where you chose first person it is written like a near one
      if state == 'far' and S.tcrew and not mfx then state = 'ours' end
      -- gliding out to the galactic table: follow the game's camera all the way out (a 'far' hand-off cut the glide)
      if state == 'far' and k.main and S.galaxy and S.bw > 0 then state = 'ours' end
      if state ~= k.state and d < 0.4 then log('camera %d: %.2f m from the head, %.2f m ahead', ci, d, al) end
      if k.main then
        if S.confirm then  -- the game's own pose for cam_confirm (chef.camera() is ours while we write it)
          local fx, fy, fz = xyz(call('Quaternion.forward', call('Camera.local_rotation', cam)))
          S.gcam = fx and { x = cx, y = cy, z = cz, fx = fx, fy = fy, fz = fz, t = S.t } or S.gcam
        end
        S.gcx, S.gcy, S.gcz = cx, cy, cz  -- the game's own camera: the line it shoots along
        -- lying or diving the floor squeezes it in and out frame to frame and the aim fix turned the view with it
        -- (aiming on your back looking down-right, 2026-11-09): hold its offset from the root steady there (0.15 s)
        local rx, ry, rz = S.trx, S.try, S.trz
        -- held only lying still: letting go in one frame turned the view 1-6 deg as a get-up went on (log 2026-11-11),
        -- so from the get-up on it glides back to the live camera (0.05 s) and is dropped once there
        -- settled only (S.pidle): in a dive, a fall that knocks you over or a landing it trailed the game camera by up
        -- to 3 m and the crosshair turned with it (log 2026-11-11)
        local hold = S.stance == 'prone' and S.pidle ~= nil and not S.getup
        if rx and (hold or S.go) then
          -- timed by the clock, not S.dt: the game moves its camera between update and draw, so this mostly runs in the
          -- draw pass, where S.dt is 0 (the hold never moved, and 1.2.20's glide back never got there: 7.9 m off)
          local o = S.go
          if not o then o = { cx - rx, cy - ry, cz - rz, t = S.t }; S.go = o end
          local g = 1 - exp(-(S.t - o.t) / (hold and 0.15 or 0.05))
          o.t = S.t
          o[1], o[2], o[3] = o[1] + (cx - rx - o[1]) * g, o[2] + (cy - ry - o[2]) * g, o[3] + (cz - rz - o[3]) * g
          S.golag = abs(cx - rx - o[1]) + abs(cy - ry - o[2]) + abs(cz - rz - o[3])
          if not hold and S.golag < 0.01 then S.go = nil else S.gcx, S.gcy, S.gcz = rx + o[1], ry + o[2], rz + o[3] end
        else S.go, S.golag = nil, 0 end
      end
      if state == 'far' and mfx and mx then
        -- take it only when the mech frame puts it where the game shows the view (so it is the mech's camera)
        local c = chef.camera()
        local wx, wy, wz = mx + cx * mfy + cy * mfx, my - cx * mfx + cy * mfy, mz + cz
        local e = c and sqrt((c.x - wx) ^ 2 + (c.y - wy) ^ 2 + (c.z - wz) ^ 2)
        if e and e < 0.5 then state = 'mech' end
      end
    end
    -- a camera the game never moves (the ship's station and hellpod cameras) kept our view in it, and the game later
    -- showed it from there: the view beside the head after a hellpod (1.0.29 log, 30 cameras left 0.31 m from the
    -- head). Only cameras the game drives get written: put it back where the game had it, once
    if cx and k.wx and state == 'ours' and not k.main then
      k.idle = abs(cx - k.wx) + abs(cy - k.wy) + abs(cz - k.wz) < 0.001 and (k.idle or 0) + 1 or 0
      if k.idle > 20 then k.static = true; log('camera %d: the game never moves it, left alone', ci) end
    end
    if k.static then state = 'static' end
    -- a lobby join starts by throwing the ship's camera far off and the game was gone within 0.1 s (3 of 5 joins,
    -- 1.2.58-1.2.69, nothing of ours open): touch nothing for 0.5 s, then hand off as usual
    if k.main and not chef.in_mission() then
      if state ~= 'far' then S.jdone = nil
      elseif k.state ~= 'far' and not S.jdone then
        S.jdone, S.jhold = true, 0.5
        log('ship: the game camera jumped away, touching nothing for 0.5 s')
        return
      end
    end
    -- any hand-off (scope, far, back): the game shows the helmet again a few frames later, re-hide every frame for 1 s
    if state ~= k.state then k.state = state; S.rehide = S.t + 1; log('camera %d (slot %d): %s', ci, k.slot, state) end
    if state == 'scope' then scoped = true end
    if state ~= 'ours' and state ~= 'mech' then
      if k.wx then restore(k, cam) end
      MECH.untilt(k, cam)
      -- not the game's view camera: put back where the game keeps it, so our view never stays in it
      if k.wx and cam and not k.main and k.home then
        call('Camera.set_local_position', cam, k.u, Vec(k.home[1], k.home[2], k.home[3])); call('World.update_unit', w, k.u)
      end
      k.wx = nil
    elseif cam then
      local px, py, pz = S.tx, S.ty, S.tz
      local bi = S.pin and k.gp and (S.t - S.pin) / 0.25 or 1
      if bi < 1 then px, py, pz = k.gp[1] + (px - k.gp[1]) * bi, k.gp[2] + (py - k.gp[2]) * bi, k.gp[3] + (pz - k.gp[3]) * bi end
      if state == 'mech' then
        local dx, dy = px - mx, py - my
        px, py, pz = dx * mfy - dy * mfx, dx * mfx + dy * mfy, pz - mz
      end
      -- first person in a mech: the game's line; GUN LINE puts the view on it
      local mk = S.mech and k.main and k.gp and MECH.line(k, cam, state, hx, hy, hz, mx, my, mz, mfx, mfy)
      if mk and mk.gun then px, py, pz = mk.qx, mk.qy, mk.qz end
      if not (finite(px) and finite(py) and finite(pz)) then
        -- never written: smoothing starts over from the head (one bad value in it would stay there for good). Only
        -- this camera's write is skipped: the other cameras and the scope hand-off below still run
        S.sm = nil
        once('badwrite', 'a camera position came out not a number: not written')
      else
        -- gliding: between the game's own spot this frame and first person, eased
        local e = 1
        if S.bw < 1 and k.gp then
          e = S.bw * S.bw * (3 - 2 * S.bw)
          px, py, pz = k.gp[1] + (px - k.gp[1]) * e, k.gp[2] + (py - k.gp[2]) * e, k.gp[3] + (pz - k.gp[3]) * e
        end
        k.wx, k.wy, k.wz = px, py, pz
        -- the game's own field of view this frame (the aim zoom follows it): any value but the one we wrote last
        if k.main then
          local cur = call('Camera.vertical_fov', cam)
          if type(cur) == 'number' and cur > 0.05 and cur < 3 and not (k.fvw and abs(cur - k.fvw) < 1e-4) then S.gfov = math.deg(cur) end
        end
        local _, why = call('Camera.set_local_position', cam, k.u, Vec(px, py, pz))
        if why then once('w' .. tostring(why), 'camera write refused: %s', tostring(why))
        else
          if mk then MECH.look(k, cam, S.dt or 0.016, state, mx, my, mz, mfx, mfy)
          elseif k.main and state == 'ours' and not S.mech then
            pitch_limit(k, cam, S.dt or 0.016)
            if not k.qw then view_limit(k, cam, S.dt or 0.016) end
            if not (k.qw or k.yq) then turn_hold(k, cam, S.dt or 0.016) end
            if not (k.qw or k.yq or k.tq) then k.qlog = nil; aim_fix(k, cam, S.dt or 0.016) end
            MECH.free_look(k, cam)
            MECH.tilt(k, cam)
          end
          -- Cut the cockpit (MECHS tab): a mech's own near range clears its frame and arm housing from the view
          local nr = S.mech and V[S.mech_pre .. 'mech_clip'] > 0 and V[S.mech_pre .. 'mech_clip']
            or (S.shw or 0) > 0 and 0.02  -- in the shield's window: close enough to keep the slot's frame drawn
            or S.shield and V.shield_near > 0 and V.shield_near or V.near
          if nr > 0 then
            k.near0 = k.near0 or call('Camera.near_range', cam)
            call('Camera.set_near_range', cam, nr)
          elseif k.near0 then call('Camera.set_near_range', cam, k.near0); k.near0 = nil end
          if S.fv then
            k.fov0 = k.fov0 or call('Camera.vertical_fov', cam)
            k.fvw = math.rad(S.fv)
            if e < 1 and type(k.fov0) == 'number' then k.fvw = k.fov0 + (k.fvw - k.fov0) * e end
            call('Camera.set_vertical_fov', cam, k.fvw)
          elseif k.fov0 then call('Camera.set_vertical_fov', cam, k.fov0); k.fov0, k.fvw = nil, nil end
          call('World.update_unit', w, k.u)
        end
      end
    end
  end
  if scoped ~= S.scoped then S.scoped = scoped; apply_hiding() end
end

-- our camera in use: on, and nothing hands the view to the game's camera (peek key, knocked down, mech, emplacement)
-- the view handed back to the game (once a glide out ends): the game holds its camera still while you use a pod, so
-- it stayed where we last put it (in the head, 0.3.100): put the game's own last spot and turn back
local function hand_back()
  S.handing = false
  local w = chef.world()
  local pod = S.offwhy == 'hellpod'
  for _, k in ipairs(S.cams) do
    local cam = cam_of(k)
    if cam and k.wx and not k.main and k.home then
      -- not the game's view camera: back where the game keeps it, so our view never stays in it
      call('Camera.set_local_position', cam, k.u, Vec(k.home[1], k.home[2], k.home[3]))
    elseif not pod then
      if cam and k.wx and k.gp then call('Camera.set_local_position', cam, k.u, Vec(k.gp[1], k.gp[2], k.gp[3])) end
      if cam and k.last and k.qb then call('Camera.set_local_rotation', cam, k.u, call('Quaternion.from_elements', k.qb[1], k.qb[2], k.qb[3], k.qb[4])) end
    end
    if cam and w and (k.wx or k.last) then call('World.update_unit', w, k.u) end
    restore(k, cam); k.wx, k.state, k.last = nil, nil, nil
  end
  S.tx = nil
end

-- back from these the 0.25 s ease from the game's camera (S.pin), not the glide. The table too (user: 'just like
-- leaving the hellpod'): it came on after 'game camera away', a cut. The ship's own camera coming back too (arriving
-- on the ship, user 2026-11-11: it snapped in 1.8 m from the head)
local EASE_IN = { hellpod = true, ['galactic map'] = true, ['game camera away'] = true }
local function set_act(act, why)
  -- off: the reason kept current (dying while gliding out of a knock-down cuts); coming on remembers the last one, so
  -- the glide in from the hellpod or a death cuts too
  if act == S.act then if not act then S.why = why end; return end
  if act then S.inwhy = S.why; S.gnd, S.gnd_t, S.fzp = nil, S.t, nil end  -- the ground measured afresh (it went stale)
  S.act, S.why = act, why
  -- hellpod: nothing written back, 0.25 s ease into the game's own camera and back out of it (not the glide)
  local pod = why == 'hellpod'
  if act and EASE_IN[S.offwhy] then S.pin = S.t end
  if not act then S.offwhy, S.pout = why, pod and S.t or nil end
  local scoped = S.scoped
  if act then S.handing = false else S.handing, S.scoped, S.aim = true, false, false end
  -- hiding follows S.shown, which glide() flips (and re-hides then); the one thing here it reads is the scope
  -- (Hide armor while scoped), cleared on the way out
  if scoped and not S.scoped then apply_hiding() end
  log('first person view %s (%s)', act and 'on' or 'off', why)
end

-- the glide between the game camera and first person: S.bw 0 (the game's) .. 1 (first person) over Glide time,
-- hiding switching halfway (S.shown). A cut instead for death, the hellpod and the ship's cutscenes: a glide there
-- would show a cutscene from the head or fly out of a dead body. (A game camera over 8 m from the head is never
-- written at all: place hands it off as 'far'.)
local CUT = { dead = true, hellpod = true, ['game camera away'] = true }  -- and anything inside a hellpod
local function glide(dt)
  local goal = S.act and 1 or 0
  if S.bw ~= goal then
    -- in a hellpod, or the game camera falling at hellpod speed for 0.1 s (the drop not recognized yet: that takes
    -- 0.25 s; a single frame's dip isn't a fall), or falling at all for the world's first switch-on (the mission's start);
    -- back from a hellpod its own 0.25 s ease (S.pin) does it
    if V.blend <= 0 or CUT[goal == 1 and S.inwhy or S.why] or goal == 1 and EASE_IN[S.offwhy] or not S.head
      or S.pod or S.puse or (S.pfall_t or 0) >= 0.1 or (S.pfall_t or 0) > 0 and not S.wglide then S.bw = goal
    elseif goal > S.bw then S.bw = min(1, S.bw + dt / V.blend)
    else S.bw = max(0, S.bw - dt / V.blend) end
    if abs(S.bw - goal) < 1e-9 then S.bw = goal end
  end
  if S.bw >= 1 then S.wglide = true end
  -- hidden only once the game showed our view in this world: joining a lobby it shows its own camera far off (over
  -- 8 m, never written, so no view camera known yet) for a few seconds, and the body stood there headless (user
  -- 2026-11-11). Any state of a known view camera counts: a weapon scope's camera reads 'far' too (1.2.55 log)
  local inview = false
  for _, k in ipairs(S.cams) do
    if k.main or k.state == 'scope' or k.state == 'mech' then inview = true; break end
  end
  -- logged once it lasts 0.2 s (coming back from a cut, the first frame is always the game's)
  S.held_t = S.bw >= 0.5 and not inview and (S.held_t or 0) + dt or 0
  local held = S.held_t > 0.2
  if held ~= (S.held or false) then
    S.held = held
    local n = {}
    for _, k in ipairs(S.cams) do local s = (k.main and 'main ' or '') .. tostring(k.state); n[s] = (n[s] or 0) + 1 end
    local l = {}
    for s, c in pairs(n) do l[#l + 1] = s .. ' ' .. c end
    table.sort(l)
    log('%s (cameras: %s)', held and 'the game shows its own camera: body shown' or 'the game shows our view: body hidden', table.concat(l, ', '))
  end
  -- the 0.25 s ease (S.pin) hides only with the view within 0.3 m of the eyes: hidden halfway, the body showed
  -- headless from 0.9 m behind (user 2026-11-11)
  local easing = false
  if S.pin and S.t - S.pin < 0.25 and S.tx then
    for _, k in ipairs(S.cams) do
      if k.main and k.gp then
        local g = k.gp
        easing = (1 - (S.t - S.pin) / 0.25) * sqrt((g[1] - S.tx) ^ 2 + (g[2] - S.ty) ^ 2 + (g[3] - S.tz) ^ 2) > 0.3
        break
      end
    end
  end
  local shown = S.bw >= 0.5 and inview and not easing
  -- Keep hidden in third person: the Meshes page's hiding also while the game's camera is in use (not guns: S.shown)
  local tpk = V.hide_tp and S.head ~= nil and not (S.dead or S.mend) and not shown
  if shown ~= S.shown or tpk ~= (S.tpkeep or false) then S.shown, S.tpkeep = shown, tpk; apply_hiding() end
  if S.bw <= 0 and S.handing then hand_back() end
end

-- now: hand the view back at once, no glide (the mod stopping, the world going)
local function set_on(on, now)
  if on ~= S.on then
    S.on = on
    log('first person %s', on and 'on' or 'off')
    if not on then set_act(false, 'switched off') end
  end
  if now and not on then
    S.bw = 0; glide(0)
    -- and what third person changed: a vehicle's field of view (restored only while the camera records live), the guns
    for _, k in ipairs(S.cams) do if k.fov0 or k.near0 then restore(k, cam_of(k)) end end
    show_guns()
  end
end

-- galactic map (ship only): using the table puts your feet on one fixed spot and leans you over it, head about
-- 1.4-1.5 m above your feet; standing or walking it's 1.65-1.7 (probe log, 2026-11-06). Leaving stands you up first.
-- shortcut: the spot is the Super Destroyer's table in world units; a ship layout change would need a new probe
local TABLE = { 0, 12.97, 19.57 }   -- x, y, z
local function galaxy_check(dt)
  local h = S.head
  local rx, ry, rz, hz
  if h and not chef.in_mission() then
    rx, ry, rz = upos(h.u, h.root)
    hz = select(3, upos(h.u, h.node))
  end
  local lean = rx and hz and abs(rx - TABLE[1]) < 0.3 and abs(ry - TABLE[2]) < 0.3 and abs(rz - TABLE[3]) < 0.3
    and hz - rz < 1.6 and anim(h.u) == 0  -- 0 = standing still (1 walk, 3 start, 5/6 stop)
  -- the moment you use it, before the lean (the game's camera often left first: a cut, 5 of 16 uses, logs 2026-11-11):
  -- the table's own animation starting (layer 8 state 223, 1.0.27 log) or the game's camera leaving the head, within
  -- 2 m of the spot. Starts only (223 can stay on until you walk off): the lean holds it after 1.5 s
  local near = rx and abs(rx - TABLE[1]) < 2 and abs(ry - TABLE[2]) < 2 and abs(rz - TABLE[3]) < 2
  local st9 = near and select(9, anim(h.u, true)) or nil
  local start = near and not S.galaxy and (st9 == 223 and S.st9 ~= 223 and 'its animation' or S.away and not S.gaway and 'game camera away')
  S.st9, S.gaway = st9, S.away
  local at = lean or start or near and S.galaxy and S.t - S.gal_on < 1.5 or false
  S.gal_off = at and 0 or (S.gal_off or 0) + dt
  if at and not S.galaxy or S.galaxy and S.gal_off > 0.25 then
    S.galaxy, S.gal_on = at, S.t
    log('galactic map %s (%shead %s above feet)', at and 'in use' or 'left', at and (start or 'leaning over it') .. ', ' or '',
      hz and rz and string.format('%.2f m', hz - rz) or '?')
  end
end

-- is the game's view away from the head at x, y, z? The two checks 1.0.2 already used on the ship: its view camera's
-- own pose (not what we wrote last frame) over 3.5 m away (the cutscene check), or, while the view isn't ours, the
-- loader's camera over 6 m away (the check that used to let go of the Helldiver). nil = nothing tells this frame
local function game_view_far(x, y, z)
  local known, far = false, false
  for _, k in ipairs(S.cams) do
    if k.main then
      local cam = cam_of(k)
      local cx, cy, cz = xyz(cam and call('Camera.local_position', cam))
      local near = false
      if cx and not (k.wx and abs(cx - k.wx) + abs(cy - k.wy) + abs(cz - k.wz) < 0.001) then
        known = true
        -- mission-end hold: a teammate picked by mistake stands a few metres off the game camera; reading that as away
        -- would pause cam_confirm, which is what lets the wrong pick go
        near = (cx - x) ^ 2 + (cy - y) ^ 2 + (cz - z) ^ 2 <= (S.mend and 6 or 3.5) ^ 2
        far = far or not near
      end
      -- a menu with a character preview (armory, Warbonds, Superstore) shows through a narrow camera, near the head
      -- or not: the game's own field of view under 48 deg, and clearly narrower (under 0.9x) than the widest the game
      -- has used on this ship, counts as away (never the one we wrote). The second test keeps a player whose own
      -- field of view setting is under 48 deg from being 'away' all the time
      local fv = cam and call('Camera.vertical_fov', cam)
      if finite(fv) and fv > 0 and not (k.fvw and abs(fv - k.fvw) < 1e-4) then
        -- the reference: the game's own field of view before we wrote ours (k.fov0), else the widest seen from a
        -- camera near the head (a cutscene's wide camera far off never raises it); with neither yet, 48 deg alone
        local ref = finite(k.fov0) and k.fov0 or S.shipfov or 0
        if fv < math.rad(48) and (ref == 0 or fv < 0.9 * ref) then known, far = true, true end
        if near then S.shipfov = max(S.shipfov or 0, fv) end
      end
    end
  end
  local c = not S.act and chef.camera()
  if c and c.x then known = true; far = far or (c.x - x) ^ 2 + (c.y - y) ^ 2 + (c.z - z) ^ 2 > 36 end
  if known then return far end
end

-- is the camera pick really yours? Over the game camera's first 8 m of travel it has to keep
-- sitting where it sits for your own head (the pick's score, a bit of slack); a teammate's head drifts out of that
-- spot as you both move. 0.75 s out of it lets the pick go, and that Helldiver isn't taken again for 8 s. On foot
-- only: paused while the game camera is legitimately elsewhere (the galactic table, a pod, a seat, a
-- terminal or menu close-up, aiming, down or dead), unless it had already drifted off before that
local function cam_confirm()
  local c, h = S.confirm, S.head
  if not c then return end
  if not h then S.confirm = nil; return end
  local g = S.act and S.gcam or not S.act and chef.camera()
  if not (g and g.fx) or S.act and S.t - g.t > 0.1 then return end
  local busy = S.galaxy or S.pod or S.away or S.term or S.aim or S.dead or S.down_any or S.down or S.diving or S.getup
    or S.mech or S.frv or S.empl or S.tank or S.gator or S.pel or S.tl14
  if busy and not c.bad then c.x = nil; return end
  local hx, hy, hz = upos(h.u, h.node)
  if not hx then return end
  local s, d, r = cam_fit(g, hx, hy, hz)
  if not s then return end
  if c.x then c.moved = c.moved + sqrt((g.x - c.x) ^ 2 + (g.y - c.y) ^ 2 + (g.z - c.z) ^ 2) end
  c.x, c.y, c.z = g.x, g.y, g.z
  if s <= c.limit then c.bad = nil
  else
    c.bad = c.bad or S.t
    if S.t - c.bad >= 0.75 then
      log('that Helldiver is not yours (the game camera sits %.2f m from its head, %.2f m to its right: score %.2f): looking again', d, r, s)
      S.reject[h.u] = S.t + 8
      S.head, S.parts, S.mine, S.confirm = nil, {}, nil, nil
      S.away, S.away_t, S.spod, S.last_scan = false, 0, false, nil  -- were about the wrong head
      if chef.in_mission() then S.drop_t, S.mdrop, S.pod = S.t, nil, false end  -- the pick is open again (no 'teammate' gate)
      return
    end
  end
  if c.moved >= 8 then S.confirm = nil; log('your Helldiver confirmed (the camera followed it for %.1f m)', c.moved) end
end

-- hellpods (the view, fixed (user): the game's from using the pod on the ship through the fall, first person 0.5 s
-- after the mission pod lands; picked every frame, before anything asks the body):
-- S.pod   in a hellpod. Ship: the head down at prone height (nothing else on the ship lays you down, 2026-11-07),
--         from climbing in until the ship unloads. Mission: the drop, from the game camera falling 25+ m/s for
--         0.25 s until you step out of the landed pod (1.5 m from where it landed, or 6 s after landing)
-- S.away  ship: the game's view over 3.5 m from your head (the launch cutscene, a terminal's close-up): the game's
--         view, as when the old 6 m check let go of the Helldiver, but the Helldiver is kept
-- S.nopod the body is left alone: no animation questions, and on the ship no scans for another Helldiver and no
--         mesh probes. Nothing here depends on saved pod spots or on which keys you use
local function pod_guard(dt)
  cam_confirm()
  local h = S.head
  local hx, hy, hz, rx, ry, rz
  if h then hx, hy, hz = upos(h.u, h.node); rx, ry, rz = upos(h.u, h.root) end
  if chef.in_mission() then
    S.away, S.spod, S.slow_t, S.sup_t = false, false, 0, 0
    local d = S.mdrop
    if not d and (S.pfall_t or 0) >= 0.25 then d = { t = S.t }; S.mdrop = d; log('hellpod drop: the game camera is falling') end
    if d then
      if (S.pfall_t or 0) > 0.1 then d.land, d.lx, d.ly = nil, nil, nil  -- falling again (one frame is a camera cut)
      elseif not d.land then d.land = S.t; log('hellpod landed') end
      if d.land then
        if rx and not d.lx then d.lx, d.ly = rx, ry end
        local out = rx and d.lx and (rx - d.lx) ^ 2 + (ry - d.ly) ^ 2 > 1.5 ^ 2
        if out or S.t - d.land > 6 or S.t - d.t > 60 then
          S.mdrop = nil
          log('out of the hellpod (%s)', out and 'stepped out' or S.t - d.land > 6 and '6 s after landing' or 'over a minute')
        end
      end
    end
    S.pod = S.mdrop ~= nil
  else
    S.mdrop = nil
    if hz and rz then
      local oz = hz - rz
      S.shmax = max(S.shmax or 1.2, min(oz, 1.85))
      local r = oz / S.shmax
      S.slow_t = r < 0.5 and (S.slow_t or 0) + dt or 0
      S.sup_t = r > 0.8 and (S.sup_t or 0) + dt or 0
      if not S.spod and S.slow_t > 0.1 then S.spod = true; log('hellpod (ship): head down to %.2f m over the feet, the body is left alone', oz) end
    end
    local far = hx and game_view_far(hx, hy, hz)
    if far ~= nil then
      S.away_t = far == (S.away or false) and 0 or (S.away_t or 0) + dt
      if S.away_t > (far and 0.1 or 0.5) then S.away, S.away_t = far, 0; log('ship: game camera %s', far and 'away from the head' or 'back') end
    end
    -- standing again with the camera back (an emote, a missed climb): first person again
    if S.spod and not S.away and (S.sup_t or 0) >= 1 then S.spod = false; log('hellpod (ship): standing again') end
    S.pod = S.spod or false
  end
  local at_table = rx and abs(rx - TABLE[1]) < 1 and abs(ry - TABLE[2]) < 1
  S.nopod = S.pod or (S.away and not at_table) or false
end

-- mission terminals: the Helldiver state machine plays its own states on layer 8 (the 9th value of
-- Unit.animation_get_state): 252 step on, 254 standing at it, 255-265 the key inputs, 253 stepping off
-- (in-game log 2026-11-07, matches the avatar_helldiver state machine)
local TERM_STATES = {}
for i = 252, 265 do TERM_STATES[i] = i ~= 253 end
-- Only on foot and standing (never down, dead, diving, getting up, seated or in a hellpod: anim() refuses most of
-- those too), ten times a second: it asks the engine straight, past the loader's guard (see anim)
local function term_check()
  local h = S.head
  local busy = S.down_any or S.dead or S.down or S.diving or S.getup or S.pod or S.nopod or S.frv or S.mech or S.empl or S.tank or S.gator or S.pel
  if not (h and chef.in_mission()) or busy then S.term, S.term_t = false, nil; return end
  if S.term_t and S.t < S.term_t then return end
  S.term_t = S.t + 0.1
  local st = { anim(h.u, true) }
  local at = TERM_STATES[st[9]] or false
  if at ~= (S.term or false) then
    S.term = at
    log('terminal %s', at and 'in use' or 'left')
  end
end

-- the game's animation layers, numbered as the in-game logs number them (the Nth value of Unit.animation_get_state):
-- 4 the upper body (its aim states), 9 actions (terminals, jumps, the reinforcement pod), 14 seats and vehicles, 22
-- the legs (running). Read 20 times a second and only for a feature that needs them, never down, dead or in a pod
-- (anim refuses those too). The same table is refilled, so nothing is made per read.
local LAY = {}
local function fill_lay(...)
  local n = select('#', ...)
  for i = 1, max(n, #LAY) do LAY[i] = (select(i, ...)) end
  return n
end
local function layers()
  if S.lay_t and S.t - S.lay_t < 0.05 and S.t >= S.lay_t then return S.lay end
  S.lay_t = S.t
  local h = S.head
  if not (h and chef.in_mission()) or S.down_any or S.dead or S.down or S.pod or S.nopod then S.lay = nil; return nil end
  if fill_lay(anim(h.u, true)) == 0 or type(LAY[1]) ~= 'number' then S.lay = nil; return nil end
  S.lay = LAY
  return LAY
end

-- hellpod (ship): the diver's animation, layer 13 (the 14th value of Unit.animation_get_state): 15 from the moment
-- you use a pod (drop zone screen), 17 once inside, back to 3 as you climb out (1.0.27 log 2026-11-09). Game camera for
-- all of it, never keys or the mouse (user). Mission: first person as soon as the new Helldiver exists.
local function pod_check()
  local h = S.head
  if not h then return end  -- head lost in the pod (cutscene camera far off): keep the state
  if chef.in_mission() then
    S.puse = false
    if h.u ~= S.podu then S.podu = h.u; log('new Helldiver: first person at once') end
    return
  end
  -- nothing asked once the body is down in the pod or the launch cutscene has the camera (S.nopod): keep the state
  local l13 = select(14, anim(h.u, true))
  if l13 == nil then return end
  local use = l13 == 15 or l13 == 17
  if use ~= (S.puse or false) then S.puse = use; log('hellpod %s', use and 'in use' or 'left') end
end

-- the game's map and stratagem list, read from the diver's animation, never from keys (the game refuses and shuts both
-- in too many ways). Map: layer 28 = 5 from the moment it comes up until it goes down, 2 otherwise, standing, crouched,
-- prone and moving (1.0.23 log, 13 presses; the arm pose missed it crouched and moving). Stratagem list: layer 10 = 306,
-- 131 lying down (1.0.20/1.0.21 logs: on 0.4 s after the key, off as it shuts, also while jogging); layer 11 = 636 bridges
-- those 0.4 s (on the very frame of the key, then 869/872 once the list is up; 1.0.20 log, every press)
local function menu_check()
  local h = S.head
  if not (S.on and V.tp_menus and h and chef.in_mission()) or S.panel or S.frv or S.mech or S.empl or S.tank then
    S.map_open, S.strat_open = false, false; return
  end
  local st = { anim(h.u, true) }
  -- 636 ends a frame or two before layer 10 reaches 306 (1.0.25 log, standing/crouched): hold it 0.15 s across the gap
  if st[11] == 636 then S.t636 = S.t end
  local map, strat = st[28] == 5, st[10] == 306 or st[10] == 131 or (S.t636 or -1) > S.t - 0.15
  if map ~= (S.map_open or false) then S.map_open = map; log('map %s', map and 'out' or 'away') end
  if strat ~= (S.strat_open or false) then S.strat_open = strat; log('stratagem list %s', strat and 'out' or 'away') end
end

-- each FRV seat's own Third person row (the model's prefix in front)
local FRV_TP = { driver = 'frv_tpd', passenger = 'frvp_tp', gunner = 'frvg_tp' }
-- first person in the mission pod 0.5 s after it lands (still the pod: S.pod keeps the body left alone)
local function pod_landed_fp()
  local d = S.mdrop
  return chef.in_mission() and d ~= nil and d.land ~= nil and S.t - d.land >= 0.5 or false
end
local function update_act()
  local why
  if S.mend and S.head and not S.confirm and not chef.in_mission() then S.mend = nil; log('mission end: your Helldiver is sure, first person again') end
  if not S.on then why = 'switched off'
  elseif S.dead then why = 'dead'
  -- user 2026-11-13: the game's own camera from the mission's outro until your Helldiver is confirmed on the ship
  -- (the ship's arrival kept picking a teammate)
  elseif S.mend then why = 'mission end'
  elseif binds.peek and binds.peek.down() and not S.panel then why = 'peek key'
  elseif S.tpk_on then why = 'third person key'
  elseif V.tp_galaxy and S.galaxy then why = 'galactic map'
  elseif (S.puse or S.pod) and not pod_landed_fp() then why = 'hellpod'  -- user: the game's own view from using a pod
  elseif S.away and not chef.in_mission() then why = 'game camera away'  -- whatever the settings (the cutscene)
  elseif V.tp_term and S.term then why = 'terminal'
  elseif V.tp_menus and S.map_open then why = 'map'
  elseif V.tp_menus and S.strat_open then why = 'stratagems'
  elseif V.tp_down and S.kdown and not S.pod then why = 'knocked down'  -- the game's ragdoll layer (HUD.daze)
  elseif S.pel then why = 'Pelican'
  elseif S.tank and (S.tank.seat == 'crew' and not V.tgun_fp or S.tank.seat == 'driver' and not V.tdrv_fp
    or S.tank.seat ~= 'crew' and S.tank.seat ~= 'driver' and V[S.tank.tp]) then why = 'tank ' .. tostring(S.tank.seat)
  elseif S.gator then why = 'Gator'
  elseif S.frv and (V[S.frv_pre .. 'frv_tp'] or V[S.frv_pre .. FRV_TP[S.frv]]) then why = 'FRV'
  elseif S.mech and V[S.mech_pre .. 'tp_mech'] then why = 'mech'
  elseif S.empl and V[S.empl_pre .. 'tp_empl'] then why = 'emplacement' end
  set_act(why == nil, why or 'first person')
end

---------------------------------------------------------------------------------------------------- panel
local P = { open = false, tab = 1, row = 1, cx = 0, cy = 0, capture = nil, capmod = nil, rep = 0, drag = nil }
local CAPTURE_KEYS = {}
for i = 1, 12 do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = 'f' .. i end
for c in ('abcdefghijklmnopqrstuvwxyz0123456789'):gmatch('.') do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = c end
for _, k in ipairs({ 'insert', 'home', 'end', 'page up', 'page down', 'tab', 'caps lock', 'left alt', 'right alt',
  'left ctrl', 'right ctrl', 'numpad 0', 'numpad 1', 'numpad 2', 'numpad 3', 'numpad 4', 'numpad 5', 'numpad 6',
  'numpad 7', 'numpad 8', 'numpad 9' }) do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = k end
P.MODLIST = { 'left ctrl', 'right ctrl', 'left alt', 'right alt' }
local CAPTURE_MOD = {}
for _, m in ipairs(P.MODLIST) do CAPTURE_MOD[m] = true end
P.COMBO = { 'ctrl', 'shift', 'alt' }   -- the loader's order

local function open_panel(on)
  P.open, P.capture, P.capmod, P.drag, S.panel, P.wlist = on, nil, nil, nil, on, false
  if chef.hold_mouse then chef.hold_mouse(on) end
  if on then local sw, sh = chef.screen(); P.cx, P.cy = sw / 2, sh / 2 end
end

local function rows() return TABS[P.tab].rows end
-- the weapon list: All weapons, then every gun with an in-game name under PRIMARY, SECONDARY and SUPPORT, A to Z
-- (a heading row has head set: never picked or stepped onto)
WP.LIST[1] = { name = 'All weapons' }
for _, c in ipairs({ 'primary', 'secondary', 'support' }) do
  local l = {}
  for k, g in pairs(GUNS) do if g[3] and g[1] == c then l[#l + 1] = { kind = k, name = g[3] } end end
  table.sort(l, function(a, b) return a.name < b.name end)
  WP.LIST[#WP.LIST + 1] = { head = true, name = c:upper() }
  for _, w in ipairs(l) do WP.LIST[#WP.LIST + 1] = w end
end
-- the list row picked now (All weapons = 1)
function WP.at()
  for i, w in ipairs(WP.LIST) do if not w.head and w.kind == WP.sel then return i end end
  return 1
end
-- a weapon picked: CAMERA, AIM and STANCE show only the rows it can have its own value for, with their headings
function WP.pick(kind)
  WP.sel, P.wlist = kind, false
  for _, tab in ipairs(TABS) do
    if tab.all then
      local out, head = {}, nil
      for _, r in ipairs(tab.all) do
        if r.head then head = r
        elseif not kind or r.wpn or r.wpick then
          if head then out[#out + 1] = head; head = nil end
          out[#out + 1] = r
        elseif r.reset_tab then out[#out + 1] = r end
      end
      tab.rows = out
    end
  end
  for i, r in ipairs(rows()) do if r.wpick then P.row = i end end
end
function WP.step(dir)
  local at = WP.at()
  repeat at = (at - 1 + dir) % #WP.LIST + 1 until not WP.LIST[at].head
  WP.pick(WP.LIST[at].kind)
end
function WP.openlist()  -- the list opens on the weapon picked
  P.wlist, P.wi, P.wkey = true, WP.at(), true
end
-- has this weapon any value of its own (asked once, again after a change)
function WP.marked(kind)
  if WP.marks[kind] == nil then
    WP.marks[kind] = false
    for _, r in pairs(WP.ROW) do if chef.load(WP.key(r, kind)) ~= nil then WP.marks[kind] = true; break end end
  end
  return WP.marks[kind]
end
-- V holds the values of the weapon in use: the panel's pick while it is open (at once, so the sliders show them),
-- else the one in your hands; distances then glide over ~0.3 s so a weapon swap doesn't jump the view (rows with a
-- word at 0 or the top, as GAME or SAME, switch at once). On P: step() is at Lua's 60-upvalue limit
function P.wapply(dt)
  local kind
  if P.open then kind = WP.sel else kind = S.wheld end
  kind = kind or false
  if WP.live ~= kind then
    WP.live = kind
    for id, r in pairs(WP.ROW) do
      local v = load_row(r, kind)
      if P.open or r.unit ~= ' m' or r.zero or r.top then V[id], WP.tgt[id] = v, nil else WP.tgt[id] = v end
    end
  end
  for id, v in pairs(WP.tgt) do
    local c = V[id] + (v - V[id]) * (1 - exp(-dt / 0.1))
    if abs(c - v) < 0.001 then c, WP.tgt[id] = v, nil end
    V[id] = c
  end
end
local function value_text(r)
  if r.key then
    if P.capture == r.id then return 'PRESS A KEY' end
    local k = binds[r.id] and binds[r.id].key() or 'off'
    return k == 'off' and 'NONE' or (chef.key_label and chef.key_label(k) or k):upper()
  end
  local v = V[r.id]
  if r.toggle then return v and 'ON' or 'OFF' end
  if v == 0 and r.zero then return r.zero end
  if r.top and v > r.max - r.step / 2 then return r.top end
  if PICKS[r.id] then local m = PICKS[r.id].models; return (m[v] or m[1]).name end
  if r.names then return r.names[v] or tostring(v) end
  local d = r.step < 1 and 2 or 0
  return string.format('%.' .. d .. 'f', v) .. (r.unit or '')
end
-- a row's default: for a picked weapon, the All weapons value (its RESET drops its own value)
function WP.def(r)
  if r.wpn and WP.sel then return load_row(r) end
  return r.def
end
local function reset(r)
  if r.wpick then WP.pick(nil); return end
  if not r.id then return end
  if r.key then chef.set(r.id, r.def) else set(r.id, WP.def(r)) end
  if r.toggle or r.id == 'profile' then apply_hiding() end
end
local function is_def(r)
  if r.key then return (binds[r.id] and binds[r.id].key()) == r.def end
  return V[r.id] == WP.def(r)
end
-- the whole tab, every model's copy on model tabs; the model pickers stay where they are
local function reset_tab()
  local list = rows()
  for _, r in ipairs(list) do if not PICKS[r.id] and r.id ~= 'profile' and not r.wpick then reset(r) end end
  for _, pk in pairs(PICKS) do
    if pk.rows == list then for _, set in ipairs(pk.sets) do for _, c in ipairs(set) do reset(c) end end end
  end
end
local function press_reset_tab()  -- second press within 3 s on the same tab resets
  if (P.confirm or 0) > 0 and P.confirm_tab == P.tab then reset_tab(); P.confirm = nil
  else P.confirm, P.confirm_tab = 3, P.tab end
end
local function change(r, dir)
  if r.reset_tab then press_reset_tab(); return end
  if r.wpick then WP.step(dir); return end
  if r.toggle then set(r.id, not V[r.id])
  elseif r.key then if dir > 0 then P.capture = r.id end
  else set(r.id, V[r.id] + dir * r.step) end
  if r.toggle or r.id == 'profile' then apply_hiding() end
end
-- step over headings from row i in direction dir; 0 = the tab bar
local function skip_heads(list, i, dir)
  while i > 0 and list[i] and list[i].head do i = i + dir end
  return i
end

-- colors are made in the frame that draws
local function col(r, g, b, a) return chef.color(r, g, b, a) end
local YEL = { 255, 214, 0 }

-- the short message after the on/off or profile key, top middle, fading out
local function say(t) if V.messages then S.msg, S.msg_t = t, 1.5 end end
local function draw_msg(dt)
  if not S.msg_t or S.msg_t <= 0 then return end
  S.msg_t = S.msg_t - dt
  local sw, sh = chef.screen()
  local s = sh / 1080
  local px = max(2, floor(2 * s + 0.5))
  local a = min(1, S.msg_t / 0.3)
  local tw = chef.text_width(S.msg, px)
  local w, h = tw + floor(48 * s), floor(44 * s)
  local x, y = floor((sw - w) / 2), sh - floor(160 * s)
  local L = chef.TOP + 90
  chef.rect(x, y, w, h, col(12, 14, 18, floor(220 * a)), L)
  chef.rect(x, y, w, floor(3 * s), col(YEL[1], YEL[2], YEL[3], floor(255 * a)), L + 1)
  chef.text(x + floor(24 * s), y + floor(15 * s), S.msg, px, col(YEL[1], YEL[2], YEL[3], floor(255 * a)), L + 2)
end

-- Mech HUD (MECHS tab): the mech you're in, from what the game shares between players about it (read only, through
-- GameSession). The
-- mod already knows the mech body it put you in, so only that body's object is read, 10 times a second, and only while
-- you're in it, alive and not down (its field reads once crashed the game on a body being torn down). Field meanings
-- are that HUD's tester's finds: 56 hull, 65 its most, 57 the parts' damage steps (2 bits each, 3 whole .. 0 worst:
-- front left, front right, rear, hips, right leg, left leg), 68 which part is destroyed (2 bits each, 1 = destroyed,
-- order front L, front R, rear, hips, left leg, right leg), 19[6] the arm objects (left, right). An arm object holds
-- the pair 699050, 800 at some field d, and field d - 1 turns 2 once that arm is destroyed.
local HUD = { next = 0 }
-- Free look (KEYS tab): while the key is held the loader holds the mouse from the game, so its aim, your gun and the
-- crosshair stay put, and the mouse turns only our view, up to 'Free look: furthest turn' each side. Let go:
-- it eases back to the aim. Turn per mouse step is learnt from normal on-foot play (view turn vs mouse step, sign included), so it matches the
-- game's sensitivity. Only while our view is on the game's main camera (not scoped, not in a mech).
function HUD.free_step(dt)
  local F = S.fl
  if not F then F = { x = 0, y = 0, lx = { 0, 0, 0 }, ly = { 0, 0, 0 } }; S.fl = F end
  local ours = false
  for _, k in ipairs(S.cams) do if k.main and k.state == 'ours' then ours = true end end
  local on = binds.freelook and binds.freelook.down() and S.act and ours and not (S.mech or P.open) or false
  -- shortcut: 0.05 deg per step until learnt (a few seconds of turning on foot)
  local function rate(L) return L[2] > 50 and (L[3] < 0 and -1 or 1) * L[1] / L[2] or -0.05 end
  if on ~= (F.held or false) then
    if not P.open and chef.hold_mouse then
      local ok, why = chef.hold_mouse(on)
      if on and not ok then once('flh', 'free look: mouse hold refused: %s', tostring(why)) end
    end
    F.held = on
    log('free look %s (%.4f / %.4f deg per mouse step%s)', on and 'on' or 'off', rate(F.lx), rate(F.ly), F.lx[2] > 50 and '' or ', not learnt yet')
  end
  local dx, dy = 0, 0
  if chef.mouse_delta and not P.open then dx, dy = chef.mouse_delta(); dx, dy = dx or 0, dy or 0 end
  if on then
    local ap = F.ap or 0
    local L = V.fl_max
    F.x = max(-L, min(L, F.x + dx * rate(F.lx)))
    F.y = max(-85 - ap, min(85 - ap, F.y + dy * rate(F.ly)))
    F.pv = nil
    return
  end
  local g = exp(-dt / 0.06)
  F.x, F.y = F.x * g, F.y * g
  if abs(F.x) + abs(F.y) < 0.2 then F.x, F.y = 0, 0 end
  -- learning: the shown view's turn this frame against this frame's mouse step (frames with a step, or right after one)
  local c = chef.camera()
  local learn = F.x == 0 and F.y == 0 and S.act and not (S.aim or S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
    and c and finite(c.fx) and finite(c.fy) and finite(c.fz)
  if not learn then F.pv = nil; return end
  local vy, vp = math.deg(math.atan2(c.fy, c.fx)), math.deg(math.asin(max(-1, min(1, c.fz))))
  local pv = F.pv
  F.pv = { vy, vp, dx, dy }
  if not pv then return end
  local function add(L, d, m, pm)
    if (m == 0 and pm == 0) or abs(d) > 20 then return end
    L[1], L[2], L[3] = L[1] * 0.995 + abs(d), L[2] * 0.995 + abs(m), L[3] * 0.995 + d * m
  end
  add(F.lx, wrap(vy - pv[1]), dx, pv[3])
  add(F.ly, vp - pv[2], dy, pv[4])
end

-- per mech model (its settings prefix): left and right arm, their name and the field with the rounds left (and spare)
HUD.ARMS = {
  [''] = { { 'ROCKETS', 6 }, { 'MINIGUN', 6 } },
  em_ = { { 'AUTOCANNON', 6 }, { 'AUTOCANNON', 6 } },
  lb_ = { { 'FLAME', 3 }, { 'CANNON', 12 } },
  bt_ = { { 'SHIELD' }, { 'SHOTGUN', 13, 11 } },
}
HUD.D68 = { [0] = 1, [1] = 2, [2] = 3, [3] = 4, [4] = 6, [5] = 5 }   -- field 68's pair -> drawn part (1-based)
-- the body unit of the mech item you're in (an arm's item: the nearest body of a known model)
function HUD.body(it)
  if PRE[it.kind] then return it.unit end
  local best, u = 6, nil
  for _, o in ipairs(mech_watch and mech_watch.items or {}) do
    local d = PRE[o.kind] and abs(o.x - it.x) + abs(o.y - it.y)
    if d and d < best then best, u = d, o.unit end
  end
  return u
end
-- glass cockpit (our game patch, shared by every exosuit): the cockpit panels are their own mesh (9) on the game's slots,
-- so the exosuit's pattern reaches them, and a glass copy of them is mesh 10. While you sit in that exosuit the glass
-- (Cockpit GLASS) or nothing (FULLY CLEAR) shows instead of the panels; every other exosuit gets its glass hidden (it
-- spawns shown). By number: the game doesn't know them by name (1.2.63). No material swaps: the game's shadow material
-- set at runtime drew flat cyan (1.2.64).
-- The Breakthrough's shield arm (same patch) the same way: its plate = mesh 14, glass copy = 15 (row Glass shield).
local GLASS = { panels = 9, glass = 10, what = 'glass cockpit', strength = 'cockpit_glass' }
HUD.SHIELD = { panels = 14, glass = 15, what = 'glass shield', kind = '65489809a8181b96', strength = 'shield_glass' }
-- glass rows (Cockpit glass / Shield glass): 1 CLEARER = our copy of the game's plain see-through shader
-- (standard_transparent, opacity 0.03: glass_cockpit.py OPAQ), 2 HARSHER = the built glass (base_glass: its refraction look
-- has no value to lower, 2.1.12c), swapped onto the glass slot only when the row or the unit changes. Values set on a
-- material at runtime never reach the screen (2.1.9-2.1.11). Ids are made fresh each time: one kept from an earlier frame
-- ends the game. standard_transparent has no skinned version (2.1.12d sat in the rest pose), so the glass meshes are rigid
-- on the cockpit / shield bone (2.1.12f, confirmed in game; the user then kept only these two of the 0-100 steps).
-- TRANSP = that shader, CLEARER swapped in only while it's loaded.
HUD.TRANSP = '84d1f2c7e35cad5e'
HUD.GLASS_MAT = { 'be9de2992cef2342', '363ae2fcdfdef63e' }
function HUD.glass_strength(u, G)
  local v = V[G.strength]
  if G.str_u == u and G.str_v == v then return end
  G.str_u, G.str_v = u, v
  local hex = HUD.GLASS_MAT[v] or HUD.GLASS_MAT[2]
  local id = call('IdString64.from_hex', hex)
  local loaded = id and call('Application.can_get', 'material', id) == true
  if loaded and v == 1 then loaded = call('Application.can_get', 'material', call('IdString64.from_hex', HUD.TRANSP)) == true end
  local slot, why = call('Mesh.material_slot_id', call('Unit.mesh', u, G.glass), 1)
  local res = loaded and slot and (select(2, call('Unit.set_material', u, slot, id)) or 'ok') or 'skipped'
  log('%s strength %d: material %s %s, slot %s, swap %s', G.what, v, hex, loaded and 'loaded' or 'NOT LOADED', tostring(slot or why), tostring(res))
end
function HUD.glass(u, on, quiet, G)
  if not u then return end
  G = G or GLASS
  local n = call('Unit.num_meshes', u)
  local k = n == G.glass and call('Mesh.num_materials', call('Unit.mesh', u, G.glass))
  if k ~= 1 then once(G.what .. 'n', '%s: not in this model (%s meshes, last has %s materials; ours %d and 1)', G.what, tostring(n), tostring(k), G.glass); return end
  local clear = on and G == GLASS and V.cockpit_look == 2
  -- the one shown first and the others hidden only after, so a refusal never leaves a hole
  local show = not on and G.panels or not clear and G.glass
  local a = show and select(2, call('Unit.set_mesh_visibility', u, show, true, 'default'))
  local b
  if not a and on then b = select(2, call('Unit.set_mesh_visibility', u, G.panels, false, 'default')) end
  if not a and (clear or not on) then b = b or select(2, call('Unit.set_mesh_visibility', u, G.glass, false, 'default')) end
  if show == G.glass and not a then HUD.glass_strength(u, G) end
  local line = string.format('%s %s (%s, %s; glass drawn: %s)', G.what, on and (clear and 'fully clear' or 'on') or 'off',
    a and 'show refused: ' .. tostring(a) or show and 'shown' or 'nothing shown', a and 'nothing hidden' or b and 'hide refused: ' .. tostring(b) or 'hidden',
    tostring(call('Mesh.visibility', call('Unit.mesh', u, G.glass))))
  if not quiet then log('%s', line) elseif a or b then once(G.what .. 'q', '%s (sweep)', line) end
end
-- the shield arm of the mech item you're in (an arm's item: the nearest shield arm), glass while the row is on
function HUD.shield(it)
  local G, sh, best = HUD.SHIELD, false, 6
  for _, o in ipairs(it and mech_watch and mech_watch.items or {}) do
    local d = o.kind == G.kind and abs(o.x - it.x) + abs(o.y - it.y)
    if d and d < best then best, sh = d, o.unit end
  end
  if sh ~= S.sglass_u then HUD.glass(S.sglass_u, false, false, G); S.sglass_u = sh; HUD.glass(sh, V.glass_shield, false, G) end
end
-- once per watch list (about every 2 s): every listed exosuit you're not in gets its glass hidden, and yours is set
-- again (a Cockpit change while seated; and if the game hid the glass, it's shown again)
function HUD.glass_sweep()
  if not mech_watch or mech_watch.generation == S.glass_gen then return end
  S.glass_gen = mech_watch.generation
  local u = S.glass_u
  if u and V.cockpit_look ~= 2 and call('Unit.num_meshes', u) == GLASS.glass
    and call('Mesh.visibility', call('Unit.mesh', u, GLASS.glass)) == false then
    once('glassgone', 'glass cockpit: the game hid the glass while you sat in it; shown again every 2 s')
  end
  if u then HUD.glass(u, true, true) end
  for _, o in ipairs(mech_watch.items) do if PRE[o.kind] and o.unit ~= u then HUD.glass(o.unit, false, true) end end
  local G, sh = HUD.SHIELD, S.sglass_u
  if sh then HUD.glass(sh, V.glass_shield, true, G) end
  for _, o in ipairs(mech_watch.items) do if o.kind == G.kind and o.unit ~= sh then HUD.glass(o.unit, false, true, G) end end
end
function HUD.goid(v) return type(v) == 'number' and v % 1 == 0 and v > 0 and v < 32767 end
function HUD.fields(id)
  if not HUD.goid(id) or call('GameSession.game_object_exists', HUD.ses, id) ~= true then return nil end
  local f = call('GameSession.game_object_field_batched', HUD.ses, id, {})
  return type(f) == 'table' and f or nil
end
function HUD.read()
  if S.mech ~= HUD.it then HUD.it, HUD.ub = S.mech, S.mech_it and HUD.body(S.mech_it) or nil end
  local u = HUD.ub
  if not (V.hud_on and S.mech and u) or S.dead or S.down or not alive(u) then
    HUD.info, HUD.ses, HUD.u, HUD.arms = nil, nil, nil, nil
    return
  end
  if S.t < HUD.next then return end
  HUD.next = S.t + 0.1
  if not HUD.ses then
    HUD.ses = call('Network.game_session')
    HUD.sync = HUD.ses and call('GameSession.unit_synchronizer', HUD.ses)
    if not HUD.sync then HUD.ses = nil; return end
  end
  if HUD.u ~= u then HUD.u, HUD.id, HUD.arms = u, call('UnitSynchronizer.unit_to_game_object_id', HUD.sync, u), nil end
  local f = HUD.fields(HUD.id)
  local hull, most = f and f[56], f and f[65]
  if not (type(hull) == 'number' and type(most) == 'number' and most > 0 and most <= 100000 and hull >= 0 and hull <= most) then
    HUD.info = nil
    return
  end
  local I = HUD.info or { part = {}, dead = {}, arm = { {}, {} } }
  I.hull, I.most, I.pre = hull, most, S.mech_pre
  local p = f[57]
  for i = 1, 6 do I.part[i], I.dead[i] = 3, false end
  if type(p) == 'number' and p % 1 == 0 and p >= 0 then
    for i = 0, 5 do I.part[i + 1] = floor(p / 4 ^ i) % 4 end
  end
  local d68 = f[68]
  if type(d68) == 'number' and d68 % 1 == 0 and d68 >= 0 then
    for i = 0, 5 do if floor(d68 / 4 ^ i) % 4 == 1 then I.dead[HUD.D68[i]] = true end end
  end
  -- the arms: their objects hang off the body (a gone object that was there: destroyed)
  local kids = type(f[19]) == 'table' and type(f[19][6]) == 'table' and f[19][6] or {}
  local spec = HUD.ARMS[S.mech_pre] or HUD.ARMS['']
  HUD.arms = HUD.arms or {}
  for i = 1, 2 do
    local a, sp, af = I.arm[i], spec[i], HUD.fields(kids[i])
    a.name = sp[1]
    if af then HUD.arms[i] = true end
    local d
    if af then for k = 2, 40 do if af[k] == 699050 and af[k + 1] == 800 then d = k; break end end end
    a.dead = (not af and HUD.arms[i]) or (d and af[d - 1] == 2) or false
    local n, s = af and sp[2] and tonumber(af[sp[2]]), af and sp[3] and tonumber(af[sp[3]])
    a.ammo = n and (s and string.format('%d/%d', floor(n), floor(s)) or tostring(floor(n))) or nil
  end
  HUD.info = I
end
-- the steps' colors: 3 whole (gray), 2 damaged (yellow), 1 badly (orange), 0 about to break (red), destroyed dark red
HUD.STEP = { [3] = { 150, 156, 162 }, [2] = { 230, 200, 60 }, [1] = { 235, 130, 40 }, [0] = { 220, 50, 40 } }
function HUD.draw()
  local I = HUD.info
  if not I or P.open or not (S.act or V.hud_tp) or not chef.in_mission() then return end
  local sw, sh = chef.screen()
  local s = sh / 1080 * V.hud_size / 100
  local a = floor(255 * V.hud_alpha / 100)
  local w, h = floor(230 * s), floor(150 * s)
  local x0, y0 = floor(sw - V.hud_right * sh / 1080 - w), floor(V.hud_bottom * sh / 1080)
  local L = chef.TOP + 70
  local function box(x, y, bw, bh, c, layer) chef.rect(x0 + floor(x * s), y0 + floor(y * s), floor(bw * s), floor(bh * s), c, layer or L + 1) end
  chef.rect(x0, y0, w, h, col(10, 12, 16, floor(a * 0.55)), L)
  -- the hull: exact, a bar and its number
  local k = I.hull / I.most
  local hc = k > 0.5 and HUD.STEP[3] or k > 0.25 and HUD.STEP[2] or HUD.STEP[0]
  box(10, 128, 210, 10, col(40, 44, 50, a))
  box(10, 128, 210 * k, 10, col(hc[1], hc[2], hc[3], a), L + 2)
  chef.text(x0 + floor(10 * s), y0 + floor(112 * s), string.format('HULL %d / %d', floor(I.hull + 0.5), floor(I.most + 0.5)),
    max(8, floor(14 * s)), col(230, 232, 235, a), L + 2)
  -- the parts, laid out as you sit in it (your left is its left): cockpit front L / R, the rear strip on top, hips, legs
  local PL = { { 82, 74, 32, 28 }, { 116, 74, 32, 28 }, { 82, 104, 66, 6 }, { 86, 50, 58, 20 }, { 120, 10, 24, 36 }, { 86, 10, 24, 36 } }
  for i, r in ipairs(PL) do
    local c = I.dead[i] and { 90, 20, 18 } or HUD.STEP[I.part[i]] or HUD.STEP[3]
    if I.dead[i] then box(r[1] - 1, r[2] - 1, r[3] + 2, r[4] + 2, col(220, 50, 40, a)) end
    box(r[1], r[2], r[3], r[4], col(c[1], c[2], c[3], a), L + 2)
  end
  -- the arms: left and right of the body, their rounds below
  for i = 1, 2 do
    local arm = I.arm[i]
    local ax = i == 1 and 22 or 162
    local c = arm.dead and { 90, 20, 18 } or HUD.STEP[3]
    box(ax, 40, 46, 56, col(c[1], c[2], c[3], a), L + 2)
    local txt = arm.dead and 'X' or arm.ammo or ''
    chef.text(x0 + floor((ax + 2) * s), y0 + floor(24 * s), txt, max(8, floor(13 * s)), col(230, 232, 235, a), L + 3)
    chef.text(x0 + floor((ax + 2) * s), y0 + floor(10 * s), arm.name or '', max(7, floor(10 * s)), col(170, 175, 180, a), L + 3)
  end
end
-- Death effect (CAMERA tab, DEATH): only from the death seen in the animation (HUD.dying; S.dead alone also fires on a
-- living body, 0.5 s out of a reinforcement pod, 1.2.9 log): the view blurs in and out, the eyes blink (Blinking), then a cut to
-- black held until a hellpod drop is seen (the game camera falling, 1 s after the death at the earliest) or you are up.
-- The blur is the game's own UI material content/ui/shared/material/gui_blur: it has no strength setting, so its
-- alpha fades it in and out. Drawn by a screen GUI of mine in the game's UI world (the first world that isn't the main
-- one, as the loader finds it), where the game draws its menus and their blur.
-- shortcut: a ragdoll or spectated teammate falling 25+ m/s for 0.25 s also ends the black; check the fall is the pod if
-- that shows up
HUD.BLUR = '2391483abbda5a58'
HUD.BLACK = 3.9                    -- the cut to black (s after the death)
HUD.MAXT = 15                      -- the black ends by then even with no drop seen (s after the death)
HUD.SIGMA = 12                     -- the UI blur's strength during the death (the game's own default 2.5)
-- the UI blur's strength is a render setting (ui_blur_sigma, in the player's user_settings.config): raised for the
-- death, put back at the cut to black or whenever the effect stops. Only in the game's memory (the loader refuses a
-- mod saving settings). Application.set_render_setting works on it (1.2.48 log: 2.5 -> 12 and back)
function HUD.sigma(on)
  if on == (HUD.sig0 ~= nil) then return end
  if on then
    if HUD.sig_bad then return end
    local v0, why0 = call('Application.user_setting', 'render_settings', 'ui_blur_sigma')
    local cur = call('Application.render_setting', 'ui_blur_sigma')
    log('death blur: ui_blur_sigma saved %s (%s), live %s', tostring(v0), tostring(why0), tostring(cur))
    v0 = tonumber(cur) or tonumber(v0)
    if not v0 then HUD.sig_bad = true; log('death blur: no blur strength to go back to, left alone'); return end
    local _, why = call('Application.set_render_setting', 'ui_blur_sigma', tostring(HUD.SIGMA))
    if why then _, why = call('Application.set_render_setting', 'ui_blur_sigma', HUD.SIGMA) end
    if why then HUD.sig_bad = true; log('death blur: set_render_setting refused (%s)', tostring(why)); return end
    HUD.sig0, HUD.sig_num = v0, type(cur) == 'number'
    log('death blur: strength %s -> %s (live now %s)', tostring(v0), HUD.SIGMA, tostring(call('Application.render_setting', 'ui_blur_sigma')))
  else
    local v0 = HUD.sig0
    HUD.sig0 = nil
    local _, why = call('Application.set_render_setting', 'ui_blur_sigma', tostring(v0))
    if why then _, why = call('Application.set_render_setting', 'ui_blur_sigma', v0) end
    log('death blur: strength back to %s (%s)', tostring(v0), why and ('refused: ' .. tostring(why)) or 'ok')
  end
end
-- a fresh random plan every death: the blur's swells (a new strength every 0.6 to 1.2 s, eased, taking turns between
-- full 0.9 to 1 and 0.55 to 0.75: the material's blur is fixed, so its alpha is the only strength there is) and the
-- blinks, in bursts of 1 to 3 at random gaps, quick, a quarter of them not shut all the way, slower and longer shut
-- toward the black; inside a burst the next blink can come before the lids are fully open. Last, the eyes close
-- slowly (0.4 to 0.6 s) and stay shut into the black
function HUD.plan()
  local R, n, bl, bt = math.random, { { 0, 0 } }, {}, 0
  while bt < HUD.BLACK do
    bt = bt + 0.6 + 0.6 * R()
    n[#n + 1] = { bt, #n % 2 == 1 and 0.9 + 0.1 * R() or 0.55 + 0.2 * R() }
  end
  local t = 0.4 + 0.6 * R()
  while t < HUD.BLACK - 0.9 do
    local k = t / HUD.BLACK
    for _ = 1, R(1, 3) do
      -- c: shutting (s), h: held shut, o: opening, d: how far shut (1 = all the way)
      local b = { t = t, c = 0.05 + 0.04 * R() + 0.06 * k, h = 0.2 * k * R(), o = 0.08 + 0.08 * R() + 0.15 * k,
        d = R() < 0.25 and 0.5 + 0.4 * R() or 1 }
      bl[#bl + 1] = b
      t = t + b.c + b.h + b.o * (0.3 + 0.7 * R())
    end
    t = t + 0.3 + 0.7 * R()
  end
  local c = 0.4 + 0.2 * R()
  bl[#bl + 1] = { t = HUD.BLACK - c, c = c, h = 99, o = 1, d = 1 }
  return { n = n, bl = bl }
end
function HUD.blur(a, sw, sh)
  local ws, main, uw = call('Application.worlds'), chef.world(), nil
  if type(ws) == 'table' then for i = 1, #ws do if ws[i] ~= main then uw = ws[i]; break end end end
  if not uw then once('blurw', 'death effect: no UI world for the blur (%s worlds)', type(ws) == 'table' and #ws or '?'); return end
  if HUD.bwld ~= uw then
    -- (a GUI left behind in an old world draws nothing: immediate GUIs are empty unless drawn into this frame)
    HUD.bwld = uw
    local ok = call('Application.can_get', 'material', call('IdString64.from_hex', HUD.BLUR))
    local g, why = call('World.create_screen_gui', uw, 'immediate')
    HUD.bgui = g
    log('death effect: blur material loaded %s, GUI %s', tostring(ok), g and 'made' or tostring(why))
  end
  if not HUD.bgui then return end
  -- (the material id made fresh each call, as the loader does: a kept one can point at another temporary)
  local _, why = call('Gui.bitmap', HUD.bgui, call('IdString64.from_hex', HUD.BLUR), call('Vector3', 0, 0, 80),
    call('Vector2', sw, sh), call('Color', floor(255 * a), 255, 255, 255))
  if why then once('blurd', 'death effect: blur refused (%s)', tostring(why)) end
end
-- the death seen in the animation: layer 13 (the 14th value) turns 103 the moment you die, about 4 s before the game
-- removes the animation (S.dead). Standing: the layers seat_layer_step read this frame (a death with no knockdown,
-- 1.2.8 log). Down, where those reads stop: read here, with the state machine checked the same frame (asking a torn-down
-- one crashed the game, 2026-11-07). The view is left as it was.
function HUD.dying()
  if not chef.in_mission() then S.dying, S.dying_u = nil, nil; return end
  local h = S.head
  if S.dying then
    if h and h.u ~= S.dying_u and not S.down_any then S.dying, S.dying_u = nil, nil end   -- your next Helldiver, standing
    -- a false alarm: a real death takes the body's animation away in about 4.5 s (1.2.9 logs); still there after 8 s,
    -- the body is alive and the effect ends
    if S.dying and S.t - S.dying > 8 and alive(S.dying_u) and call('Unit.has_animation_state_machine', S.dying_u) == true then
      S.dying, S.dying_u = nil, nil; log('death effect: the body still has its animation 8 s on, not a death: effect off')
    end
    return
  end
  if not h or S.dead or S.nopod then return end
  local l13
  if not S.down_any then
    l13 = S.l14_t == S.t and S.l14 or nil
  else
    if not (UnitApi and UnitApi.animation_get_state and alive(h.u)) or call('Unit.has_animation_state_machine', h.u) ~= true then return end
    local st = { pcall(UnitApi.animation_get_state, h.u) }
    l13 = st[1] and st[15] or nil
  end
  if l13 == 103 then S.dying, S.dying_u, S.dying_n, S.dpos = S.t, h.u, h.node, nil; log('death seen in the animation (layer 13 = 103, %s)', S.down_any and 'down' or 'standing') end
end
function HUD.death()
  if V.death_fx then HUD.dying() end   -- (no extra animation reads with the effect off)
  if not (V.death_fx and (S.on or S.keep == true) and chef.in_mission() and S.dying) then S.dth0, S.dth1 = nil, nil; HUD.sigma(false); return end
  if not S.dth0 then S.dth0, S.dplan = S.dying, HUD.plan(); log('death effect: start (%d blinks)', #S.dplan.bl); HUD.sigma(true) end
  local t = S.t - S.dth0
  if not S.dth1 and t > 1 and (S.pfall_t or 0) >= 0.25 then S.dth1 = S.t; log('death effect: drop seen after %.1f s, black ends', t) end
  if not S.dth1 and t > HUD.MAXT then S.dth1 = S.t; log('death effect: no drop seen in %d s, black ends', HUD.MAXT) end
  -- multiplayer: the game camera leaving your body (over 6 m and the view not ours, check_player's rule) = it shows a
  -- teammate until your reinforcement, so the black ends there (it held to 8 s, the camera left at about 6 s: 1.2.54 log)
  if not S.dth1 and t > 1 and others_here() then
    if alive(S.dying_u) then S.dpos = { upos(S.dying_u, S.dying_n) } end
    local c, p, ours = chef.camera(), S.dpos, false
    for _, k in ipairs(S.cams) do if k.state == 'ours' or k.state == 'scope' then ours = true end end
    local d = c and p and p[3] and sqrt((p[1] - c.x) ^ 2 + (p[2] - c.y) ^ 2 + (p[3] - c.z) ^ 2)
    if d and d > 6 and not ours then S.dth1 = S.t - 0.5; log('death effect: game camera %.0f m from your body after %.1f s (a teammate), black ends', d, t) end  -- (- 0.5: the fade already over, a cut)
  end
  local sw, sh = chef.screen()
  local L = chef.TOP + 80
  if S.dth1 or t >= HUD.BLACK then HUD.sigma(false) end
  if S.dth1 then
    local a = 1 - (S.t - S.dth1) / 0.5
    if a > 0 then chef.rect(0, 0, sw, sh, col(0, 0, 0, floor(255 * a)), L + 5) end
    return
  end
  if t >= HUD.BLACK then chef.rect(0, 0, sw, sh, col(0, 0, 0, 255), L + 5); return end
  local n, k = S.dplan.n, 1
  while n[k + 1][1] < t do k = k + 1 end   -- (the last swell ends past the black)
  local f = (t - n[k][1]) / (n[k + 1][1] - n[k][1])
  HUD.blur(n[k][2] + (n[k + 1][2] - n[k][2]) * f * f * (3 - 2 * f), sw, sh)
  chef.rect(0, 0, sw, sh, col(0, 0, 0, floor(100 * t / HUD.BLACK)), L + 1)   -- darker toward the end
  if not V.death_blink then return end
  local c = 0
  for _, b in ipairs(S.dplan.bl) do
    local s = t - b.t
    if s > 0 then c = max(c, b.d * (s < b.c and s / b.c or s < b.c + b.h and 1 or max(0, 1 - (s - b.c - b.h) / b.o))) end
  end
  if c > 0 then
    -- the lids' edges soft (4 fading bands)
    local bh, h = max(1, floor(sh * 0.025)), floor(sh / 2 * c + 0.5)
    chef.rect(0, sh - h, sw, h, col(0, 0, 0, 255), L + 4)
    chef.rect(0, 0, sw, h, col(0, 0, 0, 255), L + 4)
    for k = 1, 4 do
      local ka = floor((255 - 55 * k) * c)
      chef.rect(0, sh - h - k * bh, sw, bh, col(0, 0, 0, ka), L + 3)
      chef.rect(0, h + (k - 1) * bh, sw, bh, col(0, 0, 0, ka), L + 3)
    end
  end
end
-- Sprint tilt's lean (S.tilt, degrees, + = right), worked out once per update and eased; MECH.tilt turns the view.
-- Sprinting = feet over 3.8 m/s, all of it from 4.4 (walking 2-3.3, sprinting 4.4-5.3, 0.3.129 log). Leans into the
-- run's turn (its heading changing 120 deg/s = the whole lean) and a run across the view (5 m/s = the whole lean).
-- A sideways dive (S.diving) leans toward it for its first 0.7 s
function HUD.lean(dt)
  local c = chef.camera()
  local hl = c and sqrt(c.fx * c.fx + c.fy * c.fy) or 0
  local ok = S.act and S.head and hl > 0.2 and dt > 0
    and not (S.aim or S.scoped or S.down or S.dead or S.dying or S.pod or S.getup or S.stance == 'prone'
      or S.frv or S.mech or S.empl or S.tank or S.gator or S.pel)
  local want, spr = 0, 0
  if ok then
    local rx, ry = c.fy / hl, -c.fx / hl   -- the view's right, level
    local vx, vy = S.vx or 0, S.vy or 0
    local spd = sqrt(vx * vx + vy * vy)
    local hd = spd > 1 and math.deg(math.atan2(vy, vx)) or nil
    local yr = hd and S.thd and wrap(hd - S.thd) / dt or 0   -- + = turning left
    S.thd = hd
    S.tyr = (S.tyr or 0) + (yr - (S.tyr or 0)) * (1 - exp(-dt / 0.15))
    local sp = min(1, max(0, (spd - 3.8) / 0.6))
    spr = sp
    want = V.tilt * sp *max(-1, min(1, (vx * rx + vy * ry) / 5 - S.tyr / 120))
    if S.diving == 'dive_hide_side' and S.fall and V.tilt_dive > 0 then
      if not S.tdv then
        S.tdv, S.tds = S.t, S.fall[1] * rx + S.fall[2] * ry > 0 and 1 or -1
        log('dive tilt: %s', S.tds > 0 and 'right' or 'left')
      end
      if S.t - S.tdv < 0.7 then want = V.tilt_dive * S.tds end
    else S.tdv = nil end
  else S.thd, S.tyr, S.tdv = nil, 0, nil end
  S.tilt = (S.tilt or 0) + (want - (S.tilt or 0)) * (1 - exp(-dt / (S.tdv and 0.1 or 0.25)))
  -- one log line per lean: its biggest, once it levels again
  if abs(S.tilt) > 0.3 then S.tmax = max(S.tmax or 0, abs(S.tilt))
  elseif S.tmax then log('sprint tilt: leaned up to %.1f deg', S.tmax); S.tmax = nil end
  -- Sprint zoom-out: the same sprint share, eased; the field of view code adds V.sprint_fov times it
  S.spr = (S.spr or 0) + (spr - (S.spr or 0)) * (1 - exp(-dt / 0.25))
  if S.spr > 0.05 then S.sprmax = max(S.sprmax or 0, S.spr)
  elseif S.sprmax then log('sprint zoom-out: up to %.1f deg wider', S.sprmax * V.sprint_fov); S.sprmax = nil end
end
-- Knockdown daze (CAMERA tab, DEATH): being thrown blurs and darkens the screen at once, holds 0.4 s and clears by
-- 1.8 s. The game's own blur strength (the death effect raises it, this doesn't). A death takes over at once.
-- Thrown = the game's own ragdoll layer, not S.down's head-height guess (that fired sitting in a mech, leaving it, and
-- lying prone looking back, log 2026-11-11): the 31st value of Unit.animation_get_state (avatar_helldiver's last layer,
-- names from its state machine): 5 Ragdoll/Kinematic = animated as usual, 11 Ragdoll/Ragdoll = thrown, 7
-- Ragdoll/Land_knockdown = landing from it. Asked 20 times a second with the state machine checked the same frame
-- (asking a torn-down one crashed the game, see HUD.dying); not while the game camera falls (as anim()) or in the pod
HUD.DAZE = 1.8
HUD.RAG = { [7] = true, [11] = true }
HUD.RAGN = { [0] = 'Dead', 'Death_Powered', 'Falling', '3', 'Frozen', 'Kinematic', '6', 'Land_knockdown', 'Legs_Disabled',
  'Powered', 'Powered_Downed', 'Ragdoll', 'Vehicle', 'Vehicle_aim' }
function HUD.ragdoll()
  local h = S.head
  if not (h and chef.in_mission()) or S.dead or S.pod or S.nopod then S.rag = nil; return false end
  -- camera falling (a throw can do it): the last read stands, so one knockdown doesn't start twice
  if (S.calm_t or 0) >= 0.5 and not (S.rag_t and S.t - S.rag_t < 0.05 and S.t >= S.rag_t) then
    S.rag_t = S.t
    if UnitApi and UnitApi.animation_get_state and alive(h.u) and call('Unit.has_animation_state_machine', h.u) == true then
      local st = { pcall(UnitApi.animation_get_state, h.u) }
      local r = st[1] and st[32] or nil
      if r ~= S.rag then log('ragdoll layer: %s -> %s', tostring(HUD.RAGN[S.rag] or S.rag), tostring(HUD.RAGN[r] or r)); S.rag = r end
    end
  end
  return HUD.RAG[S.rag] or false
end
function HUD.daze()
  local rag = (V.daze or V.tp_down) and HUD.ragdoll() or false
  -- S.kdown (Third person when knocked down, update_act): thrown, then lying until the head is back up to crouch
  -- height (the ragdoll layer turns back to Kinematic as the get-up starts)
  S.kdown = rag or S.kdown and S.stance == 'prone' and not (S.dead or S.pod or S.nopod) and chef.in_mission() or false
  local down = V.daze and (S.on or S.keep == true) and rag or false
  if down and not S.dzd and not S.dying then
    S.dz0 = S.t; log('knockdown daze: start')
  end
  S.dzd = down
  if not S.dz0 then return end
  local t = S.t - S.dz0
  if t >= HUD.DAZE or S.dying or not V.daze then S.dz0 = nil; return end
  local a = t < 0.15 and t / 0.15 or t < 0.4 and 1 or 1 - (t - 0.4) / (HUD.DAZE - 0.4)
  a = a * a * (3 - 2 * a)
  local sw, sh = chef.screen()
  HUD.blur(0.85 * a, sw, sh)
  chef.rect(0, 0, sw, sh, col(0, 0, 0, floor(70 * a)), chef.TOP + 81)
end
-- everything drawn over the game each update: the Mech HUD, the death effect, the knockdown daze (and the sprint
-- tilt's lean: not a drawing, it only needs this once-per-update call)
function HUD.overlays(dt)
  HUD.lean(dt)
  HUD.read()
  HUD.draw()
  HUD.daze()
  HUD.death()
end

local function draw_panel(dt)
  local sw, sh = chef.screen()
  local s = sh / 1080
  local px = max(2, floor(2 * s + 0.5))
  local sp = max(2, px - 1)
  local W, RH, HH, HEAD, TABH, FOOT = floor(720 * s), floor(40 * s), floor(32 * s), floor(64 * s), floor(42 * s), floor(70 * s)
  local list = rows()
  local rows_h = 0
  for _, r in ipairs(list) do rows_h = rows_h + (r.head and HH or RH) end
  -- long tabs scroll: show what fits on screen, keep the selected row in view, the wheel only scrolls (never changes a setting)
  local fit = min(rows_h, sh - floor(60 * s) - HEAD - TABH - FOOT - floor(16 * s))
  local top = 0
  for i, r in ipairs(list) do
    if i == P.row then
      local h = r.head and HH or RH
      if P.tab ~= P.stab then P.scroll = 0 end
      if P.row ~= P.srow or P.tab ~= P.stab then P.scroll = min(max(P.scroll or 0, top + h - fit), top); P.srow, P.stab = P.row, P.tab end
      break
    end
    top = top + (r.head and HH or RH)
  end
  P.scroll = max(0, min(P.scroll or 0, rows_h - fit))
  local H = HEAD + TABH + fit + FOOT + floor(16 * s)
  if P.confirm then P.confirm = P.confirm - dt end
  local x0, y0 = floor((sw - W) / 2), floor((sh - H) / 2)
  local L = chef.TOP + 100
  local Y = function(a) return col(YEL[1], YEL[2], YEL[3], a or 255) end

  -- mouse: our own cursor from the movement while the mouse is held
  if chef.mouse_delta then
    local dx, dy = chef.mouse_delta()
    P.cx = max(0, min(sw, P.cx + (dx or 0))); P.cy = max(0, min(sh, P.cy - (dy or 0)))
    P.moved = (dx or 0) ~= 0 or (dy or 0) ~= 0
  end
  local click = chef.mouse_down('left')
  local pressed = click and not P.was_down
  P.was_down = click
  local function hit(x, y, w, h) return P.cx >= x and P.cx <= x + w and P.cy >= y and P.cy <= y + h end

  -- frame
  chef.rect(x0 + floor(6 * s), y0 - floor(6 * s), W, H, col(0, 0, 0, 120), L)
  chef.rect(x0, y0, W, H, col(12, 14, 18, 240), L + 1)
  chef.rect(x0, y0 + H - floor(4 * s), W, floor(4 * s), Y(), L + 2)
  -- header
  local ty = y0 + H - HEAD
  chef.rect(x0, ty, W, HEAD - floor(4 * s), col(20, 23, 29, 255), L + 2)
  chef.text(x0 + floor(24 * s), ty + floor(20 * s), 'SHODAN FIRST PERSON', px + 1, Y(), L + 3)
  local ver = 'V' .. M.version .. '   PROFILE ' .. V.profile .. (S.on and '   ON' or '   OFF')
  chef.text(x0 + W - floor(24 * s) - chef.text_width(ver, px), ty + floor(22 * s), ver, px,
    S.on and col(120, 220, 120, 255) or col(150, 150, 160, 255), L + 3)
  -- tabs
  local tby = ty - TABH
  local tw = floor(W / #TABS)
  for i, tab in ipairs(TABS) do
    local tx = x0 + (i - 1) * tw
    local active = i == P.tab
    if hit(tx, tby, tw, TABH) and pressed then P.tab, P.row, P.capture = i, 1, nil; active = true; list = rows() end
    chef.rect(tx, tby, tw, TABH, active and col(30, 34, 42, 255) or col(16, 18, 23, 255), L + 2)
    if active then chef.rect(tx, tby, tw, floor(3 * s), Y(), L + 3) end
    if active and P.row == 0 then
      chef.rect(tx, tby + TABH - floor(3 * s), tw, floor(3 * s), Y(), L + 3)
      chef.rect(tx, tby, floor(3 * s), TABH, Y(), L + 3); chef.rect(tx + tw - floor(3 * s), tby, floor(3 * s), TABH, Y(), L + 3)
    end
    local lw = chef.text_width(tab.name, px)
    chef.text(tx + floor((tw - lw) / 2), tby + floor(15 * s), tab.name, px,
      active and Y() or col(150, 150, 160, 255), L + 3)
  end
  -- the weapon list open: it takes the mouse, the rows under it don't
  local lpress, lmoved = pressed, P.moved
  if P.wlist then pressed, P.moved = false, false end
  P.wbox = nil
  -- rows
  local track_w = floor(200 * s)
  local ry = tby - floor(8 * s) + P.scroll
  for i, r in ipairs(list) do
    local rx, rw = x0 + floor(12 * s), W - floor(24 * s)
    ry = ry - (r.head and HH or RH)
    local off = tby - floor(8 * s) + P.scroll - ry  -- this row's bottom, from the top of the list
    if off - (r.head and HH or RH) < P.scroll - 1 or off > P.scroll + fit + 1 then  -- scrolled out
    elseif r.note then  -- gray remark over the rows below it (a heading row, so the arrows skip it)
      chef.text(rx + floor(8 * s), ry + floor(10 * s), r.head, sp, col(150, 150, 160, 255), L + 3)
    elseif r.head then
      chef.text(rx + floor(8 * s), ry + floor(10 * s), r.head, sp, Y(), L + 3)
      chef.rect(rx + floor(16 * s) + chef.text_width(r.head, sp), ry + floor(14 * s), rw - floor(24 * s) - chef.text_width(r.head, sp),
        max(1, floor(s)), Y(70), L + 3)
    else
      local hover = hit(rx, ry, rw, RH)
      if hover and (pressed or (P.moved and P.hover ~= i)) then P.row = i end  -- only a real move steals the row
      if hover then P.hover = i end
      local sel = i == P.row
      if sel then
        chef.rect(rx, ry, rw, RH, col(255, 255, 255, 14), L + 2)
        chef.rect(rx, ry, floor(3 * s), RH, Y(), L + 3)
      end
      if r.reset_tab then
        local armed = (P.confirm or 0) > 0 and P.confirm_tab == P.tab
        local t = armed and 'PRESS AGAIN TO RESET THIS TAB' or r.label
        local bx, bw, bh = rx + floor(60 * s), rw - floor(120 * s), RH - floor(10 * s)
        local by = ry + floor(5 * s)
        chef.rect(bx, by, bw, bh, armed and col(150, 40, 36, 255) or col(40, 44, 52, 255), L + 3)
        chef.text(bx + floor((bw - chef.text_width(t, px)) / 2), by + floor(9 * s), t, px, armed and col(255, 255, 255, 255) or Y(), L + 4)
        if hover and pressed then press_reset_tab() end
      elseif r.wpick then
        chef.text(rx + floor(16 * s), ry + floor(13 * s), r.label, px, sel and col(240, 240, 240, 255) or col(190, 190, 198, 255), L + 3)
        local bw, bh = floor(520 * s), floor(28 * s)
        local bx, by = rx + rw - floor(8 * s) - bw, ry + floor((RH - bh) / 2)
        local name = 'All weapons'
        if WP.sel then name = WP.LIST[WP.at()].name end
        chef.rect(bx, by, bw, bh, (P.wlist or hit(bx, by, bw, bh)) and col(52, 57, 67, 255) or col(40, 44, 52, 255), L + 3)
        chef.text(bx + floor(12 * s), by + floor(8 * s), name, px, WP.sel and Y() or col(235, 235, 235, 255), L + 4)
        local ax, ay, a = bx + bw - floor(20 * s), by + floor(bh / 2), floor(6 * s)
        chef.triangle(ax + a, ay + floor(a / 2), ax - a, ay + floor(a / 2), ax, ay - floor(a / 2), col(200, 200, 208, 255), L + 4)
        P.wbox = { bx, by, bw, bh, rx + floor(8 * s), ry }   -- the list: as wide as the row, under it
        if lpress and hit(bx, by, bw, bh) then
          if P.wlist then P.wlist = false else WP.openlist() end
        end
      else
        chef.text(rx + floor(16 * s), ry + floor(13 * s), r.label, px, sel and col(240, 240, 240, 255) or col(190, 190, 198, 255), L + 3)
        local vt = value_text(r)
        -- this row's reset button, lit while the value is not the default
        local rbw, rbh = floor(72 * s), floor(24 * s)
        local rbx, rby = rx + rw - floor(8 * s) - rbw, ry + floor((RH - rbh) / 2)
        local changed = not is_def(r)
        local onres = hit(rbx, rby, rbw, rbh)
        chef.rect(rbx, rby, rbw, rbh, changed and (onres and Y(110) or Y(55)) or col(30, 33, 40, 255), L + 3)
        chef.text(rbx + floor((rbw - chef.text_width('RESET', sp)) / 2), rby + floor(8 * s), 'RESET', sp,
          changed and col(240, 240, 240, 255) or col(90, 90, 100, 255), L + 4)
        if onres and pressed then reset(r) end
        hover = hover and not onres
        local right = rbx - floor(16 * s)
        if r.toggle then
          local bw, bh = floor(64 * s), floor(24 * s)
          local bx, by = right - bw, ry + floor((RH - bh) / 2)
          chef.rect(bx, by, bw, bh, V[r.id] and Y() or col(55, 58, 66, 255), L + 3)
          local kx = V[r.id] and bx + bw - bh or bx
          chef.rect(kx + floor(3 * s), by + floor(3 * s), bh - floor(6 * s), bh - floor(6 * s), col(14, 16, 20, 255), L + 4)
          if hover and pressed then change(r, 1) end
        elseif r.key then
          local bw = max(floor(120 * s), chef.text_width(vt, px) + floor(24 * s))
          local bx, bh = right - bw, floor(26 * s)
          local by = ry + floor((RH - bh) / 2)
          chef.rect(bx, by, bw, bh, P.capture == r.id and Y(90) or col(40, 44, 52, 255), L + 3)
          chef.text(bx + floor((bw - chef.text_width(vt, px)) / 2), by + floor(7 * s), vt, px, col(235, 235, 235, 255), L + 4)
          if hover and pressed then P.capture = r.id end
        else
          local bx, by, bh = right - track_w, ry + floor(RH / 2) - floor(2 * s), floor(4 * s)
          local t = (V[r.id] - r.min) / (r.max - r.min)
          chef.rect(bx, by, track_w, bh, col(55, 58, 66, 255), L + 3)
          chef.rect(bx, by, floor(track_w * t), bh, Y(), L + 4)
          local kn = floor(12 * s)
          chef.rect(bx + floor(track_w * t) - floor(kn / 2), by - floor(kn / 2) + floor(bh / 2), kn, kn, col(240, 240, 240, 255), L + 5)
          chef.text(bx - floor(16 * s) - chef.text_width(vt, px), ry + floor(13 * s), vt, px, Y(), L + 3)
          if hit(bx - floor(8 * s), ry, track_w + floor(16 * s), RH) and pressed then P.drag = r.id end
          if P.drag == r.id then
            if click then set(r.id, r.min + max(0, min(1, (P.cx - bx) / track_w)) * (r.max - r.min)) else P.drag = nil end
          end
        end
      end
    end
  end
  -- the weapon list under its box: wheel, the bar or the arrow keys scroll, a click picks, a click elsewhere closes.
  -- Marked: weapons with values of their own, the one in your hands
  if P.wlist and not P.wbox then P.wlist = false end   -- (its box scrolled out of view)
  if P.wlist then
    local bx, by, bw = P.wbox[5], P.wbox[6] - floor(2 * s), P.wbox[1] + P.wbox[3] - P.wbox[5]
    local IH = floor(30 * s)
    local show = max(1, min(#WP.LIST, 14, floor((by - floor(10 * s)) / IH)))
    local lh = show * IH
    local ly = by - lh
    P.wtop = P.wtop or 1
    if P.wkey then  -- the keys moved the highlight: keep it in view
      if P.wi < P.wtop then P.wtop = P.wi elseif P.wi >= P.wtop + show then P.wtop = P.wi - show + 1 end
      P.wkey = false
    end
    local inlist = hit(bx, ly, bw, lh)
    if inlist then local wv = chef.wheel(); if wv and wv ~= 0 then P.wtop = P.wtop - wv * 3 end end
    local sbw = floor(8 * s)
    local sbx = bx + bw - sbw
    if lpress and hit(sbx - floor(4 * s), ly, sbw + floor(4 * s), lh) then P.wdrag = true end
    if P.wdrag then
      if click then P.wtop = floor((by - P.cy) / lh * #WP.LIST - show / 2 + 1.5) else P.wdrag = nil end
    end
    P.wtop = max(1, min(#WP.LIST - show + 1, P.wtop))
    chef.rect(bx, ly - floor(2 * s), bw, lh + floor(2 * s), col(8, 9, 12, 250), L + 30)
    for k = 0, show - 1 do
      local i = P.wtop + k
      local w = WP.LIST[i]
      local iy = by - (k + 1) * IH
      local over = not P.wdrag and not w.head and hit(bx, iy, bw - sbw - floor(4 * s), IH)
      local cur = not w.head and w.kind == WP.sel
      if over and lmoved then P.wi = i end
      if w.head then  -- PRIMARY / SECONDARY / SUPPORT, drawn as the panel's own headings
        chef.text(bx + floor(8 * s), iy + floor(10 * s), w.name, sp, Y(), L + 32)
        local tw = chef.text_width(w.name, sp)
        chef.rect(bx + floor(16 * s) + tw, iy + floor(14 * s), bw - sbw - floor(28 * s) - tw, max(1, floor(s)), Y(70), L + 32)
      end
      if i == P.wi and not w.head then chef.rect(bx, iy, bw - sbw, IH, col(255, 255, 255, 22), L + 31) end
      if cur then chef.rect(bx, iy, floor(3 * s), IH, Y(), L + 32) end
      if not w.head then chef.text(bx + floor(12 * s), iy + floor(9 * s), w.name, px, cur and Y() or col(225, 225, 230, 255), L + 32) end
      local tag = w.kind and w.kind == S.wheld and 'IN HAND' or ''
      if w.kind and WP.marked(w.kind) then tag = tag .. (tag ~= '' and '  ' or '') .. 'EDITED' end
      if tag ~= '' then
        chef.text(sbx - floor(12 * s) - chef.text_width(tag, sp), iy + floor(10 * s), tag, sp, Y(200), L + 32)
      end
      if over and lpress then WP.pick(w.kind); list = rows() end
    end
    local th = max(floor(20 * s), floor(lh * show / #WP.LIST))
    local tt = by - floor((lh - th) * (P.wtop - 1) / max(1, #WP.LIST - show))
    chef.rect(sbx, ly, sbw, lh, col(30, 33, 40, 255), L + 31)
    chef.rect(sbx, tt - th, sbw, th, P.wdrag and Y() or Y(150), L + 32)
    if P.wlist and lpress and not inlist and not hit(P.wbox[1], P.wbox[2], P.wbox[3], P.wbox[4]) then P.wlist = false end
  end
  if rows_h > fit and not P.wlist and hit(x0, tby - fit, W, fit) then
    local wv = chef.wheel(); if wv and wv ~= 0 then P.scroll = max(0, min(rows_h - fit, P.scroll - wv * RH)) end
  end
  -- scrollbar in the right margin: drag the thumb, or click the track to jump there
  if rows_h > fit then
    local bw, btop = max(3, floor(6 * s)), tby - floor(8 * s)
    local bx = x0 + W - floor(9 * s)
    local th = max(floor(30 * s), floor(fit * fit / rows_h))
    local tt = btop - floor((fit - th) * P.scroll / (rows_h - fit))  -- thumb top
    if pressed and hit(bx - floor(6 * s), btop - fit, bw + floor(12 * s), fit) then
      P.sgrab = (P.cy <= tt and P.cy >= tt - th) and tt - P.cy or floor(th / 2)
    end
    if P.sgrab then
      if click then
        P.scroll = max(0, min(rows_h - fit, (btop - (P.cy + P.sgrab)) / (fit - th) * (rows_h - fit)))
        tt = btop - floor((fit - th) * P.scroll / (rows_h - fit))
      else P.sgrab = nil end
    end
    chef.rect(bx, btop - fit, bw, fit, col(30, 33, 40, 255), L + 3)
    chef.rect(bx, tt - th, bw, th, P.sgrab and Y() or Y(150), L + 4)
  end
  -- footer: the row's hint and the keys
  local sel = list[P.row]
  local fy = y0 + floor(12 * s)
  local hint = P.row == 0 and 'LEFT and RIGHT switch tabs. DOWN goes to the settings.' or sel and sel.hint or ''
  local lines = chef.text_wrap and chef.text_wrap(hint, sp, W - floor(48 * s), 2) or { hint }
  for i, l in ipairs(lines) do
    chef.text(x0 + floor(24 * s), fy + floor(44 * s) - (i - 1) * floor(18 * s), l, sp, col(170, 170, 180, 255), L + 3)
  end
  local function kl(id)  -- '' when the key is set to none
    local k = binds[id] and binds[id].key() or 'off'
    return k == 'off' and '' or (chef.key_label and chef.key_label(k) or k):upper()
  end
  local tabs = kl('tab_prev') .. ((kl('tab_prev') ~= '' and kl('tab_next') ~= '') and ' & ' or '') .. kl('tab_next')
  local keys = 'Arrow keys: Move / Left & Right: Change / Delete: Default' .. (tabs ~= '' and ' / ' .. tabs .. ': Tabs' or '') ..
    (kl('panel') ~= '' and ' / ' .. kl('panel') .. ': Close' or '')
  chef.text(x0 + floor(24 * s), fy, keys, sp, col(110, 110, 120, 255), L + 3)
  -- cursor
  if chef.mouse_delta then
    local c = floor(14 * s)
    chef.triangle(P.cx, P.cy, P.cx, P.cy - c, P.cx + c * 0.7, P.cy - c * 0.7, col(255, 255, 255, 255), L + 20)
  end
end

local function panel_keys(dt)
  local list = rows()
  -- a Ctrl held for one capture is never bound by another (a tab or another row's key clicked while holding it)
  if P.capfor ~= P.capture then P.capmod, P.capfor = nil, P.capture end
  if P.capture then
    if chef.key_pressed('delete') then chef.set(P.capture, 'off'); P.capture, P.capmod = nil, nil; return end
    -- with the loader's key combos (1.4.0): the modifiers held bind a combo (Ctrl+Shift+F6); Ctrl or Alt pressed and
    -- let go with no key between binds it on its own. Without them, every key binds as it's pressed.
    local combos = chef.has and chef.has('bind_combos')
    for _, k in ipairs(CAPTURE_KEYS) do
      if chef.key_pressed(k) then
        if combos and CAPTURE_MOD[k] then P.capmod = P.capmod or k
        else
          local pre = ''
          if combos then
            for _, m in ipairs(P.COMBO) do
              if chef.key_down('left ' .. m) or chef.key_down('right ' .. m) then pre = pre .. m .. '+' end
            end
          end
          chef.set(P.capture, pre .. k); P.capture, P.capmod = nil, nil; return
        end
      end
    end
    if P.capmod and not chef.key_down(P.capmod) then
      local other
      for _, m in ipairs(P.MODLIST) do if m ~= P.capmod and chef.key_down(m) then other = m end end
      if other then P.capmod = other   -- Ctrl let go while Alt is still held: Alt is the one now
      else chef.set(P.capture, P.capmod); P.capture, P.capmod = nil, nil end
    end
    return
  end
  if P.wlist then  -- the weapon list open: the keys move in it
    local d = (chef.key_pressed('down') and 1 or 0) - (chef.key_pressed('up') and 1 or 0) +
      (chef.key_pressed('page down') and 10 or 0) - (chef.key_pressed('page up') and 10 or 0)
    if d ~= 0 then
      local i = max(1, min(#WP.LIST, (P.wi or 1) + d))
      if WP.LIST[i].head then i = i + (d > 0 and 1 or -1) end   -- (headings are never next to each other or last)
      P.wi, P.wkey = i, true
    end
    if chef.key_pressed('enter') then WP.pick(WP.LIST[P.wi or 1].kind)
    elseif chef.key_pressed('escape') or chef.key_pressed('left') or chef.key_pressed('right') then P.wlist = false end
    return
  end
  local cur = list[P.row]
  if cur and cur.wpick and chef.key_pressed('enter') then
    WP.openlist()
    return
  end
  if chef.key_pressed('up') then P.row = skip_heads(list, P.row > 0 and P.row - 1 or #list, -1) end
  if chef.key_pressed('down') then P.row = skip_heads(list, P.row < #list and P.row + 1 or 0, 1) end
  if binds.tab_prev.pressed() then P.tab = P.tab > 1 and P.tab - 1 or #TABS; P.row = 1 end
  if binds.tab_next.pressed() then P.tab = P.tab < #TABS and P.tab + 1 or 1; P.row = 1 end
  if P.row == 0 then
    if chef.key_pressed('left') then P.tab = P.tab > 1 and P.tab - 1 or #TABS end
    if chef.key_pressed('right') then P.tab = P.tab < #TABS and P.tab + 1 or 1 end
    return
  end
  P.row = skip_heads(rows(), P.row, 1)  -- a tab switch or click can land on a heading
  local r = rows()[P.row]
  if not r then P.row = 1; return end
  if chef.key_pressed('delete') then reset(r) end
  -- held arrows repeat on sliders
  local dir = (chef.key_down('right') and 1 or 0) - (chef.key_down('left') and 1 or 0)
  local first = chef.key_pressed('right') or chef.key_pressed('left')
  if dir == 0 then P.rep = 0
  elseif first then change(r, dir); P.rep = 0.35
  elseif not r.toggle and not r.key and not r.reset_tab then
    P.rep = P.rep - dt
    if P.rep <= 0 then change(r, dir); P.rep = 0.05 end
  end
end

---------------------------------------------------------------------------------------------------- frame
-- dying: the game crashed (twice, 2026-11-07) about 3 s after the Helldiver was blown down and killed, with the
-- view still in the dead body (a fall through the dive path, so 'knocked down' never handed over). A new Helldiver
-- showing up (the reinforcement), or the cameras changing while lying down = the game's view until someone stands.
local function death_check()
  if not chef.in_mission() then S.corpse_h = nil; S.dead, S.corpse, S.corpses, S.avs, S.av_gen, S.down_any = false, nil, nil, nil, nil, false; return end
  local lying = S.head and (S.stance == 'prone' or S.down or S.dive)
  S.down_any = lying or S.dead or S.getup or false
  if cam_watch.generation ~= S.dgen then
    S.dgen = cam_watch.generation
    local set, changed = {}, false
    for _, it in ipairs(cam_watch.items) do set[it.unit] = true; if S.dcams and not S.dcams[it.unit] then changed = true end end
    for u in pairs(S.dcams or {}) do if not set[u] then changed = true end end
    S.dcams = set
    if changed and lying and not S.dead then
      S.dead, S.dsure, S.dead_u = true, S.down and true or false, S.head.u  -- knocked down: sure; prone or after a dive: a guess
      log('cameras changed while lying (%s): game camera until up', S.stance or '?')
    end
  end
  local h = S.head
  -- in the reinforcement pod the new Helldiver counts as up (its pod pose isn't lying): the hellpod view rule takes over
  -- there, as on the mission's first drop (it waited for the step out)
  if S.dead and h and not is_corpse(h.u) and (S.pod or not lying) then S.dead = false; log('up: first person again%s', S.pod and ' (in the pod)' or '') end
  if not S.dead then S.dsure, S.dead_u = nil, nil end
end

-- give the camera and every hidden mesh back to the game and start again as in a new world: the next frame picks
-- your Helldiver again. First person comes back on or off as it was.
-- what to come back as: on or off as it was once first person was decided this world (started, or switched on); before
-- that nil, so Start in first person still decides
local function keep_as() if S.on or S.started then return S.on end end
-- the person's on/off (the key or the controller): while a reset waits for its pick, this is what it will keep
local function user_toggle()
  set_on(not S.on)
  if S.keep ~= nil then S.keep = S.on end
  say(S.on and 'FIRST PERSON ON' or 'FIRST PERSON OFF')
end
-- what a restart in the same world carries (the reset key): a death known for certain (the animation gone: the body
-- is a corpse, and the reinforcement's drop picks the next). Your Helldiver itself is forgotten (reset_camera).
--   a death as it stood: certain, a corpse never picked again; a guess (the cameras changing while lying), your
--     Helldiver picked again while lying (the game camera: dead), and standing up ends the guess
--   the drop in progress (one drop per fall, the bodies followed down), and the body's stance as measured
local function carry()
  -- a certain death's body is already a corpse (anim() marks it); the head can also be the reinforcement, picked
  -- while that death is still held (the fall, the landed pod): it's yours and alive, so it's kept
  local c = { w = chef.world_id(), dead = S.dead or false, dsure = S.dead and S.dsure or nil, drop_t = S.drop_t,
    drop_held = S.drop_held, avtop = S.avtop,
    avfollow = S.avfollow, corpse = S.corpse, corpses = S.corpses, corpse_h = S.corpse_h, dead_u = S.dead and S.dead_u or nil,
    pod = { ad = S.ad, aw = S.aw, podu = S.podu, pod = S.pod, puse = S.puse,
      away = S.away, away_t = S.away_t, spod = S.spod, slow_t = S.slow_t, sup_t = S.sup_t, shmax = S.shmax,
      nopod = S.nopod, mdrop = S.mdrop, pfall_t = S.pfall_t, calm_t = S.calm_t, wglide = S.wglide },
    mine = not is_corpse(S.mine) and S.mine or nil }
  if S.head then c.body = { u = S.head.u, hmax = S.hmax, stance = S.stance, down = S.down } end
  S.carry = c
end
local function reset_camera(why)
  local was = keep_as()
  -- a second reset before the re-pick: the first one's on/off (still waiting: off, and not started)
  if was == nil and S.keep ~= nil and S.keep_w == chef.world_id() then was = S.keep end
  carry()
  -- your Helldiver is forgotten and picked again by where the game camera sits (cam_pick, then cam_confirm): the way
  -- out of a wrong pick, which the kept one locked in (2026-11-12). Not while dead: the camera follows a teammate then.
  -- The bodies seen falling are dropped too, so only the camera decides (a body never seen falling was left out)
  if not S.dead then S.carry.mine, S.carry.body, S.carry.drop_t, S.carry.avtop, S.carry.avfollow = nil, nil, S.t, {}, {} end
  set_on(false, true)
  S.world, S.keep, S.keep_w = nil, was, chef.world_id()
  log('camera reset (%s)', why)
end

-- joining a lobby tears worlds down while the loader still hands out the same main world (2 of 4 joins with first
-- person on the ship crashed, 2026-11-11/12: the game camera going 'far', the game gone within 0.1 s, no error of
-- ours). So a main world missing from the game's list of worlds is going away: touch nothing; and any change to that
-- list drops every handle first, without a call on any of them. A fresh start in the same world keeps your Helldiver
-- and first person on/off, as a reset does
local function drop_handles(why)
  local was = keep_as()
  if was == nil and S.keep ~= nil and S.keep_w == chef.world_id() then was = S.keep end
  carry()
  S.world, S.keep, S.keep_w = nil, was, chef.world_id()
  S.cams, S.head, S.parts, S.hidden, S.uhid, S.ghid, S.gst = {}, nil, {}, {}, {}, {}, {}
  S.act, S.on, S.tx, S.handing, S.glass_u, S.sglass_u = false, false, nil, false, nil, nil
  log('handles dropped: %s', why)
end
local function world_gone()
  local w = chef.world()
  local ws = w and call('Application.worlds')
  if type(ws) ~= 'table' then return false end
  local listed, sig = false, { #ws }
  for i = 1, #ws do listed = listed or ws[i] == w; sig[#sig + 1] = tostring(ws[i]) end
  sig = table.concat(sig, ' ')
  if not listed then
    if not S.wgone then S.wgone = true; drop_handles('the world is going away (not in the list of worlds)') end
    S.wsig = nil
    return true
  end
  S.wgone = nil
  -- (a new world id is the usual world change, which starts fresh by itself without carrying anything over)
  if S.wsig and sig ~= S.wsig and chef.world_id() == S.world then
    -- in a mission this only ever happens as its outro starts, ~21 s before the summary (all 4 mission ends, 2026-11-13 logs)
    if chef.in_mission() and S.mend ~= S.world then S.mend = S.world; log('mission end: the outro started, game camera') end
    drop_handles(string.format('the list of worlds changed (%d worlds)', #ws))
  end
  S.wsig = sig
  return false
end

-- the controller toggle (KEYS tab): with no hold button a press of Controller: first person on/off toggles; with one,
-- a double tap (the second within 0.35 s) while it's held. Either held 1 s (the second press of a double tap): reset
-- camera instead. It fires on letting go, so a hold never toggles first.
local PADT = { was = false, dwas = false, t0 = 0, tap = -1, armed = false, fired = false }
local function pad_step()
  local b, h = binds.pad_toggle, binds.pad_hold
  if not b or b.key() == 'off' then PADT.was, PADT.dwas, PADT.armed = false, false, false; return end
  -- the loader's menu open: binds read up, which looked like letting go. Held through it, nothing fires until let go
  local menu = chef.has and chef.has('menu_state') and chef.menu_open and chef.menu_open() or false
  if menu then PADT.block = true end
  if PADT.block then
    if not menu and not b.down() then PADT.block = false end
    PADT.was, PADT.dwas, PADT.armed = false, false, false
    return
  end
  local d = b.down()
  local active = d
  if h and h.key() ~= 'off' then
    local held = h.down()
    if not held then PADT.tap, PADT.armed = -1, false end
    d = d and held
    if d and not PADT.dwas then
      if S.t - PADT.tap < 0.35 then PADT.armed, PADT.tap = true, -1 else PADT.tap = S.t end
    end
    if not d then PADT.armed = false end
    PADT.dwas = d
    active = d and PADT.armed
  end
  if active and not PADT.was then PADT.t0, PADT.fired = S.t, false end
  if active and not PADT.fired and S.t - PADT.t0 >= 1 then
    -- at the start of the next step, as the key's: here the rest of this frame would run on the old camera list
    PADT.fired = true; S.reset_req = 'controller hold'
  end
  if not active and PADT.was and not PADT.fired then user_toggle() end
  PADT.was = active
end

-- the Pelican at extraction: the game camera aboard, like the Gator (user 2026-11-11)
local function pelican_step(on, l14)
  if on and not S.pel then log('boarding the Pelican (layer 14 = %s)', tostring(l14))
  elseif not on and S.pel then log('out of the Pelican') end
  S.pel = on
end

-- the seats known only by the seat layer (the Gator, the Pelican; the tank crew's seat): read with the other layers,
-- held 1 s through a frame the layers aren't read (the camera settling, a check refused)
local function seat_layer_step(dt)
  -- (also the new pieces' mesh probe and the re-hide window: step is at Lua 5.1's 60-upvalue limit)
  if probe_one() or (S.rehide and S.t < S.rehide) then apply_hiding() end
  local L = chef.in_mission() and S.head and layers()
  if L then S.l14, S.l14_t = L[14], S.t
  elseif S.l14_t and S.t - S.l14_t > 1 then S.l14, S.l14_t = nil, nil end
  -- stationary reload (STATIONARY RELOAD offsets), layer 11 (avatar_states.txt layer 10), standing or crouched: 688
  -- Recoilless, 689 Airburst, 690/691 Autocannon (normal/fast), 718 Spear, 719 WASP (log 2026-11-13), 655/656 MG-206 HMG (log 2026-11-14),
  -- 665/666 MG-43 (reload_mg), 685 Epoch (reload_plasmablaster). Prone ones (235, 236, 245, 246, 265, 268, 269, 274, 275, 302) left out
  local l11 = L and L[11]
  local srl = l11 == 655 or l11 == 656 or l11 == 665 or l11 == 666 or l11 == 685 or l11 == 688 or l11 == 689 or l11 == 690 or l11 == 691
    or l11 == 718 or l11 == 719
  if srl ~= (S.srl or false) then S.srl = srl; log('stationary reload %s (layer 11 = %s)', srl and 'start' or 'end', tostring(l11)) end
  -- sliding (SLIDING offsets), layer 2 (avatar_states.txt layer 1): 2/3 slide + exit from a crouch, 40/41 from standing;
  -- 31/32 and 69/70 slope slides (back/forward) crouched and standing. Prone slope slides (37/38) are lying: left out
  local l2 = L and L[2]
  local sl = l2 == 2 or l2 == 3 or l2 == 40 or l2 == 41 or l2 == 31 or l2 == 32 or l2 == 69 or l2 == 70
  -- the slide state lasts only 0.2-0.3 s while the body slides on: layer 2 goes 2 -> 1 -> 3 -> 4 -> 5 -> 43 (or 42),
  -- standing at ~1.1 s (log 2026-11-14), so the offsets dropped mid-slide and it clipped at the end. Held while layer 2
  -- stays in that sequence, until you have stood or slowed under 1 m/s for 0.25 s (at most 2 s after the slide state).
  -- While held, no prone, dive or knockdown: low slides (head 0.57 m) read as both and ran the get-up for ~1 s
  if sl then S.slide_t, S.slide_ok = S.t, nil
  elseif S.slide and S.slide_t then
    local vx, vy = S.vx or 0, S.vy or 0
    if S.stance == 'stand' or vx * vx + vy * vy < 1 then S.slide_ok = S.slide_ok or S.t else S.slide_ok = nil end
    sl = (l2 == 1 or l2 == 4 or l2 == 5 or l2 == 42 or l2 == 43) and not (S.slide_ok and S.t - S.slide_ok >= 0.25 or S.t - S.slide_t > 2)
  end
  if sl ~= (S.slide or false) then
    S.slide = sl
    log('slide %s (layer 2 = %s, %s, %.1f m/s)', sl and 'start' or 'end', tostring(l2), S.stance or '?', sqrt((S.vx or 0) ^ 2 + (S.vy or 0) ^ 2))
  end
  local l14 = type(S.l14) == 'number' and S.l14 or -1
  S.tl14 = L14.TANK[l14]
  local g = L14.GATOR[l14] or false
  if g ~= S.gator then
    S.gator = g
    log(g and ('Gator seat: ' .. (g == 'ggun' and 'gunner' or 'driver') .. ' (layer 14 = %d)') or 'out of the Gator', l14)
  end
  pelican_step(L14.PELICAN[l14] ~= nil and S.head ~= nil, l14)
end

local function step(dt)
  local busy = P.capture ~= nil
  if S.reset_req then reset_camera(S.reset_req); S.reset_req = nil; say('CAMERA RESET') end
  if not busy and binds.reset_key and binds.reset_key.pressed() then reset_camera('reset key'); say('CAMERA RESET') end
  if not busy and binds.panel and binds.panel.pressed() then open_panel(not P.open) end
  if P.open then panel_keys(dt) end
  P.wapply(dt)
  -- works on the ship too; nil while a world loads
  local w = chef.world()
  if not w then
    set_on(false, true)
    S.started = nil
    if P.open then draw_panel(dt) end
    return
  end
  if chef.world_id() ~= S.world then
    S.started = nil  -- new world (ship <-> mission): old units are gone, start fresh
    if S.keep_w ~= chef.world_id() then S.keep = nil end  -- a reset's on/off is for the world it happened in
    S.world, S.cams, S.head, S.hidden, S.parts, S.on, S.tx = chef.world_id(), {}, nil, {}, {}, false, nil
    S.ghid, S.gst, S.gsaid = {}, {}, {}
    S.last_scan, S.rescans, S.cam_gen = nil, {}, nil
    S.hr, S.gfov, S.ghip, S.asm, S.adead, S.gheld, GR.d, GR.st = nil, nil, nil, {}, nil, nil, nil, {}
    S.gnd, S.gnd_t, S.fzp, S.ph, S.bad = nil, nil, nil, nil, nil
    S.bw, S.shown, S.handing, S.held = 0, false, false, nil
    S.ad, S.aw, S.podu, S.puse, S.pod = nil, nil, nil, false, false
    S.away, S.away_t, S.spod, S.slow_t, S.sup_t, S.shmax, S.nopod, S.mdrop, S.pfall_t = false, 0, false, 0, 0, nil, false, nil, 0
    S.calm_t = 0
    S.reject, S.confirm, S.lone, S.pcam, S.gcam = {}, nil, nil, nil, nil
    S.down_any, S.getup, S.rising = false, false, false
    S.act, S.down, S.stance, S.hmax, S.fv = false, false, nil, nil, nil
    S.mech, S.mech_it, S.frv, S.empl, S.tank, S.tpass = false, false, false, false, false, false
    S.tcrew, S.gator, S.pel, S.l14, S.l14_t = false, false, false, nil, nil
    S.dead, S.corpse, S.corpses, S.avs, S.av_gen, S.dgen, S.dcams = false, nil, nil, nil, nil, nil, nil
    S.corpse_h = nil
    S.mine, S.drop_t, S.fall_t, S.lcz, S.fall_max, S.avtop, S.avfollow = nil, nil, 0, nil, 0, {}, {}
    S.drop_held = nil
    S.dsure, S.shipfov, S.dead_u, S.wglide = nil, nil, nil, nil
    local c = S.carry
    if c and c.w == S.world then
      S.dead, S.dsure, S.drop_t, S.corpse, S.corpses, S.mine = c.dead, c.dsure, c.drop_t, c.corpse, c.corpses, c.mine
      S.drop_held, S.avtop, S.avfollow, S.body_kept = c.drop_held, c.avtop, c.avfollow, c.body
      S.dead_u, S.corpse_h = c.dead_u, c.corpse_h
      for k, v in pairs(c.pod) do S[k] = v end
    else
      S.body_kept = nil
    end
    S.carry = nil
    -- mission end hold (update_act): from leaving a mission any way (or its outro, world_gone) until the ship's pick is
    -- confirmed; a new mission ends it. The outro's restart in the same mission world keeps it
    local mis = chef.in_mission()
    if S.wmis and not mis and not S.mend then S.mend = true; log('mission end: left the mission, game camera')
    elseif mis and S.mend and S.mend ~= S.world then S.mend = nil end
    S.wmis = mis
  end
  S.t, S.fno = S.t + dt, (S.fno or 0) + 1
  -- the game camera falling 25+ m/s for 0.25 s = a hellpod coming down (a single-frame jump is a camera cut; 12+ m/s
  -- is kept for the camera following a body down)
  local gc = chef.camera()
  if gc and S.lcz and dt > 0 and dt < 0.1 then
    local vz = (gc.z - S.lcz) / dt
    if vz < 0 then S.fall_max = max(S.fall_max or 0, -vz < 150 and -vz or 0) end
    S.fall_t = (vz < -12 and vz > -150) and (S.fall_t or 0) + dt or 0
    S.pfall_t = (vz < -25 and vz > -150) and (S.pfall_t or 0) + dt or 0
    S.calm_t = vz > -12 and (S.calm_t or 0) + dt or 0
    -- (12 m/s was also a 15 m ledge, yours or a spectated teammate's: it opened the multiplayer pick for 30 s)
    -- one drop per fall: your Helldiver picked mid-fall clears drop_t, and the same fall must not set it again (the
    -- pick would stay open 30 s more and take the Helldiver nearest the camera at the next rescan)
    if S.calm_t >= 0.5 then S.drop_held = nil end
    if S.pfall_t >= 0.25 and not drop_seen() and not S.drop_held then
      S.drop_t, S.drop_held = S.t, true
      if others_here() then log('hellpod drop seen (game camera falling %.0f m/s)', -vz) end
    end
  elseif not gc then
    S.calm_t = 0
  end
  S.lcz = gc and gc.z
  refresh_cams()
  S.look = S.look - dt
  if S.look <= 0 then S.look = 0.5; check_player(w); apply_hiding() end
  seat_layer_step(dt)
  S.frv_t = S.frv_t - dt
  if S.frv_t <= 0 then
    S.frv_t = 0.25
    local it, x, y, z, over = inside(frv_watch, true, S.frv_u)
    -- over the car: the gun once it holds 0.5 s (cars with one); climbing over a car from outside isn't a seat
    S.frv_over = over and (S.frv_over or 0) + 1 or 0
    local gun = over and FRV_GUN[it.kind] and S.frv_over >= 2
    if over and not gun and not S.frv then it = nil end
    -- diving or lying next to a car can put the head inside its box: only a seat animation counts then
    if it and S.diving and not S.frv and not FRV_ANIM[seat_anim()] then it = nil end
    if it then S.frv = frv_seat(it, x, y, z, gun)
    else
      it = frv_near()
      local was = S.frv
      S.frv = it and FRV_ANIM[seat_anim()] or false
      if S.frv and not was then log('FRV %s seat %s from the animation, head not in the car yet', it.kind, S.frv) end
    end
    S.frv_pre = it and FRV_PRE[it.kind] or ''
    S.frv_u = S.frv and it and it.unit or nil
    if not it then S.seat = nil end
    -- tank seats are known by animation alone, so the tank is just the nearest one: no engine call on a tank to find
    -- it. The one engine call: a passenger's view asks the hull's facing, and only of a tank that has settled (seen
    -- 3 s, not dropping or tumbling), as a car's is
    local tk = false
    -- every listed tank's settle clock runs (the watch's own spot: no engine call), so one already sitting there 3 s
    -- counts as settled the moment you climb in
    if tank_watch then for _, t in ipairs(tank_watch.items) do settled(t) end end
    local tl14 = S.tl14
    if (TANK_ANIM[seat_anim()] or tl14) and tank_watch and S.head then
      local hx, hy = upos(S.head.u, S.head.node)
      local td = 7
      for _, t in ipairs(hx and tank_watch.items or {}) do
        local d = abs(t.x - hx) + abs(t.y - hy)
        if d < td then tk, td = t, d end
      end
    end
    -- a seat animation held 0.5 s to get in, 0.5 s without one to get out (standing on top isn't a seat)
    local sit = tk and (TANK_ANIM[seat_anim()] ~= nil or tl14 ~= nil)
    S.tank_on = sit and (S.tank_on or 0) + 1 or 0
    S.tank_off = sit and 0 or (S.tank_off or 0) + 1
    if sit and (S.tank or S.tank_on >= 2) then
      -- settled once = settled while you stay in it (driving up a slope restarts settled()'s clock every 0.5 m of
      -- height, which flipped the offsets between the hull and the look)
      local was = S.tank and S.tank.u == tk.unit and S.tank.still
      S.tank = { seat = tank_seat(tk), tp = TANKS[tk.kind].tp, id = TANKS[tk.kind].id, u = tk.unit,
        still = was or settled(tk) }
    elseif S.tank and S.tank_off >= 2 then
      S.tank, S.tseat = false, nil; log('out of the tank')
    end
    S.tpass = S.tank and S.tank.seat == 'passenger' and S.tank.id or false
    -- the crew seats in first person (opt-in): their own offsets, the driver's along the hull
    S.tcrew = S.tank and (S.tank.seat == 'crew' and V.tgun_fp and 'tgun' or S.tank.seat == 'driver' and V.tdrv_fp and 'tdrv') or false
    local mech = inside(mech_watch, nil, S.mech)
    S.mech_pre = mech and mech_model(mech) or ''
    S.mech_it = mech or false
    mech = mech and mech.unit or false
    if mech ~= S.mech then
      local nm = '?'
      for _, m in ipairs(MECHS) do if m.pre == S.mech_pre then nm = m.name end end
      if mech then log('in a mech (%s)', nm) else log('out of the mech') end
    end
    local body = S.mech_it and HUD.body(S.mech_it) or false
    if body ~= S.glass_u then HUD.glass(S.glass_u, false); S.glass_u = body; HUD.glass(body, true) end
    HUD.shield(S.mech_it)
    HUD.glass_sweep()
    S.mech, S.empl = mech, at_emplacement()
  end
  -- after a reset (the key, or an error the mod got over): first person as it was, whatever Start on says
  if S.keep ~= nil and S.head then
    S.started = true
    if S.keep then set_on(true) end
    S.keep = nil
  elseif V.start_on and not S.started and S.head then S.started = true; set_on(true) end
  if not busy and binds.toggle and binds.toggle.pressed() then user_toggle() end
  if not busy and binds.tp_key and binds.tp_key.pressed() then S.tpk_on = not S.tpk_on; log('third person key: %s', S.tpk_on and 'on' or 'off') end
  if not busy then pad_step() end
  if not busy and binds.profile_key and binds.profile_key.pressed() then
    set('profile', V.profile % 5 + 1); apply_hiding(); say('PROFILE ' .. V.profile)
  end
  S.dt = dt
  death_check()
  pod_guard(dt)
  -- the game's view on the ship (its cutscene camera, or in a pod): the body isn't
  -- followed until it's back
  local ship_off = not chef.in_mission() and (S.away or S.pod)
  -- (and while gliding out after switching off: else the glide heads for the spot the head was at the key press)
  if (S.on or S.bw > 0) and S.head and not ship_off then target(dt) end
  if S.on and V.tp_galaxy then galaxy_check(dt) else S.galaxy = false end   -- every frame: the head shows at once
  if S.on and (V.tp_term or V.term_fov ~= 0 or V.term_face) then term_check() else S.term = false end
  if S.on then pod_check() else S.puse = false end
  menu_check()
  update_act()
  glide(dt)
  -- aiming (right mouse, held or toggled): its own field of view, blended; 0 = the same as the normal one
  local rmb = not P.open and chef.mouse_down('right') or false
  if V.aim_toggle then
    if rmb and not S.rmb then S.aim = not S.aim end
  else S.aim = rmb end
  S.rmb = rmb
  -- Aim from the game: its upper-body layer aims at 59 standing, 53 prone, and 0 crouched (the legs' layer 2 or 3).
  -- The game knows a toggle and a controller trigger the mouse button doesn't; with no layers (a seat check refused,
  -- the camera settling) the mouse button decides as before
  if V.aim_game and not P.open and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) then
    local L = layers()
    if L then
      local l4, l22 = L[4], L[22]
      S.aim = l4 == 59 or l4 == 53 or (l4 == 0 and (l22 == 2 or l22 == 3)) or (rmb and not V.aim_toggle) or false
    end
  end
  -- Distance while running: the legs' layer at 7 (running or sprinting) for 0.3 s, not aiming, on foot
  local runl = false
  if V.run_dist > 0 and not S.aim and not (S.frv or S.mech or S.empl or S.tank or S.gator or S.pel) then
    local L = layers()
    runl = L ~= nil and L[22] == 7
  end
  if runl then S.run0 = S.run0 or S.t else S.run0 = nil end
  local ra = S.run0 ~= nil and S.t - S.run0 >= 0.3
  if ra ~= (S.runaim or false) then log('aim: %s', ra and string.format('running, lined up at %d m', V.run_dist) or 'running ended') end
  S.runaim = ra
  neck(w)
  HUD.free_step(dt)
  -- in a mech the game narrows its view as the mech aims: first person keeps the widest seen in this mech. The game
  -- camera cutting somewhere else (1.5 m in a frame: from the on-foot camera while climbing in to the mech's own)
  -- starts the learning again, so the on-foot field of view is never taken as the mech's; an aim zoom keeps its spot
  if S.mech then
    local g = S.mgc
    if S.gcx and (not g or (S.gcx - g[1]) ^ 2 + (S.gcy - g[2]) ^ 2 + (S.gcz - g[3]) ^ 2 > 2.25) then S.mwide, S.mwt = nil, S.t end
    if S.gcx then S.mgc = S.mgc or {}; S.mgc[1], S.mgc[2], S.mgc[3] = S.gcx, S.gcy, S.gcz end
    S.mwt = S.mwt or S.t
  end
  if S.mech and S.act and S.gfov and S.t - S.mwt >= 0.1 then S.mwide = max(S.mwide or S.gfov, S.gfov)
  elseif not S.mech then S.mwide, S.md, S.mg, S.mwt, S.mgc = nil, nil, nil, nil, nil end
  local mfv = S.mech and V[S.mech_pre .. 'mech_fov']
  if mfv == 0 and V.fov == 0 and S.act and V[S.mech_pre .. 'mech_wide'] and S.mwide then mfv = S.mwide end
  local vf = S.frv and V[S.frv_pre .. 'frv_fov'] or S.tpass and V[S.tpass .. '_fov'] or S.mech and mfv
    or S.empl and V[S.empl_pre .. 'empl_fov'] or S.tank and 0
    or (S.act or S.bw > 0) and (S.stance == 'crouch' and V.crouch_fov or S.stance == 'prone' and V.prone_fov) or 0  -- stance: first person only (and its glide out)
  -- the game's hip field of view (a slow average while not aiming): how much the game zooms for the weapon in hand is
  -- its field of view now over that. Only from the game's own values (place reads them), so with nothing read it's 1.
  -- Learned only 0.6 s after letting go of aim: the game's zoom is still coming back out before that
  S.unaim_t = S.aim and 0 or (S.unaim_t or 0) + dt
  if S.gfov and not S.aim and (not S.ghip or S.unaim_t >= 0.6) then
    S.ghip = S.ghip and S.ghip + (S.gfov - S.ghip) * (1 - exp(-dt * 2)) or S.gfov
  end
  -- the game's aim zoom as a magnification: tan(half its aim angle) over tan(half its hip angle), applied the same way
  -- to ours, so a wide view zooms as much as the game's does (a share of the angle zoomed a 100 deg view far more).
  -- Extra aim zoom then narrows the angle by its percentage
  local mag, extra = 1, 1
  -- (not in a mech keeping its widest view: the game's narrowing there is the mech aiming, not a zoom to follow)
  if S.act and S.aim and V.aim_fov == 0 and not (S.mech and V[S.mech_pre .. 'mech_wide']) then
    if V.aim_zoom_game and S.gfov and S.ghip and S.ghip > 1 then
      mag = max(0.15, min(1.2, math.tan(math.rad(S.gfov) / 2) / math.tan(math.rad(S.ghip) / 2)))
    end
    extra = max(0.15, (1 - V.aim_zoom / 100) * (1 - (S.shield and V.shield_zoom or 0) / 100))
  end
  -- Field of view at GAME: nothing written, except while aiming with a zoom of our own (Extra aim zoom, or not
  -- following the game's): then from the game's hip field of view
  local base = vf > 0 and vf or V.fov > 0 and V.fov
    or (S.act and S.aim and (V.aim_zoom > 0 or (S.shield and V.shield_zoom > 0) or not V.aim_zoom_game) and S.ghip) or 0
  if mag ~= 1 and base > 0 then base = 2 * math.deg(math.atan(math.tan(math.rad(base) / 2) * mag)) end
  local want = (S.act or S.bw > 0) and (S.aim and V.aim_fov > 0 and V.aim_fov or base * extra) or vf
  -- a terminal in first person: Terminal field of view change on top (from the game's own at GAME)
  if S.act and S.term and V.term_fov ~= 0 and not V.tp_term then
    local b0 = want > 0 and want or S.ghip or S.gfov
    if b0 then want = max(10, min(150, b0 + V.term_fov)) end
  end
  -- Sprint zoom-out (HUD.lean eases S.spr to 0 while aiming, lying or seated, so it only widens a sprint on foot)
  if S.act and V.sprint_fov > 0 and (S.spr or 0) > 0.01 then
    local b0 = want > 0 and want or S.ghip or S.gfov
    if b0 then want = min(150, b0 + V.sprint_fov * S.spr) end
  end
  -- (nothing written yet at Field of view GAME: the zoom starts from the game's own, not in one jump)
  local from = S.fv or (S.act and V.fov == 0 and vf == 0 and S.gfov)
  if want > 0 then S.fv = from and from + (want - from) * (1 - exp(-dt * 14)) or want
  elseif S.fv and (S.act or S.bw > 0) and S.gfov then
    -- nothing of ours to write any more (Field of view at GAME, aim let go): back out to the game's own, eased as the
    -- zoom came in, then handed back
    S.fv = S.fv + (S.gfov - S.fv) * (1 - exp(-dt * 14))
    if abs(S.fv - S.gfov) < 0.3 then S.fv = nil end
  else S.fv = nil end
  GR.watch()
  hide_guns()
  place(w)
  HUD.overlays(dt)
  if P.open then draw_panel(dt) end
  draw_msg(dt)
end

local function render_step()
  local w = chef.world()
  if not w or S.wgone or S.jhold then return end
  hold_body(w, true)
  -- the draw pass puts the camera back (the game moves it between update and draw every frame, 1.0.1 log): no easing (it ran twice as fast with both passes) and no enemy ranging
  S.dt, S.draw = 0, true
  -- the body moves on after update too: carry the view along, or it trails a fast body (jump pack, report 2026-11-09)
  local h = S.head
  local x, y, z
  if S.act and h and S.tx and S.trx then x, y, z = chef.unit_position(h.u, h.root) end
  if x then
    local dx, dy, dz = x - S.trx, y - S.try, z - S.trz
    warp_check(dx, dy, dz)  -- same body as this frame's update, so the shift is exact even for a warp
    -- the root jumping alone (head still) flashed the view 0.77 m for a frame (log 2026-11-11): carry the head's move
    local hx, hy, hz
    if S.thx then hx, hy, hz = chef.unit_position(h.u, h.node) end
    if hx then
      local ex, ey, ez = hx - S.thx, hy - S.thy, hz - S.thz
      -- (only the root jumping: the head pops 8-11 cm by itself as a get-up starts, and carrying that flashed the view)
      if abs(dx) + abs(dy) + abs(dz) > 0.1 and abs(dx - ex) + abs(dy - ey) + abs(dz - ez) > 0.1 then dx, dy, dz = ex, ey, ez end
      S.thx, S.thy, S.thz = hx, hy, hz
    end
    S.tx, S.ty, S.tz = S.tx + dx, S.ty + dy, S.tz + dz
    S.trx, S.try, S.trz = x, y, z
    -- the arm swings the shield on after update too (turning): the window view goes to where the slot is now, or the
    -- slot slid across the view and caught up a frame later (user 2026-11-11: 'the shield noticeably lags')
    local se = S.she
    local hp = se and alive(S.shu) and node_at(S.shu, 'look_hole')
    if hp then
      local mx, my, mz = hp[1] - se[5] - se[2] - dx, hp[2] - se[6] - se[3] - dy, hp[3] - se[7] - se[4] - dz
      S.tx, S.ty, S.tz = S.tx + mx * se[1], S.ty + my * se[1], S.tz + mz * se[1]
    end
  end
  place(w)
  S.draw = nil
end

-- A Lua error in a frame. The loader logs only its first three and switches the mod off for the session after 20
-- (never forgiven), so one rare error every few minutes would end first person halfway through an evening. Here each
-- error is logged with where it came from (the first time that message is seen), the camera and meshes go back to the
-- game, and the mod waits 1, 2, 4 ... up to 30 s before it starts again as in a new world. Two minutes with no error
-- forgive the count; 8 with no such two minutes between them and it stops for the session (the camera already the
-- game's) and says so on screen.
local REC = { n = 0, wait = 0, clean = 0, stopped = false, seen = {}, live = false, STOP = 8, FORGIVE = 120, MAX_WAIT = 30 }
local function traced(e)
  local tb = debug and debug.traceback
  return tb and tb(tostring(e), 2) or tostring(e)
end
local function recover(hook, err)
  REC.n, REC.clean = REC.n + 1, 0
  -- (the loader's own form, "update error: ...", so anything reading the log for errors still finds it)
  local first = tostring(err):match('^[^\n]*')
  if not REC.seen[first] then
    REC.seen[first] = true
    log('%s error: %s', hook, tostring(err))
  else
    log('%s error: (again) %s', hook, first)
  end
  -- no render until an update runs clean again (a render error left this true, and render kept raising every frame
  -- through the pause); the panel closed, since nothing draws it while paused and it holds the mouse
  S.draw, REC.live = nil, false
  local was = keep_as()
  if P.open then pcall(open_panel, false) end
  pcall(carry)
  if not pcall(set_on, false, true) then
    -- the hand-back itself raised: each part on its own, before the restart forgets the cameras and the hidden lists
    pcall(hand_back)
    for u, names in pairs(S.hidden or {}) do
      for nm in pairs(names) do pcall(call, 'Unit.set_mesh_visibility', u, nm, true, 'default') end
    end
    S.hidden = {}
    for u in pairs(S.uhid or {}) do pcall(call, 'Unit.set_unit_visibility', u, true) end
    S.uhid = {}
    pcall(show_guns)
  end
  S.world = nil
  if S.keep == nil then S.keep, S.keep_w = was, chef.world_id() end
  if REC.n >= REC.STOP then
    REC.stopped = true
    log('stopped for this session after %d errors close together: the camera is the game\'s. Please send this log.',
      REC.n)
    S.msg, S.msg_t = 'SHODAN FIRST PERSON STOPPED AFTER ERRORS (SEE THE LOG)', 8
  else
    REC.wait = min(REC.MAX_WAIT, 2 ^ (REC.n - 1))
    log('back in %g s', REC.wait)
  end
end
local function update_now()
  if S.jhold then
    S.jhold = S.jhold - REC.dt
    if S.jhold > 0 then return end
    S.jhold = nil
    log('ship: 0.5 s held, going on')
  end
  if not world_gone() then step(REC.dt) end
end
function M.update(dt)
  if type(dt) ~= 'number' or dt ~= dt or dt < 0 or dt == math.huge then dt = 0 end
  if REC.stopped then pcall(draw_msg, dt); return end
  if REC.wait > 0 then REC.wait = REC.wait - dt; return end
  REC.dt = dt  -- (on REC, not a local: the main chunk is at Lua's 200)
  REC.live = false
  alive.c = {}
  local ok, err = xpcall(update_now, traced)
  alive.c = nil
  if not ok then return recover('update', err) end
  REC.live = true
  REC.clean = REC.clean + dt
  if REC.n > 0 and REC.clean >= REC.FORGIVE then REC.n = 0 end
end
-- (only after this frame's update ran clean: the frame a pause ends, the state is still the one from before the
-- error until the update starts the world again, and placing the camera from it wrote a stale field of view)
function M.render()
  if not REC.live then return end
  alive.c = {}
  local ok, err = xpcall(render_step, traced)
  alive.c = nil
  if not ok then recover('render', err) end
end

function M.on_stop()
  HUD.sigma(false)
  set_on(false, true)
  if P.open then open_panel(false) end
end
M.shutdown = M.on_stop

M._P, M._S, M._V, M._TABS = P, S, V, TABS
return M
