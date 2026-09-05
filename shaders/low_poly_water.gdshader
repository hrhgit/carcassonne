shader_type spatial;
render_mode cull_disabled, unshaded;

uniform vec4 deep_color : source_color = vec4(0.025, 0.34, 0.52, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.08, 0.67, 0.78, 1.0);
uniform vec4 glint_color : source_color = vec4(0.55, 0.96, 0.94, 1.0);
uniform float flow_speed : hint_range(0.0, 4.0) = 0.85;
uniform float wave_height : hint_range(0.0, 0.05) = 0.012;

varying vec3 world_position;
varying float endpoint_fade;


void vertex() {
	// UV.x is authored from 0 to 1 along every fixed ribbon. Suppressing motion
	// at both ends keeps neighboring tile ports at an identical height.
	endpoint_fade = smoothstep(0.0, 0.14, UV.x) * smoothstep(0.0, 0.14, 1.0 - UV.x);
	float facet_wave = sin(UV.x * 19.0 - TIME * flow_speed * 2.0 + UV.y * 2.2);
	VERTEX.y += facet_wave * wave_height * endpoint_fade;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	float along = UV.x * 17.0 - TIME * flow_speed * 2.4;
	float cross_wave = sin(UV.y * 7.0 + UV.x * 5.0 + TIME * flow_speed * 0.65);
	float combined = sin(along + cross_wave * 0.75) * 0.62;
	combined += sin(along * 0.47 - world_position.x * 1.3 + world_position.z * 0.9) * 0.38;

	// Deliberately quantized lighting bands preserve the low-poly graphic style.
	float stepped_wave = floor(clamp(combined * 0.5 + 0.5, 0.0, 0.999) * 4.0) / 3.0;
	float bank_depth = smoothstep(0.12, 0.5, abs(UV.y - 0.5));
	vec3 water_color = mix(deep_color.rgb, shallow_color.rgb, stepped_wave * 0.56);
	water_color = mix(water_color, deep_color.rgb, bank_depth * 0.28);

	float broken_glint = smoothstep(0.82, 0.98, sin(along * 1.65 + UV.y * 11.0));
	broken_glint *= endpoint_fade * (1.0 - bank_depth);
	ALBEDO = water_color;
	EMISSION = glint_color.rgb * broken_glint * 0.24;
}
