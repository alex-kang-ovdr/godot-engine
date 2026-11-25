extends Node
## Independent headless ENet smoke: two SceneMultiplayer APIs, two ENet peers, bare @rpc.

const PFTest = preload("res://lib/pf_test.gd")
const EndpointScript = preload("res://network/net_debug_endpoint.gd")
const C_RPC_PROFILE := "Forge-Refactoring-Multiplayer"
const C_ENET_SIMULATION := "Forge-Refactoring-Multiplayer"

var t: PFTest
var _error_mark := 0
var server_api: SceneMultiplayer
var client_api: SceneMultiplayer
var server_peer: ENetMultiplayerPeer
var client_peer: ENetMultiplayerPeer
var server_host: ENetConnection
var client_host: ENetConnection
var server_endpoint: Node
var client_endpoint: Node
var server_root: Node
var client_root: Node
var server_peer_id := 0
var client_connected := false
var server_requests: Dictionary = {}
var client_replies: Dictionary = {}
var client_sent_usec: Dictionary = {}


func _init() -> void:
	t = PFTest.new("enet_rpc_netdebug")


func _ready() -> void:
	_error_mark = t.error_mark()
	if not _setup_peers():
		await _finish()
		return
	await _run_smoke()
	await _finish()


func _setup_peers() -> bool:
	server_root = Node.new()
	server_root.name = "ServerRoot"
	add_child(server_root)
	server_endpoint = EndpointScript.new()
	server_endpoint.name = "RpcProbe"
	server_endpoint.set("side", "server")
	server_endpoint.set("fixture", self)
	server_root.add_child(server_endpoint)

	client_root = Node.new()
	client_root.name = "ClientRoot"
	add_child(client_root)
	client_endpoint = EndpointScript.new()
	client_endpoint.name = "RpcProbe"
	client_endpoint.set("side", "client")
	client_endpoint.set("fixture", self)
	client_root.add_child(client_endpoint)

	server_api = SceneMultiplayer.new()
	client_api = SceneMultiplayer.new()
	get_tree().set_multiplayer(server_api, server_root.get_path())
	get_tree().set_multiplayer(client_api, client_root.get_path())
	if not server_api.has_method("set_rpc_profiling_enabled") or not server_api.has_method("get_rpc_profile"):
		t.check("scene_multiplayer_rpc_profile_api", C_RPC_PROFILE, false, "profiling API is not present in this engine build")
		return false
	if not ClassDB.class_has_method("ENetConnection", "apply_debug_packet_command") \
			or not ClassDB.class_has_method("ENetConnection", "get_debug_packet_simulation"):
		t.check("enet_debug_packet_api", C_ENET_SIMULATION, false, "ENet simulation API is not present in this engine build")
		return false
	server_api.call("set_rpc_profiling_enabled", true)
	client_api.call("set_rpc_profiling_enabled", true)

	server_api.peer_connected.connect(_on_server_peer_connected)
	client_api.connected_to_server.connect(_on_client_connected)
	client_api.connection_failed.connect(_on_client_connection_failed)

	server_peer = ENetMultiplayerPeer.new()
	server_peer.set_bind_ip("127.0.0.1")
	var err := server_peer.create_server(0, 4)
	t.check("enet_server_create", C_ENET_SIMULATION, err == OK, "error=%d" % err)
	if err != OK:
		return false
	server_api.multiplayer_peer = server_peer
	server_host = server_peer.get_host()
	var server_port := int(server_host.get_local_port())
	t.check("enet_server_ephemeral_loopback_port", C_ENET_SIMULATION, server_port > 0, "port=%d" % server_port)
	if server_port <= 0:
		return false

	client_peer = ENetMultiplayerPeer.new()
	client_peer.set_bind_ip("127.0.0.1")
	err = client_peer.create_client("127.0.0.1", server_port)
	t.check("enet_client_create", C_ENET_SIMULATION, err == OK, "error=%d" % err)
	if err != OK:
		return false
	client_api.multiplayer_peer = client_peer
	client_host = client_peer.get_host()
	t.check("rpc_profile_starts_empty", C_RPC_PROFILE,
		server_api.call("get_rpc_profile").is_empty() and client_api.call("get_rpc_profile").is_empty())
	t.check("debug_packet_simulation_available", C_ENET_SIMULATION,
		bool(client_host.call("get_debug_packet_simulation").get("available", false))
		and bool(server_host.call("get_debug_packet_simulation").get("available", false)))
	return true


