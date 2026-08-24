class_name DiagnosticsOverlay
extends CanvasLayer

var _release_mode := false
var _seed := 0
var _speed_kph := 0.0
var _surface := "unknown"
var _slip := 0.0
var _steering := 0.0
var _throttle := 0.0
var _brake := 0.0
var _handbrake := 0.0
var _memory_peak_bytes := 0.0

@onready var _metrics_label: Label = %MetricsLabel


func _ready() -> void:
	set_release_mode(OS.has_feature("release"))
	_refresh_text()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_text(delta)


func _unhandled_input(event: InputEvent) -> void:
	if _release_mode:
		return
	if event.is_action_pressed("toggle_diagnostics") and not (event is InputEventKey and event.echo):
		toggle_visibility()
		get_viewport().set_input_as_handled()


func set_release_mode(is_release: bool) -> void:
	_release_mode = is_release
	if _release_mode:
		visible = false


func toggle_visibility() -> void:
	if not _release_mode:
		visible = not visible


func set_metrics(
	seed: int,
	speed_kph: float,
	surface: String,
	slip: float,
	steering: float,
	throttle: float,
	brake: float,
	handbrake: float,
) -> void:
	_seed = seed
	_speed_kph = speed_kph
	_surface = surface
	_slip = slip
	_steering = steering
	_throttle = throttle
	_brake = brake
	_handbrake = handbrake
	_refresh_text()


func _refresh_text(delta: float = 0.0) -> void:
	if not is_instance_valid(_metrics_label):
		return
	var frame_time_ms := delta * 1000.0 if delta > 0.0 else 0.0
	var memory_bytes := float(Performance.get_monitor(Performance.MEMORY_STATIC))
	_memory_peak_bytes = maxf(_memory_peak_bytes, memory_bytes)
	var memory_mib := memory_bytes / (1024.0 * 1024.0)
	var memory_peak_mib := _memory_peak_bytes / (1024.0 * 1024.0)
	_metrics_label.text = (
		"DEV  Back/View or F3 diagnostics\n"
		+ "FPS: %d   frame: %.2f ms\n" % [Engine.get_frames_per_second(), frame_time_ms]
		+ "memory: %.1f MiB   peak: %.1f MiB\n" % [memory_mib, memory_peak_mib]
		+ "seed: %d   speed: %.1f km/h\n" % [_seed, _speed_kph]
		+ "surface: %s   slip: %.2f\n" % [_surface, _slip]
		+ "steer: %.2f   throttle: %.2f\n" % [_steering, _throttle]
		+ "brake: %.2f   handbrake: %.2f" % [_brake, _handbrake]
	)
