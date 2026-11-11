-- HD2-Addon: mods/shodan/first_person
-- HD2-Requires: chef-shared-loader
-- SHODAN First Person: a first person camera with its own settings panel.
local chef = ...
local M = { version = '1.2.0' }
local log = chef.log
-- chef.call doesn't refuse a unit destroyed in this world (a swapped helmet): asking one ends the game
local function call(name, a, b, ...)
  local u = name:sub(1, 5) == 'Unit.' and a or (name == 'Camera.set_local_position' or name == 'Camera.set_local_rotation' or name == 'World.update_unit') and b
  if u and not chef.unit_alive(u) then return nil, 'gone' end
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
-- each exosuit / emplacement has its own settings too (bodies only; arms are other units of the same mech)
local MECHS = { { kind = '79e4b3d2da5e45e3', name = 'PATRIOT', pre = '' }, { kind = 'c2d449ecf7facab1', name = 'EMANCIPATOR', pre = 'em_' },
  { kind = '35dbf54f016f3624', name = 'BREAKTHROUGH', pre = 'bt_' }, { kind = '7b2326f6fd9c8069', name = 'LUMBERER', pre = 'lb_' } }
local EMPLS = { { kind = '0e977c49db7604f9', name = 'HMG', pre = '' }, { kind = '2b11c9e4980ec479', name = 'ANTI-TANK', pre = 'at_' } }
local PRE = {}
for _, l in ipairs({ MECHS, EMPLS }) do for _, m in ipairs(l) do PRE[m.kind] = m.pre end end
local MECH_KINDS = {}                                         -- content/fac_helldivers/vehicles/combat_walker*
for _, k in ipairs({ '79e4b3d2da5e45e3', '17c5d12d8d5dee2c', '35dbf54f016f3624', 'df51fe8d62f294be', '0736bee2d6328726',
  '7b2326f6fd9c8069', 'a526dc7d89ff696d', '824b7e0c4c879eb5', 'c2d449ecf7facab1', '65489809a8181b96' }) do MECH_KINDS[k] = true end
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
    { id = 'aim_toggle', label = 'Aim button toggles', toggle = true, def = false, global = true,
      hint = 'Turn on if your game is set to toggle aiming instead of holding the button.' },
    { head = 'SMOOTHING' },
    { id = 'smooth', label = 'Smoothing up-down', min = 0, max = 10, step = 1, def = 3, zero = 'OFF',
      hint = 'Takes the up-down head bob out of walking and running. Higher is calmer.' },
    { id = 'smooth_side', label = 'Smoothing sideways', min = 0, max = 10, step = 1, def = 3, zero = 'OFF',
      hint = 'Takes the side-to-side sway out. Keep it low so turning still feels quick.' },
    { id = 'smooth_max', label = 'Smoothing lag limit', min = 0, max = 0.3, step = 0.01, def = 0.12, unit = ' m', zero = 'OFF',
      hint = 'The smoothed view never trails your head by more than this, so quick moves (crouching, a jolt in a seat) stay crisp.' },
    { head = 'SWITCHING' },
    { id = 'start_on', label = 'Start in first person', toggle = true, def = true,
      hint = 'Turn first person on by itself at the start of every mission.' },
    { id = 'messages', label = 'On-screen messages', toggle = true, def = true, global = true,
      hint = 'Shows FIRST PERSON ON or OFF and the profile number for a moment when you press their keys.' },
    { id = 'tp_galaxy', label = 'Third person at the galactic map', toggle = true, def = true,
      hint = 'Switches to the game camera while you use the galactic map.' },
    { id = 'tp_pod', label = 'Third person in the hellpod', toggle = true, def = true,
      hint = 'Switches to the game camera from the moment you use the hellpod on the ship until you climb out, and in the drop until you step out of the pod.' },
    { id = 'tp_term', label = 'Third person at terminals', toggle = true, def = true,
      hint = 'Switches to the game camera while you use a mission terminal, and back when you step off it.' },
    { head = '(Experimental, report issues!)', note = true },
    { id = 'tp_menus', label = 'Third person for map and stratagems', toggle = true, def = false,
      hint = 'Switches to the game camera while the map or stratagem list is out.' },
    { id = 'tp_down', label = 'Third person when knocked down', toggle = true, def = false,
      hint = 'Switches to the game\'s camera while you tumble or lie dead, and back once you are up.' },
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
    { head = 'CROSSHAIR FIX' },
    { id = 'aim_fix', label = 'Crosshair follows the gun', toggle = true, def = true,
      hint = 'The view turns a little so the crosshair sits where your shots land. Everything on this tab needs it on.' },
    { id = 'aim_dist', label = 'Distance with no enemy', min = 5, max = 100, step = 1, def = 30, unit = ' m',
      hint = 'Where the crosshair is exact while no enemy is under it. Nearer or further, shots land a little off.' },
    { id = 'aim_ease', label = 'Correction time', min = 0, max = 2, step = 0.05, def = 0.15, unit = ' s',
      hint = 'How long the view takes to adjust when you aim or the target distance changes. Longer feels less like aim assist.' },
    { id = 'aim_max', label = 'Largest turn', min = 2, max = 20, step = 1, def = 8, unit = ' deg',
      hint = 'The most the view may turn off the game aim. Up close the needed turn is bigger; above this it stops at this angle.' },
    { head = 'WHILE AIMING' },
    { id = 'aim_strength', label = 'Strength', min = 1, max = 10, step = 1, def = 10,
      hint = 'How much of the gap to the game aim gets corrected while aiming. 10 = exact, lower = gentler turns, shots land a bit off.' },
    { id = 'aim_range', label = 'Correct for enemies', toggle = true, def = false,
      hint = 'Use the distance of the enemy under the crosshair instead of the fixed distance. Stronger turns up close.' },
    { head = 'HIP FIRE' },
    { id = 'aim_hip', label = 'Correct hip fire', toggle = true, def = true,
      hint = 'Corrects the crosshair when not aiming too, at the fixed distance, so hip-fire shots land on it.' },
    { id = 'hip_range', label = 'Correct for enemies', toggle = true, def = false,
      hint = 'Also correct for the enemy under the crosshair, so close shots land on it too. Stronger turns.' },
    { id = 'hip_strength', label = 'Enemy strength', min = 1, max = 10, step = 1, def = 5,
      hint = 'With Correct for enemies on: how much of the extra turn toward a close enemy is made. 10 = exact, lower = gentler.' },
    { id = 'hip_ease', label = 'Enemy time', min = 0, max = 2, step = 0.05, def = 0.4, unit = ' s',
      hint = 'With Correct for enemies on: how long the view takes to adjust when an enemy comes under the crosshair or leaves it.' },
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
    { head = 'LYING DOWN' },
    { id = 'eyes', label = 'View from past the head when down', toggle = true, def = false,
      hint = 'While diving or lying, the view sits just past the top of your head, following the animation, so it stays out of your body.' },
    { id = 'eye_fwd', label = 'Distance past the head', min = 0, max = 0.3, step = 0.01, def = 0.1, unit = ' m',
      hint = 'How far past the top of the head the view sits while diving or lying.' },
    { id = 'back_lift', label = 'Lift when looking back lying down', min = 0, max = 1, step = 0.01, def = 0.1, unit = ' m',
      hint = 'Raises the view over your back and gun when you look behind you after a dive, while prone or while getting up.' },
  } },
  { name = 'MESHES', rows = {
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
    { head = 'DRIVER' },
    { id = 'frv_fwd', label = 'Forward', min = -0.6, max = 0.6, step = 0.01, def = 0.06, unit = ' m',
      hint = 'Extra forward or back while you drive an FRV.' },
    { id = 'frv_up', label = 'Height', min = -0.6, max = 0.6, step = 0.01, def = 0.02, unit = ' m',
      hint = 'Extra height while you drive an FRV.' },
    { id = 'frv_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right while you drive an FRV.' },
    { head = 'PASSENGER' },
    { id = 'frvp_fwd', label = 'Forward', min = -0.6, max = 0.6, step = 0.01, def = 0.06, unit = ' m',
      hint = 'Extra forward or back in an FRV passenger seat.' },
    { id = 'frvp_up', label = 'Height', min = -0.6, max = 0.6, step = 0.01, def = 0.02, unit = ' m',
      hint = 'Extra height in an FRV passenger seat.' },
    { id = 'frvp_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in an FRV passenger seat.' },
    { head = 'GUNNER' },
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
      hint = 'Driver and gunner always use the game camera. This switches the passenger seats.' },
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
      hint = 'Driver and gunner always use the game camera. This switches the passenger seats.' },
    { id = 'maelstrom_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in a Maelstrom passenger seat, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'maelstrom_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back in a Maelstrom passenger seat (third person there must be off).' },
    { id = 'maelstrom_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height in a Maelstrom passenger seat (third person there must be off).' },
    { id = 'maelstrom_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in a Maelstrom passenger seat (third person there must be off).' },
  } },
  { name = 'MECHS', rows = {
    { head = 'MECH' },
    { id = 'mech_pick', global = true, label = 'Mech model to edit', min = 1, max = #MECHS, step = 1, def = 1,
      hint = 'Pick the exosuit the mech rows below change. Each exosuit keeps its own settings.' },
    { id = 'tp_mech', label = 'Third person in a mech', toggle = true, def = true,
      hint = 'Switches to the game\'s camera while you pilot an exosuit. Off = first person with the offsets below.' },
    { id = 'mech_fov', label = 'Field of view', min = 0, max = 120, step = 1, def = 0, unit = ' deg', zero = 'SAME',
      hint = 'Up-down view angle in a mech, first or third person. SAME = the normal field of view (in third person the game default).' },
    { id = 'mech_fwd', label = 'Forward', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra forward or back in a mech (third person in a mech must be off).' },
    { id = 'mech_up', label = 'Height', min = -1, max = 1, step = 0.01, def = 0, unit = ' m',
      hint = 'Extra height in a mech (third person in a mech must be off).' },
    { id = 'mech_side', label = 'Sideways', min = -0.6, max = 0.6, step = 0.01, def = 0, unit = ' m',
      hint = 'Move the view left (minus) or right in a mech (third person in it must be off).' },
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
    { id = 'freelook', label = 'Free look (immersive mode)', key = true, def = 'left alt',
      hint = 'Hold to look around while your body stays where it is. Let go and the body turns to catch up. Press RIGHT, then the new key.' },
    { id = 'peek', label = 'Hold for third person', key = true, def = 'f7',
      hint = 'Hold to see the game\'s camera, let go to go back. Press RIGHT, then the new key.' },
    { id = 'profile_key', label = 'Next profile', key = true, def = 'off',
      hint = 'Switches to the next of the five profiles. Press RIGHT, then the new key. DELETE sets none.' },
    { head = 'PANEL' },
    { id = 'panel', label = 'Open this panel', key = true, def = 'f10', hint = 'Press RIGHT, then the new key. DELETE sets none.' },
    { id = 'tab_prev', label = 'Previous tab', key = true, def = 'a', hint = 'Moves to the tab on the left. Press RIGHT, then the new key.' },
    { id = 'tab_next', label = 'Next tab', key = true, def = 'd', hint = 'Moves to the tab on the right. Press RIGHT, then the new key.' },
  } },
}
for _, tab in ipairs(TABS) do  -- every tab ends with its own reset button
  tab.rows[#tab.rows + 1] = { reset_tab = true, label = 'RESET THIS TAB TO DEFAULT',
    hint = 'Puts every setting on this tab back to default (every model on model tabs). Press twice to confirm.' }
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
-- a row's saved value: its default when there's none or it's another type (a setting added in a newer version, a
-- damaged save), numbers held to the row's range
local function load_row(r)
  local v = chef.load(sk(r), r.def)
  if type(v) ~= type(r.def) then return r.def end
  if type(v) == 'number' and r.min then v = math.min(r.max, math.max(r.min, v)) end
  return v
