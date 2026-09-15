class_name IdleDriver
extends AiDriver

## Concrete neutral producer for field integration and fixtures before reactive driving lands.
##
## It deliberately overrides nothing. The issue specifies that AiDriver itself "exists and returns
## neutral controls", so an IdleDriver.drive() returning zeros was a byte-identical copy of the
## inherited one and no assertion could see it — deleting the whole body left the suite green.
## What earns this class its place is being a NAME the field and later fixtures can ask for, which
## tests/ai_driver_contract_test.gd checks through the seam assertion and the neutral-control loop.
## The neutral body stays in AiDriver: real judgement arrived as ReactiveDriver (#58), a subclass of
## AiDriver beside this one, and ai_driver_contract_test pins AiDriver's own neutral controls.
