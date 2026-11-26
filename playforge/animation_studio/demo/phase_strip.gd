extends Control

var phase := 0.0


func _draw() -> void:
	var y := size.y * 0.5
	draw_line(Vector2(0, y), Vector2(size.x, y), Color("#47605e"), 3.0)
	draw_line(Vector2(0, y), Vector2(size.x * phase, y), Color("#acd6c6"), 3.0)
	for marker in [0.25, 0.75]:
		var x: float = marker * size.x
		draw_line(Vector2(x, y - 5), Vector2(x, y + 5), Color("#43ccb1") if marker < 0.5 else Color("#f89a50"), 3.0)
	draw_circle(Vector2(size.x * phase, y), 4.0, Color.WHITE)
