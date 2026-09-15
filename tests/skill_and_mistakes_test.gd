extends SceneTree

## Skill spread and seeded deliberate mistakes (#59).
##
## A deliberate mistake and a bug look identical from outside. Everything here is about telling them
## apart: every mistake is drawn from the car's own seed stream, typed and logged, and suppressed by
## default -- and a car that deviates from the flawless driver without a logged reason is a defect.
##
## ## What is asserted
##
## - **Skill is seeded** from the car's skill stream, pinned against values computed independently in
##   Python, and it turns its three dials: at 1.0 they are exactly #58's constants.
## - **The mistake plan is seeded**, pinned the same way, and pure.
## - **Each kind does what its name says, because the driver chose it.** Against synthetic senses, a
##   driver primed to commit one kind is compared tick for tick with a flawless one fed the same
##   senses: they agree until the mistake is logged, and then differ in exactly the way the kind says.
## - **Mistakes wait for clean racing**, end the moment it stops, and lapse if the road offers none;
##   going round a stopped car is not clean racing, so none begins while passing.
## - **The same car repeats its mistakes**: the whole logged sequence, not a count, on a real lap --
##   with guards that the sequence is long and mixed, so equality is not the equality of two empties.
## - **Different cars make different mistakes**: every pair of twenty cars' plans differ, and in a real
##   field every pair that committed the same plan number committed a different mistake under it.
## - **Suppression is total**: with mistakes off, two cars that differ ONLY in their mistake streams --
##   different indices, skill pinned equal, same start -- drive identical control streams over a full
##   lap. The issue's own wording, "two identical cars", would pass with the switch wired to nothing
##   but the log, because identical cars make identical mistakes; `--leak-mistakes` shows that.
##   With mistakes on, the same twins' streams are identical until the first logged mistake and
##   differ exactly there.
## - **Skill spreads the field**: on SPREAD_SEEDS the least and most skilled of twenty cars, by their
##   derived skills, differ in lap time by at least SPREAD_MARGIN, and pinned skills lap in order.
## - **The lowest skill finishes**: skill 0.0 with mistakes on laps every one of the fifteen seeds.
## - **Every kind is survivable**: forced to one kind at its largest, a second apart, at the lowest
##   and highest skill, a car still laps cleanly on SURVIVAL_SEEDS.
## - **A field** of twenty on the session's grid with derived skills and mistakes on: every car laps.
##
## ## Mutations
##
##   -- --break-mistake-seed   derives the mistake stream without the car index. Must fail the
##                             different-cars assertions and the twins' "differ" assertion.
##   -- --break-skill-spread   collapses every derived skill to 0.5. Must fail the lap-time spread.
##   -- --leak-mistakes        evidence, not an issue flag: the switch hides the log but the mistakes
##                             still act. Must fail the twins' suppression assertion and the
##                             off-unless-asked unit check, and passes the issue's literal "two
##                             identical cars" wording, which is why that wording is not the
##                             assertion this file relies on.
##
## Exploration: --only=a,b runs only the named sections (units, repeat, plans, twins, spread, lowest,
## survival, field).

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const TICK := 1.0 / 60.0
## As in tests/reactive_driver_test.gd: the production 1 / 60 s step, ten times faster in real time.
## That suite's _verify_the_physics_step pins that the step really is the production one.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const LAP_TICK_BUDGET := 18000
const ALL_SEEDS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
const MAX_OFF_ROAD_FRACTION := 0.05

## tests/ai_driver_contract_test.gd's identity fixture, and what Python makes of the same algorithm
## for the two new streams: skill = DomainSeed.child(domain, index, 1) / 16^15, and mistake n's draw d
## = DomainSeed.child(DomainSeed.child(domain, index, 2), n, d) / 16^15, domain being
## DomainSeed.derive(1, 7, "ai_driver").
const FIXTURE_TRACK_SEED := 7
const FIXTURE_IDENTITY := 54569277199214867
const FIXTURE_SKILL_2 := 0.1027125029750845
const FIXTURE_SKILL_3 := 0.9678007411084671
## Car 2's first two plans: [kind, amount, seconds, gap]. Car 3's first: a late brake.
const FIXTURE_PLAN_2 := [
	[ReactiveDriver.Mistake.NEEDLESS_LIFT, 0.0, 0.930412666006318, 12.230682992468463],
	[ReactiveDriver.Mistake.WIDE_LINE, 4.608358758904684, 2.0682823985487966, 15.157507832125601],
]
const FIXTURE_PLAN_3_FIRST := [ReactiveDriver.Mistake.LATE_BRAKE, 11.116721334744145, 0.0, 25.744707922834763]

## Rivals take indices 1..20 (0 is the player's identity).
const FIELD_INDICES := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
## Fixed before any derived-skill lap was run: pinned skill 0.0 against 1.0 had measured 12.8-13.8% on
## seeds 0-4, and twenty derived skills on these seeds span 0.86-0.88 of the scale, so 5% leaves room
## and a constant skill leaves none.
const SPREAD_SEEDS := [0, 1, 2]
const SPREAD_MARGIN := 0.05
const MIN_SKILL_SPAN := 0.5
const SWEEP_SEED := 0
## #58's lap on seed 0, in ticks: 66.32 s in its table. A driver pinned to skill 1.0 is #58's driver.
const SWEEP_TOP_SKILL_TICKS := 3979

## The same-seed repeat: seed 1's least skilled rival (0.010), on the longest of the tuned laps.
const REPEAT_SEED := 1
const REPEAT_INDEX := 17
const REPEAT_MIN_MISTAKES := 3
## The twins: two rivals on one seed, both pinned to the least skill, so they err most often.
const TWIN_SEED := 2
const TWIN_INDICES := [1, 2]
const TWIN_SKILL := 0.0

## Survival: seeds whose corners ask for braking at both ends of the skill range, so a late brake has
## somewhere to happen. Seeds 3 and 7 offer none at either skill; they were measured and left out, and
## the report says so. A mistake every second of clean racing (MEAN gap 1 s) at its largest amount.
## Seed 6 is one of the two narrowest roads of the fifteen (205 px, with seed 0), added in review so
## the wide line's margin to the edge is measured where it is thinnest.
const SURVIVAL_SEEDS := [0, 2, 5, 6, 8]
const SURVIVAL_SKILLS := [0.0, 1.0]
const SURVIVAL_MEAN_GAP_S := 1.0
const SURVIVAL_MIN_COMMITTED := 3
## The car's collision capsule radius, as tests/reactive_driver_test.gd states it. A lap whose car
## centre comes nearer the edge than this has had the car's body over the grass.
const CAR_RADIUS_PX := 15.0
## The largest a draw can be: [0, 1) never reaches 1.
const LARGEST_DRAW := 0.999999

const FIELD_SEED := 0
const FIELD_TICK_BUDGET := 12000
## MainSession's grid, as tests/reactive_driver_test.gd restates it.
const GRID_ROW_SPACING_M := 8.8
const GRID_COLUMN_FRACTION := 0.25

var _failures: Array[String] = []
var _checks := 0
var _tuning: VehicleTuning
var _generator := TrackGenerator.new()
var _break_mistake_seed := false
var _break_skill_spread := false
var _leak := false
var _only: Array[String] = []


## --break-mistake-seed. The mistake stream without the car's index: every car draws car 0's plan.
class MistakeSeedWithoutIndexDriver:
	extends ReactiveDriver

	func _mistake_stream_seed() -> int:
		return _stream_seed(0, MISTAKE_STREAM)


## --break-skill-spread. Every car the same skill, the middle of the scale.
class ConstantSkillDriver:
	extends ReactiveDriver

	func _skill_from_seed() -> float:
		return 0.5


## --leak-mistakes. The switch hides the log and nothing else: mistakes are still decided and still
## act on the controls.
class LeakyDriver:
	extends ReactiveDriver

	func _mistakes_on() -> bool:
		return true

	func mistake_log() -> Array[Dictionary]:
		if not mistakes_enabled:
			return []
		return super()


