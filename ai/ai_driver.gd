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

## The second key of `DomainSeed.child(domain_seed, car_index, key)`, which the persistence contract
## in docs/ai-opponents.md reserved for fanning one car's identity out into per-subsystem streams.
## Key 0 is the identity itself, `driver_seed`; the others are siblings of it, so adding a stream
## never moves a car's identity. The numbers are part of the contract and must never be reassigned.
const IDENTITY_STREAM := 0
const SKILL_STREAM := 1
const MISTAKE_STREAM := 2

var car_index: int:
	get:
		return _car_index
var driver_seed: int:
	get:
		return _driver_seed

var _car_index: int
var _driver_seed: int
var _domain_seed: int


func _init(track_seed: int = 0, index: int = 0, version: int = 1) -> void:
	_car_index = index
	_domain_seed = DomainSeed.derive(version, track_seed, "ai_driver")
	_driver_seed = _stream_seed(car_index, IDENTITY_STREAM)
	_identity_fixed()


## Called once, at the end of construction, when the identity and its streams can be read. A driver
## derives what it needs from them here rather than declaring an `_init` of its own: the seam's
## structural check (tests/ai_driver_contract_test.gd) counts every `_init` in the chain.
func _identity_fixed() -> void:
	pass


## One per-car stream's seed. `index` is a parameter rather than read from `car_index` so that a
## derivation which drops the car's index -- `--break-mistake-seed` -- is one visible argument.
func _stream_seed(index: int, stream: int) -> int:
	return DomainSeed.child(_domain_seed, index, stream)


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