end
-- the user's tuned values as defaults for vehicle rows, per model copy (copies otherwise take the base row's own default)
local MY_DEF = { frv_fwd = 0.08, frv_up = -0.08, frv_side = 0, frvp_fwd = 0, frvp_up = 0, frvp_side = 0, sp_frv_fwd = 0.08, sp_frv_up = -0.08, sp_frv_side = 0, sp_frvp_fwd = 0, sp_frvp_up = 0, sp_frvp_side = 0, fl_frv_fwd = 0.08, fl_frv_up = -0.08, fl_frv_side = 0, fl_frvp_fwd = 0, fl_frvp_up = 0, fl_frvp_side = 0, se_frv_fwd = 0.08, se_frv_up = -0.08, se_frv_side = 0, se_frvp_fwd = 0, se_frvp_up = 0, se_frvp_side = 0, frvg_fwd = 0, frvg_up = 0.06, frvg_side = 0, fl_frvg_fwd = 0, fl_frvg_up = 0.06, fl_frvg_side = 0,
  se_frvg_fwd = 0, se_frvg_up = 0.06, se_frvg_side = 0,
  tp_empl = false, at_tp_empl = false, empl_up = 0.15 }
-- immersive mode paused (user, 2026-11-07): tab + free look key hidden, V.imm_on stays nil so neck() never runs
for i = #TABS, 1, -1 do
  local t = TABS[i]
  if t.name == 'IMMERSE' then table.remove(TABS, i) end
  for j = #t.rows, 1, -1 do if t.rows[j].id == 'freelook' then table.remove(t.rows, j) end end
end
local binds = {}
for _, tab in ipairs(TABS) do
  for _, r in ipairs(tab.rows) do
    if r.id then  -- headings and the reset button have none
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
  mech_pick = { models = MECHS, match = function(id) return id == 'tp_mech' or id:match('^mech_') end },
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
  V[id] = v
  if v == r.def then chef.save(sk(r), nil) else chef.save(sk(r), v) end  -- (v ~= def and v or nil) lost every false
  if PICKS[id] then show_pick(id) end
  if id == 'profile' then  -- load the new profile's values
    for rid, row in pairs(ROW) do if not row.key and not row.global then V[rid] = load_row(row) end end
    for pid in pairs(PICKS) do show_pick(pid) end
  end
end

---------------------------------------------------------------------------------------------------- camera
local S = { on = false, cams = {}, head = nil, look = 0, frv_t = 0, said = {}, parts = {}, hidden = {}, uhid = {}, ghid = {}, gst = {}, gsaid = {}, world = -1,
  t = 0, rescans = {} }
-- a node index is only passed on while the unit has that many nodes: the loader checks the unit, not the index, and
-- indices are kept (per kind, per unit), so a handle the engine hands out again for another unit must not get one
-- that is out of range. Counted once a frame per unit; no count to be had = asked as before.
local nodes_n, nodes_t = {}, nil
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
  return chef.unit_position(u, i)
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
local function anim(u, all)
  if not u or S.nopod then return nil end
  -- mission: not while the game camera falls (a drop not yet seen as one: the world can settle mid-drop) and not
  -- until it has been still for 0.5 s
  if chef.in_mission() and (S.calm_t or 0) < 0.5 then return nil end
  if S.down_any and chef.in_mission() and (S.atrace or 0) <= S.t then S.atrace = S.t + 0.5; log('asking the animation while down') end
  local has, why = call('Unit.has_animation_state_machine', u)
  if has == false then
    if S.head and u == S.head.u and not S.dead and chef.in_mission() then S.dead = true; log('the body has no animation left (dead): game camera') end
    return nil
  end
  -- the check itself refused: still never ask a body that's down
  if has == nil then if not S.said.asm then S.said.asm = true; log('animation check unavailable: %s', tostring(why)) end; if S.down_any then return nil end end
  if all then
    if not (has == true and not (S.down_any or S.dead or S.down) and UnitApi and UnitApi.animation_get_state and chef.unit_alive(u)) then return nil end
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
  if type(x) == 'number' then return x, y, z end
end
local function once(k, ...) if not S.said[k] then S.said[k] = true; log(...) end end