func _run_smoke() -> void:
	var connected := await _wait_for_connection(5.0)
	t.check("separate_scene_multiplayer_peer_connected", C_ENET_SIMULATION, connected,
		"client=%s server_peer=%d" % [client_connected, server_peer_id])
	if not connected:
		return

	var baseline := await _exchange("baseline", 4.0)
	t.check("bare_rpc_baseline_exchange", C_RPC_PROFILE, not baseline.is_empty(), str(baseline))
	if baseline.is_empty():
		return

	# Runtime cheat command applies real outgoing datagram delay to an already-connected ENet host.
	var command_error := _apply_command(client_host, "NetEmulation.PktLag 120")
	t.check("runtime_pkt_lag_command", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	var delayed := await _exchange("delayed", 5.0)
	var delay_usec := int(delayed.get("server_received_usec", 0)) - int(delayed.get("client_sent_usec", 0))
	t.check("real_outgoing_latency_observed", C_ENET_SIMULATION,
		not delayed.is_empty() and delay_usec >= 80_000, "observed_ms=%.1f" % (float(delay_usec) / 1000.0))

	# 100% loss is deterministic; use unreliable @rpc so there is no transport retransmission after Off.
	command_error = _apply_command(client_host, "NetEmulation.PktLag 0")
	t.check("runtime_pkt_lag_reset", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	command_error = _apply_command(client_host, "NetEmulation.PktLoss 100")
	t.check("runtime_pkt_loss_command", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	var outgoing_drop_before := int(_sim_status(client_host).get("outgoing_dropped_loss", 0))
	_send_request("lost_outgoing")
	var outgoing_dropped := await _wait_for_counter(client_host, "outgoing_dropped_loss", outgoing_drop_before, 2.0)
	await get_tree().create_timer(0.2).timeout
	t.check("100_percent_outgoing_loss_drops_rpc", C_ENET_SIMULATION,
		outgoing_dropped and not server_requests.has("lost_outgoing"), str(_sim_status(client_host)))

	# Off clears all four impairment settings, drains any queued datagrams on the next host service, and restores RPC flow.
	command_error = _apply_command(client_host, "NetEmulation.Off")
	t.check("runtime_off_command", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	var client_off_status := _sim_status(client_host)
	t.check("off_restores_zero_profile", C_ENET_SIMULATION,
		int(client_off_status.get("outgoing_delay_ms", -1)) == 0
		and float(client_off_status.get("outgoing_loss_percent", -1.0)) == 0.0
		and int(client_off_status.get("incoming_delay_ms", -1)) == 0
		and float(client_off_status.get("incoming_loss_percent", -1.0)) == 0.0, str(client_off_status))
	var restored := await _exchange("restored_outgoing", 4.0)
	t.check("off_restores_rpc_delivery", C_ENET_SIMULATION, not restored.is_empty(), str(restored))
	if restored.is_empty():
		return

	# Exercise the incoming side independently on the server host, then restore it with the same runtime command.
	command_error = _apply_command(server_host, "NetEmulation.PktIncomingLoss 100")
	t.check("runtime_incoming_loss_command", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	var incoming_drop_before := int(_sim_status(server_host).get("incoming_dropped_loss", 0))
	_send_request("lost_incoming")
	var incoming_dropped := await _wait_for_counter(server_host, "incoming_dropped_loss", incoming_drop_before, 2.0)
	await get_tree().create_timer(0.15).timeout
	t.check("100_percent_incoming_loss_drops_rpc", C_ENET_SIMULATION,
		incoming_dropped and not server_requests.has("lost_incoming"), str(_sim_status(server_host)))
	command_error = _apply_command(server_host, "NetEmulation.Off")
	t.check("server_off_restores_incoming", C_ENET_SIMULATION, command_error == OK, "error=%d" % command_error)
	var incoming_restored := await _exchange("restored_incoming", 4.0)
	t.check("incoming_off_restores_rpc_delivery", C_ENET_SIMULATION, not incoming_restored.is_empty(), str(incoming_restored))

	# Profiler snapshots are cumulative per method and separate from host-level ENet statistics.
	var client_profile: Dictionary = client_api.call("get_rpc_profile")
	var server_profile: Dictionary = server_api.call("get_rpc_profile")
	var client_request := _profile_entry(client_profile, "request_probe")
	var client_reply := _profile_entry(client_profile, "reply_probe")
	var server_request := _profile_entry(server_profile, "request_probe")
	var server_reply := _profile_entry(server_profile, "reply_probe")
	var profile_keys := ["sent", "received", "sent_bytes", "received_bytes"]
	t.check("profile_method_entries", C_RPC_PROFILE,
		not client_request.is_empty() and not client_reply.is_empty() and not server_request.is_empty() and not server_reply.is_empty(),
		"client=%s server=%s" % [str(client_profile.keys()), str(server_profile.keys())])
	var has_shape := true
	for key in profile_keys:
		has_shape = has_shape and client_request.has(key) and client_reply.has(key) and server_request.has(key) and server_reply.has(key)
	t.check("profile_entry_shape", C_RPC_PROFILE, has_shape, "keys=%s" % str(profile_keys))
	t.check("profile_counts_include_remote_only_calls", C_RPC_PROFILE,
		int(client_request.get("sent", 0)) == 6
		and int(server_request.get("received", 0)) == 4
		and int(server_reply.get("sent", 0)) == 4
		and int(client_reply.get("received", 0)) == 4,
		"client_request=%s server_request=%s server_reply=%s client_reply=%s" % [str(client_request), str(server_request), str(server_reply), str(client_reply)])
	t.check("profile_bytes_positive", C_RPC_PROFILE,
		int(client_request.get("sent_bytes", 0)) > 0 and int(server_request.get("received_bytes", 0)) > 0
		and int(server_reply.get("sent_bytes", 0)) > 0 and int(client_reply.get("received_bytes", 0)) > 0)

	# Disabling freezes a capture; re-enabling starts a clean capture.
	client_api.call("set_rpc_profiling_enabled", false)
	var frozen_sent := int(client_request.get("sent", 0))
	var final_exchange := await _exchange("profiling_disabled", 4.0)
	var frozen_profile: Dictionary = client_api.call("get_rpc_profile")
	t.check("profile_disable_freezes_snapshot", C_RPC_PROFILE,
		not final_exchange.is_empty() and int(_profile_entry(frozen_profile, "request_probe").get("sent", -1)) == frozen_sent)
	client_api.call("set_rpc_profiling_enabled", true)
	t.check("profile_reenable_clears_capture", C_RPC_PROFILE, client_api.call("get_rpc_profile").is_empty())

	# ENet host counters are independent wire-level values and pop_statistic resets each sampled counter.
	var client_traffic := _pop_host_statistics(client_host)
	var server_traffic := _pop_host_statistics(server_host)
	t.info("enet_host_pop_statistics", {"client": client_traffic, "server": server_traffic})
	t.check("enet_host_statistics_positive", C_ENET_SIMULATION,
		int(client_traffic.sent_data) > 0 and int(client_traffic.received_data) > 0
		and int(server_traffic.sent_data) > 0 and int(server_traffic.received_data) > 0,
		"client=%s server=%s" % [str(client_traffic), str(server_traffic)])

	_test_dtls_upgrade_queue_cleanup()


func _test_dtls_upgrade_queue_cleanup() -> void:
	var upgrade_host := ENetConnection.new()
	var create_error := upgrade_host.create_host_bound("127.0.0.1", 0, 4)
	t.check("dtls_upgrade_fixture_host_create", C_ENET_SIMULATION, create_error == OK, "error=%d" % create_error)
	if create_error != OK:
		return
	var profile_error := upgrade_host.set_debug_packet_simulation(10000, 0.0, 7000, 0.0, 91)
	t.check("dtls_upgrade_fixture_profile", C_ENET_SIMULATION, profile_error == OK, "error=%d" % profile_error)
	if profile_error != OK:
		upgrade_host.destroy()
		return

	# This valid loopback UDP payload is deliberately held by the latency queue; it is not DTLS traffic.
	upgrade_host.socket_send("127.0.0.1", 9, PackedByteArray([0x46, 0x47, 0x45]))
	var before_upgrade := upgrade_host.get_debug_packet_simulation()
	var queued_before := int(before_upgrade.get("outgoing_queued_packets", 0))
	t.check("dtls_upgrade_fixture_has_queued_plaintext", C_ENET_SIMULATION,
		queued_before > 0, str(before_upgrade))
	if queued_before <= 0:
		upgrade_host.destroy()
		return

	var dtls_error := upgrade_host.dtls_client_setup("localhost", TLSOptions.client_unsafe())
	t.check("dtls_client_setup_transport_upgrade", C_ENET_SIMULATION, dtls_error == OK, "error=%d" % dtls_error)
	if dtls_error == OK:
		var after_upgrade := upgrade_host.get_debug_packet_simulation()
		t.check("dtls_upgrade_clears_queued_datagrams", C_ENET_SIMULATION,
			int(after_upgrade.get("outgoing_queued_packets", -1)) == 0
			and int(after_upgrade.get("incoming_queued_packets", -1)) == 0
			and int(after_upgrade.get("outgoing_discarded_transport_upgrade", 0)) >= queued_before,
			str(after_upgrade))
		t.check("dtls_upgrade_preserves_simulation_profile", C_ENET_SIMULATION,
			int(after_upgrade.get("outgoing_delay_ms", -1)) == 10000
			and float(after_upgrade.get("outgoing_loss_percent", -1.0)) == 0.0
			and int(after_upgrade.get("incoming_delay_ms", -1)) == 7000
			and float(after_upgrade.get("incoming_loss_percent", -1.0)) == 0.0,
			str(after_upgrade))
	upgrade_host.destroy()


func _on_server_peer_connected(peer_id: int) -> void:
	server_peer_id = peer_id


func _on_client_connected() -> void:
	client_connected = true


func _on_client_connection_failed() -> void:
	client_connected = false


func _on_request_probe(label: String, sender_id: int, received_usec: int) -> void:
	server_requests[label] = {"server_received_usec": received_usec, "sender_id": sender_id}
	server_endpoint.rpc_id(sender_id, "reply_probe", label, received_usec)


func _on_reply_probe(label: String, server_received_usec: int, received_usec: int) -> void:
	client_replies[label] = {"server_received_usec": server_received_usec, "client_received_usec": received_usec}


func _send_request(label: String) -> void:
	client_sent_usec[label] = Time.get_ticks_usec()
	client_endpoint.rpc_id(1, "request_probe", label)


func _exchange(label: String, timeout_seconds: float) -> Dictionary:
	_send_request(label)
	var server_event := await _wait_for_record(server_requests, label, timeout_seconds)
	if server_event.is_empty():
		return {}
	var client_event := await _wait_for_record(client_replies, label, timeout_seconds)
	if client_event.is_empty():
		return {}
	return {
		"client_sent_usec": int(client_sent_usec.get(label, 0)),
		"server_received_usec": int(server_event.server_received_usec),
		"client_received_usec": int(client_event.client_received_usec),
		"sender_id": int(server_event.sender_id),
	}


func _wait_for_connection(timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if client_connected and server_peer_id > 1:
			return true
		await get_tree().process_frame
	return false


func _wait_for_record(records: Dictionary, label: String, timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if records.has(label):
			return records[label]
		await get_tree().process_frame
	return {}


func _wait_for_counter(host: ENetConnection, key: String, before: int, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if int(_sim_status(host).get(key, 0)) > before:
			return true
		await get_tree().process_frame
	return false


func _sim_status(host: ENetConnection) -> Dictionary:
	var status: Variant = host.call("get_debug_packet_simulation")
	return status if status is Dictionary else {}


func _apply_command(host: ENetConnection, command: String) -> int:
	return int(host.call("apply_debug_packet_command", command))


func _profile_entry(profile: Dictionary, method: String) -> Dictionary:
	var entry: Variant = profile.get(StringName(method), profile.get(method, {}))
	return entry if entry is Dictionary else {}


func _pop_host_statistics(host: ENetConnection) -> Dictionary:
	return {
		"sent_data": int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)),
		"sent_packets": int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)),
		"received_data": int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)),
		"received_packets": int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)),
	}


func _finish() -> void:
	if is_instance_valid(client_peer):
		client_peer.close()
	if is_instance_valid(server_peer):
		server_peer.close()
	await PFTest.frames(get_tree(), 1)
	var errors := t.errors_since(_error_mark)
	t.check("no_engine_errors", C_RPC_PROFILE, errors.is_empty(), str(errors))
	t.finish(get_tree())
