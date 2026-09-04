extends Node3D

# ---- Config ----
const GRID_SIZE := 9
const TILE_SPACING := 1.2
const TURNS_PER_GAME := 30
const SPREAD_CHANCE := 0.45
const STARTING_SEEDS := 5
const SEEDS_PER_TURN := 1

const TERRAIN_TOP := [
	Color(0.58, 0.88, 0.42), Color(0.35, 0.62, 0.95),
	Color(0.20, 0.55, 0.25), Color(0.95, 0.85, 0.55),
]
const TERRAIN_MID := [
	Color(0.45, 0.72, 0.32), Color(0.25, 0.48, 0.78),
	Color(0.14, 0.40, 0.18), Color(0.82, 0.70, 0.42),
]
const TERRAIN_BOT := [
	Color(0.32, 0.52, 0.22), Color(0.18, 0.32, 0.55),
	Color(0.08, 0.22, 0.10), Color(0.58, 0.48, 0.28),
]
const TERRAIN_NAMES := ["草地", "水域", "森林", "荒漠"]
const TERRAIN_DECOR_CHANCE := 0.6

const PLAYER_COLORS := [
	Color(0.15, 0.95, 0.22),  # P1 green
	Color(0.25, 0.55, 1.00),  # P2 blue
	Color(1.00, 0.55, 0.15),  # P3 orange
	Color(0.75, 0.30, 0.90),  # P4 purple
]
const PLAYER_EMISSION := [
	Color(0.05, 0.35, 0.08),
	Color(0.08, 0.15, 0.40),
	Color(0.40, 0.18, 0.05),
	Color(0.28, 0.08, 0.35),
]
const PLAYER_NAMES := ["玩家1", "玩家2", "玩家3", "玩家4"]

# ---- State ----
enum S { TITLE, SETUP, PLACE_TILE, PLACE_SEED, GAME_OVER }

var grid := []; var plants := []     # plants[x][y] = player_id+1 or 0
var plant_age := []
var tile_meshes := []; var plant_meshes := []; var decor_meshes := []
var current_tile := 0; var state := S.TITLE
var player_count := 2; var current_player := 0  # 0-indexed
var seeds := []; var total_turns := 0; var turns_played := 0
var scores := []; var group_counts := []
var hovered_cell := Vector2i(-1, -1); var pulse := 0.0
var flash_timer := 0.0; var flash_color := Color.WHITE
var last_placed := Vector2i(-1, -1)

# Nodes
var camera: Camera3D; var grid_root: Node3D; var plant_root: Node3D
var decor_root: Node3D; var hover_mesh: MeshInstance3D; var ui_ctrl: Control

func _ready():
	_setup_scene()
	_init_grid()
	state = S.TITLE

# ================================================================
#  SCENE SETUP
# ================================================================
func _setup_scene():
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 16
	camera.position = Vector3(8, 15, 11)
	camera.rotation_degrees = Vector3(-40, 42, 0)
	camera.near = 0.1; camera.far = 200
	add_child(camera)

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -25, 0)
	sun.light_energy = 1.2; sun.light_color = Color(1, 0.97, 0.9)
	sun.shadow_enabled = true; add_child(sun)

	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(30, 150, 0)
	fill.light_energy = 0.3; fill.light_color = Color(0.6, 0.7, 1.0)
	add_child(fill)

	var env = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.10, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.20, 0.22, 0.28)
	e.ambient_light_energy = 0.7
	e.glow_enabled = true; e.glow_intensity = 0.35; e.glow_bloom = 0.04
	env.environment = e; add_child(env)

	grid_root = Node3D.new(); add_child(grid_root)
	plant_root = Node3D.new(); add_child(plant_root)
	decor_root = Node3D.new(); add_child(decor_root)

	var ground = MeshInstance3D.new()
	var gp = PlaneMesh.new(); gp.size = Vector2(20, 20)
	ground.mesh = gp
	var gm = StandardMaterial3D.new(); gm.albedo_color = Color(0.05, 0.06, 0.10)
	ground.material_override = gm; ground.position = Vector3(4.8, -0.35, 4.8)
	add_child(ground)

	hover_mesh = MeshInstance3D.new()
	var hbox = BoxMesh.new(); hbox.size = Vector3(1.15, 0.03, 1.15)
	hover_mesh.mesh = hbox
	var hm = StandardMaterial3D.new()
	hm.albedo_color = Color(1, 1, 1, 0.18)
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.no_depth_test = true
	hover_mesh.material_override = hm; hover_mesh.visible = false
	add_child(hover_mesh)

	ui_ctrl = Control.new()
	ui_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	var canvas = CanvasLayer.new(); canvas.layer = 10
	add_child(canvas); canvas.add_child(ui_ctrl)
	ui_ctrl.connect("draw", _draw_ui)