local BONES = { 'head', 'chest', 'hips' }
-- gear hung on the hips, separate units hidden whole (ids from the files a PDA/sample container remover replaces)
local GEAR = { ['1c8764d62e12925a'] = 'hide_pda', a9936cbe561e8180 = 'hide_sample' }
-- GUNS BEGIN
local GUNS = {  -- generated by gen_guns.py: kind = { category, mesh names (8 hex digits: name unknown) }
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
  ['006e44327bb953fe'] = { 'primary', { 'g_pump_grenade_launcher_LOD4', 'g_pump_grenade_launcher_LOD3', 'g_pump_grenade_launcher_LOD2', 'g_pump_grenade_launcher_LOD1', 'g_pump_grenade_launcher' } },  -- pump_grenade_launcher
  ['03e67a19b07c6523'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' } },  -- marksman_rifle_vigilance
  ['05d8d8c073b9d502'] = { 'primary', { '8755602b', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pump_shotgun_plasma
  ['076dd5d4f4360204'] = { 'primary', { 'g_arc_shotgun_LOD4', 'g_arc_shotgun_LOD3', 'g_arc_shotgun_LOD2', 'g_arc_shotgun_LOD1', 'g_arc_shotgun' } },  -- arc_shotgun
  ['0c197bbd8d2c725b'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_rifle_penetrator
  ['0f83639ab8c86165'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- battle_rifle_ceremonial
  ['11ec8e2296a3d662'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pump_shotgun_02
  ['16051937941bb709'] = { 'primary', { 'g_rhino_default_muzzle_LOD2', 'g_rhino_default_muzzle_LOD1', 'g_rhino_default_muzzle' } },  -- smg_rhino_default_muzzle
  ['186ea95de7306b1a'] = { 'primary', { 'g_smg_solvent_LOD4', 'g_smg_solvent_LOD3', 'g_smg_solvent_LOD2', 'g_smg_solvent_LOD1', 'g_smg_solvent' } },  -- smg_solvent
  ['1abbff60d26ba391'] = { 'primary', { 'g_marksman_rifle_shark_LOD4', 'g_marksman_rifle_shark_LOD3', 'g_marksman_rifle_shark_LOD2', 'g_marksman_rifle_shark_LOD1', 'g_marksman_rifle_shark' } },  -- marksman_rifle_shark
  ['2383b0439f0bc465'] = { 'primary', { '294eb1fd', 'c9c1870e', 'bfbd8efc', 'fd59deb1' } },  -- assault_rifle_rico_default_muzzle
  ['27ee1ed8f6fb6356'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- laser_rifle
  ['295beb26dc4f8ff1'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_charge', 'g_body' } },  -- laser_rifle_long_hotshot
  ['2b28e17ffed05f7c'] = { 'primary', { 'g_triple_barrel_breakshotgun_LOD4', 'g_triple_barrel_breakshotgun_LOD3', 'g_triple_barrel_breakshotgun_LOD2', 'g_triple_barrel_breakshotgun_LOD1', 'g_triple_barrel_breakshotgun' } },  -- triple_barrel_breakshotgun
  ['30061f91af477f5e'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- sniper_rifle_helghast
  ['3c86e871923f3970'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- laser_shotgun
  ['41eac4a03987faa0'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pump_shotgun
  ['46183b50961d1328'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_shotgun
  ['4ba41b6f9f405cc2'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- smg_helghast
  ['4dbd74f49c8ffc13'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'a94a089d', 'g_screen', 'g_reciever' } },  -- assault_rifle_nacho
  ['4e4a613eb9bf5c24'] = { 'primary', { '22cbeab1', 'a3572540', '51705c29', 'g_pdw_LOD4', 'g_pdw_LOD3', 'g_pdw_LOD2', 'g_pdw_LOD1', 'g_pdw' } },  -- personal_defense_weapon
  ['4fb0f8c02f55c82b'] = { 'primary', { 'g_flamer_LOD4', 'g_flamer_LOD3', 'g_flamer_LOD2', 'g_flamer_LOD1', 'g_flamer' } },  -- flamethrower_ripley
  ['53eebe75cd6e26df'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pump_shotgun_slug
  ['5fecab819f96a3e8'] = { 'primary', { 'g_battle_rifle_LOD4', 'g_battle_rifle_LOD3', 'g_battle_rifle_LOD2', 'g_battle_rifle_LOD1', 'g_battle_rifle' } },  -- battle_rifle
  ['6228d0242bde56b6'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_shotgun_sprayandpray
  ['6e68194b95d60145'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' } },  -- marksman_rifle_vigilance_counter_sniper
  ['708ea298c82093d0'] = { 'primary', { 'c4846e6b', '1d8a6f58', '66acf2b1', '199d951f', '6651bc24', '8f0fa4be', '713ebe31', '1aa3a27c', 'd5ef6d73' } },  -- assault_rifle_whisper
  ['719f42b7d137789c'] = { 'primary', { 'g_jet_rifle_phoenix_default_muzzle_LOD2', 'g_jet_rifle_phoenix_default_muzzle_LOD1', 'g_jet_rifle_phoenix_default_muzzle' } },  -- jet_rifle_phoenix_default_muzzle
  ['72170a55a1f37ff1'] = { 'primary', { 'g_shotgun_double_freedom_LOD4', 'g_shotgun_double_freedom_LOD3', 'g_shotgun_double_freedom_LOD2', 'g_shotgun_double_freedom_LOD1', 'g_shotgun_double_freedom' } },  -- shotgun_double_freedom
  ['72fe4b13f726c344'] = { 'primary', { '499ab1ad', '89d21542', 'd3caaff6', '4808c321', 'b83e206d', 'acb89e54', 'ee98d9aa', 'db8498d5', 'cb91c978' } },  -- smg_flamer_attachment
  ['7b75e5132ffd4ca6'] = { 'primary', { 'g_bolt_action_rifle_LOD4', 'g_bolt_action_rifle_LOD3', 'g_bolt_action_rifle_LOD2', 'g_bolt_action_rifle_LOD1', 'g_bolt_action_rifle' } },  -- bolt_action_rifle
  ['7e3145a5baa4b948'] = { 'primary', { 'g_laser_rifle_charge_LOD4', 'g_laser_rifle_charge_LOD3', 'g_laser_rifle_charge_LOD2', 'g_laser_rifle_charge_LOD1', 'g_laser_rifle_charge' } },  -- laser_rifle_charge
  ['8039834a4b7489b9'] = { 'primary', { '2fe0d6ff', 'd2259a6e', '9e14c212', '21ba31f8' } },  -- assault_rifle_penetrator_default_muzzle
  ['80f1a156d9fa1e36'] = { 'primary', { 'g_jet_rifle_LOD4', 'g_jet_rifle_LOD3', 'g_jet_rifle_LOD2', 'g_jet_rifle_LOD1', 'g_jet_rifle' } },  -- jet_rifle
  ['84354339522c932d'] = { 'primary', { 'g_assault_rifle_large_calibre_01_LOD4', 'g_assault_rifle_large_calibre_01_LOD3', 'g_assault_rifle_large_calibre_01_LOD2', 'g_assault_rifle_large_calibre_01_LOD1', 'g_assault_rifle_large_calibre_01' } },  -- assault_rifle_large_calibre_01
  ['8645f167b3c813a2'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- laser_rifle_long
  ['8a307bd1811a5fe9'] = { 'primary', { 'eb7d2210', 'g_smg_flamer_LOD4', 'g_smg_flamer_LOD3', 'g_smg_flamer_LOD2', 'g_smg_flamer_LOD1', 'g_smg_flamer' } },  -- smg_flamer
  ['8a35c1dc19f41870'] = { 'primary', { 'g_bolt_action_rifle_default_muzzle_LOD1', 'g_bolt_action_rifle_default_muzzle' } },  -- bolt_action_rifle_default_muzzle
  ['8dc91f277c6096ee'] = { 'primary', { 'g_jet_rifle_LOD4', 'g_jet_rifle_LOD3', 'g_jet_rifle_LOD2', 'g_jet_rifle_LOD1', 'g_jet_rifle' } },  -- jet_rifle_phoenix
  ['90ddc374f4e3d756'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- shotgun_nacho
  ['94bd931b5fb4ee95'] = { 'primary', { 'g_rhino_LOD4', 'g_rhino_LOD3', 'g_rhino_LOD2', 'g_rhino_LOD1', 'g_rhino' } },  -- smg_rhino
  ['9571ca51f0daf35b'] = { 'primary', { 'g_smg_defender_LOD4', 'g_smg_defender_LOD3', 'g_smg_defender_LOD2', 'g_smg_defender_LOD1', 'g_smg_defender' } },  -- smg_defender
  ['968211c0033dce64'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_rifle
  ['a6a735accb4a327f'] = { 'primary', { 'g_mesh_LOD4', 'g_mesh_LOD3', 'g_mesh_LOD2', 'g_mesh_LOD1', 'g_mesh' } },  -- lmg_stalwart
  ['a7ee1ebf58fcdf1f'] = { 'primary', { 'g_receiver_LOD4', 'g_receiver_LOD3', 'g_receiver_LOD2', 'g_receiver_LOD1', 'g_receiver' } },  -- assault_rifle_patriot
  ['a8a91eb54892b6b2'] = { 'primary', { 'g_assault_rifle_risk_LOD4', 'g_assault_rifle_risk_LOD3', 'g_assault_rifle_risk_LOD2', 'g_assault_rifle_risk_LOD1', 'g_assault_rifle_risk' } },  -- assault_rifle_risk
  ['a955c4ea6f6d4203'] = { 'primary', { 'g_assault_rifle_grenadier_LOD4', 'g_assault_rifle_grenadier_LOD3', 'g_assault_rifle_grenadier_LOD2', 'g_assault_rifle_grenadier_LOD1', 'g_assault_rifle_grenadier' } },  -- assault_rifle_grenadier
  ['ab2a2b390c539f18'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_rifle_explosive
  ['bc29613666df696b'] = { 'primary', { 'g_assault_rifle_karbin_LOD4', 'g_assault_rifle_karbin_LOD3', 'g_assault_rifle_karbin_LOD2', 'g_assault_rifle_karbin_LOD1', 'g_assault_rifle_karbin' } },  -- assault_rifle_karbin
  ['be70ee0d8d44028e'] = { 'primary', { 'g_smg_nacho_LOD4', 'g_smg_nacho_LOD3', 'g_smg_nacho_LOD2', 'g_smg_nacho_LOD1', 'g_lens', 'g_smg_nacho' } },  -- smg_nacho
  ['bf9504e95c0103a1'] = { 'primary', { 'f7d5424f', '88bbc12f', '220f4306', '57757ff1', 'a729554f' } },  -- battle_rifle_ceremonial_default_muzzle
  ['bfe35746f5084222'] = { 'primary', { '5a6cd994' } },  -- assault_rifle_karbin_default_muzzle
  ['c12a34f375bd5a87'] = { 'primary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- assault_shotgun_incendiary
  ['c4232a0e62166d91'] = { 'primary', { '22cbeab1', 'a3572540', '51705c29', 'g_pdw_LOD4', 'g_pdw_LOD3', 'g_pdw_LOD2', 'g_pdw_LOD1', 'g_pdw' } },  -- personal_defense_weapon_pepper
  ['c85f576d5e086147'] = { 'primary', { 'g_laser_smg_blaster_LOD4', 'g_laser_smg_blaster_LOD3', 'g_laser_smg_blaster_LOD2', 'g_laser_smg_blaster_LOD1', 'g_laser_smg_blaster' } },  -- laser_smg_blaster
  ['cdf28be026bb7d84'] = { 'primary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- assault_rifle_helghast
  ['cdf733b0106a23c3'] = { 'primary', { 'bae8caeb', 'f0e645af', 'a37a5a94', '0f969650' } },  -- assault_shotgun_incendiary_default_muzzle
  ['ce063aa33d95a812'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' } },  -- assault_rifle_rico
  ['d323de60855898ac'] = { 'primary', { 'g_pump_shotgun_dragon_LOD4', 'g_pump_shotgun_dragon_LOD3', 'g_pump_shotgun_dragon_LOD2', 'g_pump_shotgun_dragon_LOD1', 'g_pump_shotgun_dragon' } },  -- pump_shotgun_dragon
  ['dcd1c835407ef7ba'] = { 'primary', { '65132739', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pump_shotgun_trench
  ['e5796355a8fd67e0'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' } },  -- marksman_rifle_drake
  ['e6d932be83729076'] = { 'primary', { 'g_rifle_LOD4', 'g_rifle_LOD3', 'g_rifle_LOD2', 'g_rifle_LOD1', 'g_rifle' } },  -- lever_action_rifle_01
  ['eea5e3cef1e12c14'] = { 'primary', { 'g_plasma_LOD4', 'g_plasma_LOD3', 'g_plasma_LOD2', 'g_plasma_LOD1', 'g_plasma' } },  -- plasma_rifle
  ['efdcef306cea63fe'] = { 'primary', { 'g_plasma_rifle_charge_LOD3', 'g_plasma_rifle_charge_LOD2', 'g_plasma_rifle_charge_LOD1', 'g_plasma_rifle_charge' } },  -- plasma_rifle_charge
  ['f0338468dcdb6a6c'] = { 'primary', { 'g_marksman_rifle_justice_LOD4', 'g_marksman_rifle_justice_LOD3', 'g_marksman_rifle_justice_LOD2', 'g_marksman_rifle_justice_LOD1', 'g_marksman_rifle_justice' } },  -- marksman_rifle_justice
  ['f49227a0630a3f7f'] = { 'primary', { 'g_crossbow_LOD4', 'g_crossbow_LOD3', 'g_crossbow_LOD2', 'g_crossbow_LOD1', 'g_crossbow' } },  -- crossbow_greyfax
  ['f992ce97577c8a7f'] = { 'primary', { 'g_volley_gun_LOD4', 'g_volley_gun_LOD3', 'g_volley_gun_LOD2', 'g_volley_gun_LOD1', 'g_volley_gun' } },  -- volley_gun
  ['ffc18b2ce10ca381'] = { 'primary', { 'da6b11ea', '400fb5d6', '86f07750', '455663e2' } },  -- battle_rifle_default_muzzle
  ['05e4e5c2db6e44a2'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- standard_pistol
  ['0b882808c6f498e8'] = { 'secondary', { 'g_caustic_dart_gun_LOD4', 'g_caustic_dart_gun_LOD3', 'g_caustic_dart_gun_LOD2', 'g_caustic_dart_gun_LOD1', 'g_caustic_dart_gun' } },  -- caustic_dart_gun
  ['14d5d4506056c7a4'] = { 'secondary', { 'g_smart_pistol_missile_LOD4', 'g_smart_pistol_missile_LOD3', 'g_smart_pistol_missile_LOD2', 'g_smart_pistol_missile_LOD1', 'g_screen', 'g_smart_pistol_missile' } },  -- smart_pistol_missile
  ['1a437158e1b8d2a1'] = { 'secondary', { 'g_pistol_LOD4', 'g_pistol_LOD3', 'g_pistol_LOD2', 'g_pistol_LOD1', 'g_pistol' } },  -- magnum_pistol
  ['3575aabc5f1f9326'] = { 'secondary', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- automatic_pistol
  ['3f92ba65ef65cca9'] = { 'secondary', { 'g_flamer_pistol_LOD4', 'g_flamer_pistol_LOD3', 'g_flamer_pistol_LOD2', 'g_flamer_pistol_LOD1', 'g_flamer_pistol' } },  -- flamer_pistol
  ['416d053372c4e433'] = { 'secondary', { 'g_energy_revolver_LOD4', 'g_energy_revolver_LOD3', 'g_energy_revolver_LOD2', 'g_energy_revolver_LOD1', 'g_energy_revolver' } },  -- energy_revolver
  ['4d58c77087b774c5'] = { 'secondary', { 'g_pistol_nacho_LOD4', 'g_pistol_nacho_LOD3', 'g_pistol_nacho_LOD2', 'g_pistol_nacho_LOD1', 'g_pistol_nacho' } },  -- pistol_nacho
  ['52e4334e6a128caf'] = { 'secondary', { 'g_grenade_pistol_LOD4', 'g_grenade_pistol_LOD3', 'g_grenade_pistol_LOD2', 'g_grenade_pistol_LOD1', 'g_grenade_pistol' } },  -- grenade_pistol
  ['7b06196e90154c88'] = { 'secondary', { 'g_laserpistol_LOD4', 'g_laserpistol_LOD3', 'g_laserpistol_LOD2', 'g_laserpistol_LOD1', 'g_laserpistol' } },  -- laser_pistol
  ['7de84a343186671f'] = { 'secondary', { 'g_speedloader_LOD1', 'g_speedloader' } },  -- stim_pistol_speedloader
  ['8d3d52a3b2f19402'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_casings', 'g_feed_casing', 'g_body_crosshair', 'g_body' } },  -- revolver_pistol
  ['9eb160830321bfd6'] = { 'secondary', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- pistol_cricket
  ['aa69a60d74a3ec54'] = { 'secondary', { 'g_plasma_pistol_LOD4', 'g_plasma_pistol_LOD3', 'g_plasma_pistol_LOD2', 'g_plasma_pistol_LOD1', 'g_plasma_pistol' } },  -- plasma_pistol
  ['b96cc3b704a76464'] = { 'secondary', { 'g_speedloader' } },  -- revolver_speedloader
  ['bb8e970248330bdb'] = { 'secondary', { 'g_caustic_dart_LOD4', 'g_caustic_dart_LOD3', 'g_caustic_dart_LOD2', 'g_caustic_dart_LOD1', 'g_caustic_dart' } },  -- caustic_dart
  ['bde1f2534280300d'] = { 'secondary', { 'g_barrel_LOD4', 'g_barrel_LOD3', 'g_barrel_LOD2', 'g_barrel_LOD1', 'g_barrel', 'g_body_crosshair', 'g_feed_casing', 'g_casings', 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- revolver_pistol_long
  ['c780bcd79547da0f'] = { 'secondary', { 'g_pistol_broomhandle_LOD4', 'g_pistol_broomhandle_LOD3', 'g_pistol_broomhandle_LOD2', 'g_pistol_broomhandle_LOD1', 'g_pistol_broomhandle' } },  -- pistol_broomhandle
  ['cf8934ff6567a42d'] = { 'secondary', { 'g_lens', 'g_smart_pistol_LOD4', 'g_smart_pistol_LOD3', 'g_smart_pistol_LOD2', 'g_smart_pistol_LOD1', 'g_smart_pistol' } },  -- smart_pistol
  ['d6b1fb05b9109353'] = { 'secondary', { 'g_stim_pistol_LOD4', 'g_stim_pistol_LOD3', 'g_stim_pistol_LOD2', 'g_stim_pistol_LOD1', 'g_stim_pistol' } },  -- stim_pistol
  ['dbb6c961c59fadc1'] = { 'secondary', { 'g_pistol_shark_LOD4', 'g_pistol_shark_LOD3', 'g_pistol_shark_LOD2', 'g_pistol_shark_LOD1', 'g_pistol_shark' } },  -- pistol_shark
  ['e2177e205d9a7a55'] = { 'secondary', { '7cade4c9', 'g_caustic_dart_gun_cylinder_LOD4', 'g_caustic_dart_gun_cylinder_LOD3', 'g_caustic_dart_gun_cylinder_LOD2', 'g_caustic_dart_gun_cylinder_LOD1', 'g_caustic_dart_gun_cylinder' } },  -- caustic_dart_gun_cylinder
  ['e91f569c2ad8af01'] = { 'secondary', { 'g_hornet_pistol_LOD4', 'g_hornet_pistol_LOD3', 'g_hornet_pistol_LOD2', 'g_hornet_pistol_LOD1', 'g_hornet_pistol' } },  -- hornet_pistol
  ['02eecd0b1fa49630'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' } },  -- grenade_launcher
  ['11c27d3babb38956'] = { 'support', { 'g_mg_LOD4', 'g_mg_LOD3', 'g_mg_LOD2', 'g_mg_LOD1', 'g_mg' } },  -- machinegun
  ['2152d5147b0ac418'] = { 'support', { 'g_hmg_LOD4', 'g_hmg_LOD3', 'g_hmg_LOD2', 'g_hmg_LOD1', 'g_hmg' } },  -- heavy_mg
  ['25aa2fd4643cf4ee'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' } },  -- faf_missile_launcher
  ['26e40437ea275296'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' } },  -- air_burst_rocket_launcher
  ['2e9d0bdc48b09e60'] = { 'support', { 'g_railgun_LOD4', 'g_railgun_LOD3', 'g_railgun_LOD2', 'g_railgun_LOD1', 'g_charge', 'g_railgun' } },  -- railgun
  ['35a61296619cc47e'] = { 'support', { 'g_laser_pulse_cannon_LOD4', 'g_laser_pulse_cannon_LOD3', 'g_laser_pulse_cannon_LOD2', 'g_laser_pulse_cannon_LOD1', 'g_laser_pulse_cannon', 'g_charge' } },  -- laser_pulse_cannon
  ['3828e2051aa9e897'] = { 'support', { 'g_harpoon_gun_LOD4', 'g_harpoon_gun_LOD3', 'g_harpoon_gun_LOD2', 'g_harpoon_gun_LOD1', 'g_harpoon_gun' } },  -- harpoon_gun
  ['39ab99895147a3bf'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- flamethrower
  ['43a58cb89cfa197c'] = { 'support', { 'g_minigun_LOD4', 'g_minigun_LOD3', 'g_minigun_LOD2', 'g_minigun_LOD1', 'g_minigun' } },  -- minigun
  ['43b2d7766120203b'] = { 'support', { 'g_chemgun_LOD3', 'g_chemgun_LOD2', 'g_chemgun_LOD1', 'g_chemgun' } },  -- chemgun
  ['46427f2630a80d88'] = { 'support', { 'g_scope_LOD2', 'g_scope_LOD1', 'g_lens', 'g_scope' } },  -- faf_missile_launcher_helghast_scope
  ['5990123d142b16cb'] = { 'support', { 'g_launcher_LOD4', 'g_launcher_LOD3', 'g_launcher_LOD2', 'g_launcher_LOD1', 'g_launcher' } },  -- laser_guided_missile_launcher
  ['692eb345969d368e'] = { 'support', { 'g_lens' } },  -- lat_oneshot_sight
  ['6cfcc7f8801a0266'] = { 'support', { 'g_energy_weapon_shark_LOD4', 'g_energy_weapon_shark_LOD3', 'g_energy_weapon_shark_LOD2', 'g_energy_weapon_shark_LOD1', 'g_energy_weapon_shark' } },  -- energy_weapon_shark
  ['7617642765ac38c7'] = { 'support', { 'g_expendable_massive_rocket_launcher_LOD4', 'g_expendable_massive_rocket_launcher_LOD3', 'g_expendable_massive_rocket_launcher_LOD2', 'g_expendable_massive_rocket_launcher_LOD1', 'g_expendable_massive_rocket_launcher' } },  -- expendable_massive_rocket_launcher
  ['78a8185f63a70795'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- heavy_flamethrower
  ['80932fa0ed6901d3'] = { 'support', { 'g_lat_LOD4', 'g_lat_LOD3', 'g_lat_LOD2', 'g_lat_LOD1', 'g_lat' } },  -- lat_oneshot
  ['8666e5f49f440d44'] = { 'support', { 'g_faf_scope_LOD2', 'g_faf_scope_LOD1', 'g_faf_scope' } },  -- faf_scope
  ['88c2d09ad85a7c9f'] = { 'support', { 'g_belt_fed_grenade_launcher_LOD4', 'g_belt_fed_grenade_launcher_LOD3', 'g_belt_fed_grenade_launcher_LOD2', 'g_belt_fed_grenade_launcher_LOD1', 'g_belt_fed_grenade_launcher' } },  -- belt_fed_grenade_launcher
  ['89c5493e08ca4207'] = { 'support', { 'g_reciever_LOD4', 'g_reciever_LOD3', 'g_reciever_LOD2', 'g_reciever_LOD1', 'g_reciever' } },  -- sniper_rifle
  ['96de9cd50f7306e6'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- arc_thrower
  ['9bc319730887bdd8'] = { 'support', { 'g_clip' } },  -- autocannon_clip
  ['9f80d67a12a7e40f'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- recoilless_rifle
  ['a8cffb316f0b5c5f'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- automatic_cannon
  ['b16c9d490aa59b77'] = { 'support', { 'g_expendable_machinegun_LOD4', 'g_expendable_machinegun_LOD3', 'g_expendable_machinegun_LOD2', 'g_expendable_machinegun_LOD1', 'g_expendable_machinegun' } },  -- expendable_machinegun
  ['b2b5e0d185605f9e'] = { 'support', { 'g_expendable_napalm_launcher_LOD4', 'g_expendable_napalm_launcher_LOD3', 'g_expendable_napalm_launcher_LOD2', 'g_expendable_napalm_launcher_LOD1', 'g_expendable_napalm_launcher' } },  -- expendable_napalm_launcher
  ['b814eece17533bc4'] = { 'support', { '4834a0fb', 'abec8954', '22569bd8', '79649ca8', '0168b0fa', 'a52c2602', '2189b218', 'b3f8ac5c', '2a2a02c7' } },  -- (rack support b814eece17533bc4)
  ['cc786f6491fe7e65'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- faf_missile_launcher_helghast
  ['d54b9505c0f72873'] = { 'support', { 'g_body_LOD4', 'g_body_LOD3', 'g_body_LOD2', 'g_body_LOD1', 'g_body' } },  -- laser_cannon
  ['e8d5f49ad7780e54'] = { 'support', { 'g_plasma_blaster_LOD4', 'g_plasma_blaster_LOD3', 'g_plasma_blaster_LOD2', 'g_plasma_blaster_LOD1', 'g_charge', 'g_plasma_blaster' } },  -- plasma_blaster
  ['e8ffad77b73c221c'] = { 'support', { 'g_railgun_sabot' } },  -- railgun_sabot
  ['fe3b29b2cfa63f9b'] = { 'support', { 'g_grenade_launcher_tactical_LOD4', 'g_grenade_launcher_tactical_LOD3', 'g_grenade_launcher_tactical_LOD2', 'g_grenade_launcher_tactical_LOD1', 'g_grenade_launcher_tactical' } },  -- grenade_launcher_tactical
}
-- GUNS END
local GUN_KINDS = {}
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
-- every frame: which of your guns is in a hand (its root on a hand's attach node) or stowed (it rides rigidly with
-- its slot while the slot moves), and hide those the settings ask for, with their magazines
local function hide_guns()
  local want = {}
  local d = S.head and S.head.u
  if S.act and d and gun_watch and chef.unit_alive(d) then
    local refs = { left = node_at(d, 'attach_hand_l'), right = node_at(d, 'attach_hand_r') }
    for _, l in pairs(SLOTS) do for _, n in ipairs(l) do refs[n] = refs[n] or node_at(d, n) end end
    local rx, ry, rz = upos(d)
    local parts, carried = {}, {}
    for _, it in ipairs(rx and gun_watch.items or {}) do
      if (it.x - rx) ^ 2 + (it.y - ry) ^ 2 < 100 and chef.unit_alive(it.unit) then  -- the list's spots are up to 1 s old
        local g = GUNS[it.kind]
        local x, y, z = upos(it.unit)
        local p = x and { x, y, z }
        local st = S.gst[it.unit] or {}
        S.gst[it.unit] = st
        if g[1] == 'magazine' or g[1] == 'attachment' then parts[#parts + 1] = { u = it.unit, p = p, list = g[2] }
        elseif p then
          if dist(p, refs.left) < 0.002 or dist(p, refs.right) < 0.002 then
            st.state, st.learn = 'held', nil
          else
            if st.state == 'held' then st.state = nil end
            -- rigid on a slot: same distance to it (3 mm) over 3+ samples and 0.1 s while the slot moved 5 cm
            local ok = false
            for _, n in ipairs(SLOTS[g[1]]) do
              local r = refs[n]
              local dd = dist(p, r)
              if r and dd < 0.9 then
                local a = st.learn
                if st.state == 'stowed' and st.slot == n then ok = abs(dd - st.d) < 0.003
                elseif not a or a.slot ~= n or abs(dd - a.d) >= 0.003 or S.t - a.last > 0.25 then
                  st.learn = { slot = n, d = dd, r = r, first = S.t, last = S.t, count = 1 }
                else
                  a.last, a.count = S.t, a.count + 1
                  if a.count >= 3 and S.t - a.first >= 0.1 and dist(r, a.r) > 0.05 then
                    st.state, st.slot, st.d, ok = 'stowed', n, a.d, true
                  end
                end
                if ok then break end
              end
            end
            if not ok and st.state == 'stowed' then st.state, st.learn = nil, nil end
          end
          if st.state then
            local on = V['hide_' .. st.state .. '_' .. g[1]]
            carried[#carried + 1] = { p = p, on = on }
            if on then want[it.unit] = g[2] end
          else parts[#parts + 1] = { u = it.unit, p = p, list = g[2] } end  -- a scope or sight that is its own unit
          if st.state ~= S.gsaid[it.unit] then
            S.gsaid[it.unit] = st.state
            log('gun %s (%s): %s', it.kind, g[1], st.state or 'not yours')
          end
        end
      end
    end
    -- magazines, scopes, muzzles, launchers: they go with the nearest gun you carry within 0.8 m
    for _, m in ipairs(parts) do
      local best, bd = nil, 0.8
      for _, c in ipairs(carried) do local dd = dist(m.p, c.p); if dd < bd then best, bd = c, dd end end
      if best and best.on then want[m.u] = m.list end
    end
  end
  for u in pairs(S.ghid) do if not want[u] then if chef.unit_alive(u) then gun_meshes(u, nil, false) else S.ghid[u] = nil end end end
  for u, list in pairs(want) do gun_meshes(u, list, true) end
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

-- the end of a scan, all in one frame on the few units near the view: the Helldiver whose head is nearest, and the
-- pieces worn on him (the same spot of the same bone)
local function scan_done(near)
  local c = chef.camera()
  if not c then return end
  local best, bd = nil, 6
  -- ship: your Helldiver (S.mine) while it's there, never a teammate's (nothing on the ship gives you a new one)
  local gate = others_here() and not drop_seen() or not chef.in_mission() and S.mine ~= nil and chef.unit_alive(S.mine)
  -- right after your drop: your Helldiver is the one that came down with the pod (30+ m below its highest point;
  -- it exists from the mission load, 2026-11-07 log), so a teammate standing where you land is never taken. None
  -- fell = nearest, as before
  local function fell(h) return h.z and S.avtop[h.u] and S.avtop[h.u] - h.z > 30 end
  local fresh = nil
  if others_here() and drop_seen() then
    for _, h in ipairs(near) do
      h.x, h.y, h.z = upos(h.u, h.node)
      if h.bone == 'head' and h.kind == AVATAR_KIND and h.u ~= S.mine and fell(h) then fresh = true end
    end
  end
  for _, h in ipairs(near) do
    h.x, h.y, h.z = upos(h.u, h.node)
    local teammate = gate and h.u ~= S.mine
    if teammate and others_here() and h.bone == 'head' and h.kind == AVATAR_KIND then
      once('podwait' .. tostring(h.u), 'a teammate near the camera: waiting for your hellpod (%d players, fastest camera fall so far %.0f m/s)',
        chef.players(), S.fall_max or 0)
    end
    if fresh and not fell(h) then teammate = true end
    if h.x and h.bone == 'head' and h.kind == AVATAR_KIND and h.u ~= S.corpse and not teammate then  -- never back into a dead body
      local d = sqrt((h.x - c.x) ^ 2 + (h.y - c.y) ^ 2 + (h.z - c.z) ^ 2)
      -- several pods at once (a group reinforcement): the one the camera followed down most wins, then the nearest
      local f = fresh and (S.avfollow[h.u] or 0) or 0
      h.f = f
      if d < 6 and (not best or f > best.f or f == best.f and d < bd) then best, bd = h, d end
    end
  end
  if not best then S.head, S.parts = nil, {}; return end
  if not (S.head and S.head.u == best.u) then
    if best.u ~= S.mine and others_here() then
      log('your hellpod came down: taking that Helldiver (%s, came down %.0f m, followed by the camera %d times)',
        fresh and 'the one that fell' or 'nearest, none fell', S.avtop[best.u] and best.z and S.avtop[best.u] - best.z or 0,
        S.avfollow[best.u] or 0)
      S.avfollow = {}
      S.drop_t = nil
    end
    S.mine = best.u
    S.head = { u = best.u, node = best.node, root = chef.unit_node(best.u, 'root') or 1 }
    S.hmax, S.stance, S.down, S.rising, S.pidle = nil, nil, false, false, nil
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
    local lost = not chef.unit_alive(h.u)
    if not lost then
      local ours = false
      for _, k in ipairs(S.cams) do if k.state == 'ours' or k.state == 'scope' then ours = true end end
      local c = chef.camera()
      local x, y, z = upos(h.u, h.node)
      -- ship: kept while it's there (the cutscene camera framing a teammate's pod made the old check let go and
      -- take the teammate's Helldiver); S.away hands the view to the game instead
      lost = not x or (chef.in_mission() and not ours and not S.galaxy and c and (x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2 > 36)
    end
    if lost then
      if S.dead or S.down_any then
        S.corpse = h.u
      end
      S.head, S.parts = nil, {}
    end
  end
  -- a piece swapped out (new helmet or armour): drop it and look for the new one soon
  local live = {}
  for _, p in ipairs(S.parts) do if chef.unit_alive(p.u) then live[#live + 1] = p end end
  if #live < #S.parts then S.parts = live; table.insert(S.rescans, 1, S.t + 1) end
  -- in a hellpod on the ship, or its cutscene: no scans (the launch makes and removes units all at once)
  if S.nopod and not chef.in_mission() then return end
  if not S.head then
    -- right after your hellpod is seen: look every half second, so first person comes on as it lands
    local every = drop_seen() and 0.5 or 3
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
  local want = {}
  if S.act then
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
      if S.act and V[p.gear] then uw[p.u] = true end
    elseif p.groups and next(p.groups) == nil and p.u ~= (S.head and S.head.u) then
      n = n + 1
      local r = ROW['extra' .. n]
      if r then r.label = 'Piece ' .. n .. ' (on ' .. (p.bone or '?') .. ')' end
      if S.act and V['extra' .. n] then uw[p.u] = true end
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
local FRV_ANIM = { [108] = 'driver', [112] = 'passenger', [104] = 'gunner' }
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
local function tank_seat(it)
  local anim = seat_anim()
  local seat = TANK_ANIM[anim]
  if seat ~= S.tseat then S.tseat = seat; log('%s seat %s (animation %s)', TANKS[it.kind].name, seat, tostring(anim)) end
  return seat
end
local SEAT = { driver = { 'frv_fwd', 'frv_up', 'frv_side' }, passenger = { 'frvp_fwd', 'frvp_up', 'frvp_side' },
  gunner = { 'frvg_fwd', 'frvg_up', 'frvg_side' }, mech = { 'mech_fwd', 'mech_up', 'mech_side' }, empl = { 'empl_fwd', 'empl_up', 'empl_side' },
  bastion = { 'bastion_fwd', 'bastion_up', 'bastion_side' }, maelstrom = { 'maelstrom_fwd', 'maelstrom_up', 'maelstrom_side' } }

-- manning an emplacement: your feet stay within 1.2 m of its base (the head isn't inside its box)
-- the exosuit's settings prefix: its body's, or the nearest body's when the head sits in an arm's box
local function mech_model(it)
  if PRE[it.kind] then return PRE[it.kind] end
  local best, pre = 99, ''
  for _, o in ipairs(mech_watch.items) do
    local d = PRE[o.kind] and abs(o.x - it.x) + abs(o.y - it.y)
    if d and d < best then best, pre = d, PRE[o.kind] end
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
local function stance(dt, ox, oy, oz, rx, ry)
  -- tallest standing height: on foot only (the FRV gun read 2.1 m and made standing look like a crouch)
  if not (S.frv or S.mech or S.empl or S.tank) then S.hmax = max(S.hmax or 1.2, min(oz, 1.85)) end
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
  if r > 0.75 then S.fall, S.dive = nil, nil
  elseif not S.fall then
    local v = sqrt(S.vx * S.vx + S.vy * S.vy)
    S.fall = v > 1.5 and { S.vx / v, S.vy / v, v } or false
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
  local dv = S.dive == true and S.fall and not (S.frv or S.mech or S.empl or S.tank)
  if not dv and S.fall and not (S.frv or S.mech or S.empl or S.tank) and r < 0.75 and l > 0.3 then dv = (ox * S.fall[1] + oy * S.fall[2]) / l > 0.5 end
  -- S.diving = the hide switch for this dive's direction, or false
  dv = dv and (S.fall[4] > 0.5 and 'dive_hide' or S.fall[4] < -0.5 and 'dive_hide_back' or 'dive_hide_side')
  -- a dive lasts until you stand (standing height held 0.3 s), so its hiding and forward push hold while you get up
  local seated = S.frv or S.mech or S.empl or S.tank
  S.up_t = (S.stance == 'stand' or r > 0.8) and (S.up_t or 0) + dt or 0
  if not dv and S.diving and not seated and S.up_t < 0.3 then dv = S.diving end
  -- getting up: risen out of prone, until standing the same way
  S.rise_t = S.rising and (S.rise_t or 0) + (r > 0.5 and dt or 0) or 0
  if S.stance == 'prone' and oz > 0.1 and not seated and S.rise_t < 3 then S.rising = true elseif seated or S.up_t >= 0.3 or S.rise_t >= 3 then S.rising, S.pidle, S.prone_t = false, nil, 0 end
  -- the get-up starts while the head is still low: anything but the animation you settled prone in counts
  -- (log 2026-11-06: head goes 0.73 -> 1.39 m in 0.2 s, the clipping comes before that)
  local an
  if S.rising and chef.in_mission() then
    an = anim(S.head.u)
    if an ~= S.an then log('anim %s (%s, head %.2f m over feet)', tostring(an), S.stance or 'stand', oz); S.an = an end
    S.prone_t = S.stance == 'prone' and (S.prone_t or 0) + dt or 0
    if S.prone_t > 0.6 and S.pidle == nil and not GETUP_ANIM[an] then S.pidle = an; log('settled prone, anim %s', tostring(an)) end
  end
  local gu = S.rising and (r > 0.5 or GETUP_ANIM[an] or S.pidle ~= nil and an ~= S.pidle) or false
  if gu ~= (S.getup or false) then S.getup = gu; log('getting up %s', gu and 'start' or 'end') end
  if dv ~= (S.diving or false) then S.diving = dv; log('dive %s (head %.2f m over feet)', dv or 'end', oz); apply_hiding() end
  -- the game can show pieces again mid-dive: re-hide every frame while it lasts
  if dv and V[dv] then S.rehide = max(S.rehide or 0, S.t + 0.2) end
  local cur = S.stance or 'stand'
  local new = cur
  if cur == 'stand' and r < 0.75 or cur == 'prone' and r > 0.5 then new = 'crouch' end
  if r < 0.45 then new = 'prone' elseif r > 0.85 then new = 'stand' end
  if new ~= cur then S.stance = new; log('stance %s (head %.2f m over feet, tallest %.2f)', new, oz, S.hmax) end
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
  local a = 1 - exp(-dt * 10)
  -- lying: the lift fades out as you look down (none past ~45 deg down), so looking down at your back never shows the neck
  local dk = S.stance == 'prone' and c and min(1, max(0, 1 - (-c.fz - 0.3) / 0.4)) or 1
  local wf, wu = (st[1] == 0 and 0 or V[st[1]]) + (S.diving and S.diving ~= 'dive_hide_back' and V.dive_fwd * (1 - back) or 0), (st[2] == 0 and 0 or V[st[2]] * dk) + V.back_lift * back * dk + (S.getup and V.getup_cam and V.getup_lift * min(1, max(0, (0.8 - r) / 0.25)) or 0)
  local ws = st[3] == 0 and 0 or V[st[3]]
  -- backward dive in the air (until S.oblie = lying still on your back)
  if S.diving == 'dive_hide_back' and not S.getup and not S.oblie then wf = wf + V.bdive_fwd end
  -- face view: the face already places the view, so no guessed pushes or lifts while down
  S.eyes = V.eyes and (S.diving or S.stance == 'prone') and not S.getup and not (S.frv or S.mech or S.empl or S.tank) or false
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
    S.down_t = (r < 0.5 and away and not S.dive) and (S.down_t or 0) + dt or 0
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
  S.warp = S.t
end

-- the view position for this frame: head (its offset from the root smoothed), then the offsets along the view
local function target(dt)
  local h = S.head
  local hx, hy, hz = upos(h.u, h.node)
  local rx, ry, rz = upos(h.u, h.root)
  if not (hx and rx) then S.head = nil; return end
  if S.prx and S.prz and S.wu == h.u then warp_check(rx - S.prx, ry - S.pry, rz - S.prz) end
  S.wu = h.u  -- a new body (reinforced) is no warp
  -- rising speed, eased over 0.05 s (a single-frame jump is a respawn or teleport)
  if S.prz and dt > 0 and abs(rz - S.prz) < 2 then S.vz = S.vz + ((rz - S.prz) / dt - S.vz) * (1 - exp(-dt * 20)) else S.vz = 0 end
  S.prz = rz
  local ox, oy, oz = hx - rx, hy - ry, hz - rz
  -- lying on your back, whatever got you there (backward or side dive, rolling over)
  local bu = (S.diving or S.stance == 'prone' or not S.bsign) and belly_up(h)
  local ob = (S.diving or S.stance == 'prone') and bu and (S.onback and bu > 0.3 or bu > 0.5) or false
  if ob ~= (S.onback or false) then S.onback = ob; log('on your back %s (belly up %.2f)', ob and 'start' or 'end', bu or -9) end
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
  local onb = (S.onback or S.diving == 'dive_hide_back') and S.an == 48 and not S.getup and not (S.frv or S.mech or S.empl or S.tank)
  S.oblie = onb
  -- the belly shows for the whole time on your back, the dive's air part too (0.3.57 only showed it once landed)
  local bl = (S.onback or S.diving == 'dive_hide_back') and not S.getup and not (S.frv or S.mech or S.empl or S.tank) or false
  if bl ~= (S.belly or false) then S.belly = bl; apply_hiding() end
  S.obk = (S.obk or 0) + ((onb and 1 or 0) - (S.obk or 0)) * (1 - exp(-dt * 10))
  if S.obk > 0.005 then
    local hl = sqrt(ox * ox + oy * oy)
    if V.onback_reach > 0 and hl > V.onback_reach then
      local k = 1 - S.obk * (1 - V.onback_reach / hl); ox, oy = ox * k, oy * k
    end
    if V.onback_height > 0 and oz < V.onback_height then oz = oz + S.obk * (V.onback_height - oz) end
  end
  -- S.gw = how much the clamp holds (1 while getting up, then eased out over ~0.3 s): a blend, so letting go never
  -- snaps (a max() with a shrinking distance jumped 0.5 m in one frame, 2026-11-07). S.ga = the clamp's reach now
  -- get-ups only: in a backward dive the head ends 0.7 m behind the hips, so letting go at lying slid the view back
  -- through the chest (black screen, log 2026-11-07)
  local low = V.getup_cam and S.getup and not (S.frv or S.mech or S.empl or S.tank)
  local want = low and V.getup_ahead * rise or 0
  if low then S.gw, S.gr = 1, want else S.gw = (S.gw or 0) * exp(-dt * 10) end
  S.ga = S.gw * (S.gr or 0)
  local c0 = S.ga > 0.005 and chef.camera()
  local h0 = c0 and sqrt(c0.fx * c0.fx + c0.fy * c0.fy) or 0
  if h0 > 1e-4 then
    local ux, uy = c0.fx / h0, c0.fy / h0
    local f, sd = ox * ux + oy * uy, ox * uy - oy * ux
    f = f + S.gw * (max(f, S.gr) - f)
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
  if fly then local g = 1 - exp(-dt / 0.03); a, b = max(a, g), max(b, g) end
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
  local c = chef.camera()
  local fx, fy, fz = 0, 1, 0
  if c then fx, fy, fz = c.fx, c.fy, c.fz end
  local hl = sqrt(fx * fx + fy * fy); if hl < 1e-4 then hl = 1 end
  local seat = SEAT[S.frv or S.mech and 'mech' or S.empl and 'empl' or S.tpass or '']
  local pre = S.frv and S.frv_pre or S.mech and S.mech_pre or S.empl and S.empl_pre or ''
  local f = V.fwd + (seat and V[pre .. seat[1]] or S.sf or 0)
  local up = V.up + (seat and V[pre .. seat[2]] or S.su or 0)
  local sd = V.side + (seat and V[pre .. seat[3]] or S.ss or 0)
  -- aiming on foot: the VIEW WHILE AIMING offsets, eased in and out with the aim (S.aimw 0..1)
  local aiming = S.aim and S.act and not (S.frv or S.mech or S.empl or S.tank) or false
  local at = V.aimpos_time
  S.aimw = at > 0 and max(0, min(1, (S.aimw or 0) + (aiming and dt or -dt) / at)) or (aiming and 1 or 0)
  if S.aimw > 0 then
    local e = S.aimw * S.aimw * (3 - 2 * S.aimw)   -- eased: starts and ends gently
    f, up, sd = f + e * V.aimpos_fwd, up + e * V.aimpos_up, sd + e * V.aimpos_side
  end
  -- offsets along the level view, height straight up: looking up or down no longer carries the view up into the gun
  -- or down into the chest; on foot, looking down pushes it forward instead
  local ux, uy = fx / hl, fy / hl
  if not seat then f = f + max(0, -fz) * V.look_down end
  S.tx = rx + S.sm[1] + ux * f + uy * sd
  S.ty = ry + S.sm[2] + uy * f - ux * sd
  S.tz = rz + S.sm[3] + up
  S.trx, S.try, S.trz = rx, ry, rz  -- the root this view was built from (the draw pass moves it along)
end

-- the game's own camera rotation this frame: the one we wrote last frame (k.last) is still ours, anything else is the
-- game's (the mouse). Shared by the look limit and the crosshair fix, so neither takes the other's turn for the mouse.
local function game_rot(k, cam)
  local a, b, c, d = call('Quaternion.to_elements', call('Camera.local_rotation', cam))
  if type(a) ~= 'number' then once('qr', 'camera rotation: none (%s)', tostring(b)); return end
  local l = k.last
  local mine = l and abs(a - l[1]) + abs(b - l[2]) + abs(c - l[3]) + abs(d - l[4]) < 1e-5
  if not mine or not k.qb then k.qb = { a, b, c, d } end
  return call('Quaternion.from_elements', k.qb[1], k.qb[2], k.qb[3], k.qb[4]), mine
end

local function wrote(k, q)
  local e1, e2, e3, e4 = call('Quaternion.to_elements', q)
  k.last = { e1, e2, e3, e4 }
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
local enemy_watch = chef.watch and chef.watch(ENEMY_KINDS, 1) or nil

-- the game shoots along its own camera line (over your shoulder). While aiming, the view turns a little toward the
-- point that line reaches at the target distance, so the crosshair and the shots meet there: the distance of the
-- enemy under the crosshair (box test along the game's line), else aim_dist. Only the mouse moves that line, so no
-- jitter (0.3.66/67 used the gun: it sways 2-11 deg off the aim).
local function aim_range(G, dx, dy, dz)
  if not (enemy_watch and chef.ray_box) then return nil, 'no enemy list' end
  local from, dir = { x = G[1], y = G[2], z = G[3] }, { x = dx, y = dy, z = dz }
  local best, bu
  for _, it in ipairs(enemy_watch.items) do
    local x, y, z = upos(it.unit)
    if x then
      local vx, vy, vz = x - G[1], y - G[2], z - G[3]
      local along = vx * dx + vy * dy + vz * dz
      if along > 2 and along < 200 then
        local side = sqrt(max(0, vx * vx + vy * vy + vz * vz - along * along))
        -- only enemies within 6 deg (or 3 m) of the line get the box test
        if side < max(3, along * 0.105) then
          local hit = chef.ray_box(from, dir, it.unit)
          if type(hit) == 'number' and hit > 2 and (not best or hit < best) then best, bu = hit, it.unit end
        end
      end
    end
  end
  if best then return best, 'enemy', bu end
  return nil, 'no enemy'
end

-- the distance the view converges at, held steady: re-picking the nearest enemy every frame flipped between enemies
-- in a crowd (0.3.108 'jumpy'). A new enemy or distance counts only once it stayed 0.15 s (0.25 s to switch enemy),
-- changes under 1.5 m (or 5%) are ignored, and a lost target is kept 1.25 s before going back to aim_dist.
local function held_range(D, u)
  local h = S.hr or {}
  S.hr = h
  if D then
    h.lost = nil
    if h.cu ~= u or not h.cd or abs(D - h.cd) > max(1, h.cd * 0.05) then h.cu, h.cd, h.since = u, D, S.t end
    if S.t - h.since >= ((h.u and h.u ~= u) and 0.25 or 0.15) then
      if not h.d or h.u ~= u or abs(h.cd - h.d) >= max(1.5, h.d * 0.05) then h.d = h.cd end
      h.u = u
    end
  else
    h.cu, h.cd = nil, nil
    h.lost = h.lost or S.t
    if S.t - h.lost >= 1.25 then h.d, h.u = nil, nil end
  end
  return h.d
end

local function aim_fix(k, cam, dt)
  local base, mine = game_rot(k, cam)
  if not base then return end
  local dx, dy, dz = xyz(call('Quaternion.forward', base))
  local on = V.aim_fix and (S.aim or V.aim_hip) and dx and S.gcx and k.wx
  local D, src
  if on and not S.draw then
    -- fixed distance unless aim_range (aiming) or hip_range (hip; enemy ranging there turned the view far too hard, 0.3.109)
    local raw, u, _
    if (S.aim and V.aim_range) or (not S.aim and V.hip_range) then raw, _, u = aim_range({ S.gcx, S.gcy, S.gcz }, dx, dy, dz) end
    S.araw = raw
    D = held_range(raw, u)
    src = D and 'enemy' or 'no enemy'
    -- from the hip hip_strength scales only the extra turn toward the enemy (in 1/distance), the base aim_dist turn
    -- stays whole so shots at range still land
    if D and not S.aim then D = 1 / (1 / V.aim_dist + V.hip_strength / 10 * (1 / D - 1 / V.aim_dist)) end
    D = D or V.aim_dist
    -- eased in 1/distance (up close the turn goes with 1/distance, so equal steps feel equal): a held enemy over at
    -- most 0.25 s, back to aim_dist over aim_ease; from the hip both over hip_ease
    local te = max(not S.aim and V.hip_ease or S.hr.d and min(V.aim_ease, 0.25) or V.aim_ease, 0.01)
    S.ad = S.ad and 1 / (1 / S.ad + (1 / D - 1 / S.ad) * (1 - exp(-dt / te))) or D
  end
  local rate = 1 / max(V.aim_ease, 0.05)
  S.aw = on and min(1, (S.aw or 0) + dt * rate) or max(0, (S.aw or 0) - dt * rate)
  if S.aw <= 0 or not (S.ad and S.gcx and dx) then
    if S.aw <= 0 then S.ad, S.hr = nil, nil end
    if mine then call('Camera.set_local_rotation', cam, k.u, base) end
    k.last = nil
    return
  end
  -- from where the camera really is this frame (head + the forward/side offsets), not the bare head: up close the
  -- offsets left the turn short (0.3.107: hip shots right of the crosshair)
  local hx, hy, hz = S.gcx + S.ad * dx - k.wx, S.gcy + S.ad * dy - k.wy, S.gcz + S.ad * dz - k.wz
  local hl = sqrt(hx * hx + hy * hy + hz * hz)
  if hl < 0.5 then return end
  hx, hy, hz = hx / hl, hy / hl, hz / hl
  -- never more than aim_max deg off the game's look (at least 20 from the hip with hip_range: the game camera sits ~0.9 m to the side, so an enemy
  -- at 3 m needs ~17 deg)
  local c = hx * dx + hy * dy + hz * dz
  local lim = math.cos(math.rad((S.aim or not V.hip_range) and V.aim_max or max(V.aim_max, 20)))
  if c < lim then
    local px, py, pz = hx - c * dx, hy - c * dy, hz - c * dz
    local pl = sqrt(px * px + py * py + pz * pz)
    local sn = sqrt(1 - lim * lim)
    hx, hy, hz = dx * lim + px / pl * sn, dy * lim + py / pl * sn, dz * lim + pz / pl * sn
  end
  -- the strength slider only while aiming: from the hip the game camera sits far back, so anything less than the
  -- full turn leaves the shots far off the crosshair (0.3.103 at strength 5)
  local w = S.aw * (S.aim and V.aim_strength / 10 or 1)
  local nq = call('Quaternion.look', Vec(dx + w * (hx - dx), dy + w * (hy - dy), dz + w * (hz - dz)), Vec(0, 0, 1))
  local _, err = call('Camera.set_local_rotation', cam, k.u, nq)
  if err then once('aw' .. tostring(err), 'aim fix: rotation write refused: %s', tostring(err)) else wrote(k, nq) end
end

-- backward dive: the view tilts no further down than dive_look, eased in and out, so it never looks through the open
-- collar into the hollow body (log 2026-11-07: head 0.11 m from the chest). Turns the view only, never moves it.
local function pitch_limit(k, cam, dt)
  local on = V.dive_look > 0 and S.diving == 'dive_hide_back' and not S.oblie and not S.getup and not S.aim
  S.pw = on and min(1, (S.pw or 0) + dt * 8) or max(0, (S.pw or 0) - dt * 6)
  if S.pw <= 0 and not k.qw then return end
  local base, mine = game_rot(k, cam)
  if not base then return end
  if S.pw <= 0 then
    if mine then call('Camera.set_local_rotation', cam, k.u, base) end
    k.qw, k.last = nil, nil; log('look limit off'); return
  end
  local fx, fy, fz = xyz(call('Quaternion.forward', base))
  local hl = fx and sqrt(fx * fx + fy * fy) or 0
  if hl < 1e-3 then return end
  local down = math.deg(math.asin(max(-1, min(1, -fz))))
  local L, soft = V.dive_look, 10
  local t = down
  if down > L - soft then t = L - soft + soft * (1 - exp(-(down - (L - soft)) / soft)) end
  t = down + S.pw * (t - down)
  local cr, sr = math.cos(math.rad(t)), math.sin(math.rad(t))
  local nq = call('Quaternion.look', Vec(fx / hl * cr, fy / hl * cr, -sr), Vec(0, 0, 1))
  local _, why = call('Camera.set_local_rotation', cam, k.u, nq)
  if why then once('qw' .. tostring(why), 'look limit: rotation write refused: %s', tostring(why)); return end
  k.qw = true; wrote(k, nq)
  if not k.qlog then log('look limit on') end
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
  local ok = V.imm_on and S.act and u and (S.stance or 'stand') ~= 'prone'
    and not (S.aim or S.diving or S.getup or S.frv or S.mech or S.empl or S.tank or S.down or S.dead)
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

local function restore(k, cam)
  if cam and k.near0 then call('Camera.set_near_range', cam, k.near0) end
  if cam and k.fov0 then call('Camera.set_vertical_fov', cam, k.fov0) end
  k.near0, k.fov0, k.fvw = nil, nil, nil
end

local function place(w)
  -- hellpod hand-off: each frame write the game's own camera spot moved toward first person by what's left of 0.25 s
  local bw = not S.act and S.pout and S.tx and 1 - (S.t - S.pout) / 0.25 or 0
  if bw > 0 then
    for _, k in ipairs(S.cams) do
      local cam = k.main and call('Unit.camera', k.u, k.slot)
      local cx, cy, cz = xyz(cam and call('Camera.local_position', cam))
      if cx then
        call('Camera.set_local_position', cam, k.u, Vec(cx + (S.tx - cx) * bw, cy + (S.ty - cy) * bw, cz + (S.tz - cz) * bw))
        call('World.update_unit', w, k.u)
      end
    end
  end
  if not S.act then
    -- third person: only a vehicle's own field of view, else the game's
    for _, k in ipairs(S.cams) do
      local cam = (S.fv or k.fov0) and cam_of(k)
      if cam and S.fv then
        k.fov0 = k.fov0 or call('Camera.vertical_fov', cam)
        call('Camera.set_vertical_fov', cam, math.rad(S.fv))
      elseif cam then call('Camera.set_vertical_fov', cam, k.fov0); k.fov0 = nil end
    end
    return
  end
  if not (S.head and S.tx) then return end
  local hx, hy, hz = upos(S.head.u, S.head.node)
  if not hx then return end
  local scoped = false
  -- in a mech the game's camera sits in the mech's own frame (x right, y forward, z up from its root)
  local mx, my, mz, mfx, mfy
  if S.mech and not V[S.mech_pre .. 'tp_mech'] then
    mx, my, mz = upos(S.mech)
    mfx, mfy = chef.unit_rotation(S.mech)
    local l = mfx and sqrt(mfx * mfx + mfy * mfy) or 0
    if l > 1e-4 then mfx, mfy = mfx / l, mfy / l else mfx = nil end
  end
  for ci, k in ipairs(S.cams) do
    local cam = cam_of(k)
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
      if state ~= k.state and d < 0.4 then log('camera %d: %.2f m from the head, %.2f m ahead', ci, d, al) end
      if k.main then
        S.gcx, S.gcy, S.gcz = cx, cy, cz  -- the game's own camera: the line it shoots along
        -- lying or diving the floor squeezes it in and out frame to frame and the aim fix turned the view with it
        -- (aiming on your back looking down-right, 2026-11-09): hold its offset from the root steady there (0.15 s)
        local rx, ry, rz = S.trx, S.try, S.trz
        if rx and (S.diving or S.stance == 'prone') then
          local o, g = S.go, 1 - exp(-(S.dt or 0) / 0.15)
          if not o then o = { cx - rx, cy - ry, cz - rz }; S.go = o end
          o[1], o[2], o[3] = o[1] + (cx - rx - o[1]) * g, o[2] + (cy - ry - o[2]) * g, o[3] + (cz - rz - o[3]) * g
          S.gcx, S.gcy, S.gcz = rx + o[1], ry + o[2], rz + o[3]
        else S.go = nil end
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
    -- any hand-off (scope, far, back): the game shows the helmet again a few frames later, re-hide every frame for 1 s
    if state ~= k.state then k.state = state; S.rehide = S.t + 1; log('camera %d (slot %d): %s', ci, k.slot, state) end
    if state == 'scope' then scoped = true end
      if state ~= 'ours' and state ~= 'mech' then
      if k.wx then restore(k, cam) end
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
      k.wx, k.wy, k.wz = px, py, pz
      local _, why = call('Camera.set_local_position', cam, k.u, Vec(px, py, pz))
      if why then once('w' .. tostring(why), 'camera write refused: %s', tostring(why))
      else
        if k.main and state == 'ours' then
          pitch_limit(k, cam, S.dt or 0.016)
          if not k.qw then view_limit(k, cam, S.dt or 0.016) end
          if not (k.qw or k.yq) then k.qlog = nil; aim_fix(k, cam, S.dt or 0.016) end
        end
        local nr = V.near
        if nr > 0 then
          k.near0 = k.near0 or call('Camera.near_range', cam)
          call('Camera.set_near_range', cam, nr)
        elseif k.near0 then call('Camera.set_near_range', cam, k.near0); k.near0 = nil end
        if S.fv then
          k.fov0 = k.fov0 or call('Camera.vertical_fov', cam)
          k.fvw = math.rad(S.fv)
          call('Camera.set_vertical_fov', cam, k.fvw)
        elseif k.fov0 then call('Camera.set_vertical_fov', cam, k.fov0); k.fov0, k.fvw = nil, nil end
        call('World.update_unit', w, k.u)
      end
    end
  end
  if scoped ~= S.scoped then S.scoped = scoped; apply_hiding() end
end

-- our camera in use: on, and nothing hands the view to the game's camera (peek key, knocked down, mech, emplacement)
local function set_act(act, why)
  if act == S.act then return end
  S.act = act
  -- hellpod: nothing written back, 0.25 s ease into the game's own camera and back out of it
  local pod = why == 'hellpod'
  if act and S.offwhy == 'hellpod' then S.pin = S.t end
  if not act then S.offwhy, S.pout = why, pod and S.t or nil end
  if not act then
    -- other hand-offs: put the game's own last spot back and turn back (0.3.100)
    local w = chef.world()
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
      restore(k, cam)
      k.wx, k.state, k.last = nil, nil, nil
    end
    S.tx, S.scoped, S.aim = nil, false, false
  end
  apply_hiding()
  log('first person view %s (%s)', act and 'on' or 'off', why)
end

local function set_on(on)
  if on == S.on then return end
  S.on = on
  log('first person %s', on and 'on' or 'off')
  if not on then set_act(false, 'switched off') end
end

-- galactic map (ship only): using the table puts your feet on one fixed spot and leans you over it, head about
-- 1.4-1.5 m above your feet; standing or walking it's 1.65-1.7 (probe log, 2026-11-06). Leaving stands you up first.
-- shortcut: the spot is the Super Destroyer's table in world units; a ship layout change would need a new probe
local TABLE_X, TABLE_Y, TABLE_Z = 0, 12.97, 19.57
local function galaxy_check(dt)
  local h = S.head
  local rx, ry, rz, hz
  if h and not chef.in_mission() then
    rx, ry, rz = upos(h.u, h.root)
    hz = select(3, upos(h.u, h.node))
  end
  local at = rx and hz and abs(rx - TABLE_X) < 0.3 and abs(ry - TABLE_Y) < 0.3 and abs(rz - TABLE_Z) < 0.3
    and hz - rz < 1.6 and anim(h.u) == 0  -- 0 = standing still (1 walk, 3 start, 5/6 stop)
  S.gal_off = at and 0 or (S.gal_off or 0) + dt
  if at and not S.galaxy or S.galaxy and S.gal_off > 0.25 then
    S.galaxy = at
    log('galactic map %s (head %s above feet)', at and 'in use' or 'left', hz and rz and string.format('%.2f m', hz - rz) or '?')
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
      if cx and not (k.wx and abs(cx - k.wx) + abs(cy - k.wy) + abs(cz - k.wz) < 0.001) then
        known = true
        far = far or (cx - x) ^ 2 + (cy - y) ^ 2 + (cz - z) ^ 2 > 3.5 ^ 2
      end
    end
  end
  local c = not S.act and chef.camera()
  if c and c.x then known = true; far = far or (c.x - x) ^ 2 + (c.y - y) ^ 2 + (c.z - z) ^ 2 > 36 end
  if known then return far end
end

-- hellpods, whatever the settings (tp_pod only picks the view, every frame, before anything asks the body):
-- S.pod   in a hellpod. Ship: the head down at prone height (nothing else on the ship lays you down, 2026-11-07),
--         from climbing in until the ship unloads. Mission: the drop, from the game camera falling 25+ m/s for
--         0.25 s until you step out of the landed pod (1.5 m from where it landed, or 6 s after landing)
-- S.away  ship: the game's view over 3.5 m from your head (the launch cutscene, a terminal's close-up): the game's
--         view, as when the old 6 m check let go of the Helldiver, but the Helldiver is kept
-- S.nopod the body is left alone: no animation questions, and on the ship no scans for another Helldiver and no
--         mesh probes. Nothing here depends on saved pod spots or on which keys you use
local function pod_guard(dt)
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
  local at_table = rx and abs(rx - TABLE_X) < 1 and abs(ry - TABLE_Y) < 1
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
  local busy = S.down_any or S.dead or S.down or S.diving or S.getup or S.pod or S.nopod or S.frv or S.mech or S.empl or S.tank
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

local function update_act()
  local why
  if not S.on then why = 'switched off'
  elseif S.dead then why = 'dead'
  elseif binds.peek and binds.peek.down() and not S.panel then why = 'peek key'
  elseif V.tp_galaxy and S.galaxy then why = 'galactic map'
  elseif V.tp_pod and (S.puse or S.pod) then why = 'hellpod'  -- user: the game's own view from using a pod
  elseif S.away and not chef.in_mission() then why = 'game camera away'  -- whatever the settings (the cutscene)
  elseif V.tp_term and S.term then why = 'terminal'
  elseif V.tp_menus and S.map_open then why = 'map'
  elseif V.tp_menus and S.strat_open then why = 'stratagems'
  elseif V.tp_down and S.down and not (S.frv or S.mech or S.empl or S.tank) then why = 'knocked down'  -- seats look like lying down
  elseif S.tank and (S.tank.seat == 'crew' or V[S.tank.tp]) then why = 'tank ' .. S.tank.seat
  elseif S.frv and V[S.frv_pre .. 'frv_tp'] then why = 'FRV'
  elseif S.mech and V[S.mech_pre .. 'tp_mech'] then why = 'mech'
  elseif S.empl and V[S.empl_pre .. 'tp_empl'] then why = 'emplacement' end
  set_act(why == nil, why or 'first person')
end

---------------------------------------------------------------------------------------------------- panel
local P = { open = false, tab = 1, row = 1, cx = 0, cy = 0, capture = nil, rep = 0, drag = nil }
local CAPTURE_KEYS = {}
for i = 1, 12 do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = 'f' .. i end
for c in ('abcdefghijklmnopqrstuvwxyz0123456789'):gmatch('.') do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = c end
for _, k in ipairs({ 'insert', 'home', 'end', 'page up', 'page down', 'tab', 'caps lock', 'left alt', 'right alt',
  'left ctrl', 'right ctrl', 'numpad 0', 'numpad 1', 'numpad 2', 'numpad 3', 'numpad 4', 'numpad 5', 'numpad 6',
  'numpad 7', 'numpad 8', 'numpad 9' }) do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = k end

local function open_panel(on)
  P.open, P.capture, P.drag, S.panel = on, nil, nil, on
  if chef.hold_mouse then chef.hold_mouse(on) end
  if on then local sw, sh = chef.screen(); P.cx, P.cy = sw / 2, sh / 2 end
end

local function rows() return TABS[P.tab].rows end
local function value_text(r)
  if r.key then
    if P.capture == r.id then return 'PRESS A KEY' end
    local k = binds[r.id] and binds[r.id].key() or 'off'
    return k == 'off' and 'NONE' or (chef.key_label and chef.key_label(k) or k):upper()
  end
  local v = V[r.id]
  if r.toggle then return v and 'ON' or 'OFF' end
  if v == 0 and r.zero then return r.zero end
  if PICKS[r.id] then local m = PICKS[r.id].models; return (m[v] or m[1]).name end
  local d = r.step < 1 and 2 or 0
  return string.format('%.' .. d .. 'f', v) .. (r.unit or '')
end
local function reset(r)
  if not r.id then return end
  if r.key then chef.set(r.id, r.def) else set(r.id, r.def) end
  if r.toggle or r.id == 'profile' then apply_hiding() end
end
local function is_def(r)
  if r.key then return (binds[r.id] and binds[r.id].key()) == r.def end
  return V[r.id] == r.def
end
-- the whole tab, every model's copy on model tabs; the model pickers stay where they are
local function reset_tab()
  local list = rows()
  for _, r in ipairs(list) do if not PICKS[r.id] and r.id ~= 'profile' then reset(r) end end
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

local function draw_panel(dt)
  local sw, sh = chef.screen()
  local s = sh / 1080
  local px = max(2, floor(2 * s + 0.5))
  local sp = max(2, px - 1)
  local W, RH, HH, HEAD, TABH, FOOT = floor(720 * s), floor(40 * s), floor(32 * s), floor(64 * s), floor(42 * s), floor(70 * s)
  local list = rows()
  local rows_h = 0
  for _, r in ipairs(list) do rows_h = rows_h + (r.head and HH or RH) end
  -- long tabs scroll: show what fits on screen, keep the selected row in view, the wheel scrolls off the sliders
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
  -- rows
  local track_w = floor(200 * s)
  local ry = tby - floor(8 * s) + P.scroll
  local over_slider = false
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
          if hover then over_slider = true; local wv = chef.wheel(); if wv and wv ~= 0 then change(r, wv > 0 and 1 or -1) end end
        end
      end
    end
  end
  if rows_h > fit and not over_slider and hit(x0, tby - fit, W, fit) then
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
  if P.capture then
    if chef.key_pressed('delete') then chef.set(P.capture, 'off'); P.capture = nil; return end
    for _, k in ipairs(CAPTURE_KEYS) do
      if chef.key_pressed(k) then chef.set(P.capture, k); P.capture = nil; return end
    end
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
  if not chef.in_mission() then S.dead, S.corpse, S.avs, S.av_gen, S.down_any = false, nil, nil, nil, false; return end
  local lying = S.head and (S.stance == 'prone' or S.down or S.dive)
  S.down_any = lying or S.dead or S.getup or false
  if cam_watch.generation ~= S.dgen then
    S.dgen = cam_watch.generation
    local set, changed = {}, false
    for _, it in ipairs(cam_watch.items) do set[it.unit] = true; if S.dcams and not S.dcams[it.unit] then changed = true end end
    for u in pairs(S.dcams or {}) do if not set[u] then changed = true end end
    S.dcams = set
    if changed and lying and not S.dead then S.dead = true; log('cameras changed while lying (%s): game camera until up', S.stance or '?') end
  end
  local h = S.head
  if S.dead and h and h.u ~= S.corpse and not lying and not S.pod then S.dead = false; log('up: first person again') end
end

function M.update(dt)
  local busy = P.capture ~= nil
  if not busy and binds.panel and binds.panel.pressed() then open_panel(not P.open) end
  if P.open then panel_keys(dt) end
  -- works on the ship too; nil while a world loads
  local w = chef.world()
  if not w then
    if S.on then set_on(false) end
    S.started = nil
    if P.open then draw_panel(dt) end
    return
  end
  if chef.world_id() ~= S.world then
    S.started = nil  -- new world (ship <-> mission): old units are gone, start fresh
    S.world, S.cams, S.head, S.hidden, S.parts, S.on, S.tx = chef.world_id(), {}, nil, {}, {}, false, nil
    S.ghid, S.gst, S.gsaid = {}, {}, {}
    S.last_scan, S.rescans, S.cam_gen = nil, {}, nil
    S.hr = nil
    S.ad, S.aw, S.podu, S.puse, S.pod = nil, nil, nil, false, false
    S.away, S.away_t, S.spod, S.slow_t, S.sup_t, S.shmax, S.nopod, S.mdrop, S.pfall_t = false, 0, false, 0, 0, nil, false, nil, 0
    S.calm_t = 0
    S.down_any, S.getup, S.rising = false, false, false
    S.act, S.down, S.stance, S.hmax, S.fv = false, false, nil, nil, nil
    S.mech, S.frv, S.empl, S.tank, S.tpass = false, false, false, false, false
    S.dead, S.corpse, S.avs, S.av_gen, S.dgen, S.dcams = false, nil, nil, nil, nil, nil
    S.mine, S.drop_t, S.fall_t, S.lcz, S.fall_max, S.avtop, S.avfollow = nil, nil, 0, nil, 0, {}, {}
  end
  S.t = S.t + dt
  -- the game camera falling 12+ m/s for 0.25 s = a hellpod coming down (a single-frame jump is a camera cut)
  local gc = chef.camera()
  if gc and S.lcz and dt > 0 and dt < 0.1 then
    local vz = (gc.z - S.lcz) / dt
    if vz < 0 then S.fall_max = max(S.fall_max or 0, -vz < 150 and -vz or 0) end
    S.fall_t = (vz < -12 and vz > -150) and (S.fall_t or 0) + dt or 0
    S.pfall_t = (vz < -25 and vz > -150) and (S.pfall_t or 0) + dt or 0
    S.calm_t = vz > -12 and (S.calm_t or 0) + dt or 0
    if S.fall_t >= 0.25 and not drop_seen() then
      S.drop_t = S.t
      if others_here() then log('hellpod drop seen (game camera falling %.0f m/s)', -vz) end
    end
  elseif not gc then
    S.calm_t = 0
  end
  S.lcz = gc and gc.z
  refresh_cams()
  S.look = S.look - dt
  if S.look <= 0 then S.look = 0.5; check_player(w); apply_hiding() end
  if probe_one() or (S.rehide and S.t < S.rehide) then apply_hiding() end
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
    -- tank seats are known by animation alone, so the tank is just the nearest one: no engine call on a tank at all
    local tk = false
    if TANK_ANIM[seat_anim()] and tank_watch and S.head then
      local hx, hy = upos(S.head.u, S.head.node)
      for _, t in ipairs(hx and tank_watch.items or {}) do
        if abs(t.x - hx) + abs(t.y - hy) < 7 then tk = t end
      end
    end
    -- a seat animation held 0.5 s to get in, 0.5 s without one to get out (standing on top isn't a seat)
    local sit = tk and TANK_ANIM[seat_anim()] ~= nil
    S.tank_on = sit and (S.tank_on or 0) + 1 or 0
    S.tank_off = sit and 0 or (S.tank_off or 0) + 1
    if sit and (S.tank or S.tank_on >= 2) then
      S.tank = { seat = tank_seat(tk), tp = TANKS[tk.kind].tp, id = TANKS[tk.kind].id }
    elseif S.tank and S.tank_off >= 2 then
      S.tank, S.tseat = false, nil; log('out of the tank')
    end
    S.tpass = S.tank and S.tank.seat == 'passenger' and S.tank.id or false
    local mech = inside(mech_watch, nil, S.mech)
    S.mech_pre = mech and mech_model(mech) or ''
    mech = mech and mech.unit or false
    if mech ~= S.mech then log(mech and 'in a mech' or 'out of the mech') end
    S.mech, S.empl = mech, at_emplacement()
  end
  if V.start_on and not S.started and S.head then S.started = true; set_on(true) end
  if not busy and binds.toggle and binds.toggle.pressed() then set_on(not S.on); say(S.on and 'FIRST PERSON ON' or 'FIRST PERSON OFF') end
  if not busy and binds.profile_key and binds.profile_key.pressed() then
    set('profile', V.profile % 5 + 1); apply_hiding(); say('PROFILE ' .. V.profile)
  end
  S.dt = dt
  death_check()
  pod_guard(dt)
  -- the game's view on the ship (its cutscene camera, or in a pod with Third person in the hellpod): the body isn't
  -- followed until it's back
  local ship_off = not chef.in_mission() and (S.away or S.pod and V.tp_pod)
  if S.on and S.head and not ship_off then target(dt) end
  if S.on and V.tp_galaxy then galaxy_check(dt) else S.galaxy = false end   -- every frame: the head shows at once
  if S.on and V.tp_term then term_check() else S.term = false end
  if S.on and V.tp_pod then pod_check() else S.puse = false end
  menu_check()
  update_act()
  -- aiming (right mouse, held or toggled): its own field of view, blended; 0 = the same as the normal one
  local rmb = not P.open and chef.mouse_down('right') or false
  if V.aim_toggle then
    if rmb and not S.rmb then S.aim = not S.aim end
  else S.aim = rmb end
  S.rmb = rmb
  neck(w)
  local vf = S.frv and V[S.frv_pre .. 'frv_fov'] or S.tpass and V[S.tpass .. '_fov'] or S.mech and V[S.mech_pre .. 'mech_fov']
    or S.empl and V[S.empl_pre .. 'empl_fov'] or S.tank and 0
    or S.act and (S.stance == 'crouch' and V.crouch_fov or S.stance == 'prone' and V.prone_fov) or 0  -- stance: first person only
  local want = S.act and (S.aim and V.aim_fov > 0 and V.aim_fov or vf > 0 and vf or V.fov) or vf
  if want > 0 then S.fv = S.fv and S.fv + (want - S.fv) * (1 - exp(-dt * 14)) or want else S.fv = nil end
  hide_guns()
  place(w)
  if P.open then draw_panel(dt) end
  draw_msg(dt)
end

function M.render()
  local w = chef.world()
  if not w then return end
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
    S.tx, S.ty, S.tz = S.tx + dx, S.ty + dy, S.tz + dz
    S.trx, S.try, S.trz = x, y, z
  end
  place(w)
  S.draw = nil
end

function M.on_stop()
  set_on(false)
  if P.open then open_panel(false) end
end
M.shutdown = M.on_stop

M._P, M._S, M._V, M._TABS = P, S, V, TABS
return M
