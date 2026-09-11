class_name DriverSenses
extends RefCounted

## Everything one car knows about the world for one tick, and nothing else.
##
## This is the whole of a driver's input. A driver holds no reference to its car, its rivals or the
## track (tests/ai_driver_contract_test.gd::_verify_seam_isolation enforces that structurally), so a
## value that is not here is a value no driver can read.
##
## ## Frames
##
## **No field is a world coordinate.** Two cars in the same road-relative pose at opposite ends of
## the circuit, facing different compass directions, read identical senses -- that is what makes an
## opponent reactive rather than a car following a memorised map, and it is asserted in
## tests/driver_senses_test.gd::_verify_senses_are_in_the_car_frame, which the `--break-sense-frame`
## mutation exists to fail.
##
## Two kinds of relative live here, and they are invariant for different reasons:
##
## - **Road-relative scalars** -- `lateral_offset`, `heading_error`, the two edge distances -- are
##   measured against the road, so no world axis enters them. Their sign comes from the road's own
##   direction of travel (the centerline's index order), not from where the car's nose happens to
##   point: positive is the road's right. A car that spins does not flip the track's meaning of
##   right, and `heading_error` near +/-PI is how a driver learns it is facing the wrong way.
## - **Car-basis vectors** -- `gradient_ahead`, `rival_offset`, `rival_relative_velocity`,
##   `obstacle_offset`, `local_velocity` -- are rotated out of the world by the car's own basis,
##   in exactly the convention TopDownCar.get_local_velocity() already uses: **+x is the car's
##   right, and forward is -y.**
##
## `height_change_ahead` is a third case: a difference, not a level. An absolute ground height is a
## world-frame value wearing a scalar's clothes -- it says where on the map the car is -- so what a
## driver gets is how much the ground ahead rises or falls from the ground under it.
##
## ## Reading the fields
##
## The three `*_found` / `has_*` booleans gate the fields around them. When one is false, its
## fields are zero and mean nothing; a driver that ignores the flag and reads the zeros will act as
## if it were on the centerline with a clear road ahead. Nothing in this class enforces that -- the
## flags are the contract.

## False when the road query found no centerline segment near this position at all: far off-track,
## or on a fixture with no road. `lateral_offset`, `heading_error` and both edge distances are then
## zero and carry no information. The car's own automatic reset owns this state; a driver's job is
## to not steer confidently through it.
##
## "Near" is the search REGION, which is a little larger than the search radius. `SegmentGrid` is a
## broadphase over square cells and answers with every segment in the bounding box of cells the
## radius touches, and neither road query clamps the result afterwards, so a segment up to roughly
## one cell -- one track width -- beyond the radius still sets this true. The `lateral_offset` that
## comes back with it is accurate; it is simply further away than the horizon that asked. Treating
## the flag as an exact range test would be reading it more tightly than the grid can deliver, and
## `SurfaceQuery.distance_to_centerline` states the same looseness ("an implementation MAY return
## INF beyond search_radius"). A driver that needs an exact horizon should compare a distance itself.
var road_found: bool = false
## Signed distance from the centerline in pixels. Positive: the car is to the road's right.
var lateral_offset: float = 0.0
## Signed angle in radians from the road's direction to the car's nose. Positive: the nose is
## turned to the road's right. Near +/-PI means the car faces back down the track.
var heading_error: float = 0.0
## Pixels from the car to each road edge, along the road's normal. Signed: a car that has left the
## road reads a negative distance to the edge it crossed, which is how far outside it now is.
var distance_to_left_edge: float = 0.0
var distance_to_right_edge: float = 0.0

## The road where the car's nose points, `look_ahead` pixels out -- the same point the ground-ahead
## probe and the obstacle ray end at. Everything above describes the road UNDER the car, which is
## enough to follow it and not enough to drive it: a car braking at the tyres' limit needs most of
## a look-ahead to shed top speed for a tight corner, and nothing under the car says a corner is
## coming until it has arrived. These three are what a driver sees when it looks down the road.
##
## Road-relative, like the four above, and read the same way: measured from the NEAREST centerline
## segment to that point, whichever part of the lap it belongs to. On a winding circuit that can be a
## different stretch of road from the one the car is on, and nothing here claims otherwise.
##
## False when no centerline lies within the search region of that point; the two fields below are
## then zero.
var road_ahead_found: bool = false
## Signed distance of the look-ahead point from the centerline, in pixels. Positive: the point lies to
## the road's right. A car pointing straight down a straight road reads its own `lateral_offset`
## here; the difference is how far the road bends, or the car is turned, across the horizon.
var road_ahead_lateral_offset: float = 0.0
## Signed angle in radians from the road's direction at the look-ahead point to the car's nose,
## exactly as `heading_error` is at the car. `heading_error - road_ahead_heading_error` is how far the
## road turns between the two -- the car's own heading cancels out of it.
var road_ahead_heading_error: float = 0.0

## The surface directly under the car, from the same query the car's own physics samples.
var surface_type: SurfaceQuery.SurfaceType = SurfaceQuery.SurfaceType.UNKNOWN
var surface_grip: float = 1.0
var surface_drag: float = 1.0

## Pixels the ground rises over the look-ahead distance, measured from the ground under the car.
## Negative means the ground ahead falls away, which is a driver's warning that it is about to
## launch off a crest.
var height_change_ahead: float = 0.0
## The ground's slope at the look-ahead point, in the car's basis. dh/d(right) in x, dh/d(-forward)
## in y -- so `-gradient_ahead.y` is the climb straight ahead.
var gradient_ahead: Vector2 = Vector2.ZERO

## The nearest rival in front of this car and within the look-ahead distance, taken from the
## field's own list. False when the field holds no such car; the three fields below are then zero.
var has_rival_ahead: bool = false
## Where that rival is, in the car's basis. Distance is carried separately because it is the value
## a following rule actually reads, and recomputing a length from the offset every tick is waste.
var rival_offset: Vector2 = Vector2.ZERO
var rival_distance: float = 0.0
## That rival's velocity minus this car's, in the car's basis. POSITIVE y is closing: the rival sits
## at negative y, and the gap shrinks as the rival moves back toward this car. (Until #58 this line
## said "negative y is closing", which is backwards; the value itself never changed.)
var rival_relative_velocity: Vector2 = Vector2.ZERO

## The nearest solid thing a single ray found straight ahead, within the look-ahead distance:
## a tree, a rock, or the play area's boundary. Never a rival -- every car in the field is excluded
## from the ray, because rivals are a list and a list needs no raycast.
var has_obstacle_ahead: bool = false
var obstacle_offset: Vector2 = Vector2.ZERO
var obstacle_distance: float = 0.0

## This car's own velocity in its own basis, the same value and convention as
## TopDownCar.get_local_velocity(): `-local_velocity.y` is speed along the nose. Without it the
## relative velocities above have nothing to be relative to, and a driver with no car handle has no
## other way to know how fast it is going.
var local_velocity: Vector2 = Vector2.ZERO

## How far ahead this pass looked, in pixels. Carried because it is the one dial that changes what
## a driver can see (task #59 varies it by skill), so a driver reading a sense must be able to read
## the horizon that produced it.
var look_ahead: float = 0.0
