extends RefCounted

## Only the managed USB bridge may introduce HTTP media endpoints. Keep file,
## arbitrary HTTP resources and URL options out of the decoder's input surface.
static func is_valid(url: String, metadata: Dictionary) -> bool:
	if url.length() > 2048:
		return false
	if url.begins_with("rtmp://") or url.begins_with("rtmps://"):
		return true
	if str(metadata.get("transport", "")) != "usb":
		return false
	var pattern := RegEx.new()
	pattern.compile("^http://([0-9.]+):([0-9]{1,5})/([a-f0-9]{48})/video\\.ts$")
	var matched := pattern.search(url)
	if matched == null:
		return false
	var address := matched.get_string(1)
	var port := int(matched.get_string(2))
	if not address.is_valid_ip_address() or port < 1 or port > 65535:
		return false
	# The stream is served by a collaboration PC, including wired LAN/VPN.
	return address != "0.0.0.0" and (not address.begins_with("127.") or address == "127.0.0.1")
