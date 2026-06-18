class_name LLMKnowledgeBase
extends Node

@export_file("*.json") var knowledge_base_path: String = "res://Assets/ARSpace/Data/llm_knowledge_base.json"
@export_dir var knowledge_base_directory: String = "res://Assets/ARSpace/Data/Knowledge"
@export var additional_knowledge_directories: PackedStringArray = PackedStringArray()
@export_range(1, 12, 1) var max_results: int = 5
@export_range(400, 2400, 100) var text_chunk_max_chars: int = 1200

var _entries: Array[Dictionary] = []
var _runtime_entries: Array[Dictionary] = []
var _last_error := ""


func _ready() -> void:
	load_entries()


func load_entries() -> bool:
	_entries.clear()
	_last_error = ""

	if not knowledge_base_path.strip_edges().is_empty():
		_load_json_entries(knowledge_base_path, true)

	if not knowledge_base_directory.strip_edges().is_empty():
		_load_directory_entries(knowledge_base_directory)

	for directory_path in additional_knowledge_directories:
		var clean_path := str(directory_path).strip_edges()
		if not clean_path.is_empty() and clean_path != knowledge_base_directory:
			_load_directory_entries(clean_path)

	return not _entries.is_empty()


func set_runtime_entries(entries: Array) -> void:
	_runtime_entries.clear()
	for entry in entries:
		var normalized := _normalize_entry(entry)
		if not normalized.is_empty():
			_runtime_entries.append(normalized)


func add_runtime_entry(entry: Dictionary) -> void:
	var normalized := _normalize_entry(entry)
	if not normalized.is_empty():
		_runtime_entries.append(normalized)


func clear_runtime_entries() -> void:
	_runtime_entries.clear()


func get_last_error() -> String:
	return _last_error


func get_entry_count() -> int:
	return _entries.size() + _runtime_entries.size()


func get_source_summary() -> Dictionary:
	return {
		"static_entry_count": _entries.size(),
		"runtime_entry_count": _runtime_entries.size(),
		"static_sources": _count_sources(_entries),
		"runtime_sources": _count_sources(_runtime_entries),
	}


func get_entries_snapshot() -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = []
	for entry in _entries:
		snapshot.append(entry.duplicate(true))
	for entry in _runtime_entries:
		snapshot.append(entry.duplicate(true))
	return snapshot


func search(query: String, limit: int = -1) -> Array[Dictionary]:
	var normalized_query := query.strip_edges()
	if normalized_query.is_empty():
		return []

	var effective_limit := max_results if limit <= 0 else limit
	var query_terms := _extract_terms(normalized_query)
	var scored: Array[Dictionary] = []
	var all_entries := _get_all_entries()

	for index in range(all_entries.size()):
		var entry := all_entries[index]
		var score := _score_entry(entry, normalized_query, query_terms)
		if score <= 0.0:
			continue
		scored.append({
			"score": score,
			"entry": entry,
		})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var results: Array[Dictionary] = []
	for item in scored:
		if results.size() >= effective_limit:
			break
		results.append((item.get("entry", {}) as Dictionary).duplicate(true))

	if results.is_empty() and not all_entries.is_empty():
		results.append(all_entries[0].duplicate(true))

	return results


func build_context(query: String, limit: int = -1) -> String:
	var results := search(query, limit)
	var lines: Array[String] = []
	for index in range(results.size()):
		var item := results[index]
		lines.append("%d. [%s] %s\n%s" % [
			index + 1,
			str(item.get("source", "知识库")),
			str(item.get("title", "未命名条目")),
			str(item.get("content", "")),
		])
	return "\n\n".join(lines)


