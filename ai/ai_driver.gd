class_name AiDriver
extends RefCounted

## Hardware- and scene-independent control producer. Identity is fixed at construction;
## later drivers receive senses as data, never a reference to the car or session.
##
## One tick, from whoever owns the field:
##
##     driver.perceive(sensing_pass.sense(field, index, driver.sensing_horizon()))
##     car.set_input_state(driver.drive(delta))
##
## `perceive` is how senses arrive, and it is the only door: a driver keeps what it needs out of
## them as plain values and never the DriverSenses itself (tests/ai_driver_contract_test.gd walks
## every declared field and refuses anything that is an object).

## The horizon a driver senses at when it has no opinion of its own. Fifty metres is 625 px, a
## little over a braking distance from the car's top speed to a cornering speed.
const DEFAULT_SENSING_HORIZON_M := 50.0

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


## This tick's senses. The neutral driver has no use for them.
func perceive(_senses: DriverSenses) -> void:
	pass


## How far ahead, in pixels, the next DriverSenses should be built to see. Asked of the driver
## rather than fixed by the field because look-ahead is the one dial that most changes what a
## driver can do, and a driver may want to widen it -- a car that has lost the road looks further.
func sensing_horizon() -> float:
	return WorldScale.metres(DEFAULT_SENSING_HORIZON_M)


func drive(_delta: float) -> VehicleInputState:
	return VehicleInputState.new()
