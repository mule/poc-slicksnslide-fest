extends SceneTree

## Pins the engine behaviour every other test script in this suite now relies on.
##
## A GDScript runtime error does not stop the script. It aborts only the function the error occurs
## in, returns control to that function's caller, and execution carries on. `_finish()` is still
## reached, `_failures` is still empty, and the script exits 0 while printing "checks passed" --
## with every assertion after the error silently skipped. A broken test was indistinguishable from
## a passing one, which is what issue #32 was filed for.
##
## GDScript exposes no way to ask whether an error occurred: there is no error count on Engine, and
## `print_error_messages` only silences errors rather than counting them. What is detectable is the
## return value. A function typed `-> bool` that is aborted returns false to its caller instead of
## the true it would have returned on reaching its final line.
##
## So every verification function in this suite is typed `-> bool`, ends in `return true`, and is
## called through `_check(...)`. This file exists so that if a future Godot version changes how an
## aborted function returns -- making the whole suite quietly blind again -- something fails loudly
## and says so, rather than every test going green for the wrong reason.
##
## This script prints one SCRIPT ERROR on purpose. That error IS the thing under test.

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("NOTE: this script deliberately triggers one runtime error; it is the behaviour under test.")
	_check(_verify_completion_is_observable(), "the completion-contract verification ran to completion")
	_finish()


func _verify_completion_is_observable() -> bool:
	_check(_function_that_completes(), "a function that reaches its final line returns true")
	_check(not _function_that_aborts(), "a function aborted by a runtime error returns false")

	var reached_caller := true
	_check(reached_caller, "the caller keeps running after a callee aborts, which is why exit codes lied")
	return true


## Returns true from its last line, the way every verification function in this suite does.
func _function_that_completes() -> bool:
	return true


## Aborts before its `return true` is reached. The caller receives false.
func _function_that_aborts() -> bool:
	var nothing = null
	var unreachable = nothing.property_that_does_not_exist
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Harness contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Harness contract check failed: %s" % failure)
	quit(1)
