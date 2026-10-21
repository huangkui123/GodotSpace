extends SceneTree

const Health := preload("res://Assets/ARSpace/Scripts/Startup/helper_health.gd")
var failures: Array[String] = []


func _initialize() -> void:
	var health := Health.new()
	_check(health.evaluate(0, false, true, true, true, false, false, "").state == "waiting_xr", "Do not launch before XR")
	_check(health.evaluate(100, true, false, true, true, false, false, "").state == "waiting_receiver", "Wait for receiver to bind")
	_check(_state(health, 101) == "settling", "Allow XR to settle")
	_check(_state(health, 2100) == "start", "Launch automatically after XR and receiver are ready")
	health.mark_launched(2100, false)
	_check(_state(health, 22099) == "waiting_stream", "Command accepted is not proof of receiving frames")
	_check(_state(health, 22100) == "retry", "Missing first frame must recover automatically")
	health.mark_launched(22100, true)
	_check(_state(health, 62099) == "waiting_stream", "Back off the second retry")
	_check(_state(health, 62100) == "retry", "Second retry after 40 seconds")
	health.mark_launched(62100, true)
	_check(_state(health, 142100) == "retry", "Third retry after 80 seconds")
	health.mark_launched(142100, true)
	_check(_state(health, 142101) == "waiting_stream", "Allow final retry to produce frames")
	_check(_state(health, 222100) == "exhausted", "Bound automatic recovery attempts")
	_check(health.evaluate(222101, true, true, true, true, true, true, "started").state == "ready", "Late first frame recovers from exhaustion")
	health.evaluate(232101, true, true, true, true, true, true, "started")
	_check(health.retries == 0, "Sustained healthy stream restores retry budget")
	_check(_state(health, 240000) == "waiting_stream", "A stale last frame is not healthy")
	_check(_state(health, 260000) == "retry", "Recover a stream that stopped after startup")
	health.mark_launched(260000, true)
	_check(_state(health, 280000, "permission") == "blocked", "Never reopen the permission activity on a timer")
	_check(_state(health, 900000, "permission") == "blocked", "Permission wait is unbounded")
	_check(_state(health, 900001) == "waiting_stream", "Start a fresh timeout after permission granted")
	_check(_state(health, 940001) == "retry", "Recover if permission granted but no stream")
	_check(_state(health, 950000, "failed") == "blocked", "Configuration errors require correction")
	health.reset()
	_state(health, 0)
	_check(_state(health, 2000) == "start", "Manual retry resets an exhausted session")
	health.mark_launched(2000, false)
	var deadline := 2000 + Health.INSTALL_TIMEOUT_MSEC
	_check(_state(health, deadline - 1, "launching") == "launching", "Allow APK installation and USB component download to complete")
	_check(_state(health, deadline, "launching") == "waiting_stream", "Installation grace is finite")
	_check(_state(health, deadline + 20000, "launching") == "retry", "Hung wrapper must not suppress recovery forever")
	_check(health.evaluate(deadline + 30000, true, true, true, false, true, false, "started").state == "ready", "Capture-only does not require casting")
	_check(health.evaluate(deadline + 30000, true, false, false, true, false, true, "started").state == "ready", "Cast-only does not require local camera receiver")
	_check(health.evaluate(deadline + 30001, true, true, true, true, true, true, "worker_missing").state == "waiting_stream", "A dead USB encoder is not healthy even while its old URL remains cached")
	_check(health.evaluate(deadline + 30002, false, false, false, false, false, false, "").state == "disabled", "Disabled features never launch")
	for failure in failures:
		push_error(failure)
	print("Helper health self-test: %s" % ("passed" if failures.is_empty() else "FAILED"))
	quit(0 if failures.is_empty() else 1)


func _state(health: RefCounted, now: int, helper_state: String = "started") -> String:
	return str(health.evaluate(now, true, true, true, true, false, true, helper_state).state)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
