shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.043, 0.043, 0.13);
uniform vec3 window_color : source_color = vec3(1.0, 0.85, 0.63);
uniform vec3 neon_color : source_color = vec3(0.0, 0.94, 1.0);
uniform float time_ = 0.0;
uniform float window_density : hint_range(0.5, 2.0) = 1.0;

// v3.0.2 兼容修复：INSTANCE_CUSTOM 在 fragment 直读在部分渲染路径编译失败
// （headless 实验复现）——改 vertex 读取经 varying 传递，语义等效且兼容面最宽。
varying vec4 v_facade;

void vertex() {
    v_facade = INSTANCE_CUSTOM;
}

float hash(vec2 p) {
    // Polynomial hash avoids a sine per lookup; the facade shader calls hash many
    // times per pixel, so this is friendlier to mobile GPUs while keeping variation.
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
    vec2 uv = UV;
    // INSTANCE_CUSTOM is populated per MultiMesh instance: R=seed, G=warmth,
    // B=contrast and A=density. This prevents dozens of towers repeating the same atlas-like facade.
    vec4 facade = v_facade;
    float facade_seed = facade.r;
    float facade_warmth = facade.g;
    float facade_contrast = mix(0.78, 1.18, facade.b);
    float density_scale = mix(0.84, 1.16, facade.a);
    // More, smaller windows at close range, with stable anti-aliased transitions at distance.
    float uv_footprint = max(fwidth(uv.x), fwidth(uv.y));
    float detail = 1.0 - smoothstep(0.004, 0.028, uv_footprint);
    vec2 grid = mix(vec2(5.0, 10.0), vec2(12.0, 24.0), detail) * window_density * density_scale;
    vec2 raw_cell = uv * grid;
    vec2 cell = fract(raw_cell);
    vec2 cell_id = floor(raw_cell) + vec2(facade_seed * 127.0, facade_seed * 53.0 + facade_warmth * 79.0);
    vec2 aa = max(fwidth(raw_cell), vec2(0.018));
    float inset_x = max(0.075, aa.x * 0.7);
    float inset_y = max(0.075, aa.y * 0.7);
    float inside_x = smoothstep(inset_x, inset_x + aa.x, cell.x) * (1.0 - smoothstep(1.0 - inset_x - aa.x, 1.0 - inset_x, cell.x));
    float inside_y = smoothstep(inset_y, inset_y + aa.y, cell.y) * (1.0 - smoothstep(1.0 - inset_y - aa.y, 1.0 - inset_y, cell.y));
    float win_mask = inside_x * inside_y;
    float outer_inset_x = max(0.025, aa.x * 0.45);
    float outer_inset_y = max(0.025, aa.y * 0.45);
    float outer_x = smoothstep(outer_inset_x, outer_inset_x + aa.x, cell.x) * (1.0 - smoothstep(1.0 - outer_inset_x - aa.x, 1.0 - outer_inset_x, cell.x));
    float outer_y = smoothstep(outer_inset_y, outer_inset_y + aa.y, cell.y) * (1.0 - smoothstep(1.0 - outer_inset_y - aa.y, 1.0 - outer_inset_y, cell.y));
    float window_frame = max(outer_x * outer_y - win_mask, 0.0);
    float lit_threshold = clamp(0.48 + (facade_warmth - 0.5) * 0.18, 0.34, 0.61);
    // NORMAL is coherent across a tower face. Compute window flicker/hash work only
    // on visible side faces with enough screen-space detail; roofs and distant facades
    // keep their structural shading without paying for pane animation that is not seen.
    float side = 1.0 - step(0.5, NORMAL.y);
    float cell_random = 0.5;
    float cell_variation = 0.5;
    float lit = 0.0;
    float flicker = 1.0;
    float occasional_glitch = 0.0;
    if (side > 0.5 && detail > 0.025) {
        // Two stable random values drive light state, flicker, tint and glitch behavior.
        cell_random = hash(cell_id);
        cell_variation = hash(cell_id + vec2(9.2, 2.3));
        lit = step(lit_threshold, cell_random);
        float flicker_phase = time_ * (0.65 + cell_variation * 1.4) + cell_random * 6.283;
        flicker = 0.88 + 0.12 * sin(flicker_phase);
        float glitch_seed = fract(cell_random * 17.17 + cell_variation * 31.7 + floor(time_ * 4.0) * 0.618);
        occasional_glitch = step(0.985, glitch_seed) * 0.65;
    }

    vec3 wall = base_color;
    // Dark beveled gasket and layered signal-rails give the tower skin a manufactured cybernetic language.
    wall += vec3(0.012, 0.019, 0.034) * window_frame * side;
    // Vertical architectural ribs and horizontal slab breaks add scale to each tower.
    float vertical_rib = 1.0 - smoothstep(0.014, 0.035, abs(fract(uv.x * 4.0) - 0.5));
    float floor_band = 1.0 - smoothstep(0.008, 0.02, abs(fract(uv.y * 8.0) - 0.02));
    // Reuse the pane variation for subtle facade mottle instead of a fourth random hash.
    // This preserves low-contrast surface variation while lowering hot-fragment ALU.
    wall *= mix(0.82, 1.0, cell_variation) * facade_contrast;
    wall += vec3(0.018, 0.024, 0.042) * vertical_rib * side;
    wall += vec3(0.035, 0.045, 0.075) * floor_band * side;
    // Thin segmented power conduits sit between facade bays. They use existing
    // per-instance seed/variation data, so no extra hash, texture read or node is added.
    float spine_distance = abs(fract(uv.x * 7.0 + facade_seed * 0.173) - 0.5);
    float spine_line = 1.0 - smoothstep(0.008, 0.024, spine_distance);
    float spine_segment_id = floor(uv.y * 36.0);
    float spine_segment = step(0.43, fract(spine_segment_id * 0.6180339 + facade_seed * 7.13 + facade_warmth));
    float spine_mask = spine_line * spine_segment * side * detail;
    float crown_trace = (1.0 - smoothstep(0.006, 0.022, abs(fract(uv.y * 16.0) - 0.5))) * side * detail;
    vec3 spine_color = mix(neon_color, vec3(1.0, 0.075, 0.39), step(0.57, cell_variation));
    wall += spine_color * spine_mask * 0.16;
    wall *= mix(1.0, 0.42, step(0.5, NORMAL.y));

    float local_tint = clamp(cell_variation * 0.24 + facade_warmth * 0.23, 0.0, 0.52);
    vec3 warm_tint = mix(window_color, vec3(1.0, 0.63, 0.34), facade_warmth * 0.18);
    vec3 window_tint = mix(warm_tint, neon_color, local_tint);
    float glass_glint = smoothstep(0.08, 0.25, cell.x) * (1.0 - smoothstep(0.27, 0.43, cell.x));
    vec3 windows = window_tint * win_mask * lit * flicker * (1.0 - occasional_glitch);
    windows += vec3(0.18, 0.23, 0.30) * glass_glint * win_mask * lit * 0.14;

    // Narrow signage bands are sparse; skip their hash/sine path for roofs and
    // sub-pixel distant facades. The band pattern remains deterministic per tower row.
    vec3 signage = vec3(0.0);
    if (side > 0.5 && detail > 0.05) {
        float band_phase = uv.y * 24.0;
        float band_row = floor(band_phase);
        float band_fraction = fract(band_phase);
        float sign_random = hash(vec2(band_row, floor(uv.x * 3.0) + 7.7));
        float has_sign = step(0.84, sign_random);
        float band_shape = smoothstep(0.12, 0.2, band_fraction) * (1.0 - smoothstep(0.27, 0.34, band_fraction));
        float sign_pulse = 0.84 + 0.16 * sin(time_ * 1.6 + band_row * 0.91);
        vec3 sign_tint = mix(neon_color, vec3(1.0, 0.12, 0.42), sign_random);
        signage = sign_tint * band_shape * has_sign * sign_pulse * detail;
    }

    float roof_edge = step(0.5, NORMAL.y) * (1.0 - smoothstep(0.025, 0.085, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y))));
    ALBEDO = wall + windows * 0.38;
    EMISSION = windows * 0.86 + signage * 1.3 + neon_color * roof_edge * 1.15
        + spine_color * spine_mask * 0.52 + neon_color * crown_trace * 0.10;
    ROUGHNESS = mix(0.72, 0.42, max(max(windows.r, windows.g), windows.b));
    METALLIC = 0.22;
}