# ================================================================
#  GRID
# ================================================================
func _init_grid():
	for c in grid_root.get_children(): c.queue_free()
	for c in plant_root.get_children(): c.queue_free()
	for c in decor_root.get_children(): c.queue_free()
	grid = []; plants = []; plant_age = []
	tile_meshes = []; plant_meshes = []; decor_meshes = []
	for x in GRID_SIZE:
		grid.append([]); plants.append([]); plant_age.append([])
		tile_meshes.append([]); plant_meshes.append([]); decor_meshes.append([])
		for y in GRID_SIZE:
			grid[x].append(-1); plants[x].append(0); plant_age[x].append(0)
			tile_meshes[x].append(null); plant_meshes[x].append(null); decor_meshes[x].append(null)

func _world(pos: Vector2i) -> Vector3:
	var off = (GRID_SIZE - 1) * TILE_SPACING * 0.5
	return Vector3(pos.x * TILE_SPACING - off, 0, pos.y * TILE_SPACING - off)

func _pick_tile():
	current_tile = randi() % TERRAIN_TOP.size()
	state = S.PLACE_TILE

func _has_any() -> bool:
	for x in GRID_SIZE:
		for y in GRID_SIZE:
			if grid[x][y] != -1: return true
	return false

func _can_place(pos: Vector2i) -> bool:
	if pos.x < 0 or pos.x >= GRID_SIZE or pos.y < 0 or pos.y >= GRID_SIZE: return false
	if grid[pos.x][pos.y] != -1: return false
	if not _has_any(): return true
	for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var n = pos + d
		if n.x >= 0 and n.x < GRID_SIZE and n.y >= 0 and n.y < GRID_SIZE:
			if grid[n.x][n.y] != -1: return true
	return false

func _place_tile(pos: Vector2i) -> bool:
	if not _can_place(pos): return false
	grid[pos.x][pos.y] = current_tile; last_placed = pos
	_spawn_tile(pos, current_tile)
	flash_timer = 0.25; flash_color = TERRAIN_TOP[current_tile]
	return true

