shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

// The land meshes stay authored as fixed prefabs. This shader deliberately
// ignores their legacy vertex-color palette so flat normals and the key light,
// rather than per-triangle hue jumps, describe the low-poly facets.
uniform vec4 fertile_earth : source_color = vec4(0.32, 0.235, 0.16, 1.0);
uniform vec4 moss_tint : source_color = vec4(0.29, 0.33, 0.21, 1.0);
uniform float color_variation : hint_range(0.0, 0.10) = 0.05;
uniform float moss_strength : hint_range(0.0, 0.25) = 0.11;
uniform float roughness : hint_range(0.0, 1.0) = 0.92;
// 0 keeps the original single-axis moss zones built for the north/south arcs.
// 1 reads UV.x instead, which is the baked across-field position (0 at each
// claimed outer tile edge, 1 at the connected field's inner contour).
uniform float moss_band_uv : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_position;
varying vec3 local_position;


float quantized_macro_field(vec2 point, float phase) {
	// Two long wavelengths yield broad world-space bands, never triangle noise.
	float field = sin(point.x * 0.46 + point.y * 0.18 + phase);
	field += sin(point.x * -0.20 + point.y * 0.36 + phase * 1.73) * 0.52;
	field = clamp(field * 0.33 + 0.5, 0.0, 0.999);
	return floor(field * 3.0) * 0.5;
}


void vertex() {
	local_position = VERTEX;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	float earth_band = quantized_macro_field(world_position.xz, 0.38);
	float value_offset = (earth_band - 0.5) * 2.0 * color_variation;
	vec3 earth = fertile_earth.rgb * (1.0 + value_offset);

	// Moss is limited to broad strips at the planted zone's outer edge and its
	// river-facing edge. The sparse selector is also low-frequency and quantized.
	float moss_zone;
	if (moss_band_uv > 0.5) {
		// Connected field: a thin strip at the claimed tile border and a slightly
		// softer strip at the inner contour. Keeping both under 12% of the band
		// width stops the low-frequency moss field from blanketing the land mass.
		float across_band = clamp(UV.x, 0.0, 1.0);
		moss_zone = max(1.0 - step(0.10, across_band), step(0.88, across_band) * 0.55);
	} else {
		float far_boundary = step(2.16, abs(local_position.z));
		float river_boundary = 1.0 - step(1.56, abs(local_position.z));
		moss_zone = max(far_boundary, river_boundary * 0.65);
	}
	float moss_field = sin(world_position.x * 0.98 + world_position.z * 0.20 + 0.70);
	moss_field += sin(world_position.x * -0.36 + world_position.z * 0.57 + 2.0) * 0.50;
	moss_field = clamp(moss_field * 0.33 + 0.5, 0.0, 0.999);
	// Only the upper cell of this broad five-band field gets moss, so it lands
	// as occasional large patches rather than a continuous edge stripe.
	float moss_band = floor(moss_field * 5.0) * 0.25;
	float moss_patch = step(0.95, moss_band) * moss_zone;
	earth = mix(earth, moss_tint.rgb, moss_patch * moss_strength);

	ALBEDO = earth;
	ROUGHNESS = roughness;
	SPECULAR = 0.16;
}
