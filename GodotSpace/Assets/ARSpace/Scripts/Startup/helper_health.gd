extends RefCounted

## Judge the actual streams, not merely the lifetime of the ADB watchdog.
## Explicit clock input keeps cold-start, permissions and stalls testable.
const XR_SETTLE_MSEC := 2000
const FRAME_TIMEOUT_MSEC := 20000
const INSTALL_TIMEOUT_MSEC := 240000
const MAX_RETRIES := 3
const HEALTHY_RESET_MSEC := 10000

var launched := false
var retries := 0
var _xr_ready_since := -1
var _missing_since := -1
var _healthy_since := -1
var _launched_at := 0


func reset() -> void:
	launched = false
	retries = 0
	_xr_ready_since = -1
	_missing_since = -1
	_healthy_since = -1
	_launched_at = 0


func mark_launched(now: int, is_retry: bool) -> void:
	launched = true
	_launched_at = now
	_missing_since = now
	_healthy_since = -1
	if is_retry:
		retries += 1


func evaluate(now: int, xr_ready: bool, listener_ready: bool, capture_enabled: bool,
		cast_enabled: bool, recent_frame: bool, cast_ready: bool, helper_state: String) -> Dictionary:
	if not capture_enabled and not cast_enabled:
		return _result("disabled", "")
	if not xr_ready:
		_xr_ready_since = -1
		_missing_since = -1
		_healthy_since = -1
		return _result("waiting_xr", "等待 XR 就绪后启动采集与投屏")
	if _xr_ready_since < 0:
		_xr_ready_since = now
	if capture_enabled and not listener_ready:
		_missing_since = -1
		_healthy_since = -1
		return _result("waiting_receiver", "相机接收端尚未就绪，请检查 8789 端口")
	if now - _xr_ready_since < XR_SETTLE_MSEC:
		return _result("settling", "XR 已就绪，正在准备采集与投屏")
	if not launched:
		return _result("start", "正在自动启动采集与投屏")
	if helper_state in ["permission", "failed"]:
		_missing_since = -1
		_healthy_since = -1
		return _result("blocked", "请处理下方的权限或配置提示，再点击重试")
	if (not capture_enabled or recent_frame) and (not cast_enabled or cast_ready) \
			and helper_state not in ["worker_missing", "worker_exited", "waiting_device"]:
		_missing_since = -1
		if _healthy_since < 0:
			_healthy_since = now
		if now - _healthy_since >= HEALTHY_RESET_MSEC:
			retries = 0
		return _result("ready", "")
	_healthy_since = -1
	if helper_state == "launching" and now - _launched_at < INSTALL_TIMEOUT_MSEC:
		_missing_since = -1
		return _result("launching", "正在准备头显 helper，请稍候")
	if _missing_since < 0:
		_missing_since = now
	var timeout := FRAME_TIMEOUT_MSEC * (1 << mini(retries, MAX_RETRIES - 1))
	var remaining := timeout - (now - _missing_since)
	if remaining > 0:
		if retries >= MAX_RETRIES:
			return _result("waiting_stream", "已自动重试 %d 次，正在等待画面（%d 秒）" % [retries, ceili(remaining / 1000.0)])
		return _result("waiting_stream", "等待画面，%d 秒后自动重试（%d/%d）" % [
			ceili(remaining / 1000.0), retries + 1, MAX_RETRIES])
	if retries >= MAX_RETRIES:
		return _result("exhausted", "自动恢复未成功，请检查 USB 连接与头显权限后点击重试")
	return _result("retry", "正在自动恢复采集 / 投屏（%d/%d）" % [retries + 1, MAX_RETRIES])


func _result(state: String, detail: String) -> Dictionary:
	return {"state": state, "message": detail}
