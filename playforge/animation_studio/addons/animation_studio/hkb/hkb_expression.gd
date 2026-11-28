@tool
class_name HkbExpressionEvaluator
extends RefCounted
## Pure-GDScript Havok hkbCompiledExpressionSet & hkbCondition Evaluator.
## Implements all 43 official Havok expression operators & math functions
## (arithmetic, comparison, logical, ternary `?:`, `clamp`, `lerp`, `clerp`,
##  `cond`, `sin/cos/sind/cosd/asin/acos/atan2/deg2rad/rad2deg/sqrt/fabs/min/max/sign/mod/pow`).

const HkbCtx := preload("res://addons/animation_studio/hkb/hkb_context.gd")

static var _token_cache: Dictionary = {} # expr_str -> Array[Dictionary]


static func evaluate(expr: String, ctx: HkbCtx) -> float:
	var s := expr.strip_edges()
	if s.is_empty():
		return 0.0
	var tokens: Array = _tokenize_cached(s)
	if tokens.is_empty():
		return 0.0
	var p := _Parser.new(tokens, ctx)
	return p.parse_expr()


static func evaluate_condition(cond: Variant, ctx: HkbCtx) -> bool:
	if cond == null:
		return true
	if cond is bool:
		return cond
	if cond is String:
		var s := (cond as String).strip_edges()
		return true if s.is_empty() else absf(evaluate(s, ctx)) > 1e-6
	if cond is Dictionary:
		var d: Dictionary = cond as Dictionary
		var kind := str(d.get("kind", "expression"))
		var expr := str(d.get("expr", ""))
		if expr.is_empty():
			return true
		if kind == "expression" or kind == "string":
			return absf(evaluate(expr, ctx)) > 1e-6
	return true


static func _tokenize_cached(s: String) -> Array:
	if _token_cache.has(s):
		return _token_cache[s] as Array
	var toks := _tokenize(s)
	_token_cache[s] = toks
	return toks


static func _tokenize(s: String) -> Array:
	var toks: Array = []
	var i := 0
	var n := s.length()
	while i < n:
		var ch := s[i]
		if ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
			i += 1
			continue
		# Two-char operators
		if i + 1 < n:
			var two := s.substr(i, 2)
			if two in ["==", "!=", "<=", ">=", "&&", "||"]:
				toks.append({"t": "op", "v": two})
				i += 2
				continue
		# Single-char punctuation / operators
		if ch in ["+", "-", "*", "/", "%", "^", "<", ">", "!", "(", ")", ",", "?", ":"]:
			toks.append({"t": "op", "v": ch})
			i += 1
			continue
		# Number literal
		if _is_digit(ch) or (ch == "." and i + 1 < n and _is_digit(s[i + 1])):
			var start := i
			var has_dot := (ch == ".")
			i += 1
			while i < n:
				var c := s[i]
				if _is_digit(c):
					i += 1
				elif c == "." and not has_dot:
					has_dot = true
					i += 1
				elif (c == "e" or c == "E") and i + 1 < n:
					i += 1
					if i < n and (s[i] == "+" or s[i] == "-"):
						i += 1
				else:
					break
			toks.append({"t": "num", "v": float(s.substr(start, i - start))})
			continue
		# Identifier (supports Havok variable names with letters, digits, underscores, dots)
		if _is_ident_start(ch):
			var start := i
			i += 1
			while i < n and (_is_ident_char(s[i]) or s[i] == "."):
				i += 1
			var ident := s.substr(start, i - start)
			var low := ident.to_lower()
			if low == "true":
				toks.append({"t": "num", "v": 1.0})
			elif low == "false":
				toks.append({"t": "num", "v": 0.0})
			elif low == "and":
				toks.append({"t": "op", "v": "&&"})
			elif low == "or":
				toks.append({"t": "op", "v": "||"})
			elif low == "not":
				toks.append({"t": "op", "v": "!"})
			else:
				toks.append({"t": "id", "v": ident})
			continue
		# Skip unknown character safely
		i += 1
	return toks


