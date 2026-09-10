class_name AiDriver
extends RefCounted

## Hardware- and scene-independent control producer. Identity is fixed at construction;
## later drivers receive senses as data, never a reference to the car or session.

var car_index: int:
	get:
		return _car_index
var driver_seed: int:
	get:
		return _driver_seed

var _car_index: int
var _driver_seed: int


func _init(track_seed: int = 0, index: int = 0, version: int = 1) -> void:
	_car_index = index
	var domain_seed := DomainSeed.derive(version, track_seed, "ai_driver")
	_driver_seed = DomainSeed.child(domain_seed, car_index, 0)


func drive(_delta: float) -> VehicleInputState:
	return VehicleInputState.new()