## A driver primed to commit one kind as often as the stream allows, at its largest: every draw is
## replaced, the kind's by one that maps to `forced_kind`, the gap's by the shortest and the amount's
## and seconds' by the largest. The mapping from draws to a plan stays production code. It is only a
## mistake-maker when mistakes are on; off, it must drive exactly as a flawless driver does.
class ForcedMistakeDriver:
	extends ReactiveDriver

	var forced_kind: int = Mistake.NONE
	var mean_gap_override: float = -1.0
	## --leak-mistakes reaches these drivers too: the switch then gates nothing.
	var leaky: bool = false

	func _mistakes_on() -> bool:
		return leaky or super()

	func _draw(n: int, draw: int) -> float:
		if forced_kind == Mistake.NONE:
			return super(n, draw)
		match draw:
			DRAW_GAP:
				return 0.0
			DRAW_KIND:
				return (float(forced_kind - Mistake.LATE_BRAKE) + 0.5) / 3.0
		return LARGEST_DRAW

	func mean_mistake_gap() -> float:
		return mean_gap_override if mean_gap_override >= 0.0 else super()


func _initialize() -> void:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	var arguments := OS.get_cmdline_user_args()
	_break_mistake_seed = arguments.has("--break-mistake-seed")
	_break_skill_spread = arguments.has("--break-skill-spread")
	_leak = arguments.has("--leak-mistakes")
	for argument in arguments:
		if argument.begins_with("--only="):
			for name in argument.trim_prefix("--only=").split(","):
				_only.append(name)
	call_deferred("_run")


func _wants(section: String) -> bool:
	return _only.is_empty() or _only.has(section)


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	if _break_mistake_seed:
		print("NOTE: --break-mistake-seed is on; every driver's mistake stream ignores its car index.")
	if _break_skill_spread:
		print("NOTE: --break-skill-spread is on; every driver's derived skill is 0.5.")
	if _leak:
		print("NOTE: --leak-mistakes is on; the switch hides the log but mistakes still act.")
	if _wants("units"):
		_check(_verify_skill_is_seeded(), "the skill seeding verification ran to completion")
		_check(_verify_skill_turns_the_dials(), "the skill dial verification ran to completion")
		_check(_verify_the_mistake_plan_is_seeded(), "the mistake plan verification ran to completion")
		_check(_verify_mistakes_are_off_unless_asked(), "the default-off verification ran to completion")
		_check(_verify_a_late_brake_is_chosen(), "the late brake verification ran to completion")
		_check(_verify_a_wide_line_is_chosen(), "the wide line verification ran to completion")
		_check(_verify_a_needless_lift_is_chosen(), "the needless lift verification ran to completion")
		_check(_verify_mistakes_wait_for_clean_racing(), "the clean-racing verification ran to completion")
		_check(_verify_no_mistake_begins_while_passing(), "the no-mistake-while-passing verification ran to completion")
	if _wants("plans"):
		_check(_verify_different_cars_plan_different_mistakes(), "the different-plans verification ran to completion")
	# The field goes first among the sections that use physics, and that is load-bearing: which race a
	# field of twenty drives depends on whether a physics step runs between placing its cars and their
	# first sense (the step re-rounds each spawn pose), and on what track the space held before. Run
	# here, from the deferred first call with no await before it, it spawns in the same phase and the
	# same clean space as `--only=field`. Not contact order. See the section's comment and the #59 review.
	if _wants("field"):
		_check(await _verify_a_field_with_skill_and_mistakes(), "the field verification ran to completion")
	if _wants("repeat"):
		_check(await _verify_the_same_car_repeats_its_mistakes(), "the repeat verification ran to completion")
	if _wants("twins"):
		_check(await _verify_twins_differ_only_by_their_mistakes(), "the twins verification ran to completion")
	if _wants("spread"):
		_check(await _verify_skill_spreads_lap_times(), "the skill spread verification ran to completion")
	if _wants("lowest"):
		_check(await _verify_the_lowest_skill_finishes(), "the lowest skill verification ran to completion")
	if _wants("survival"):
		_check(await _verify_every_mistake_is_survivable(), "the survival verification ran to completion")
	_finish()


## Every car in this file that is not deliberately forced is made here, so a mutation flag reaches
## every section. Skill is the car's own unless a section pins it; mistakes are off unless it asks.
func _make_driver(seed: int, index: int) -> ReactiveDriver:
	if _break_mistake_seed:
		return MistakeSeedWithoutIndexDriver.new(seed, index)
	if _break_skill_spread:
		return ConstantSkillDriver.new(seed, index)
	if _leak:
		return LeakyDriver.new(seed, index)
	return ReactiveDriver.new(seed, index)


func _forced(kind: int, mistakes: bool, mean_gap: float) -> ForcedMistakeDriver:
	var driver := ForcedMistakeDriver.new(0, 1)
	driver.set_skill(1.0)
	driver.forced_kind = kind
	driver.mean_gap_override = mean_gap
	driver.mistakes_enabled = mistakes
	driver.leaky = _leak
	return driver


# ---------------------------------------------------------------------------------------------
# Seeds and dials


func _verify_skill_is_seeded() -> bool:
	var two := ReactiveDriver.new(FIXTURE_TRACK_SEED, 2)
	var three := ReactiveDriver.new(FIXTURE_TRACK_SEED, 3)
	_check(two.driver_seed == FIXTURE_IDENTITY, "adding the skill and mistake streams leaves car 2's identity where #56 pinned it (%d)" % two.driver_seed)
	_check(absf(two.skill - FIXTURE_SKILL_2) < 1e-12, "car 2's skill on seed 7 is the value computed independently in Python (%.16f against %.16f)" % [two.skill, FIXTURE_SKILL_2])
	_check(absf(three.skill - FIXTURE_SKILL_3) < 1e-12, "car 3's is too (%.16f against %.16f)" % [three.skill, FIXTURE_SKILL_3])
	_check(ReactiveDriver.new(FIXTURE_TRACK_SEED, 2).skill == two.skill, "the same track seed and index give the same skill")
	_check(ReactiveDriver.new(FIXTURE_TRACK_SEED + 1, 2).skill != two.skill, "a different track seed gives a different skill")
	_check(ReactiveDriver.new(FIXTURE_TRACK_SEED, 2, 2).skill != two.skill, "a different contract version gives a different skill")
	# Through _make_driver, so --break-skill-spread reaches it.
	for seed: int in SPREAD_SEEDS:
		var skills: Array[float] = []
		for index: int in FIELD_INDICES:
			skills.append(_make_driver(seed, index).skill)
		var distinct := {}
		var in_range := true
		for value in skills:
			distinct[value] = true
			in_range = in_range and value >= 0.0 and value < 1.0
		_check(in_range, "seed %d: every derived skill lies in [0, 1)" % seed)
		_check(distinct.size() == FIELD_INDICES.size(), "seed %d: twenty rivals draw twenty different skills (%d distinct)" % [seed, distinct.size()])
		_check(skills.max() - skills.min() >= MIN_SKILL_SPAN, "seed %d: they span at least %.1f of the scale (%.3f to %.3f)" % [seed, MIN_SKILL_SPAN, skills.min(), skills.max()])
	return true


## At 1.0 the dials must be #58's constants exactly -- `==`, not approximately -- because #58's suite
## pins its drivers to 1.0 and claims its measurements still hold. The rest are worked by hand from
## the documented range: 36-48 m of look-ahead, 12.0-13.6 m/s^2 of cornering, a mistake every 10-30 s.
func _verify_skill_turns_the_dials() -> bool:
	var driver := ReactiveDriver.new(0, 1)
	driver.set_skill(1.0)
	_check(driver.sensing_horizon() == WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M), "at skill 1.0 it senses #58's 48 m exactly (%.6f px)" % driver.sensing_horizon())
	_check(driver.cornering_belief_m() == ReactiveDriver.CORNERING_ACCELERATION_M, "and believes in #58's 13.6 m/s^2 of cornering exactly (%.9f)" % driver.cornering_belief_m())
	_check(absf(driver.mean_mistake_gap() - 30.0) < 1e-9, "and errs every 30 s on average (%.3f)" % driver.mean_mistake_gap())
	driver.set_skill(0.0)
	_check(absf(driver.sensing_horizon() - 450.0) < 1e-6, "at skill 0.0 it senses 36 m, 450 px (%.3f)" % driver.sensing_horizon())
	_check(absf(driver.cornering_belief_m() - 12.0) < 1e-9, "and corners at 12.0 m/s^2 (%.3f)" % driver.cornering_belief_m())
	_check(absf(driver.mean_mistake_gap() - 10.0) < 1e-9, "and errs every 10 s on average (%.3f)" % driver.mean_mistake_gap())
	driver.set_skill(0.5)
	_check(absf(driver.sensing_horizon() - 525.0) < 1e-6 and absf(driver.cornering_belief_m() - 12.8) < 1e-9 and absf(driver.mean_mistake_gap() - 20.0) < 1e-9, "at skill 0.5 every dial is half way: 42 m, 12.8 m/s^2, 20 s (%.3f px, %.3f, %.3f)" % [driver.sensing_horizon(), driver.cornering_belief_m(), driver.mean_mistake_gap()])
	driver.set_skill(-0.5)
	var low := driver.skill
	driver.set_skill(1.5)
	_check(low == 0.0 and driver.skill == 1.0, "set_skill clamps to [0, 1] (%.2f, %.2f)" % [low, driver.skill])
	return true