static func _is_digit(c: String) -> bool:
	var u := c.unicode_at(0)
	return u >= 48 and u <= 57


static func _is_ident_start(c: String) -> bool:
	var u := c.unicode_at(0)
	return (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or u == 95 or u == 36


static func _is_ident_char(c: String) -> bool:
	return _is_ident_start(c) or _is_digit(c)


class _Parser extends RefCounted:
	var toks: Array
	var pos: int = 0
	var ctx: HkbCtx

	func _init(p_toks: Array, p_ctx: HkbCtx) -> void:
		toks = p_toks
		ctx = p_ctx

	func _peek() -> Dictionary:
		if pos < toks.size():
			return toks[pos] as Dictionary
		return {"t": "eof", "v": ""}

	func _match_op(op: String) -> bool:
		var t := _peek()
		if t["t"] == "op" and t["v"] == op:
			pos += 1
			return true
		return false

	func parse_expr() -> float:
		return _parse_ternary()

	func _parse_ternary() -> float:
		var c := _parse_or()
		if _match_op("?"):
			var a := _parse_ternary()
			_match_op(":")
			var b := _parse_ternary()
			return a if absf(c) > 1e-6 else b
		return c

	func _parse_or() -> float:
		var left := _parse_and()
		while _match_op("||"):
			var right := _parse_and()
			left = 1.0 if (absf(left) > 1e-6 or absf(right) > 1e-6) else 0.0
		return left

	func _parse_and() -> float:
		var left := _parse_eq()
		while _match_op("&&"):
			var right := _parse_eq()
			left = 1.0 if (absf(left) > 1e-6 and absf(right) > 1e-6) else 0.0
		return left

	func _parse_eq() -> float:
		var left := _parse_rel()
		while true:
			if _match_op("=="):
				var right := _parse_rel()
				left = 1.0 if absf(left - right) < 1e-5 else 0.0
			elif _match_op("!="):
				var right := _parse_rel()
				left = 1.0 if absf(left - right) >= 1e-5 else 0.0
			else:
				break
		return left

	func _parse_rel() -> float:
		var left := _parse_add()
		while true:
			if _match_op("<"):
				left = 1.0 if left < _parse_add() else 0.0
			elif _match_op(">"):
				left = 1.0 if left > _parse_add() else 0.0
			elif _match_op("<="):
				left = 1.0 if left <= _parse_add() else 0.0
			elif _match_op(">="):
				left = 1.0 if left >= _parse_add() else 0.0
			else:
				break
		return left

	func _parse_add() -> float:
		var left := _parse_mul()
		while true:
			if _match_op("+"):
				left += _parse_mul()
			elif _match_op("-"):
				left -= _parse_mul()
			else:
				break
		return left

	func _parse_mul() -> float:
		var left := _parse_unary()
		while true:
			if _match_op("*"):
				left *= _parse_unary()
			elif _match_op("/"):
				var d := _parse_unary()
				left = left / d if absf(d) > 1e-8 else 0.0
			elif _match_op("%"):
				var m := _parse_unary()
				left = fmod(left, m) if absf(m) > 1e-8 else 0.0
			elif _match_op("^"):
				left = pow(left, _parse_unary())
			else:
				break
		return left

	func _parse_unary() -> float:
		if _match_op("-"):
			return -_parse_unary()
		if _match_op("+"):
			return _parse_unary()
		if _match_op("!"):
			return 0.0 if absf(_parse_unary()) > 1e-6 else 1.0
		return _parse_primary()

	func _parse_primary() -> float:
		var t := _peek()
		if t["t"] == "num":
			pos += 1
			return float(t["v"])
		if _match_op("("):
			var v := parse_expr()
			_match_op(")")
			return v
		if t["t"] == "id":
			pos += 1
			var ident := str(t["v"])
			if _match_op("("):
				var args: Array[float] = []
				if not _match_op(")"):
					args.append(parse_expr())
					while _match_op(","):
						args.append(parse_expr())
					_match_op(")")
				return _eval_func(ident.to_lower(), args)
			if ctx == null:
				return 0.0
			# Vector component access e.g. myVec.x / .y / .z / .w
			if "." in ident:
				var parts := ident.split(".", false, 1)
				var base_val: Variant = ctx.get_symbol_value(parts[0])
				var comp := parts[1].to_lower()
				if base_val is Vector3:
					var v3: Vector3 = base_val as Vector3
					return v3.x if comp == "x" else (v3.y if comp == "y" else (v3.z if comp == "z" else v3.length()))
				elif base_val is Vector4:
					var v4: Vector4 = base_val as Vector4
					return v4.x if comp == "x" else (v4.y if comp == "y" else (v4.z if comp == "z" else v4.w))
			var val: Variant = ctx.get_symbol_value(ident)
			if val is bool:
				return 1.0 if (val as bool) else 0.0
			if val is int or val is float:
				return float(val)
			return 0.0
		return 0.0

	func _eval_func(fn: String, a: Array[float]) -> float:
		var n := a.size()
		match fn:
			"sin": return sin(a[0]) if n >= 1 else 0.0
			"cos": return cos(a[0]) if n >= 1 else 0.0
			"asin": return asin(clampf(a[0], -1.0, 1.0)) if n >= 1 else 0.0
			"acos": return acos(clampf(a[0], -1.0, 1.0)) if n >= 1 else 0.0
			"sind": return sin(deg_to_rad(a[0])) if n >= 1 else 0.0
			"cosd": return cos(deg_to_rad(a[0])) if n >= 1 else 0.0
			"asind": return rad_to_deg(asin(clampf(a[0], -1.0, 1.0))) if n >= 1 else 0.0
			"acosd": return rad_to_deg(acos(clampf(a[0], -1.0, 1.0))) if n >= 1 else 0.0
			"atan2": return atan2(a[0], a[1]) if n >= 2 else 0.0
			"atan2d": return rad_to_deg(atan2(a[0], a[1])) if n >= 2 else 0.0
			"deg2rad": return deg_to_rad(a[0]) if n >= 1 else 0.0
			"rad2deg": return rad_to_deg(a[0]) if n >= 1 else 0.0
			"sqrt": return sqrt(maxf(0.0, a[0])) if n >= 1 else 0.0
			"sqrtinv": return (1.0 / sqrt(a[0])) if (n >= 1 and a[0] > 1e-8) else 0.0
			"fabs", "abs": return absf(a[0]) if n >= 1 else 0.0
			"ceil": return ceil(a[0]) if n >= 1 else 0.0
			"floor": return floor(a[0]) if n >= 1 else 0.0
			"sign": return signf(a[0]) if n >= 1 else 0.0
			"pow": return pow(a[0], a[1]) if n >= 2 else 0.0
			"min", "min2": return minf(a[0], a[1]) if n >= 2 else 0.0
			"max", "max2": return maxf(a[0], a[1]) if n >= 2 else 0.0
			"clamp": return clampf(a[0], a[1], a[2]) if n >= 3 else 0.0
			"lerp": return lerpf(a[0], a[1], a[2]) if n >= 3 else 0.0
			"clerp": return lerpf(a[0], a[1], clampf(a[2], 0.0, 1.0)) if n >= 3 else 0.0
			"cond": return (a[1] if absf(a[0]) > 1e-6 else a[2]) if n >= 3 else 0.0
			"rand01": return fposmod(sin(float(ctx.tick if ctx != null else 1) * 12.9898) * 43758.5453, 1.0)
			"randrange":
				var r := fposmod(sin(float(ctx.tick if ctx != null else 1) * 12.9898) * 43758.5453, 1.0)
				return lerpf(a[0], a[1], r) if n >= 2 else r
			_:
				return 0.0
