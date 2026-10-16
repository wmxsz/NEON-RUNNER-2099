shader_type canvas_item;

// Boost-only cyber speed fringe. Normal color, contrast, saturation, fog, bloom,
// MSAA and texture filtering remain on Godot's native rendering pipeline.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float ca_amount : hint_range(0.0, 0.2) = 0.0;
uniform float boost_vignette : hint_range(0.0, 0.08) = 0.025;

void fragment() {
    vec2 uv = SCREEN_UV;
    vec2 center = uv - vec2(0.5);
    vec3 center_color = texture(screen_texture, uv).rgb;
    vec3 color = center_color;

    // This canvas layer is hidden until ca_amount is nonzero. The boost pass
    // requires only the center image plus two chromatic offset samples.
    if (ca_amount > 0.005) {
        vec2 pixel_size = 1.0 / vec2(textureSize(screen_texture, 0));
        vec2 offset = center * pixel_size * ca_amount * 8.0;
        color = vec3(
            texture(screen_texture, uv + offset).r,
            center_color.g,
            texture(screen_texture, uv - offset).b
        );
        float radius = length(center);
        float vignette_curve = 1.0 - smoothstep(0.32, 0.84, radius);
        color *= mix(1.0 - boost_vignette, 1.0, vignette_curve);
    }
    COLOR = vec4(max(color, vec3(0.0)), 1.0);
}
