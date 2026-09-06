shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

// UV.x is a stable palette coordinate baked by Blender: the complete LAND top
// shares one value, while only its polygonal slope faces vary. After glTF's
// V-axis conversion, UV.y runs from 0 on the top to 1 at the slope foot.
uniform vec4 dark_earth : source_color = vec4(0.275, 0.168, 0.098, 1.0);
uniform vec4 middle_earth : source_color = vec4(0.285, 0.175, 0.103, 1.0);
uniform vec4 light_earth : source_color = vec4(0.295, 0.182, 0.108, 1.0);
uniform float face_contrast : hint_range(0.0, 0.20) = 0.015;
uniform float slope_shadow : hint_range(0.0, 0.30) = 0.10;
uniform float roughness : hint_range(0.0, 1.0) = 0.94;


void fragment() {
	float face_tone = clamp(UV.x, 0.0, 1.0);
	vec3 earth = mix(dark_earth.rgb, middle_earth.rgb, smoothstep(0.18, 0.55, face_tone));
	earth = mix(earth, light_earth.rgb, smoothstep(0.55, 0.82, face_tone));
	float centred_tone = (face_tone - 0.5) * 2.0;
	earth *= 1.0 + centred_tone * face_contrast;

// The slope has real geometry; this restrained value shift keeps its polygonal
// rings readable without creating painted stripes on the flat top.
	float slope_depth = clamp(UV.y, 0.0, 1.0);
	earth *= 1.0 - slope_depth * slope_shadow;

	ALBEDO = earth;
	ROUGHNESS = roughness;
	SPECULAR = 0.12;
}
