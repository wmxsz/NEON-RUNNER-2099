shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Cybernetic race-deck: layered carbon-ceramic plates, machined seams, etched
// data conduits, polished inlays and animated energy guidance. RGB stores the
// deck material; alpha stores linear roughness. Cyan/magenta lines are authored as energy systems.
uniform sampler2D road_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 grid_color : source_color = vec3(0.0, 0.94, 1.0);
uniform vec3 bg_color : source_color = vec3(0.025, 0.035, 0.075);
uniform float scroll : hint_range(0.0, 100.0) = 0.0;
uniform float road_cycle_length : hint_range(20.0, 100.0) = 42.0;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.56;
uniform float grid_strength : hint_range(0.0, 1.2) = 0.90;

// Screen-space derivative-aware coverage keeps thin etched circuitry from flickering
// into broken dots at distance, without texture lookups or resolution reduction.
float cyber_line_coverage(float distance_to_line, float half_width) {
    float aa_width = max(fwidth(distance_to_line), 0.00045);
    float edge_coverage = 1.0 - smoothstep(max(0.0, half_width - aa_width), half_width + aa_width, distance_to_line);
    // Once the line is thinner than a pixel, fade by its approximate screen coverage;
    // this prevents the rail from blinking at full strength as it crosses pixel centers.
    float subpixel_coverage = clamp(half_width / max(aa_width, half_width), 0.0, 1.0);
    return edge_coverage * subpixel_coverage;
}

void fragment() {
    vec2 uv = UV;
    // One authored tile is a structural module; three across the track and forty
    // along it give a readable scale without stretching micro-detail at phone size.
    vec2 deck_uv = uv * vec2(3.0, 40.0) + vec2(0.0, scroll / (road_cycle_length / 4.0));
    vec4 deck_sample = texture(road_albedo_tex, deck_uv);
    vec3 normal_sample = texture(road_normal_tex, deck_uv).rgb;
    float rough_sample = deck_sample.a;

    // Panel sub-cell coordinates drive detail/energy, while surface relief comes from PBR.
    vec2 module_uv = fract(deck_uv);
    float panel_v = fract(deck_uv.y * 4.0);
    float panel_edge = min(min(module_uv.x, 1.0 - module_uv.x), min(panel_v, 1.0 - panel_v));
    float panel_joint = cyber_line_coverage(panel_edge, 0.008);

    // Recessed circuit conduits are inset from the module edge and broken into
    // machine-readable segments. They brighten with the chapter's current energy hue.
    float bus_distance = min(abs(module_uv.x - 0.135), abs(module_uv.x - 0.865));
    float bus_line = cyber_line_coverage(bus_distance, 0.00465);
    float bus_segment = smoothstep(0.085, 0.14, panel_v) * (1.0 - smoothstep(0.80, 0.86, panel_v));
    float segment_id = floor(deck_uv.y * 4.0);
    float segment_enable = step(0.15, fract(segment_id * 0.6180339 + 0.23));
    float branch_distance = min(abs(panel_v - 0.20), min(abs(panel_v - 0.52), abs(panel_v - 0.75)));
    float branch_line = cyber_line_coverage(branch_distance, 0.00465);
    float branch_left = smoothstep(0.12, 0.17, module_uv.x) * (1.0 - smoothstep(0.19, 0.25, module_uv.x));
    float branch_right = smoothstep(0.75, 0.81, module_uv.x) * (1.0 - smoothstep(0.83, 0.89, module_uv.x));
    float circuit_trace = clamp(bus_line * bus_segment * segment_enable + branch_line * (branch_left + branch_right), 0.0, 1.0);

    // Slim triple guide rails identify playable lanes; side colors subtly split the silhouette.
    float left_lane_distance = abs(uv.x - 0.375);
    float right_lane_distance = abs(uv.x - 0.625);
    float left_lane_line = cyber_line_coverage(left_lane_distance, 0.00465);
    float right_lane_line = cyber_line_coverage(right_lane_distance, 0.00465);
    float lane_line = max(left_lane_line, right_lane_line);
    float left_edge_line = cyber_line_coverage(uv.x, 0.00775);
    float right_edge_line = cyber_line_coverage(1.0 - uv.x, 0.00775);
    float edge_line = max(left_edge_line, right_edge_line);
    float center_distance = abs(uv.x - 0.5);
    float center_rail = cyber_line_coverage(center_distance, 0.00325);

    // A traveling sync bar and short center ticks make the deck feel like a live data runway.
    float sync_phase = fract(uv.y * 10.0 + scroll / road_cycle_length * 10.0);
    float sync_bar = cyber_line_coverage(abs(sync_phase - 0.5), 0.013);
    float tick_phase = fract(deck_uv.y * 0.25);
    float data_tick = (cyber_line_coverage(abs(tick_phase - 0.5), 0.018))
        * (1.0 - smoothstep(0.012, 0.035, center_distance)) * 0.60;

    // Selective mirror-polished inlays have lower roughness and stronger specular response;
    // surrounding ceramic remains tactile instead of becoming a flat reflective mirror.
    float polished_inlay = clamp(max(circuit_trace * 0.72, max(lane_line, edge_line * 0.8)), 0.0, 1.0);
    float smooth_patch = 1.0 - smoothstep(0.36, 0.70, rough_sample);
    float polished_sheen = clamp(smooth_patch * 0.42 + lane_line * 0.68 + edge_line * 0.22, 0.0, 1.0);

    // Far-distance blending controls detail contrast, not render resolution or AA.
    float far_fade = clamp((uv.y - 0.64) * 2.7, 0.0, 1.0);
    vec3 base = deck_sample.rgb;
    base = mix(base, bg_color * 0.40, panel_joint * 0.38);
    base += grid_color * circuit_trace * 0.20;
    vec3 accent_color = mix(vec3(1.0, 0.055, 0.34), grid_color, 0.42);
    float accent_selector = step(0.63, fract(segment_id * 0.381966 + 0.11));
    base += grid_color * (left_lane_line * 0.30 + left_edge_line * 0.18) * grid_strength;
    base += accent_color * (right_lane_line * 0.27 + right_edge_line * 0.16) * grid_strength;
    base += grid_color * (sync_bar * 0.18 + data_tick * 0.12) * grid_strength;
    base += mix(grid_color, accent_color, accent_selector * 0.42) * bus_line * bus_segment * 0.14;
    ALBEDO = mix(base, bg_color + grid_color * 0.10, far_fade * 0.82);

    NORMAL_MAP = normal_sample;
    NORMAL_MAP_DEPTH = normal_strength;
    ROUGHNESS = clamp(mix(rough_sample, 0.23, max(polished_sheen * 0.62, polished_inlay * 0.58)), 0.20, 0.94);
    // The carbon-ceramic faces retain a diffuse component; only polished energy inlays
    // approach full metallic response, avoiding an almost-black all-metal road deck.
    METALLIC = mix(0.48, 0.82, polished_inlay);
    SPECULAR = mix(0.50, 0.84, max(polished_sheen, polished_inlay * 0.82));
    EMISSION = (
        grid_color * (left_lane_line * 1.02 + left_edge_line * 0.82 + sync_bar * 1.16 + data_tick * 0.58)
        + accent_color * (right_lane_line * 0.90 + right_edge_line * 0.74)
        + mix(grid_color, accent_color, accent_selector * 0.42) * circuit_trace * 0.92
        + center_rail * grid_color * 0.28
    ) * (1.0 - far_fade * 0.84) * grid_strength;
}
