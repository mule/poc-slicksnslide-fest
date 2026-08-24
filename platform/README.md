# Platform boundary

Platform-specific behavior belongs in this directory behind small adapters. Track generation, vehicle physics, and session flow must not branch directly on Android, Linux, or controller model.

`ApplicationLifecycle` translates application pause/resume and focus changes
into platform-neutral session signals. The session responds by pausing physics,
neutralizing input, and requiring explicit resume confirmation; it does not
auto-resume into held throttle after an Android app switch.

Issue #6 owns Android export and hardware validation. Input normalization stays
in the shared `ControllerInput` adapter because Godot exposes standard joypad
actions on Android. Issue #7 owns Steam Deck/Linux export and Gaming Mode
validation. Both consume the shared contracts established by issue #2.