# ================================================================
#  TILE MESH
# ================================================================
func _spawn_tile(pos: Vector2i, terr: int):
	var root = Node3D.new(); root.position = _world(pos)
	grid_root.add_child(root); tile_meshes[pos.x][pos.y] = root

	var bot = MeshInstance3D.new()
	var bm = BoxMesh.new(); bm.size = Vector3(1.02, 0.12, 1.02)
	bot.mesh = bm
	var bmat = StandardMaterial3D.new(); bmat.albedo_color = TERRAIN_BOT[terr]
	bot.material_override = bmat; bot.position.y = -0.06
	root.add_child(bot)

	var mid = MeshInstance3D.new()
	var mm = BoxMesh.new(); mm.size = Vector3(0.98, 0.10, 0.98)
	mid.mesh = mm
	var mmat = StandardMaterial3D.new(); mmat.albedo_color = TERRAIN_MID[terr]
	mid.material_override = mmat; mid.position.y = 0.05
	root.add_child(mid)

	var top = MeshInstance3D.new()
	var tm = BoxMesh.new(); tm.size = Vector3(0.94, 0.06, 0.94)
	top.mesh = tm
	var tmat = StandardMaterial3D.new(); tmat.albedo_color = TERRAIN_TOP[terr]
	top.material_override = tmat; top.position.y = 0.13
	root.add_child(top)

	var bevel = MeshInstance3D.new()
	var bvm = BoxMesh.new(); bvm.size = Vector3(1.04, 0.015, 1.04)
	bevel.mesh = bvm
	var bvmat = StandardMaterial3D.new()
	bvmat.albedo_color = TERRAIN_TOP[terr].lightened(0.25)
	bvmat.emission_enabled = true; bvmat.emission = TERRAIN_TOP[terr].lightened(0.1)
	bvmat.emission_energy_multiplier = 0.3
	bevel.material_override = bvmat; bevel.position.y = 0.17
	root.add_child(bevel)

	if randf() < TERRAIN_DECOR_CHANCE:
		_spawn_decor(terr, root)

	root.scale = Vector3(0.01, 0.01, 0.01)
	var tw = create_tween()
	tw.tween_property(root, "scale", Vector3(1, 1, 1), 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

func _spawn_decor(terr: int, parent: Node3D):
	var d = Node3D.new(); parent.add_child(d)
	match terr:
		0: _decor_grass(d)
		1: _decor_water(d)
		2: _decor_forest(d)
		3: _decor_desert(d)

func _decor_grass(p: Node3D):
	for i in randi_range(2, 5):
		var fl = MeshInstance3D.new()
		var fm = SphereMesh.new(); fm.radius = randf_range(0.03, 0.06); fm.height = fm.radius * 2
		fl.mesh = fm
		var m = StandardMaterial3D.new()
		var r = randf()
		if r < 0.4: m.albedo_color = Color(1, 0.9, 0.3)
		elif r < 0.7: m.albedo_color = Color(1, 0.5, 0.6)
		else: m.albedo_color = Color(1, 1, 1)
		fl.material_override = m
		fl.position = Vector3(randf_range(-0.35, 0.35), 0.18, randf_range(-0.35, 0.35))
		p.add_child(fl)
	for i in randi_range(1, 3):
		var bl = MeshInstance3D.new()
		var bm = BoxMesh.new(); bm.size = Vector3(0.015, randf_range(0.08, 0.15), 0.015)
		bl.mesh = bm
		var m = StandardMaterial3D.new()
		m.albedo_color = Color(0.35, 0.75, 0.25).lerp(Color(0.5, 0.9, 0.35), randf())
		bl.material_override = m
		bl.position = Vector3(randf_range(-0.3, 0.3), 0.18, randf_range(-0.3, 0.3))
		bl.rotation_degrees.z = randf_range(-15, 15)
		p.add_child(bl)

func _decor_water(p: Node3D):
	var pad = MeshInstance3D.new()
	var pm = CylinderMesh.new(); pm.top_radius = randf_range(0.08, 0.14); pm.bottom_radius = pm.top_radius; pm.height = 0.015
	pad.mesh = pm
	var m = StandardMaterial3D.new(); m.albedo_color = Color(0.25, 0.7, 0.3)
	pad.material_override = m
	pad.position = Vector3(randf_range(-0.25, 0.25), 0.17, randf_range(-0.25, 0.25))
	p.add_child(pad)
	if randf() < 0.5:
		var fl = MeshInstance3D.new()
		var fm = SphereMesh.new(); fm.radius = 0.03; fm.height = 0.06
		fl.mesh = fm
		var fm2 = StandardMaterial3D.new(); fm2.albedo_color = Color(1, 0.7, 0.85)
		fl.material_override = fm2; fl.position = pad.position + Vector3(0, 0.03, 0)
		p.add_child(fl)
	var rip = MeshInstance3D.new()
	var rm = TorusMesh.new(); rm.inner_radius = 0.12; rm.outer_radius = 0.15; rm.rings = 16
	rip.mesh = rm
	var rmat = StandardMaterial3D.new()
	rmat.albedo_color = Color(0.5, 0.75, 1.0, 0.3)
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rip.material_override = rmat
	rip.position = Vector3(randf_range(-0.2, 0.2), 0.16, randf_range(-0.2, 0.2))
	rip.rotation_degrees.x = 90; p.add_child(rip)

func _decor_forest(p: Node3D):
	var trunk = MeshInstance3D.new()
	var trm = CylinderMesh.new(); trm.top_radius = 0.02; trm.bottom_radius = 0.03; trm.height = randf_range(0.12, 0.22)
	trunk.mesh = trm
	var tm = StandardMaterial3D.new(); tm.albedo_color = Color(0.45, 0.30, 0.18)
	trunk.material_override = tm
	var th = trm.height
	trunk.position = Vector3(randf_range(-0.25, 0.25), 0.18 + th * 0.5, randf_range(-0.25, 0.25))
	p.add_child(trunk)
	for layer in randi_range(2, 3):
		var fol = MeshInstance3D.new()
		var fm = CylinderMesh.new()
		var lr = randf_range(0.10, 0.18) - layer * 0.03
		fm.top_radius = 0.01; fm.bottom_radius = max(0.03, lr); fm.height = randf_range(0.10, 0.16)
		fol.mesh = fm
		var fmat = StandardMaterial3D.new()
		fmat.albedo_color = Color(0.15, 0.55, 0.20).lerp(Color(0.25, 0.70, 0.30), randf())
		fol.material_override = fmat
		fol.position = trunk.position + Vector3(0, th * 0.3 + layer * 0.08, 0)
		p.add_child(fol)

func _decor_desert(p: Node3D):
	for i in randi_range(1, 3):
		var rock = MeshInstance3D.new()
		var rm = BoxMesh.new(); rm.size = Vector3(randf_range(0.06, 0.15), randf_range(0.04, 0.10), randf_range(0.06, 0.15))
		rock.mesh = rm
		var m = StandardMaterial3D.new()
		m.albedo_color = Color(0.65, 0.55, 0.38).lerp(Color(0.80, 0.70, 0.50), randf())
		rock.material_override = m
		rock.position = Vector3(randf_range(-0.3, 0.3), 0.18, randf_range(-0.3, 0.3))
		rock.rotation_degrees.y = randf_range(0, 360); p.add_child(rock)
	if randf() < 0.4:
		var cac = MeshInstance3D.new()
		var cm = CylinderMesh.new(); cm.top_radius = 0.025; cm.bottom_radius = 0.03; cm.height = randf_range(0.10, 0.18)
		cac.mesh = cm
		var cm2 = StandardMaterial3D.new(); cm2.albedo_color = Color(0.3, 0.6, 0.25)
		cac.material_override = cm2
		cac.position = Vector3(randf_range(-0.2, 0.2), 0.18 + cm.height * 0.5, randf_range(-0.2, 0.2))
		p.add_child(cac)

# ================================================================
#  PLANT (per player)
# ================================================================
func _place_seed(pos: Vector2i) -> bool:
	if pos.x < 0 or pos.x >= GRID_SIZE or pos.y < 0 or pos.y >= GRID_SIZE: return false
	if grid[pos.x][pos.y] == -1 or plants[pos.x][pos.y] != 0: return false
	if seeds[current_player] <= 0: return false
	plants[pos.x][pos.y] = current_player + 1  # 1-indexed player id
	plant_age[pos.x][pos.y] = 0
	seeds[current_player] -= 1
	_spawn_plant(pos, current_player)
	flash_timer = 0.2; flash_color = PLAYER_COLORS[current_player]
	return true

func _spawn_plant(pos: Vector2i, pid: int):
	var root = Node3D.new()
	root.position = _world(pos); root.position.y = 0.20
	plant_root.add_child(root)
	plant_meshes[pos.x][pos.y] = root

	var sprout = MeshInstance3D.new()
	var sm = SphereMesh.new(); sm.radius = 0.18; sm.height = 0.36
	sprout.mesh = sm
	var mat = StandardMaterial3D.new()
	mat.albedo_color = PLAYER_COLORS[pid]
	mat.emission_enabled = true; mat.emission = PLAYER_EMISSION[pid]
	mat.emission_energy_multiplier = 1.2
	sprout.material_override = mat; sprout.position.y = 0.05
	root.add_child(sprout)

	var hl = MeshInstance3D.new()
	var hm = SphereMesh.new(); hm.radius = 0.08; hm.height = 0.16
	hl.mesh = hm
	var hlm = StandardMaterial3D.new()
	hlm.albedo_color = PLAYER_COLORS[pid].lightened(0.4); hlm.albedo_color.a = 0.5
	hlm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hlm.emission_enabled = true; hlm.emission = PLAYER_COLORS[pid].lightened(0.2)
	hlm.emission_energy_multiplier = 0.8
	hl.material_override = hlm; hl.position = Vector3(-0.04, 0.12, -0.04)
	root.add_child(hl)

	var ring = MeshInstance3D.new()
	var rm = TorusMesh.new(); rm.inner_radius = 0.22; rm.outer_radius = 0.26; rm.rings = 20
	ring.mesh = rm
	var rmat = StandardMaterial3D.new()
	rmat.albedo_color = PLAYER_COLORS[pid]; rmat.albedo_color.a = 0.15
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.emission_enabled = true; rmat.emission = PLAYER_COLORS[pid].darkened(0.3)
	rmat.emission_energy_multiplier = 0.5
	ring.material_override = rmat; ring.position.y = -0.08
	ring.rotation_degrees.x = 90; root.add_child(ring)

	root.scale = Vector3(0.01, 0.01, 0.01)
	var tw = create_tween()
	tw.tween_property(root, "scale", Vector3(1, 1, 1), 0.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

# ================================================================
#  GAME FLOW
# ================================================================
func _start_game():
	_init_grid()
	current_player = 0; turns_played = 0
	total_turns = TURNS_PER_GAME * player_count  # each player gets TURNS_PER_GAME turns
	seeds = []; scores = []; group_counts = []
	for i in player_count:
		seeds.append(STARTING_SEEDS); scores.append(0); group_counts.append(0)
	_pick_tile(); ui_ctrl.queue_redraw()

func _end_turn():
	# Grow all plants for current player
	_do_grow()
	seeds[current_player] += SEEDS_PER_TURN
	turns_played += 1

	if turns_played >= total_turns:
		state = S.GAME_OVER
		_calc_all_scores()
		ui_ctrl.queue_redraw()
		return

	# Next player
	current_player = (current_player + 1) % player_count
	_pick_tile()
	ui_ctrl.queue_redraw()

func _do_grow():
	var new_p := []; var new_a := []
	for x in GRID_SIZE:
		new_p.append([]); new_a.append([])
		for y in GRID_SIZE:
			new_p[x].append(plants[x][y]); new_a[x].append(plant_age[x][y])

	for x in GRID_SIZE:
		for y in GRID_SIZE:
			if plants[x][y] == current_player + 1:
				var t = grid[x][y]
				for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
					var nx = x + d.x; var ny = y + d.y
					if nx >= 0 and nx < GRID_SIZE and ny >= 0 and ny < GRID_SIZE:
						if grid[nx][ny] == t and plants[nx][ny] == 0:
							if randf() < SPREAD_CHANCE:
								new_p[nx][ny] = current_player + 1
								new_a[nx][ny] = 0

	for x in GRID_SIZE:
		for y in GRID_SIZE:
			if new_p[x][y] != 0 and new_p[x][y] != plants[x][y]:
				plants[x][y] = new_p[x][y]
				plant_age[x][y] = 0
				_spawn_plant(Vector2i(x, y), plants[x][y] - 1)
			elif plants[x][y] != 0:
				plant_age[x][y] = new_a[x][y] + 1
				if plant_meshes[x][y] != null:
					var s = min(1.0, plant_age[x][y] * 0.10)
					var r = plant_meshes[x][y]
					var tw = create_tween()
					tw.tween_property(r, "scale", Vector3(s, s, s), 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SPRING)

func _calc_all_scores():
	for pid in player_count:
		var count := 0
		for x in GRID_SIZE:
			for y in GRID_SIZE:
				if plants[x][y] == pid + 1: count += 1
		var vis := []
		for x in GRID_SIZE:
			vis.append([])
			for y in GRID_SIZE: vis[x].append(false)
		var groups := 0
		for x in GRID_SIZE:
			for y in GRID_SIZE:
				if plants[x][y] == pid + 1 and not vis[x][y]:
					groups += 1; _flood_player(x, y, vis, pid + 1)
		scores[pid] = count + groups * 5
		group_counts[pid] = groups

func _flood_player(x: int, y: int, v: Array, pid: int):
	if x < 0 or x >= GRID_SIZE or y < 0 or y >= GRID_SIZE: return
	if v[x][y] or plants[x][y] != pid: return
	v[x][y] = true
	_flood_player(x+1,y,v,pid); _flood_player(x-1,y,v,pid)
	_flood_player(x,y+1,v,pid); _flood_player(x,y-1,v,pid)

# ================================================================
#  MOUSE
# ================================================================
func _mouse_to_grid(mp: Vector2) -> Vector2i:
	var from = camera.project_ray_origin(mp)
	var dir = camera.project_ray_normal(mp)
	if absf(dir.y) < 0.0001: return Vector2i(-1, -1)
	var t = -from.y / dir.y
	if t < 0: return Vector2i(-1, -1)
	var hit = from + dir * t
	var off = (GRID_SIZE - 1) * TILE_SPACING * 0.5
	var gx = roundi((hit.x + off) / TILE_SPACING)
	var gy = roundi((hit.z + off) / TILE_SPACING)
	if gx >= 0 and gx < GRID_SIZE and gy >= 0 and gy < GRID_SIZE:
		return Vector2i(gx, gy)
	return Vector2i(-1, -1)

# ================================================================
#  LOOP
# ================================================================
func _process(delta):
	pulse += delta
	if flash_timer > 0: flash_timer = max(0, flash_timer - delta * 2.5)
	camera.position.y = 15 + sin(pulse * 0.35) * 0.2
	ui_ctrl.queue_redraw()

func _input(event):
	# Title screen
	if state == S.TITLE:
		if event is InputEventKey and event.pressed:
			if event.keycode == KEY_2: player_count = 2; state = S.SETUP; _start_game()
			elif event.keycode == KEY_3: player_count = 3; state = S.SETUP; _start_game()
			elif event.keycode == KEY_4: player_count = 4; state = S.SETUP; _start_game()
		if event is InputEventMouseButton and event.pressed:
			player_count = 2; state = S.SETUP; _start_game()
		return

	if event is InputEventMouseMotion:
		var nc = _mouse_to_grid(event.position)
		if nc != hovered_cell:
			hovered_cell = nc
			if hovered_cell.x >= 0:
				hover_mesh.visible = true
				hover_mesh.position = _world(hovered_cell); hover_mesh.position.y = 0.01
			else: hover_mesh.visible = false

	if event is InputEventMouseButton and event.pressed:
		var cell = _mouse_to_grid(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if state == S.PLACE_TILE:
				if _place_tile(cell): state = S.PLACE_SEED; ui_ctrl.queue_redraw()
			elif state == S.PLACE_SEED:
				if _place_seed(cell): _end_turn()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if state == S.PLACE_SEED: _end_turn()

	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		get_tree().reload_current_scene()

# ================================================================
#  UI
# ================================================================
func _draw_ui():
	var font = ThemeDB.fallback_font
	var vp = get_viewport().get_visible_rect().size
	var ux = vp.x - 320.0; var uy = 30.0

	ui_ctrl.draw_rect(Rect2(ux - 15, uy - 10, 305, vp.y - 40), Color(0, 0, 0, 0.50), 0, true, 10.0)

	if state == S.TITLE:
		_draw_title(vp, font); return

	if state == S.GAME_OVER:
		_draw_gameover(vp, font); return

	# Current player indicator
	var pcol = PLAYER_COLORS[current_player]
	var pname = PLAYER_NAMES[current_player]
	ui_ctrl.draw_rect(Rect2(ux, uy, 270, 42), pcol.darkened(0.6), 0, true, 8.0)

	var state_text := ""
	if state == S.PLACE_TILE: state_text = "放置地形"
	elif state == S.PLACE_SEED: state_text = "放置种子"
	ui_ctrl.draw_string(font, Vector2(ux + 16, uy + 18), pname, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, pcol.lightened(0.5))
	ui_ctrl.draw_string(font, Vector2(ux + 90, uy + 18), state_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

	# Stats
	var sy = uy + 70
	ui_ctrl.draw_string(font, Vector2(ux + 12, sy), "回合", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.45, 0.45, 0.45))
	ui_ctrl.draw_string(font, Vector2(ux + 12, sy + 22), "%d / %d" % [turns_played + 1, total_turns], HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.9, 0.9, 0.9))
	var bp = float(turns_played) / total_turns
	ui_ctrl.draw_rect(Rect2(ux + 12, sy + 32, 246, 7), Color(0.12, 0.12, 0.12), 0, true, 4.0)
	ui_ctrl.draw_rect(Rect2(ux + 12, sy + 32, 246 * bp, 7), pcol.darkened(0.2), 0, true, 4.0)

	ui_ctrl.draw_string(font, Vector2(ux + 12, sy + 60), "种子", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.45, 0.45, 0.45))
	ui_ctrl.draw_string(font, Vector2(ux + 12, sy + 82), str(seeds[current_player]), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.9, 0.9, 0.9))

	# All player scores
	ui_ctrl.draw_string(font, Vector2(ux + 120, sy + 60), "得分", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.45, 0.45, 0.45))
	for i in player_count:
		var py = sy + 80 + i * 22
		ui_ctrl.draw_circle(Vector2(ux + 125, py - 3), 5, PLAYER_COLORS[i])
		ui_ctrl.draw_string(font, Vector2(ux + 136, py), PLAYER_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, PLAYER_COLORS[i].lightened(0.3))

	# Current tile
	var iy = sy + 180
	if state == S.PLACE_TILE:
		ui_ctrl.draw_string(font, Vector2(ux + 12, iy), "当前地形", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.45, 0.45, 0.45))
		ui_ctrl.draw_rect(Rect2(ux + 12, iy + 8, 50, 50), TERRAIN_TOP[current_tile], 0, true, 8.0)
		ui_ctrl.draw_string(font, Vector2(ux + 72, iy + 40), TERRAIN_NAMES[current_tile], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.85, 0.85, 0.85))
	elif state == S.PLACE_SEED:
		ui_ctrl.draw_string(font, Vector2(ux + 12, iy), "操作", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.45, 0.45, 0.45))
		ui_ctrl.draw_string(font, Vector2(ux + 12, iy + 22), "左键 → 放种子", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.5, 1, 0.5))
		ui_ctrl.draw_string(font, Vector2(ux + 12, iy + 44), "右键 → 直接生长", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.6, 0.6, 0.6))

	# Legend
	var ly = vp.y - 200.0
	ui_ctrl.draw_string(font, Vector2(ux + 12, ly), "地形", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.4, 0.4, 0.4))
	for i in TERRAIN_TOP.size():
		ui_ctrl.draw_rect(Rect2(ux + 12, ly + 14 + i * 24, 14, 14), TERRAIN_TOP[i], 0, true, 4.0)
		ui_ctrl.draw_string(font, Vector2(ux + 32, ly + 26 + i * 24), TERRAIN_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.55, 0.55, 0.55))

	ui_ctrl.draw_string(font, Vector2(ux + 120, ly), "玩家", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.4, 0.4, 0.4))
	for i in player_count:
		ui_ctrl.draw_circle(Vector2(ux + 128, ly + 20 + i * 24), 6, PLAYER_COLORS[i])
		ui_ctrl.draw_string(font, Vector2(ux + 140, ly + 26 + i * 24), PLAYER_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, PLAYER_COLORS[i].lightened(0.2))

	# Hint
	ui_ctrl.draw_string(font, Vector2(ux + 12, vp.y - 60), "R = 重新开始", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.3, 0.3, 0.3))

