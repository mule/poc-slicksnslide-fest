class_name ApplicationLifecycle
extends Node

signal suspension_requested(reason: String)
signal resume_observed


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			suspension_requested.emit("application paused")
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			suspension_requested.emit("application focus lost")
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			resume_observed.emit()
