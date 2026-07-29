extends SceneTree

const PipelineScript := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/reconstruction_pipeline_controller.gd"
)


func _init() -> void:
	var pipeline: Node = PipelineScript.new()
	var controller_manifest := {
		"schema_version": 2,
		"coordinate_contract": "lingbot_world_to_reconstruction_root_parent",
		"solved": true,
		"automatic": {
			"scale": 2.0,
			"rotation_quaternion": [0.0, 0.0, 0.0, 1.0],
			"translation": [1.0, 2.0, 3.0],
		},
		"manual": {
			"translation": [0.1, 0.2, 0.3],
			"yaw_degrees": 10.0,
			"pitch_degrees": 2.0,
			"roll_degrees": -3.0,
			"scale": 1.05,
			"pivot": [4.0, 0.0, 2.0],
		},
		"quality": {
			"position_rms_cm": 4.0,
			"rotation_rms_deg": 2.0,
		},
	}
	var gsmap_registration: Dictionary = pipeline._registration_for_gsmap(
		controller_manifest,
		true,
	)
	_expect(bool(gsmap_registration.get("confirmed", false)), "confirmed flag must persist")
	_expect(
		(gsmap_registration.get("automatic_sim3", {}) as Dictionary).has(
			"rotation_wxyz"
		),
		"automatic Sim(3) must use the GSM1 quaternion convention",
	)
	_expect(
		(gsmap_registration.get("controller_manifest", {}) as Dictionary) \
			== controller_manifest,
		"full controller registration must be preserved for exact import",
	)

	var legacy_controller: Dictionary = pipeline._controller_manifest_from_gsmap(
		gsmap_registration,
	)
	_expect(bool(legacy_controller.get("solved", false)), "GSM1 registration must import")
	_expect(
		is_equal_approx(
			float((legacy_controller["automatic"] as Dictionary).get("scale", 0.0)),
			2.0,
		),
		"automatic scale must survive GSM1 conversion",
	)
	_expect(
		is_equal_approx(
			float((legacy_controller["manual"] as Dictionary).get(
				"roll_degrees",
				0.0,
			)),
			-3.0,
		),
		"legacy GSM1 roll must preserve the Vector3.FORWARD sign convention",
	)

	var valid_snapshot := {
		"schema_version": 2,
		"point_data_auth_token": "0123456789abcdef0123456789abcdef",
		"services": {},
		"registration": {},
		"stats": {},
		"map_library": [],
	}
	_expect(
		pipeline._validate_pipeline_snapshot(valid_snapshot),
		"bounded status snapshot must validate",
	)
	valid_snapshot["schema_version"] = 99
	_expect(
		not pipeline._validate_pipeline_snapshot(valid_snapshot),
		"unknown status snapshot schema must be rejected",
	)
	valid_snapshot["schema_version"] = 2
	valid_snapshot["point_data_auth_token"] = "short"
	_expect(
		not pipeline._validate_pipeline_snapshot(valid_snapshot),
		"status snapshot must reject a short point-data authorization token",
	)

	_expect(
		pipeline._accept_lab_chunk_sequence("session-a", "1").is_empty(),
		"first LingBot chunk must begin at sequence 1",
	)
	_expect(
		pipeline._accept_lab_chunk_sequence("session-a", "2").is_empty(),
		"contiguous LingBot chunks must be accepted",
	)
	_expect(
		pipeline._accept_lab_chunk_sequence("session-a", "4").contains("缺失"),
		"missing LingBot chunks must be detected",
	)
	pipeline._stale_lab_session_id = "session-a"
	pipeline._awaiting_fresh_lab_session = true
	_expect(
		pipeline._accept_lab_chunk_sequence("session-a", "3") == "stale",
		"old-session output must be ignored while a fresh session starts",
	)
	_expect(
		pipeline._accept_lab_chunk_sequence("session-b", "1").is_empty(),
		"a fresh LingBot generation must start at sequence 1",
	)
	_expect(
		pipeline._auto_save_display_name(
			"2026-07-28T12-34-56",
			"最终",
		) == "2026-07-28T12-34-56_最终_自动保存",
		"automatic-save labels must be filename suffixes",
	)

	pipeline.free()
	print("RECONSTRUCTION_PIPELINE_SELF_TEST PASS")
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("RECONSTRUCTION_PIPELINE_SELF_TEST FAIL: %s" % message)
	quit(1)