func _draw_title(vp: Vector2, font: Font):
	ui_ctrl.draw_rect(Rect2(0, 0, vp.x, vp.y), Color(0, 0, 0, 0.75))
	for i in 10:
		var a = pulse * 0.22 + i * 0.628
		var c = PLAYER_COLORS[i % 4]; c.a = 0.15 + sin(pulse + i) * 0.06
		ui_ctrl.draw_circle(Vector2(vp.x * 0.5 + cos(a) * 300, vp.y * 0.35 + sin(a * 0.7) * 120), 30 + sin(pulse + i) * 10, c)

	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 140, vp.y * 0.25), "蔓  延", HORIZONTAL_ALIGNMENT_LEFT, -1, 88, Color.WHITE)
	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 170, vp.y * 0.25 + 65), "G R O W  C A S S O N N E", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(0.45, 0.78, 0.45))
	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 100, vp.y * 0.25 + 105), "卡卡颂 × GROW  多人对战", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.4, 0.4, 0.4))

	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 120, vp.y * 0.50), "选择玩家人数:", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.8, 0.8, 0.8))
	var blink = sin(pulse * 2.2) * 0.3 + 0.7
	for i in 3:
		var np = i + 2
		var bx = vp.x * 0.5 - 100 + i * 120.0
		var by = vp.y * 0.55
		ui_ctrl.draw_rect(Rect2(bx, by, 90, 45), PLAYER_COLORS[np - 2].darkened(0.5), 0, true, 8.0)
		ui_ctrl.draw_string(font, Vector2(bx + 18, by + 30), "%d 人" % np, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, PLAYER_COLORS[np - 2])

	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 120, vp.y * 0.65), "按 2 / 3 / 4 选择 或 点击开始", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, blink))

	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 90, vp.y * 0.78), "每人轮流: 放地形 → 播种 → 生长", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.45, 0.45, 0.45))
	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 100, vp.y * 0.82), "植物蔓延到同类地形，连片越大分越高", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.40, 0.40, 0.40))

	ui_ctrl.draw_string(font, Vector2(vp.x * 0.5 - 90, vp.y * 0.92), "GGJ 2025  ·  GROW Theme", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.22, 0.22, 0.22))

