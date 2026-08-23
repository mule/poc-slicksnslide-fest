class_name DiagnosticsOverlay
extends CanvasLayer

var _release_mode := false
var _seed := 0
var _speed_kph := 0.0
var _surface := "unknown"
var _slip := 0.0

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
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		toggle_visibility()
		get_viewport().set_input_as_handled()


func set_release_mode(is_release: bool) -> void:
	_release_mode = is_release
	if _release_mode:
		visible = false


func toggle_visibility() -> void:
	if not _release_mode:
		visible = not visible


func set_metrics(seed: int, speed_kph: float, surface: String, slip: float) -> void:
	_seed = seed
	_speed_kph = speed_kph
	_surface = surface
	_slip = slip
	_refresh_text()


func _refresh_text(delta: float = 0.0) -> void:
	if not is_instance_valid(_metrics_label):
		return
	var frame_time_ms := delta * 1000.0 if delta > 0.0 else 0.0
	_metrics_label.text = (
		"DEV  F3 diagnostics\n"
		+ "FPS: %d   frame: %.2f ms\n" % [Engine.get_frames_per_second(), frame_time_ms]
		+ "seed: %d   speed: %.1f km/h\n" % [_seed, _speed_kph]
		+ "surface: %s   slip: %.2f" % [_surface, _slip]
	)
