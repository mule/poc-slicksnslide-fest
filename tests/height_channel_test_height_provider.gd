class_name HeightChannelTestHeightProvider
extends HeightQuery

## Scripted ground for vehicle tests. HUMP is one symmetric ramp along +X centred at crest_x that
## spans every Y. PLATEAU is flat ground at plateau_height for x < plateau_end_x and zero beyond,
## so a car can be held at a height or driven off an edge without a generated track.

enum Mode { HUMP, PLATEAU }

var mode := Mode.HUMP
var crest_x := 0.0
var half_length := 150.0
var crest_height := 18.0
var plateau_height := 0.0
var plateau_end_x := INF
var sample_count := 0


func sample_at(world_position: Vector2) -> HeightSample:
	sample_count += 1
	if mode == Mode.PLATEAU:
		if world_position.x < plateau_end_x:
			return HeightSample.new(plateau_height, Vector2.ZERO)
		return HeightSample.new()
	var along := world_position.x - crest_x
	if absf(along) > half_length:
		return HeightSample.new()
	var slope := crest_height / half_length
	return HeightSample.new(crest_height * (1.0 - absf(along) / half_length), Vector2(-signf(along) * slope, 0.0))
