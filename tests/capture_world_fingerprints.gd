extends SceneTree

## Evidence for epic #55's "no track, object or terrain fingerprint moved": the four world fingerprints
## of seeds 0-99, and digests of the raw generated data behind them, one line a seed.
##
## `docs/evidence/ai-opponents/world-fingerprints-seeds-0-99.txt` is this script's output on the branch.
## The claim is made by comparing that file with the same dump from a tree before the epic (447cadb),
## not by anything this script asserts: it prints, it does not judge. Headless; no display needed.
##
##   godot --headless --path . --script res://tests/capture_world_fingerprints.gd -- --out=<file>
##   diff <file> docs/evidence/ai-opponents/world-fingerprints-seeds-0-99.txt
##
## Without --out it prints the lines instead. Never write the output over the committed file to make
## the two agree: a fingerprint that moved is a blocker, not a re-baseline.
##
## First written as a scratch script in task #61b; committed unchanged but for the --out switch in the
## PR #62 fix round, so the committed file has a producer in the repo.

const SEED_COUNT := 100


func _initialize() -> void:
	var out := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			out = argument.trim_prefix("--out=")
	var generator := TrackGenerator.new()
	var lines := PackedStringArray()
	for seed in range(SEED_COUNT):
		var d: TrackDefinition = generator.generate(seed)
		var centre := var_to_str(d.centerline).sha256_text().substr(0, 16)
		var poses := var_to_str([d.spawn_transform, d.checkpoints, d.left_boundary, d.right_boundary, d.play_area, d.track_width]).sha256_text().substr(0, 16)
		var objects: Array = []
		for o in d.offtrack_objects:
			objects.append([o.stable_id, o.archetype_id, o.transform, o.solid, o.collision_profile])
		var ramps: Array = []
		for r in d.jump_ramps:
			ramps.append([r.stable_id, r.transform])
		lines.append("seed=%d geometry=%s offtrack_object=%s height=%s terrain=%s terrain_seed=%d centerline=%s poses=%s objects=%d:%s ramps=%d:%s" % [
			seed, d.geometry_fingerprint, d.offtrack_object_fingerprint, d.height_fingerprint, d.terrain_fingerprint, d.terrain_seed,
			centre, poses, objects.size(), var_to_str(objects).sha256_text().substr(0, 16), ramps.size(), var_to_str(ramps).sha256_text().substr(0, 16)])
	if out.is_empty():
		for line in lines:
			print(line)
		quit(0)
		return
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file == null:
		push_error("capture_world_fingerprints: cannot write %s" % out)
		quit(1)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("capture_world_fingerprints: %d seeds written to %s" % [lines.size(), out])
	quit(0)
