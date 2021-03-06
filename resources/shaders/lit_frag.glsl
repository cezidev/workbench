#version 330 core

in vec3 tex_coord;
in vec3 vert_normal;
in vec3 frag_position;
in vec4 vert_color;



struct Material {
    float metallic;
    float roughness;
    float ao;
};

uniform vec3 camera_position;

uniform Material material;

uniform sampler2D texture_handle;
uniform int has_texture_handle;

uniform samplerCube skybox_texture;
uniform int has_skybox_texture;

#define NUM_SHADOW_MAPS 4
uniform sampler2D shadow_maps[NUM_SHADOW_MAPS];

uniform float cascade_distances[NUM_SHADOW_MAPS];
uniform mat4 cascade_light_space_matrices[NUM_SHADOW_MAPS];

#define MAX_LIGHTS 100

uniform vec3  point_light_positions  [MAX_LIGHTS];
uniform vec4  point_light_colors     [MAX_LIGHTS];
uniform float point_light_intensities[MAX_LIGHTS];
uniform int   num_point_lights;

uniform vec3  sun_direction;
uniform vec4  sun_color;
uniform float sun_intensity;

uniform float bloom_threshhold;

uniform int visualize_shadow_cascades;


layout (location=0) out vec4 out_color;
layout (location=1) out vec4 bloom_color;



float calculate_shadow(int shadow_map_idx) {
    vec4 frag_position_light_space = cascade_light_space_matrices[shadow_map_idx] * vec4(frag_position, 1.0);
    vec3 proj_coords = frag_position_light_space.xyz / frag_position_light_space.w; // todo(josh): check for divide by zero?
    proj_coords = proj_coords * 0.5 + 0.5;
    if (proj_coords.z > 1.0) {
        proj_coords.z = 1.0;
    }

    float dot_to_sun = clamp(dot(vert_normal, -sun_direction), 0, 1);
    float bias = max(0.005 * (1.0 - dot_to_sun), 0.005);
    // float bias = 0.005;

#if 0
    float depth = texture(shadow_maps[shadow_map_idx], proj_coords.xy).r;
    float shadow = depth + 0.001 < proj_coords.z ? 1.0 : 0.0;
    return shadow;
#else
    float shadow = 0.0;
    vec2 texel_size = 1.0 / textureSize(shadow_maps[shadow_map_idx], 0);
    for (int x = -2; x <= 2; x += 1) {
        for (int y = -2; y <= 2; y += 1) {
            float pcf_depth = texture(shadow_maps[shadow_map_idx], proj_coords.xy + vec2(x, y) * texel_size).r;
            shadow += pcf_depth + bias < proj_coords.z ? 1.0 : 0.0;
        }
    }
    return shadow / 25.0;
#endif
}

#define PI 3.14159265359

vec3 fresnel_schlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
float distribution_ggx(vec3 N, vec3 H, float roughness) {
    float a      = roughness*roughness;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;

    float num   = a;
    float denom = (NdotH2 * (a - 1.0) + 1.0);
    denom = PI * denom * denom;

    return num / denom;
}

float geometry_schlick_ggx(float NdotV, float roughness) {
    // todo(josh): (roughness + 1) should only be used for analytic light sources, not IBL
    // "if applied to image-based lighting, the results at glancing angles will be much too dark"
    // page 3
    // https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf

#if 1
    float r = (roughness + 1.0);
#else
    float r = roughness;
#endif

    r *= r;

    float k = (r*r) / 8.0;

    float num   = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return num / denom;
}
float geometry_smith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2  = geometry_schlick_ggx(NdotV, roughness);
    float ggx1  = geometry_schlick_ggx(NdotL, roughness);

    return ggx1 * ggx2;
}

