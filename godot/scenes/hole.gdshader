shader_type canvas_item;

void fragment() {
    vec2 uv = UV - vec2(0.47);
    float r = length(uv);          // distance from center
    if (r > 0.47) discard;          // outside circle -> invisible
    COLOR = texture(TEXTURE, UV) * COLOR;
}