func _verify_the_mistake_plan_is_seeded() -> bool:
	var two := ReactiveDriver.new(FIXTURE_TRACK_SEED, 2)
	for n in range(FIXTURE_PLAN_2.size()):
		var expected: Array = FIXTURE_PLAN_2[n]
		var plan := two.mistake_plan(n)
		_check(plan.kind == expected[0] and absf(plan.amount - expected[1]) < 1e-9 and absf(plan.seconds - expected[2]) < 1e-9 and absf(plan.gap - expected[3]) < 1e-9, "car 2's plan %d on seed 7 is Python's: %s %.6f m %.6f s after %.6f s (got %s %.6f m %.6f s after %.6f s)" % [
			n, ReactiveDriver.mistake_name(expected[0]), expected[1], expected[2], expected[3], ReactiveDriver.mistake_name(plan.kind), plan.amount, plan.seconds, plan.gap,
		])
	var three := ReactiveDriver.new(FIXTURE_TRACK_SEED, 3).mistake_plan(0)
	_check(three.kind == FIXTURE_PLAN_3_FIRST[0] and absf(three.amount - FIXTURE_PLAN_3_FIRST[1]) < 1e-9 and absf(three.gap - FIXTURE_PLAN_3_FIRST[3]) < 1e-9, "car 3's first plan is Python's late brake of %.6f m (got %s %.6f m)" % [FIXTURE_PLAN_3_FIRST[1], ReactiveDriver.mistake_name(three.kind), three.amount])
	_check(two.mistake_plan(0) == two.mistake_plan(0) and two.mistakes_planned == 0, "asking for a plan is pure: the same answer twice, and nothing drawn (%d planned)" % two.mistakes_planned)
	# The stream is neither constant nor stuck: over a car's first thirty plans all three kinds come up
	# and every amount lies in its kind's documented range.
	var kinds := {}
	var in_range := true
	for n in range(30):
		var plan := two.mistake_plan(n)
		kinds[plan.kind] = true
		match plan.kind:
			ReactiveDriver.Mistake.LATE_BRAKE:
				in_range = in_range and plan.amount >= ReactiveDriver.LATE_BRAKE_MIN_M and plan.amount <= ReactiveDriver.LATE_BRAKE_MAX_M
			ReactiveDriver.Mistake.WIDE_LINE:
				in_range = in_range and plan.amount >= ReactiveDriver.WIDE_LINE_MIN_M and plan.amount <= ReactiveDriver.WIDE_LINE_MAX_M and plan.seconds >= ReactiveDriver.WIDE_LINE_MIN_SECONDS and plan.seconds <= ReactiveDriver.WIDE_LINE_MAX_SECONDS
			ReactiveDriver.Mistake.NEEDLESS_LIFT:
				in_range = in_range and plan.seconds >= ReactiveDriver.NEEDLESS_LIFT_MIN_SECONDS and plan.seconds <= ReactiveDriver.NEEDLESS_LIFT_MAX_SECONDS
			_:
				in_range = false
	_check(kinds.size() == 3, "car 2's first thirty plans use all three kinds (%d)" % kinds.size())
	_check(in_range, "and every one lies in its kind's documented range")
	return true


# ---------------------------------------------------------------------------------------------
# Single ticks against synthetic senses. Each kind, primed in a ForcedMistakeDriver with a 0.1 s mean
# gap (so it is armed within a few ticks), is compared with a flawless driver fed the same senses.


## #58's straight-road senses: on the centreline, aligned, at `speed` px/s along the nose.
func _straight_road_senses(speed: float) -> DriverSenses:
	var senses := DriverSenses.new()
	senses.look_ahead = WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M)
	senses.road_found = true
	senses.distance_to_left_edge = 120.0
	senses.distance_to_right_edge = 120.0
	senses.road_ahead_found = true
	senses.surface_type = SurfaceQuery.SurfaceType.DIRT
	senses.local_velocity = Vector2(0.0, -speed)
	return senses


## #58's corner: the road turns `turn` rad right across the look-ahead, and the look-ahead point sits
## outside the car's line as a straight running into an arc would put it.
func _bend_senses(speed: float, turn: float) -> DriverSenses:
	var senses := _straight_road_senses(speed)
	senses.road_ahead_heading_error = -turn
	senses.road_ahead_lateral_offset = -0.5 * senses.look_ahead * sin(turn)
	return senses


func _tick(driver: ReactiveDriver, senses: DriverSenses) -> VehicleInputState:
	driver.perceive(senses)
	return driver.drive(TICK)


func _same(left: VehicleInputState, right: VehicleInputState) -> bool:
	return left.steer == right.steer and left.throttle == right.throttle and left.brake == right.brake and left.handbrake == right.handbrake


## The switch, alone. A driver primed to err at every chance, with mistakes off, drives a script that
## offers every kind its moment -- a straight, a corner that asks for braking, a bend -- exactly as a
## plain flawless driver does, and draws nothing.
func _verify_mistakes_are_off_unless_asked() -> bool:
	_check(not ReactiveDriver.new(0, 1).mistakes_enabled, "a ReactiveDriver is built with mistakes off")
	for kind: int in [ReactiveDriver.Mistake.LATE_BRAKE, ReactiveDriver.Mistake.WIDE_LINE, ReactiveDriver.Mistake.NEEDLESS_LIFT]:
		var primed := _forced(kind, false, 0.1)
		var plain := ReactiveDriver.new(0, 1)
		plain.set_skill(1.0)
		var identical := true
		var script: Array[DriverSenses] = []
		for tick in range(60):
			script.append(_straight_road_senses(400.0))
		for tick in range(30):
			script.append(_bend_senses(400.0, 1.0))
		for tick in range(60):
			script.append(_bend_senses(400.0, 0.5))
		for senses in script:
			identical = _same(_tick(primed, senses), _tick(plain, senses)) and identical and primed.active_mistake == ReactiveDriver.Mistake.NONE
		_check(identical, "primed for %s but switched off, it drives %d ticks exactly as a flawless driver" % [ReactiveDriver.mistake_name(kind), script.size()])
		_check(primed.mistake_log().is_empty() and primed.mistakes_planned == 0 and primed.mistakes_lapsed == 0, "and draws nothing and logs nothing (%d planned, %d logged)" % [primed.mistakes_planned, primed.mistake_log().size()])
	# Switched off in the middle of a lift: the lift ends that tick and is logged as ended, and switching
	# back on does not resume it with its old clock.
	var toggled := _forced(ReactiveDriver.Mistake.NEEDLESS_LIFT, true, 0.1)
	var lifting_at := -1
	for tick in range(20):
		_tick(toggled, _straight_road_senses(400.0))
		if toggled.active_mistake == ReactiveDriver.Mistake.NEEDLESS_LIFT:
			lifting_at = tick
			break
	toggled.mistakes_enabled = false
	var off := _tick(toggled, _straight_road_senses(400.0))
	var ended := toggled.mistake_log()
	_check(lifting_at >= 0 and ended.size() == 1 and ended[0].until == lifting_at + 1 and off.throttle > 0.5, "switched off mid-lift, the lift ends that tick, logged (began %d, until %d), and the throttle is back (%.2f)" % [lifting_at, ended[0].until if not ended.is_empty() else -1, off.throttle])
	toggled.mistakes_enabled = true
	var back := _tick(toggled, _straight_road_senses(400.0))
	_check(back.throttle > 0.5 and toggled.mistake_log().size() == 1 and toggled.mistake_log()[0].until == lifting_at + 1, "switched back on, the old lift does not resume (throttle %.2f, %d logged)" % [back.throttle, toggled.mistake_log().size()])
	return true


