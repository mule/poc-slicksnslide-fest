# Platform boundary

Platform-specific behavior belongs in this directory behind small adapters. Track generation, vehicle physics, and session flow must not branch directly on Android, Linux, or controller model.

Issue #6 owns Android-specific export/input normalization. Issue #7 owns Steam Deck/Linux-specific export and focus behavior. Both consume the shared contracts established by issue #2.
