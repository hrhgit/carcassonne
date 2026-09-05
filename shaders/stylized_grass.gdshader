shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

// Large, quiet color masses keep the grass readable beside the faceted soil.
uniform vec4 grass_color : source_color = vec4(0.30, 0.44, 0.245, 1.0);
uniform float color_variation : hint_range(0.0, 0.10) = 0.045;
uniform float roughness : hint_range(0.0, 1.0) = 0.90;

varying vec3 world_position;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	float field = sin(world_position.x * 0.34 + world_position.z * 0.22);
	field += sin(world_position.x * -0.14 + world_position.z * 0.43 + 1.31) * 0.55;
	field = clamp(field * 0.34 + 0.5, 0.0, 0.999);
	float broad_band = floor(field * 3.0) * 0.5;
	float value_offset = (broad_band - 0.5) * 2.0 * color_variation;

	ALBEDO = grass_color.rgb * (1.0 + value_offset);
	ROUGHNESS = roughness;
	SPECULAR = 0.12;
}