## A late brake: #58's corner, which at 400 px/s is inside its braking distance, and a flawless driver
## brakes hard for it. A driver with a late brake armed does not: it holds the throttle for the brake's
## metres. At the largest late brake, 12 m (150 px) at 400 px/s (6.67 px a tick) is 22.5 ticks, so the
## corner's brake comes back on the 23rd.
func _verify_a_late_brake_is_chosen() -> bool:
	var chooser := _forced(ReactiveDriver.Mistake.LATE_BRAKE, true, 0.1)
	var flawless := _forced(ReactiveDriver.Mistake.LATE_BRAKE, false, 0.1)
	var identical := true
	for tick in range(30):
		identical = _same(_tick(chooser, _straight_road_senses(400.0)), _tick(flawless, _straight_road_senses(400.0))) and identical
	_check(identical and chooser.mistake_log().is_empty(), "armed with a late brake on a straight, it drives as the flawless driver: a straight offers a late brake nowhere to happen")
	var corner := _bend_senses(400.0, 1.0)
	var chose := _tick(chooser, corner)
	var should := _tick(flawless, corner)
	_check(should.brake > 0.5, "at 400 px/s the flawless driver brakes for the corner (brake %.2f)" % should.brake)
	_check(chose.brake == 0.0 and chose.throttle > 0.0, "the driver with a late brake armed does not: it stays on the throttle (throttle %.2f, brake %.2f)" % [chose.throttle, chose.brake])
	_check(chooser.active_mistake == ReactiveDriver.Mistake.LATE_BRAKE, "and says why: its active mistake is a late brake (%s)" % ReactiveDriver.mistake_name(chooser.active_mistake))
	var log := chooser.mistake_log()
	_check(log.size() == 1 and log[0].kind == ReactiveDriver.Mistake.LATE_BRAKE and log[0].tick == 30 and log[0].until == -1, "and logs it: one late brake, begun on tick 30, still under way (%s)" % [log])
	var withheld := 1
	while withheld < 100:
		var controls := _tick(chooser, corner)
		if controls.brake > 0.0:
			break
		withheld += 1
	log = chooser.mistake_log()
	_check(withheld == 23, "it brakes again once it has run its 12 m: the brake was withheld for 23 ticks (%d)" % withheld)
	_check(log[0].until == 30 + 23, "and the log says it ended there (until %d)" % log[0].until)
	# Only the corner's brake. A rival being caught in its path is braked for through a late brake.
	var second := _forced(ReactiveDriver.Mistake.LATE_BRAKE, true, 0.1)
	for tick in range(30):
		_tick(second, _straight_road_senses(400.0))
	var crowded := _bend_senses(400.0, 1.0)
	crowded.has_rival_ahead = true
	crowded.rival_offset = Vector2(0.0, -120.0)
	crowded.rival_distance = 120.0
	crowded.rival_relative_velocity = Vector2(0.0, 150.0)
	var braked := _tick(second, crowded)
	_check(second.active_mistake == ReactiveDriver.Mistake.LATE_BRAKE and braked.brake > 0.5, "a late brake withholds only the corner's brake: a rival caught in the path is braked for through it (%s, brake %.2f)" % [ReactiveDriver.mistake_name(second.active_mistake), braked.brake])
	return true


## A wide line: in a bend turning right, the driver aims to the left of the centreline. Exactly how
## far is pinned where the edge caps the aim, because the cap does not depend on the drawn amount: on a
## road 100 px from centre to edge the aim can go 100 - 75 = 25 px out (the keep is 6 m, 75 px), so a
## driver 25 px left of the centreline is exactly on its line, and steers exactly as a flawless driver
## on the centreline does.
##
## The aim is not the car. The car overshoots its aim through a bend, so the mistake also lets go the
## tick the car's own centre is within the keep of an edge; that is checked here, and the distance the
## car actually keeps is asserted on every lap in _check_clean_lap.
func _verify_a_wide_line_is_chosen() -> bool:
	var chooser := _forced(ReactiveDriver.Mistake.WIDE_LINE, true, 0.1)
	var flawless := _forced(ReactiveDriver.Mistake.WIDE_LINE, false, 0.1)
	for tick in range(30):
		_tick(chooser, _straight_road_senses(400.0))
		_tick(flawless, _straight_road_senses(400.0))
	_check(chooser.mistake_log().is_empty(), "armed with a wide line on a straight, it waits: a straight is no bend")
	var bend := _bend_senses(400.0, 0.5)
	var chose := _tick(chooser, bend)
	var should := _tick(flawless, bend)
	_check(chooser.active_mistake == ReactiveDriver.Mistake.WIDE_LINE and chooser.mistake_log().size() == 1, "in a bend it commits the wide line and logs it (%s)" % ReactiveDriver.mistake_name(chooser.active_mistake))
	_check(chose.steer < should.steer - 0.02, "on the centreline of a right-hand bend it steers left of the flawless driver, toward the outside (steer %+.3f against %+.3f)" % [chose.steer, should.steer])
	# The car reaches 70 px from the left edge, inside the 75 px keep: the wide line lets go that tick.
	var near_the_edge := _bend_senses(400.0, 0.5)
	near_the_edge.lateral_offset = -50.0
	near_the_edge.distance_to_left_edge = 70.0
	near_the_edge.distance_to_right_edge = 170.0
	var letting_go := _tick(chooser, near_the_edge)
	var log := chooser.mistake_log()
	_check(chooser.active_mistake == ReactiveDriver.Mistake.NONE and log[0].until == 31, "the tick the car's centre is 70 px from the edge, inside the 75 px keep, the wide line ends (until %d, expected 31)" % log[0].until)
	var plain := ReactiveDriver.new(0, 1)
	plain.set_skill(1.0)
	_check(letting_go.steer == _tick(plain, near_the_edge).steer, "and it steers that tick exactly as a flawless driver would (%+.6f)" % letting_go.steer)
	var narrow := _forced(ReactiveDriver.Mistake.WIDE_LINE, true, 0.1)
	for tick in range(30):
		_tick(narrow, _straight_road_senses(400.0))
	var on_its_line := _bend_senses(400.0, 0.5)
	on_its_line.lateral_offset = -25.0
	on_its_line.distance_to_left_edge = 75.0
	on_its_line.distance_to_right_edge = 125.0
	var narrow_steer := _tick(narrow, on_its_line)
	var centred := _bend_senses(400.0, 0.5)
	centred.distance_to_left_edge = 100.0
	centred.distance_to_right_edge = 100.0
	var reference := ReactiveDriver.new(0, 1)
	reference.set_skill(1.0)
	var reference_steer := _tick(reference, centred)
	_check(narrow.active_mistake == ReactiveDriver.Mistake.WIDE_LINE and narrow_steer.steer == reference_steer.steer, "on a road 100 px from centre to edge its aim is 25 px outside, 75 px from the edge: there it steers exactly as a flawless car on the centreline (%+.6f against %+.6f)" % [narrow_steer.steer, reference_steer.steer])
	var cramped := _forced(ReactiveDriver.Mistake.WIDE_LINE, true, 0.1)
	for tick in range(30):
		_tick(cramped, _straight_road_senses(400.0))
	var tight := _bend_senses(400.0, 0.5)
	tight.distance_to_left_edge = 70.0
	tight.distance_to_right_edge = 70.0
	_tick(cramped, tight)
	_check(cramped.mistake_log().is_empty(), "on a road 70 px from centre to edge, inside the keep, a wide line cannot begin at all")
	return true


## A needless lift: on a clear straight at speed, the throttle comes off -- and nothing else happens.
## The largest lift is 1.2 s, 72 ticks at 60 a second; the log's first tick must be the first tick the
## controls show it.
func _verify_a_needless_lift_is_chosen() -> bool:
	var chooser := _forced(ReactiveDriver.Mistake.NEEDLESS_LIFT, true, 0.1)
	var flawless := _forced(ReactiveDriver.Mistake.NEEDLESS_LIFT, false, 0.1)
	var first_lift := -1
	var lifted := 0
	var agreed_before := true
	var only_the_throttle := true
	for tick in range(200):
		var senses := _straight_road_senses(400.0)
		var chose := _tick(chooser, senses)
		var should := _tick(flawless, senses)
		var lifting := chose.throttle == 0.0 and should.throttle > 0.5
		if lifting and (first_lift < 0 or tick == first_lift + lifted):
			if first_lift < 0:
				first_lift = tick
			lifted += 1
			only_the_throttle = only_the_throttle and chose.brake == 0.0 and chose.steer == should.steer
		elif first_lift < 0:
			agreed_before = agreed_before and _same(chose, should)
	var log := chooser.mistake_log()
	_check(first_lift >= 0 and agreed_before, "on a straight at 400 px/s it drives as the flawless driver until it lifts, on tick %d" % first_lift)
	_check(lifted == 72, "it lifts for 72 ticks in a row, 1.2 s (%d)" % lifted)
	_check(only_the_throttle, "and the lift is only the throttle: no brake, the same steering")
	_check(not log.is_empty() and log[0].kind == ReactiveDriver.Mistake.NEEDLESS_LIFT and log[0].tick == first_lift and log[0].until == first_lift + 72, "the log says the same: a needless lift from tick %d until %d (%s)" % [first_lift, first_lift + 72, log])
	return true


