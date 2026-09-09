// Conservative Forward+ light binning. One invocation owns one cluster, so the
// fixed-stride output needs no allocator and overflow is deterministic.
struct Light
{
    float4 direction;
    float4 color;
    float4 area_right;
    float4 area_up;
    uint4 meta;
};

struct ClusterPush
{
    Light* lights;
    uint* counts;
    uint* indices;
    uint* overflow;
    float4x4 view_projection;
    uint light_count;
    float4 camera_near;
    float far_plane;
};
[vk_push_constant] const ClusterPush push;

[numthreads(64, 1, 1)]
[shader("compute")]
void computeMain(uint3 tid : SV_DispatchThreadID)
{
    const uint3 grid = uint3(16, 9, 24);
    const uint capacity = 64;
    uint clusterCount = grid.x * grid.y * grid.z;
    uint cluster = tid.x;
    if (cluster >= clusterCount) return;

    uint x = cluster % grid.x;
    uint y = (cluster / grid.x) % grid.y;
    uint z = cluster / (grid.x * grid.y);
    float2 lo = float2((float)x / grid.x, (float)y / grid.y) * 2.0 - 1.0;
    float2 hi = float2((float)(x + 1) / grid.x, (float)(y + 1) / grid.y) * 2.0 - 1.0;
    // Fragment rows increase down the framebuffer, while the geometry viewport's
    // negative height puts clip-space +Y at its top.
    lo.y = 1.0 - 2.0 * (float)(y + 1) / grid.y;
    hi.y = 1.0 - 2.0 * (float)y / grid.y;
    float zlo = push.camera_near.w * pow(push.far_plane / push.camera_near.w, (float)z / grid.z);
    float zhi = push.camera_near.w * pow(push.far_plane / push.camera_near.w, (float)(z + 1) / grid.z);

    uint written = 0;
    for (uint i = 1; i < push.light_count; ++i)
    {
        Light light = push.lights[i];
        if (light.meta.z == 0u) continue; // directional lights are global
        float radius = light.direction.w;
        if (light.meta.z == 2u || light.meta.z == 3u)
            radius += length(light.area_right.xyz * light.area_right.w)
                + length(light.area_up.xyz * light.area_up.w);
        float4 r0 = push.view_projection[0], r1 = push.view_projection[1];
        float4 r2 = push.view_projection[2], r3 = push.view_projection[3];
        float4 planes[4] = { r0 - lo.x*r3, hi.x*r3 - r0, r1 - lo.y*r3, hi.y*r3 - r1 };
        float4 world = float4(light.direction.xyz, 1.0);
        bool overlap = true;
        for (uint p = 0; p < 4; ++p)
            overlap = overlap && dot(planes[p], world) >= -radius * length(planes[p].xyz);
        float cameraDistance = distance(light.direction.xyz, push.camera_near.xyz);
        overlap = overlap && cameraDistance + radius >= zlo && cameraDistance - radius <= zhi;
        if (!overlap) continue;
        if (written < capacity)
            push.indices[cluster * capacity + written++] = i;
        else {
            InterlockedAdd(push.overflow[0], 1u);
            written |= 0x80000000u;
        }
    }
    push.counts[cluster] = written;
}
