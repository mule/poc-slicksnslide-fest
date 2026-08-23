class_name MainSession
extends Node

@export var session_settings: Resource
@export var vehicle_tuning: Resource

@onready var _diagnostics_overlay: CanvasLayer = %DiagnosticsOverlay


func _ready() -> void:
	if session_settings == null:
		push_error("MainSession requires a SessionSettings resource")
		return
	_diagnostics_overlay.visible = bool(session_settings.get("diagnostics_visible_in_debug"))
	_diagnostics_overlay.call("set_release_mode", OS.has_feature("release"))
	_diagnostics_overlay.call("set_metrics", int(session_settings.get("seed")), 0.0, "placeholder", 0.0)


func install_track(track_scene: Node2D) -> void:
	_install_scene(%TrackMount, track_scene)


func install_vehicle(vehicle_scene: Node2D) -> void:
	_install_scene(%VehicleMount, vehicle_scene)


func _install_scene(mount: Node2D, scene_root: Node2D) -> void:
	for child in mount.get_children():
		child.free()
	mount.add_child(scene_root)