## Mistakes begin only while the car is racing cleanly, the gap before one counts down only then, and
## leaving that state ends one at once. An armed mistake the road offers nothing to lapses.
func _verify_mistakes_wait_for_clean_racing() -> bool:
	var driver := _forced(ReactiveDriver.Mistake.NEEDLESS_LIFT, true, 0.1)
	var off_road := _straight_road_senses(400.0)
	off_road.surface_type = SurfaceQuery.SurfaceType.OFF_TRACK
	var misaligned := _straight_road_senses(400.0)
	misaligned.heading_error = 0.5
	misaligned.road_ahead_heading_error = 0.5
	var crawling := _straight_road_senses(100.0)
	var lost := DriverSenses.new()
	lost.look_ahead = WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M)
	lost.local_velocity = Vector2(0.0, -400.0)
	var dirty := 0
	for senses: DriverSenses in [off_road, misaligned, crawling, lost]:
		for tick in range(120):
			_tick(driver, senses)
			dirty += 1
	_check(driver.mistake_log().is_empty() and driver.mistakes_planned == 0, "off the road, misaligned, below 12 m/s or with no road found, for %d ticks, it plans nothing (%d planned)" % [dirty, driver.mistakes_planned])
	# The 0.05 s gap is three ticks. Had it counted down on the dirty ticks, the lift would begin on the
	# first clean one.
	for tick in range(10):
		_tick(driver, _straight_road_senses(400.0))
	var log := driver.mistake_log()
	_check(log.size() == 1 and log[0].tick >= dirty + 2, "its gap counts only clean racing: the lift begins on tick %d, not on the first clean tick %d" % [log[0].tick if not log.is_empty() else -1, dirty])
	_tick(driver, off_road)
	log = driver.mistake_log()
	_check(driver.active_mistake == ReactiveDriver.Mistake.NONE and log[0].until == dirty + 10, "leaving the road ends the lift that tick (until %d, expected %d)" % [log[0].until, dirty + 10])
	# Patience. A late brake armed on an endless straight finds no corner: after 0.05 s and then
	# MISTAKE_PATIENCE_S it lapses, and the next one is drawn.
	var waiting := _forced(ReactiveDriver.Mistake.LATE_BRAKE, true, 0.1)
	var ticks := roundi((0.05 + ReactiveDriver.MISTAKE_PATIENCE_S) / TICK) + 10
	for tick in range(ticks):
		_tick(waiting, _straight_road_senses(400.0))
	_check(waiting.mistakes_lapsed == 1 and waiting.mistakes_planned == 2 and waiting.mistake_log().is_empty(), "a late brake armed on a straight for %d ticks lapses once, and the next is drawn (%d lapsed, %d planned)" % [ticks, waiting.mistakes_lapsed, waiting.mistakes_planned])
	return true


## Going round a stopped car is not racing cleanly (#61): no mistake begins while the car passes. A driver
## primed for a needless lift stalls behind a rival 52 px ahead in its lane, which starts a pass, then
## drives on at 400 px/s on a straight with that rival still close ahead, so the pass holds until its
## timeout. Guards: it really is passing on every tick after the pass's 1 s of grace, and on each of those
## ticks the road offers the lift its moment -- the rival is beside the line the pass aims for -- so only
## the pass keeps the lift from beginning. Dropping the pass from _racing_cleanly fails it.
func _verify_no_mistake_begins_while_passing() -> bool:
	var driver := _forced(ReactiveDriver.Mistake.NEEDLESS_LIFT, true, 0.1)
	var stalled := _straight_road_senses(0.0)
	stalled.has_rival_ahead = true
	stalled.rival_offset = Vector2(10.0, -52.0)
	stalled.rival_distance = stalled.rival_offset.length()
	var stall_ticks := ceili(ReactiveDriver.STALL_SECONDS / TICK) + 1
	for tick in range(stall_ticks):
		_tick(driver, stalled)
	var alongside := _straight_road_senses(400.0)
	alongside.has_rival_ahead = true
	alongside.rival_offset = stalled.rival_offset
	alongside.rival_distance = stalled.rival_distance
	var grace_ticks := ceili(ReactiveDriver.RECOVERY_GRACE_SECONDS / TICK) + 1
	var passing_ticks := roundi((ReactiveDriver.PASS_TIMEOUT_SECONDS - ReactiveDriver.RECOVERY_GRACE_SECONDS) / TICK) - 10
	var passing := 0
	var offered := 0
	for tick in range(grace_ticks + passing_ticks):
		_tick(driver, alongside)
		if tick >= grace_ticks:
			passing += int(driver.get("passing") == true)
			offered += int(driver.call("_mistake_has_its_moment", ReactiveDriver.Mistake.NEEDLESS_LIFT, 400.0))
	_check(passing == passing_ticks and offered == passing_ticks, "stalled behind a rival, it goes round it and is still passing %d ticks after the pass's grace, with the road offering a needless lift its moment on every one (%d passing, %d offered)" % [passing_ticks, passing, offered])
	_check(driver.mistake_log().is_empty() and driver.mistakes_planned == 0, "primed for a needless lift, it begins none while passing (%d planned, %d logged)" % [driver.mistakes_planned, driver.mistake_log().size()])
	return true


# ---------------------------------------------------------------------------------------------
# Different cars


## What the stream decides is different for every car. Twenty rivals' first three plans -- kind,
## amount and seconds -- compared for every one of the 190 pairs on each of SPREAD_SEEDS. Those three
## read nothing but the stream, so this is the stream's answer and nothing else's, and
## --break-mistake-seed makes every pair equal. The gap is left out on purpose: it reads skill, so it
## would tell cars apart even with the stream broken. So is comparing kind and amount alone: a needless
## lift's amount is always 0, and the first version found two cars whose first three were all lifts.
func _verify_different_cars_plan_different_mistakes() -> bool:
	for seed: int in SPREAD_SEEDS:
		var plans: Array[Array] = []
		for index: int in FIELD_INDICES:
			var driver := _make_driver(seed, index)
			var mine: Array = []
			for n in range(3):
				var plan := driver.mistake_plan(n)
				mine.append([plan.kind, plan.amount, plan.seconds])
			plans.append(mine)
		var same_pairs := 0
		var pairs := 0
		for a in range(plans.size()):
			for b in range(a + 1, plans.size()):
				pairs += 1
				same_pairs += int(plans[a] == plans[b])
		_check(pairs == 190 and same_pairs == 0, "seed %d: no two of twenty rivals plan the same first three mistakes (%d of %d pairs the same)" % [seed, same_pairs, pairs])
	return true


# ---------------------------------------------------------------------------------------------
# Laps


