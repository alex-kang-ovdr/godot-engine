extends Node
## Bare @rpc endpoint used by the ENet/RPC profiling regression fixture.

var fixture: Node
var side := ""


@rpc("any_peer", "call_remote", "unreliable")
func request_probe(label: String) -> void:
	if side != "server":
		return
	var sender := multiplayer.get_remote_sender_id()
	fixture._on_request_probe(label, sender, Time.get_ticks_usec())


@rpc("authority", "call_remote", "unreliable")
func reply_probe(label: String, server_received_usec: int) -> void:
	if side != "client":
		return
	fixture._on_reply_probe(label, server_received_usec, Time.get_ticks_usec())
