shader_type spatial;
render_mode cull_back;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 edge = abs(fract(world_xz + 0.5) - 0.5);
	vec2 line = 1.0 - smoothstep(vec2(0.0), max(fwidth(world_xz), vec2(0.012)), edge);
	float fade = 1.0 - smoothstep(6.0, 16.0, length(world_xz - CAMERA_POSITION_WORLD.xz));
	ALBEDO = mix(vec3(0.105, 0.145, 0.15), vec3(0.20, 0.285, 0.27), max(line.x, line.y) * fade);
	ROUGHNESS = 0.96;
}