func _verify_the_same_car_repeats_its_mistakes() -> bool:
	var definition: TrackDefinition = _generator.generate(REPEAT_SEED)
	var runs: Array[Dictionary] = []
	for run in range(2):
		var driver := _make_driver(REPEAT_SEED, REPEAT_INDEX)
		driver.mistakes_enabled = true
		var record := await _drive(definition, driver, definition.spawn_transform, LAP_TICK_BUDGET)
		record["log"] = driver.mistake_log()
		record["skill"] = driver.skill
		record["plans"] = []
		for entry in record.log:
			record.plans.append(driver.mistake_plan(entry.n))
		runs.append(record)
		_report_lap("repeat run %d" % run, REPEAT_SEED, REPEAT_INDEX, driver, record)
	var first: Array = runs[0].log
	var kinds := {}
	for entry in first:
		kinds[entry.kind] = true
	_check(runs[0].completed and runs[1].completed, "seed %d car %d (skill %.3f) with mistakes on laps twice (%.2f s and %.2f s)" % [REPEAT_SEED, REPEAT_INDEX, runs[0].skill, runs[0].ticks * TICK, runs[1].ticks * TICK])
	# The guards that keep the equality below from being the equality of two empty or constant logs.
	_check(first.size() >= REPEAT_MIN_MISTAKES and kinds.size() >= 2, "the lap commits at least %d mistakes of at least two kinds (%d, %d kinds)" % [REPEAT_MIN_MISTAKES, first.size(), kinds.size()])
	_check(first == runs[1].log, "the whole logged sequence repeats -- plan number, kind, tick, amount, seconds and end tick of every mistake:\n  %s\n  %s" % [_log_text(first), _log_text(runs[1].log)])
	_check(_first_difference(runs[0].controls, runs[1].controls) == -1, "and so does the whole control stream, tick for tick over the lap")
	var faithful := true
	var ordered := true
	for i in range(first.size()):
		var plan: Dictionary = runs[0].plans[i]
		faithful = faithful and first[i].kind == plan.kind and first[i].amount == plan.amount and first[i].seconds == plan.seconds
		# The last may still be under way when the lap ends (until -1); every other has ended.
		var ended: bool = first[i].until > first[i].tick or (first[i].until == -1 and i == first.size() - 1)
		ordered = ordered and ended and (i == 0 or (first[i].n > first[i - 1].n and first[i].tick >= first[i - 1].until))
	_check(faithful, "every mistake logged is the stream's plan for its number, kind, amount and seconds")
	_check(ordered, "and they come in plan order, one at a time, each lasting at least a tick")
	return true


## Two rivals differing only in their mistake streams: the same seed, the same start, skill pinned
## to the same value, different car indices. The only thing the index still reaches is the mistakes.
##
## - Mistakes off: their control streams are identical over a whole lap. This is the suppression
##   assertion. --leak-mistakes fails it.
## - The issue's own wording, two identical cars with mistakes off, is checked too -- and printed as
##   what it is: it cannot tell a working switch from one that hides only the log.
## - Mistakes on: their logs differ, and their control streams are identical up to the first mistake
##   either logs and differ on that very tick. That is the lap-scale "because it chose to": nothing
##   separates the twins but a logged decision. --break-mistake-seed fails it, because the twins then
##   draw the same plan and drive the same lap.
func _verify_twins_differ_only_by_their_mistakes() -> bool:
	var definition: TrackDefinition = _generator.generate(TWIN_SEED)
	var off: Array[Dictionary] = []
	var on: Array[Dictionary] = []
	for index: int in TWIN_INDICES:
		var quiet := _make_driver(TWIN_SEED, index)
		quiet.set_skill(TWIN_SKILL)
		var record := await _drive(definition, quiet, definition.spawn_transform, LAP_TICK_BUDGET)
		record["log"] = quiet.mistake_log()
		record["planned"] = quiet.mistakes_planned
		off.append(record)
		_report_lap("twin off", TWIN_SEED, index, quiet, record)
	for index: int in TWIN_INDICES:
		var erring := _make_driver(TWIN_SEED, index)
		erring.set_skill(TWIN_SKILL)
		erring.mistakes_enabled = true
		var record := await _drive(definition, erring, definition.spawn_transform, LAP_TICK_BUDGET)
		record["log"] = erring.mistake_log()
		on.append(record)
		_report_lap("twin on", TWIN_SEED, index, erring, record)
	var again := _make_driver(TWIN_SEED, TWIN_INDICES[0])
	again.set_skill(TWIN_SKILL)
	var repeat := await _drive(definition, again, definition.spawn_transform, LAP_TICK_BUDGET)

	var quiet_difference := _first_difference(off[0].controls, off[1].controls)
	_check(off[0].completed and off[1].completed, "both twins lap with mistakes off (%.2f s and %.2f s)" % [off[0].ticks * TICK, off[1].ticks * TICK])
	_check(off[0].log.is_empty() and off[1].log.is_empty() and off[0].planned == 0 and off[1].planned == 0, "neither logs nor plans a mistake")
	_check(quiet_difference == -1, "SUPPRESSION: with mistakes off, twins that differ only in their mistake streams drive identical control streams over the whole lap (first difference at value %d)" % quiet_difference)
	var literal := _first_difference(off[0].controls, repeat.controls)
	_check(literal == -1, "the issue's wording, two identical cars with mistakes off, also drive identical streams -- which a switch that hid only the log would pass too (first difference at value %d)" % literal)

	var first_mistake := LAP_TICK_BUDGET
	for record in on:
		if not record.log.is_empty():
			first_mistake = mini(first_mistake, int(record.log[0].tick))
	var loud_difference := _first_difference(on[0].controls, on[1].controls)
	_check(on[0].completed and on[1].completed, "both twins lap with mistakes on (%.2f s and %.2f s)" % [on[0].ticks * TICK, on[1].ticks * TICK])
	_check(not on[0].log.is_empty() and not on[1].log.is_empty(), "both commit mistakes (%d and %d)" % [on[0].log.size(), on[1].log.size()])
	_check(on[0].log != on[1].log, "DIFFERENT CARS: with mistakes on the twins log different mistakes:\n  %s\n  %s" % [_log_text(on[0].log), _log_text(on[1].log)])
	_check(loud_difference >= 0 and loud_difference / 4 == first_mistake, "their control streams agree until the first mistake either logs, and differ on that tick (first difference on tick %d, first mistake on tick %d)" % [loud_difference / 4 if loud_difference >= 0 else -1, first_mistake])
	return true


## Each seed's least and most skilled rival by derived skill, solo, mistakes off. --break-skill-spread
## gives every car 0.5, so the two are the same driver and lap in the same time.
func _verify_skill_spreads_lap_times() -> bool:
	for seed: int in SPREAD_SEEDS:
		var definition: TrackDefinition = _generator.generate(seed)
		var lowest := FIELD_INDICES[0]
		var highest := FIELD_INDICES[0]
		for index: int in FIELD_INDICES:
			if _make_driver(seed, index).skill < _make_driver(seed, lowest).skill:
				lowest = index
			if _make_driver(seed, index).skill > _make_driver(seed, highest).skill:
				highest = index
		var slow_driver := _make_driver(seed, lowest)
		var fast_driver := _make_driver(seed, highest)
		var slow := await _drive(definition, slow_driver, definition.spawn_transform, LAP_TICK_BUDGET)
		var fast := await _drive(definition, fast_driver, definition.spawn_transform, LAP_TICK_BUDGET)
		_report_lap("spread lowest", seed, lowest, slow_driver, slow)
		_report_lap("spread highest", seed, highest, fast_driver, fast)
		var spread := float(slow.ticks) / float(fast.ticks) - 1.0
		_check(slow.completed and fast.completed, "seed %d: the least skilled rival (car %d, %.3f) and the most (car %d, %.3f) both lap" % [seed, lowest, slow_driver.skill, highest, fast_driver.skill])
		_check(spread >= SPREAD_MARGIN, "SKILL SPREAD: seed %d: the least skilled rival's lap is at least %.0f%% slower than the most skilled's (%.2f s against %.2f s, %.1f%%)" % [seed, 100.0 * SPREAD_MARGIN, slow.ticks * TICK, fast.ticks * TICK, 100.0 * spread])
	# Pinned skills, in order. Not reached by --break-skill-spread: this is the dial, not the derivation.
	var definition: TrackDefinition = _generator.generate(SWEEP_SEED)
	var ticks: Array[int] = []
	for skill: float in [0.0, 0.5, 1.0]:
		var driver := ReactiveDriver.new(SWEEP_SEED, 1)
		driver.set_skill(skill)
		var record := await _drive(definition, driver, definition.spawn_transform, LAP_TICK_BUDGET)
		_report_lap("sweep %.1f" % skill, SWEEP_SEED, 1, driver, record)
		ticks.append(record.ticks if record.completed else LAP_TICK_BUDGET + 1)
	_check(ticks[0] > ticks[1] and ticks[1] > ticks[2], "seed %d: skill 0.0, 0.5 and 1.0 lap in that order, slowest first (%d, %d, %d ticks)" % [SWEEP_SEED, ticks[0], ticks[1], ticks[2]])
	_check(ticks[2] == SWEEP_TOP_SKILL_TICKS, "seed %d at skill 1.0 is #58's lap to the tick (%d, #58: %d)" % [SWEEP_SEED, ticks[2], SWEEP_TOP_SKILL_TICKS])
	return true


