shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

// Three related blue values are enough for a readable stylized river. The
// material remains visually opaque: the river reads as a painted tabletop
// water channel.
uniform vec4 deep_color : source_color = vec4(0.10, 0.32, 0.49, 1.0);
uniform vec4 middle_color : source_color = vec4(0.12, 0.40, 0.57, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.17, 0.49, 0.64, 1.0);
uniform vec4 highlight_color : source_color = vec4(0.72, 0.89, 0.94, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.48;

// The depth sampler is provided by the current viewport. Keep its sampling
// sharp so the intentionally thin shoreline band does not smear inland.
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// Shoreline foam uses a fixed repeating noise resource. The procedural wave
// decides when a crest breaks; noise only selects which rounded bubbles join
// that crest. Every mask is hard thresholded later, so pixels are either
// absent or solid white.
uniform sampler2D foam_texture : repeat_enable, filter_linear_mipmap;
uniform bool foam_enabled = true;
uniform bool foam_animation_enabled = true;
uniform float foam_line_width : hint_range(0.0025, 0.085, 0.0025) = 0.06;
uniform float foam_width : hint_range(0.02, 0.20, 0.0025) = 0.05;
uniform float foam_scale : hint_range(1.0, 16.0, 0.10) = 10.7;
uniform float foam_radius : hint_range(0.08, 0.68, 0.01) = 0.4;
uniform float foam_cutoff : hint_range(0.0, 1.0, 0.01) = 0.6;
// The baked perimeter length of the fused water outline, in world units.
// It makes the UV2.y shoreline coordinate usable as a locally metric axis.
uniform float foam_shoreline_length : hint_range(1.0, 32.0, 0.01) = 15.41997;
// These values are applied per *material instance* when a tile joins a water
// network. They map each frozen local UV2 shoreline into one shared network
// coordinate without modifying the mesh, its baked d/s data, or the source
// material resource. `phase_offset` is measured in normalized wave cycles.
uniform float foam_network_s_offset = 0.0;
uniform float foam_network_shoreline_length = 0.0;
uniform float foam_network_phase_offset = 0.0;
uniform float foam_network_speed_scale = 1.0;
// Normalized shoreline-coordinate units travelled by a crest per second.
uniform float foam_speed : hint_range(0.0, 0.85, 0.005) = 0.025;
uniform float foam_wave_strength : hint_range(0.0, 1.40, 0.02) = 0.5;
uniform float foam_wave_frequency : hint_range(1.0, 14.0, 0.10) = 10.0;

varying vec3 world_position;
const float FOAM_PHASE_TAU = 6.28318530718;


float linear_scene_depth(float raw_depth, vec2 screen_uv, mat4 inverse_projection_matrix) {
	// Godot 4.6's Compatibility renderer uses the OpenGL -1..1 Z range,
	// while Forward+ and Mobile use the Vulkan 0..1 Z range.
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(screen_uv, raw_depth) * 2.0 - 1.0;
	#else
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
	#endif
	vec4 view_position = inverse_projection_matrix * vec4(ndc, 1.0);
	return -view_position.z / view_position.w;
}


float foam_hash21(vec2 value) {
	return fract(sin(dot(value, vec2(127.1, 311.7))) * 43758.5453123);
}


vec2 foam_hash22(vec2 value) {
	return vec2(
		foam_hash21(value + vec2(19.19, 73.41)),
		foam_hash21(value + vec2(47.23, 11.17))
	);
}


float effective_network_length() {
	return max(foam_network_shoreline_length, foam_shoreline_length);
}


float network_shoreline_u(float local_shoreline_u) {
	float local_s = local_shoreline_u * foam_shoreline_length;
	return fract((local_s + foam_network_s_offset) / effective_network_length());
}


float shoreline_phase_from_network(float network_u, float foam_time) {
	return (
		network_u
		- foam_time * foam_speed * foam_network_speed_scale
		+ foam_network_phase_offset
	) * foam_wave_frequency;
}


float shoreline_phase(float local_shoreline_u, float foam_time) {
	return shoreline_phase_from_network(network_shoreline_u(local_shoreline_u), foam_time);
}


float shoreline_wave(float shoreline_u, float foam_time) {
	float phase = shoreline_phase(shoreline_u, foam_time);
	float primary_wave = sin(phase * FOAM_PHASE_TAU);
	float secondary_wave = sin((phase * 2.13 + 0.19) * FOAM_PHASE_TAU) * 0.28;
	return clamp(primary_wave * 0.78 + secondary_wave, -1.0, 1.0);
}


float circular_shore_delta(float sample_u, float source_u) {
	return fract(sample_u - source_u + 0.5) - 0.5;
}


float shoreline_burst_clusters(vec2 shoreline_coordinate, float foam_time) {
	float shoreline_length = max(effective_network_length(), 0.001);
	float network_u = network_shoreline_u(shoreline_coordinate.x);
	float source_count = max(4.0, ceil(shoreline_length * foam_scale));
	float current_cell = floor(network_u * source_count);
	float cell_size = shoreline_length / source_count;
	// The same user-facing wave strength that expands the white edge also
	// controls how far and how long its descendants can survive as foam.
	float wave_response = clamp(foam_wave_strength / 0.50, 0.0, 1.0);
	float foam_clusters = 0.0;

	// Each one-dimensional source lives on the baked shoreline itself. At the
	// crest it is born at d=0, then its age moves the whole cluster inward. The
	// three discs below are therefore descendants of this one crest, not free
	// world-space dots.
	for (int source_offset = -1; source_offset <= 1; source_offset++) {
		float raw_cell = current_cell + float(source_offset);
		float cell_id = mod(raw_cell + source_count, source_count);
		float source_jitter = mix(0.26, 0.74, foam_hash21(vec2(cell_id, 7.37)));
		float source_u = (cell_id + source_jitter) / source_count;
		float random_presence = foam_hash21(vec2(cell_id, 5.31));
		float noise_presence = texture(
			foam_texture,
			fract(vec2(source_u * 0.791 + 0.137, cell_id * 0.113 + 0.61))
		).r;
		float source_mask = step(
			mix(1.0, foam_cutoff, wave_response),
			mix(random_presence, noise_presence, 0.45)
		);

		// The birth time is precisely the same p=1/4 crest that makes this piece
		// of shoreline widest. A source remains visible only while it travels
		// through the protected shore band.
		float source_phase = shoreline_phase_from_network(source_u, foam_time);
		float burst_age = fract(source_phase - 0.25 + (foam_hash21(vec2(cell_id, 31.7)) - 0.5) * 0.05);
		float lifetime_mask = 1.0 - step(mix(0.12, 0.86, wave_response), burst_age);
		float reach = foam_width * mix(
			0.18,
			mix(0.54, 0.84, foam_hash21(vec2(cell_id, 17.3))),
			wave_response
		);
		float burst_distance = burst_age * reach;
		float rounded_cluster = 0.0;

		for (int bubble_index = 0; bubble_index < 3; bubble_index++) {
			float bubble = float(bubble_index);
			float radius = cell_size * foam_radius * mix(
				0.48,
				0.82,
				foam_hash21(vec2(cell_id, 13.1) + bubble * vec2(3.17, 5.93))
			);
			vec2 cluster_offset = (
				foam_hash22(vec2(cell_id, 41.9) + bubble * vec2(7.13, 11.71)) - 0.5
			) * radius * 1.35;
			float bubble_u = fract(source_u + cluster_offset.x / shoreline_length);
			float bubble_distance = max(0.0, burst_distance + cluster_offset.y);
			vec2 bubble_delta = vec2(
				circular_shore_delta(network_u, bubble_u) * shoreline_length,
				shoreline_coordinate.y - bubble_distance
			);
			float circle = 1.0 - step(radius, length(bubble_delta));
			rounded_cluster = max(rounded_cluster, circle);
		}
		foam_clusters = max(foam_clusters, source_mask * lifetime_mask * rounded_cluster);
	}
	return foam_clusters;
}


void vertex() {
	// The tabletop river is a still, fused surface: no traveling vertex waves.
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	// Keep the existing low-poly blue facets, but pin them in world space so a
	// Y-shaped river does not imply one impossible shared flow direction.
	float facet_field = sin(world_position.x * 1.06 + world_position.z * 0.18);
	facet_field += sin(world_position.x * 0.32 - world_position.z * 0.28) * 0.36;
	facet_field = clamp(facet_field * 0.37 + 0.5, 0.0, 0.999);
	float tone_band = floor(facet_field * 3.0) * 0.5;

	vec3 water_color = deep_color.rgb;
	water_color = mix(water_color, middle_color.rgb, step(0.25, tone_band));
	water_color = mix(water_color, shallow_color.rgb, step(0.75, tone_band));

	// The Fresnel response remains a static, restrained glint toward grazing
	// views; it is not a moving current or a surface wave.
	float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.35);
	float facet_highlight = smoothstep(0.62, 0.92, facet_field);
	float highlight = (0.018 + fresnel * 0.13) * (0.35 + facet_highlight * 0.65);

	// Compare the opaque scene behind this visually opaque water surface with
	// the surface's own view-space depth. A small difference means that a bank
	// or opaque object meets the water here; deep water contributes no foam.
	float scene_depth = linear_scene_depth(textureLod(depth_texture, SCREEN_UV, 0.0).r, SCREEN_UV, INV_PROJECTION_MATRIX);
	float water_surface_depth = -(VIEW_MATRIX * vec4(world_position, 1.0)).z;
	float water_depth = max(scene_depth - water_surface_depth, 0.0);
	float foam_time = foam_animation_enabled ? TIME : 0.0;

	// UV2.x is the baked distance inward from the nearest bank; UV2.y is that
	// bank's normalized arc coordinate around the final merged outline. This is
	// the only coordinate system used by both the shore line and foam births.
	vec2 shoreline_coordinate = vec2(UV2.y, UV2.x);
	float rounded_patch_mask = shoreline_burst_clusters(shoreline_coordinate, foam_time);

	// One shared phase drives both layers. The base line never breaks, but its
	// width breathes smoothly as the crest runs along the baked shoreline.
	float shore_wave = shoreline_wave(shoreline_coordinate.x, foam_time);
	float wavy_line_width = foam_line_width * max(0.34, 1.0 + shore_wave * foam_wave_strength);
	// Foam is always bounded to the authored shore band; the line can never
	// overtake that band even when a debug control is pushed to its upper range.
	wavy_line_width = min(wavy_line_width, min(foam_width * 0.78, 0.085));

	// The continuous base line and crest-born rounded clusters both require the
	// authored shoreline distance and real bank contact. UV.y is the ribbon's
	// across-flow coordinate; reserving its middle keeps even high debug values
	// out of the river centre.
	float bank_contact_mask = 1.0 - step(foam_width * 1.30, water_depth);
	float base_line_mask = 1.0 - step(wavy_line_width, UV2.x);
	base_line_mask *= bank_contact_mask;
	float patch_band_mask = 1.0 - step(foam_width, UV2.x);
	float centre_clearance_mask = step(0.105, abs(UV.y - 0.5));
	patch_band_mask *= bank_contact_mask * centre_clearance_mask;
	float floating_foam_mask = patch_band_mask * rounded_patch_mask;
	float foam_mask = step(0.5, max(base_line_mask, floating_foam_mask));
	if (!foam_enabled) {
		foam_mask = 0.0;
	}

	vec3 shaded_water = mix(water_color, highlight_color.rgb, highlight);
	vec3 water_emission = highlight_color.rgb * highlight * 0.035;
	// Foam is emitted white rather than lit white. This prevents directional
	// light, roughness, or tint from reintroducing a grey gradient inside it.
	ALBEDO = mix(shaded_water, vec3(0.0), foam_mask);
	ROUGHNESS = mix(roughness, 1.0, foam_mask);
	SPECULAR = mix(0.62, 0.0, foam_mask);
	EMISSION = mix(water_emission, vec3(1.0), foam_mask);

	// Sampling the pre-water depth buffer requires the transparent queue. Full
	// alpha preserves the existing opaque tabletop-water appearance while
	// preventing this surface from reading its own depth as a shoreline.
	ALPHA = 1.0;
}