func _load_directory_entries(directory_path: String) -> void:
	var dir := DirAccess.open(directory_path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if dir.current_is_dir():
			if not file_name.begins_with("."):
				_load_directory_entries(directory_path.path_join(file_name))
		else:
			var path := directory_path.path_join(file_name)
			var extension := file_name.get_extension().to_lower()
			if extension == "json":
				_load_json_entries(path, false)
			elif extension == "txt" or extension == "md":
				_load_text_entries(path)
		file_name = dir.get_next()
	dir.list_dir_end()


func _load_json_entries(path: String, warn_when_missing: bool) -> void:
	if not FileAccess.file_exists(path):
		if warn_when_missing:
			_last_error = "知识库文件不存在：%s" % path
			push_warning(_last_error)
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_last_error = "无法读取知识库：%s" % path
		push_warning(_last_error)
		return

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_last_error = "知识库 JSON 格式错误：根节点需要是对象，文件：%s" % path
		push_warning(_last_error)
		return

	var items: Array = parsed.get("entries", [])
	for raw_item in items:
		var item := _normalize_entry(raw_item)
		if item.is_empty():
			continue
		if str(item.get("source", "")).is_empty():
			item["source"] = path.get_file()
		_entries.append(item)


func _load_text_entries(path: String) -> void:
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_last_error = "无法读取知识文本：%s" % path
		push_warning(_last_error)
		return

	var text := file.get_as_text().strip_edges()
	if text.is_empty():
		return

	var title := _derive_text_title(path, text)
	var chunks := _chunk_text_document(text)
	for index in range(chunks.size()):
		var content := chunks[index].strip_edges()
		if content.is_empty():
			continue
		_entries.append({
			"id": "%s#%d" % [path.get_file().get_basename(), index + 1],
			"title": title if chunks.size() == 1 else "%s / %d" % [title, index + 1],
			"source": "知识文档 / %s" % path.get_file(),
			"tags": _extract_document_tags(title + "\n" + content),
			"content": content,
		})


func _normalize_entry(raw_entry: Variant) -> Dictionary:
	if typeof(raw_entry) != TYPE_DICTIONARY:
		return {}

	var entry := raw_entry as Dictionary
	var content := str(entry.get("content", "")).strip_edges()
	if content.is_empty():
		return {}

	return {
		"id": str(entry.get("id", "")),
		"title": str(entry.get("title", "未命名条目")),
		"source": str(entry.get("source", "知识库")),
		"tags": _string_array_from_variant(entry.get("tags", [])),
		"content": content,
	}


func _derive_text_title(path: String, text: String) -> String:
	for raw_line in text.split("\n", false):
		var line := str(raw_line).strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			line = line.trim_prefix("#").strip_edges()
		return line.substr(0, 48)
	return path.get_file().get_basename()


func _chunk_text_document(text: String) -> Array[String]:
	var chunks: Array[String] = []
	var current := ""
	var paragraphs := text.replace("\r\n", "\n").replace("\r", "\n").split("\n\n", false)
	for raw_paragraph in paragraphs:
		var paragraph := str(raw_paragraph).strip_edges()
		if paragraph.is_empty():
			continue
		if current.length() > 0 and current.length() + paragraph.length() + 2 > text_chunk_max_chars:
			chunks.append(current)
			current = ""
		if current.length() > 0:
			current += "\n\n"
		current += paragraph

	if not current.strip_edges().is_empty():
		chunks.append(current.strip_edges())
	return chunks


func _extract_document_tags(text: String) -> Array[String]:
	var tags: Array[String] = []
	for keyword in _domain_keywords():
		if text.find(keyword) != -1 and not tags.has(keyword):
			tags.append(keyword)
	return tags


func _get_all_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in _runtime_entries:
		result.append(entry)
	for entry in _entries:
		result.append(entry)
	return result


func _score_entry(entry: Dictionary, query: String, query_terms: Array[String]) -> float:
	var haystack := ("%s %s %s %s" % [
		entry.get("title", ""),
		entry.get("source", ""),
		_join_strings(entry.get("tags", [])),
		entry.get("content", ""),
	]).to_lower()
	var normalized_query := query.to_lower()
	var score := 0.0

	if haystack.find(normalized_query) != -1:
		score += 4.0

	for term in query_terms:
		if term.is_empty():
			continue
		if haystack.find(term) != -1:
			score += 2.0 if str(entry.get("title", "")).to_lower().find(term) != -1 else 1.0

	for keyword in _domain_keywords():
		if query.find(keyword) != -1 and haystack.find(keyword) != -1:
			score += 2.0

	if str(entry.get("source", "")).find("当前") != -1:
		score += 0.75

	return score


func _extract_terms(text: String) -> Array[String]:
	var normalized := text.to_lower()
	var separators := ["，", "。", "？", "！", "、", ",", ".", "?", "!", ":", "：", ";", "；", " ", "\n", "\t", "（", "）", "(", ")"]
	for separator in separators:
		normalized = normalized.replace(separator, " ")

	var terms: Array[String] = []
	for raw in normalized.split(" ", false):
		var term := str(raw).strip_edges()
		if term.length() >= 2 and not terms.has(term):
			terms.append(term)

	for keyword in _domain_keywords():
		if text.find(keyword) != -1 and not terms.has(keyword):
			terms.append(keyword)

	return terms


func _domain_keywords() -> Array[String]:
	return [
		"氧气", "分压", "舱门", "密封", "告警", "复核", "上报", "阀门", "传感器", "环境", "设备", "手册",
		"步骤", "任务", "专家", "航天员", "样品盒", "无容器", "工具", "手环", "连接器", "螺钉", "力矩", "断电",
		"口令", "确认", "复述", "风险", "安全",
	]


func _string_array_from_variant(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value:
		result.append(str(item))
	return result


func _join_strings(value: Variant) -> String:
	if typeof(value) != TYPE_ARRAY:
		return ""

	var parts: Array[String] = []
	for item in value:
		parts.append(str(item))
	return " ".join(parts)


func _count_sources(entries: Array[Dictionary]) -> Dictionary:
	var counts := {}
	for entry in entries:
		var source := str(entry.get("source", "知识库")).strip_edges()
		if source.is_empty():
			source = "知识库"
		counts[source] = int(counts.get(source, 0)) + 1
	return counts