## The lowest skill there is, with its mistakes on at the rate that skill makes them, on every seed.
## #58's lap standard, and the stuck rule it defined: never slower than the car's own stuck speed for
## its stuck time.
func _verify_the_lowest_skill_finishes() -> bool:
	var committed := 0
	for seed: int in ALL_SEEDS:
		var definition: TrackDefinition = _generator.generate(seed)
		var driver := _make_driver(seed, 1)
		driver.set_skill(0.0)
		driver.mistakes_enabled = true
		var record := await _drive(definition, driver, definition.spawn_transform, LAP_TICK_BUDGET)
		_report_lap("lowest", seed, 1, driver, record)
		committed += driver.mistake_log().size()
		_check_clean_lap("seed %d at skill 0.0 with mistakes on" % seed, record)
	_check(committed >= ALL_SEEDS.size(), "mistakes really were on: %d committed across the %d laps" % [committed, ALL_SEEDS.size()])
	return true


func _verify_every_mistake_is_survivable() -> bool:
	for kind: int in [ReactiveDriver.Mistake.LATE_BRAKE, ReactiveDriver.Mistake.WIDE_LINE, ReactiveDriver.Mistake.NEEDLESS_LIFT]:
		for seed: int in SURVIVAL_SEEDS:
			var definition: TrackDefinition = _generator.generate(seed)
			for skill: float in SURVIVAL_SKILLS:
				var driver := ForcedMistakeDriver.new(seed, 1)
				driver.set_skill(skill)
				driver.forced_kind = kind
				driver.mean_gap_override = SURVIVAL_MEAN_GAP_S
				driver.mistakes_enabled = true
				var record := await _drive(definition, driver, definition.spawn_transform, LAP_TICK_BUDGET)
				_report_lap("survival %s" % ReactiveDriver.mistake_name(kind), seed, 1, driver, record)
				var of_kind := 0
				for entry in driver.mistake_log():
					of_kind += int(entry.kind == kind)
				var name := "%s at skill %.1f on seed %d" % [ReactiveDriver.mistake_name(kind), skill, seed]
				_check(of_kind >= SURVIVAL_MIN_COMMITTED and of_kind == driver.mistake_log().size(), "%s: committed repeatedly, and nothing else (%d of %d)" % [name, of_kind, driver.mistake_log().size()])
				_check_clean_lap(name, record)
	return true


## Twenty rivals on the session's grid, every one with its derived skill and its mistakes on. Every
## car must lap without meeting the stuck rule or straying. Contact is printed, not bounded: a field
## with a skill spread and no overtaking is #61's to judge.
##
## And the different-cars assertion on real logs. The plan number is what the stream indexes, so two
## cars that each committed plan n are compared on what they did under it. --break-mistake-seed gives
## every car the same plan n, and every such comparison comes out equal.
##
## **Which race a field drives depends on how and where it was spawned, and this suite pins one.**
## The same seed and drivers in a fresh process drive the identical race run after run; spawned after
## other sections, they did not (6 of 20 cars after one section, 13 after the whole suite), and #58's
## driver at skill 1.0 with mistakes off does the same. This file first blamed contact order and the
## server's history. The #59 review measured the real mechanism and showed it bit for bit:
##
## - **The spawn phase.** What matters is whether a physics step runs between placing the cars and
##   their first sense. Integrating a body rebuilds its transform from its angle in 32-bit `real_t`,
##   which re-rounds the basis `_grid_slot` built: at the first driving tick the two spawn phases
##   agree on every position, height and velocity and differ only in some cars' `global_rotation`,
##   in the last digit. No car touches another at spawn. The driver amplifies that ulp and contact
##   spreads it. Snapping each spawn pose to its own fixed point before placing it (rebuild it from
##   its rotation and origin until it stops changing) makes every spawn phase drive the same race.
## - **A reused space.** Separately, a physics space that has held a different track changes the race
##   even with snapped poses; a fresh World2D after the same history does not.
##
## Running first puts this field in the phase and the space `--only=field` has. That is a measurement
## fix, not a cure. The cure -- a snapped spawn, a fresh space per race, and a test that runs the same
## race twice in one process with different histories between -- is #61's, in MainSession and
## tests/field_race_test.gd; this section builds its field by hand and has neither. When the first full run
## failed this section's guard (89 comparable pairs against a fresh field's 104), the guard was not
## lowered to make that run pass. Once the review had named the mechanism, it was given a basis that
## does not depend on which race is driven -- a quarter of the pairs, 48 -- see below.
func _verify_a_field_with_skill_and_mistakes() -> bool:
	var definition: TrackDefinition = _generator.generate(FIELD_SEED)
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var surface := TrackSurfaceMap.new(definition)
	var field: Array[TopDownCar] = []
	var drivers: Array[ReactiveDriver] = []
	var detectors: Array[CheckpointCrossingDetector] = []
	var trackers: Array[LapProgressTracker] = []
	for index: int in FIELD_INDICES:
		var car := VEHICLE_SCENE.instantiate() as TopDownCar
		car.tuning = _tuning
		car.global_transform = _grid_slot(definition, index)
		runtime.add_child(car)
		car.set_surface_query(surface)
		car.set_height_query(runtime.height_query())
		car.set_auto_reset_enabled(false)
		field.append(car)
		var driver := _make_driver(FIELD_SEED, index)
		driver.mistakes_enabled = true
		drivers.append(driver)
		var detector := CheckpointCrossingDetector.new(definition)
		detector.reset(car.global_position)
		detectors.append(detector)
		trackers.append(LapProgressTracker.new(definition.checkpoints.size()))
	await physics_frame
	var sensing := SensingPass.new(surface, runtime.height_query())
	var count := FIELD_INDICES.size()
	var finished_at: Array[int] = []
	var slow: Array[int] = []
	var longest_slow: Array[int] = []
	var touching: Array[int] = []
	var strayed: Array[int] = []
	for slot in range(count):
		finished_at.append(-1)
		slow.append(0)
		longest_slow.append(0)
		touching.append(0)
		strayed.append(0)
	for tick in range(FIELD_TICK_BUDGET):
		var senses: Array[DriverSenses] = []
		for slot in range(count):
			senses.append(sensing.sense(field, slot, drivers[slot].sensing_horizon()))
		for slot in range(count):
			drivers[slot].perceive(senses[slot])
			field[slot].set_input_state(drivers[slot].drive(TICK))
		await physics_frame
		for slot in range(count):
			if finished_at[slot] >= 0:
				continue
			var car := field[slot]
			slow[slot] = slow[slot] + 1 if car.get_speed() < _tuning.auto_reset_stuck_speed else 0
			longest_slow[slot] = maxi(longest_slow[slot], slow[slot])
			for body in car.get_colliding_bodies():
				if body is TopDownCar:
					touching[slot] += 1
					break
			if not definition.play_area.has_point(car.global_position) or surface.distance_to_centerline(car.global_position, _tuning.auto_reset_lost_distance * 2.0) > _tuning.auto_reset_lost_distance:
				strayed[slot] += 1
			var crossing := detectors[slot].sample(car.global_position)
			if not crossing.is_empty() and trackers[slot].cross_checkpoint(int(crossing.checkpoint), float(crossing.forward_dot)):
				finished_at[slot] = tick + 1
		if not finished_at.has(-1):
			break
	var finished := 0
	var worst_slow := 0
	var strayed_cars := 0
	var worst_contact := 0.0
	var committed := 0
	for slot in range(count):
		var ticks := finished_at[slot] if finished_at[slot] >= 0 else FIELD_TICK_BUDGET
		finished += int(finished_at[slot] >= 0)
		worst_slow = maxi(worst_slow, longest_slow[slot])
		strayed_cars += int(strayed[slot] > 0)
		worst_contact = maxf(worst_contact, touching[slot] / float(ticks))
		committed += drivers[slot].mistake_log().size()
		print("field seed=%d car=%d skill=%.3f finished=%s lap_s=%.2f slowest_streak=%d contact_ticks=%d (%.1f%%) recoveries=%d mistakes=%d planned=%d lapsed=%d %s" % [
			FIELD_SEED, FIELD_INDICES[slot], drivers[slot].skill, finished_at[slot] >= 0, ticks * TICK, longest_slow[slot], touching[slot], 100.0 * touching[slot] / ticks,
			drivers[slot].recoveries, drivers[slot].mistake_log().size(), drivers[slot].mistakes_planned, drivers[slot].mistakes_lapsed, _log_text(drivers[slot].mistake_log()),
		])
	runtime.queue_free()
	await process_frame
	_check(finished == count, "a field of %d with skill and mistakes on seed %d: every car laps (%d)" % [count, FIELD_SEED, finished])
	_check(worst_slow < _stuck_ticks(), "no car in it meets the stuck rule (longest slow streak %d of %d ticks)" % [worst_slow, _stuck_ticks()])
	_check(strayed_cars == 0, "no car leaves the play area or gets lost (%d did)" % strayed_cars)
	print("field contact: worst %.1f%% of a lap; %d mistakes committed across the field" % [100.0 * worst_contact, committed])

	var comparable := 0
	var same := 0
	for a in range(count):
		for b in range(a + 1, count):
			var shared := 0
			var differs := false
			for left in drivers[a].mistake_log():
				for right in drivers[b].mistake_log():
					if left.n == right.n:
						shared += 1
						differs = differs or left.kind != right.kind or left.amount != right.amount or left.seconds != right.seconds
			if shared > 0:
				comparable += 1
				same += int(not differs)
	# The guard's job is only that the zero below is measured over most of the field. It was "half of
	# 190", calibrated to one race; a race's comparable pairs move with its spawn (89-104 observed), so
	# it is now a quarter of the pairs, a basis that does not depend on which race this is.
	_check(comparable >= 48, "at least a quarter of the field's 190 pairs committed a mistake under the same plan number, so the check below has something to compare (%d pairs)" % comparable)
	_check(same == 0, "DIFFERENT CARS: in the field, every pair that committed the same plan number committed a different mistake under it (%d of %d pairs the same)" % [same, comparable])
	return true