vec3 calculate_light(vec3 albedo, float metallic, float roughness, vec3 N, vec3 V, vec3 L, vec3 radiance) {
    vec3 H = normalize(V + L);

    // todo(josh): no need to do this for each light, should be constant for a given draw call
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    // cook-torrance brdf
    float NDF = distribution_ggx(N, H, roughness);
    float G   = geometry_smith(N, V, L, roughness);
    vec3  F   = fresnel_schlick(clamp(dot(H, V), 0.0, 1.0), F0);

    vec3 kS = F;
    vec3 kD = vec3(1.0) - kS;
    kD *= 1.0 - metallic;

    vec3 numerator    = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
    vec3 specular     = numerator / max(denominator, 0.001);

    // add to outgoing radiance Lo
    float NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

void main() {
    vec3 N = normalize(vert_normal);
    vec3 V = normalize(camera_position - frag_position);

    // base color
    vec3 albedo = vert_color.rgb;
    float frag_alpha = vert_color.a;

    // texture color
    if (has_texture_handle == 1) {
        vec4 texture_sample = texture(texture_handle, tex_coord.xy);
        albedo *= texture_sample.rgb;

        // todo(josh): do we need to gamma correct when sampling textures? I assume it depends on how the texture is authored. that sucks.
        // albedo *= pow(texture_sample.rgb, vec3(2.2));

        // todo(josh): handle alpha properly. having a multiply here was giving me weird artifacts
        frag_alpha = texture_sample.a;
    }

    // point lights
    vec3 Lo = vec3(0.0);
    for (int i = 0; i < num_point_lights; i++) {
        vec3  light_position  = point_light_positions  [i];
        vec3  light_color     = point_light_colors     [i].rgb;
        float light_intensity = point_light_intensities[i];

        vec3 L = normalize(light_position - frag_position);

        float distance    = length(light_position - frag_position);
        float attenuation = 1.0 / (distance * distance);
        vec3 radiance     = light_color * attenuation * light_intensity;

        Lo += calculate_light(albedo, material.metallic, material.roughness, N, V, L, radiance);
    }

    // shadow color
    float dist = length(camera_position - frag_position);
    float shadow = 0;
    int shadow_map_index = 0;
    for (int cascade_idx = 0; cascade_idx < NUM_SHADOW_MAPS; cascade_idx++) {
        if (dist < cascade_distances[cascade_idx]) {
            shadow = 1.0 - calculate_shadow(cascade_idx);
            shadow_map_index = cascade_idx;
            break;
        }
    }

    // sun
    vec3 sun_color = calculate_light(albedo, material.metallic, material.roughness, N, V, -normalize(sun_direction), sun_color.rgb * sun_intensity);
    sun_color *= shadow;
    Lo += sun_color;

    // skybox light
    // todo(josh): real IBL
    if (has_skybox_texture == 1) {
        vec3 reflected_direction = normalize(reflect(-V, N));
        vec3 skybox_color = pow(texture(skybox_texture, reflected_direction).rgb, vec3(2.2)); // todo(josh): should we normalize tex_coord here?
        Lo += calculate_light(albedo, material.metallic, material.roughness, N, V, reflected_direction, skybox_color);
    }



    // todo(josh): why the 0.03? is that just a hardcoded ambient that we should remove?
    vec3 ambient = vec3(0.03) * albedo * material.ao;
    // todo(josh): ask jake why he changed this
    // vec3 color = albedo + ambient + Lo;
    vec3 color = ambient + Lo;

    out_color = vec4(color.rgb, frag_alpha);

    if (visualize_shadow_cascades == 1) {
        if (shadow_map_index == 0) {
            out_color.rgb += vec3(0.2, 0, 0);
        }
        else if (shadow_map_index == 1) {
            out_color.rgb += vec3(0, 0.2, 0);
        }
        else if (shadow_map_index == 2) {
            out_color.rgb += vec3(0, 0, 0.2);
        }
        else if (shadow_map_index == 3) {
            out_color.rgb += vec3(0.2, 0.2, 0);
        }
    }

    // bloom color
    float brightness = dot(out_color.rgb, vec3(1, 1, 1)); // todo(josh): make configurable?
    if (brightness > bloom_threshhold) {
        bloom_color = vec4(out_color.rgb * ((brightness / bloom_threshhold) - 1), 1.0);
    }
    else {
        bloom_color = vec4(0.0, 0.0, 0.0, 1.0);
    }
}