func _draw_gameover(vp: Vector2, font: Font):
	ui_ctrl.draw_rect(Rect2(0, 0, vp.x, vp.y), Color(0, 0, 0, 0.85))
	var cx = vp.x * 0.5
	ui_ctrl.draw_string(font, Vector2(cx - 130, vp.y * 0.15), "游戏结束", HORIZONTAL_ALIGNMENT_LEFT, -1, 58, Color.WHITE)

	# Find winner
	var max_score = 0; var winner = 0
	for i in player_count:
		if scores[i] > max_score: max_score = scores[i]; winner = i

	# Player results
	for i in player_count:
		var py = vp.y * 0.28 + i * 80.0
		var is_winner = (i == winner)

		# Highlight winner
		if is_winner:
			ui_ctrl.draw_rect(Rect2(cx - 180, py - 15, 360, 65), PLAYER_COLORS[i].darkened(0.6), 0, true, 10.0)

		ui_ctrl.draw_circle(Vector2(cx - 150, py + 15), 12, PLAYER_COLORS[i])
		ui_ctrl.draw_string(font, Vector2(cx - 130, py + 22), PLAYER_NAMES[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, PLAYER_COLORS[i])

		var plant_count := 0
		var pid = i + 1
		for x in GRID_SIZE:
			for y in GRID_SIZE:
				if plants[x][y] == pid: plant_count += 1

		ui_ctrl.draw_string(font, Vector2(cx - 20, py + 8), "%d 分" % scores[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color.YELLOW if is_winner else Color(0.8, 0.8, 0.8))
		ui_ctrl.draw_string(font, Vector2(cx + 80, py + 8), "(%d格 %d组)" % [plant_count, group_counts[i]], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.5, 0.5, 0.5))

		if is_winner:
			ui_ctrl.draw_string(font, Vector2(cx + 80, py + 28), "★ 胜利!", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, PLAYER_COLORS[i].lightened(0.3))

	var blink = sin(pulse * 2.5) * 0.3 + 0.7
	ui_ctrl.draw_string(font, Vector2(cx - 75, vp.y * 0.85), "按 R 重新开始", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, blink))