# ---------------------------------------------------------------------------------------------
# Driving


## One car, one driver, the production world, the car's own reset off: until it laps or the budget
## runs out. #58's lap loop, trimmed to what these checks read. The control stream is 64-bit, the
## width VehicleInputState holds, so "identical" is literal: #58's review found its 32-bit streams
## could have hidden a difference below float precision.
func _drive(definition: TrackDefinition, driver: ReactiveDriver, pose: Transform2D, budget: int) -> Dictionary:
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var surface := TrackSurfaceMap.new(definition)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	car.global_transform = pose
	runtime.add_child(car)
	car.set_surface_query(surface)
	car.set_height_query(runtime.height_query())
	car.set_auto_reset_enabled(false)
	await physics_frame
	var sensing := SensingPass.new(surface, runtime.height_query())
	var field: Array[TopDownCar] = [car]
	var detector := CheckpointCrossingDetector.new(definition)
	detector.reset(car.global_position)
	var tracker := LapProgressTracker.new(definition.checkpoints.size())
	var record := {
		"completed": false, "ticks": 0, "controls": PackedFloat64Array(), "off_road_ticks": 0,
		"outside_ticks": 0, "max_from_centre": 0.0, "longest_slow": 0, "half_width": definition.track_width * 0.5,
	}
	var slow := 0
	for tick in range(budget):
		driver.perceive(sensing.sense(field, 0, driver.sensing_horizon()))
		var controls := driver.drive(TICK)
		record.controls.append_array(PackedFloat64Array([controls.steer, controls.throttle, controls.brake, controls.handbrake]))
		car.set_input_state(controls)
		await physics_frame
		record.ticks += 1
		var position := car.global_position
		record.off_road_ticks += int(surface.sample_at(position).surface_type == SurfaceQuery.SurfaceType.OFF_TRACK)
		record.outside_ticks += int(not definition.play_area.has_point(position))
		record.max_from_centre = maxf(record.max_from_centre, surface.distance_to_centerline(position, _tuning.auto_reset_lost_distance * 2.0))
		slow = slow + 1 if car.get_speed() < _tuning.auto_reset_stuck_speed else 0
		record.longest_slow = maxi(record.longest_slow, slow)
		var crossing := detector.sample(position)
		if not crossing.is_empty() and tracker.cross_checkpoint(int(crossing.checkpoint), float(crossing.forward_dot)):
			record.completed = true
			break
	runtime.queue_free()
	await process_frame
	return record


## #58's lap standard: laps, never outside the play area or lost, never stuck, on the road.
func _check_clean_lap(name: String, record: Dictionary) -> void:
	_check(record.completed, "%s: laps (%.2f s)" % [name, record.ticks * TICK])
	_check(record.outside_ticks == 0 and record.max_from_centre <= _tuning.auto_reset_lost_distance, "%s: never outside the play area or lost (%.1f px from the centreline at most)" % [name, record.max_from_centre])
	_check(record.longest_slow < _stuck_ticks(), "%s: never stuck (longest slow streak %d of %d ticks)" % [name, record.longest_slow, _stuck_ticks()])
	_check(record.off_road_ticks <= MAX_OFF_ROAD_FRACTION * record.ticks, "%s: on the road, off it for %.2f%% of the lap" % [name, 100.0 * record.off_road_ticks / float(maxi(record.ticks, 1))])
	# The car, not the aim: the review found "0.00% off road" sampled at the car's centre while the
	# centre came 1.7 px from the edge. The whole body stays on the dirt.
	var clearance: float = record.half_width - record.max_from_centre
	_check(clearance >= CAR_RADIUS_PX, "%s: the car's body never leaves the dirt -- its centre comes no nearer the edge than %.1f px (at least the %.0f px of its own radius)" % [name, clearance, CAR_RADIUS_PX])


func _stuck_ticks() -> int:
	return roundi(_tuning.auto_reset_stuck_seconds / TICK)


func _report_lap(label: String, seed: int, index: int, driver: ReactiveDriver, record: Dictionary) -> void:
	print("%s seed=%d car=%d skill=%.3f completed=%s lap_s=%.2f ticks=%d off_road=%.2f%% max_from_centre=%.1f slowest_streak=%d recoveries=%d mistakes=%d planned=%d lapsed=%d %s" % [
		label, seed, index, driver.skill, record.completed, record.ticks * TICK, record.ticks, 100.0 * record.off_road_ticks / float(maxi(record.ticks, 1)),
		record.max_from_centre, record.longest_slow, driver.recoveries, driver.mistake_log().size(), driver.mistakes_planned, driver.mistakes_lapsed, _log_text(driver.mistake_log()),
	])


func _log_text(log: Array) -> String:
	var parts: Array[String] = []
	for entry in log:
		var until: String = str(entry.until) if entry.until >= 0 else "still"
		parts.append("#%d %s @%d-%s %.2fm %.2fs" % [entry.n, ReactiveDriver.mistake_name(entry.kind), entry.tick, until, entry.amount, entry.seconds])
	return "[" + ", ".join(parts) + "]"


## MainSession._grid_slot_transform, restated as tests/reactive_driver_test.gd restates it.
func _grid_slot(definition: TrackDefinition, slot: int) -> Transform2D:
	if slot <= 0:
		return definition.spawn_transform
	var row := (slot + 1) / 2
	var side := -1.0 if slot % 2 == 1 else 1.0
	var points := definition.centerline
	var unique := points.size() - 1
	var index := 0
	var remaining := row * WorldScale.metres(GRID_ROW_SPACING_M)
	var pose := Transform2D((points[1] - points[0]).angle(), points[0])
	while remaining > 0.0 and unique > 0:
		var previous := points[(index - 1 + unique) % unique]
		var segment := points[index].distance_to(previous)
		if segment >= remaining:
			pose = Transform2D((points[index] - previous).angle(), points[index].lerp(previous, remaining / maxf(segment, 0.000001)))
			break
		remaining -= segment
		index = (index - 1 + unique) % unique
	var lateral := pose.y * (side * definition.track_width * GRID_COLUMN_FRACTION)
	return Transform2D(pose.get_rotation() + PI * 0.5, pose.origin + lateral)


func _first_difference(left: PackedFloat64Array, right: PackedFloat64Array) -> int:
	for index in range(mini(left.size(), right.size())):
		if left[index] != right[index]:
			return index
	return -1 if left.size() == right.size() else mini(left.size(), right.size())


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)
	return condition


func _finish() -> void:
	print("Skill and mistakes: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)
