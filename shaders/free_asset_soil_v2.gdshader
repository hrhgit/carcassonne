shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform vec4 fertile_earth : source_color = vec4(0.27, 0.17, 0.10, 1.0);
uniform vec4 cool_earth : source_color = vec4(0.20, 0.145, 0.095, 1.0);
uniform float furrow_strength : hint_range(0.0, 0.25) = 0.16;
uniform float roughness : hint_range(0.0, 1.0) = 0.94;

varying vec3 world_position;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	float macro = sin(world_position.x * 0.42 + world_position.z * 0.18 + 0.7);
	macro += sin(world_position.x * -0.17 + world_position.z * 0.38 + 2.1) * 0.48;
	macro = floor(clamp(macro * 0.32 + 0.5, 0.0, 0.999) * 3.0) * 0.5;
	vec3 earth = mix(cool_earth.rgb, fertile_earth.rgb, 0.68 + macro * 0.22);

	// Broad, gently warped cultivation marks break up the large bare LAND mass.
	// They are shader-only surface detail: planting height and baked topology do
	// not change, and the effect fades before every canonical tile boundary.
	float warp = sin(world_position.x * 0.85 + 0.6) * 0.10;
	float repeated = abs(fract((world_position.z + world_position.x * 0.16 + warp) * 0.92) - 0.5);
	float furrow = 1.0 - smoothstep(0.055, 0.12, repeated);
	float boundary_distance = min(2.45 - abs(world_position.x), 2.45 - abs(world_position.z));
	float interior = smoothstep(0.35, 0.72, boundary_distance);
	earth *= 1.0 - furrow * interior * furrow_strength;

	ALBEDO = earth;
	ROUGHNESS = roughness;
	SPECULAR = 0.12;
}
