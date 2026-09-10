class_name IdleDriver
extends AiDriver

## Concrete neutral producer for field integration and fixtures before reactive driving lands.


func drive(_delta: float) -> VehicleInputState:
	return VehicleInputState.new()
