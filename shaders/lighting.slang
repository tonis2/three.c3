// Shared clustered and finite-emitter maths. Spliced after the fragment globals
// in both shading templates.
uint shared_fragment_cluster(FrameBlock* frame, float4 screenPosition, float3 position)
{
    uint3 grid=frame[0].cluster_grid.xyz;
    float2 extent=max(frame[0].cluster_screen.xy,float2(1.0));
    uint x=min((uint)(screenPosition.x*grid.x/extent.x),grid.x-1u);
    uint y=min((uint)(screenPosition.y*grid.y/extent.y),grid.y-1u);
    float nearPlane=frame[0].cluster_screen.z,farPlane=frame[0].cluster_screen.w;
    float depth=max(distance(position,frame[0].camera.xyz),nearPlane);
    uint z=min((uint)(saturate(log(depth/nearPlane)/log(farPlane/nearPlane))*grid.z),grid.z-1u);
    return x+grid.x*(y+grid.y*z);
}

float shared_spot_reach(Light light,float3 toward)
{
    return smoothstep(light.area_right.w,light.area_up.w,dot(normalize(light.area_right.xyz),-toward));
}

// The range window, and zero wherever the integral cannot be anything else: the
// point is behind the emitter plane, or the whole emitter is behind the surface.
// Every sample shares the sign of `dot(emitter,-l)`, and the extent bound is the
// furthest a sample can reach along the surface normal.
float shared_area_window(Light light,float3 position,float3 normal,float3 right,float3 up,float3 emitter)
{
    float3 toward=light.direction.xyz-position;
    if(dot(emitter,-toward)<=0.0)return 0.0;
    if(dot(normal,toward)+abs(dot(normal,right))*light.area_right.w+abs(dot(normal,up))*light.area_up.w<=0.0)return 0.0;
    float cd=distance(light.direction.xyz,position)/max(light.direction.w,1e-4);
    return saturate(1.0-cd*cd*cd*cd);
}

float shared_area_diffuse(Light light,float3 position,float3 normal)
{
    float3 right=normalize(light.area_right.xyz),up=normalize(light.area_up.xyz);
    float3 emitter=-normalize(cross(right,up));float sum=0.0;uint samples=0u;
    float window=shared_area_window(light,position,normal,right,up,emitter);if(window<=0.0)return 0.0;
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;
        if(light.meta.z==3u&&dot(q,q)>1.0)continue;float3 p=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w;
        float3 ray=p-position;float d2=max(dot(ray,ray),1e-6);float3 toward=ray*rsqrt(d2);
        sum+=max(dot(normal,toward),0.0)*max(dot(emitter,-toward),0.0)/d2;samples++;}
    return light.color.w*sum*window*window/(3.14159265*3.14159265*max(samples,1u));
}

struct SharedAreaTerms
{
    float diffuse;
    float3 specular;
};

// Both lobes for built-in shading. Custom lambert and specular calls keep the
// single-lobe helpers above and below, so they only calculate what was asked for.
SharedAreaTerms shared_area_terms(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
{
    float3 right=normalize(light.area_right.xyz),up=normalize(light.area_up.xyz),emitter=-normalize(cross(right,up));
    float diffuse=0.0;float3 specular=0.0;uint samples=0u;
    SharedAreaTerms terms;terms.diffuse=0.0;terms.specular=float3(0.0);
    float window=shared_area_window(light,position,normal,right,up,emitter);if(window<=0.0)return terms;
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;if(light.meta.z==3u&&dot(q,q)>1.0)continue;
        float3 ray=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w-position;float d2=max(dot(ray,ray),1e-6);float3 l=ray*rsqrt(d2);
        float nl=max(dot(normal,l),0.0),el=max(dot(emitter,-l),0.0);diffuse+=nl*el/d2;samples++;if(nl<=0.0||el<=0.0)continue;
        float3 h=normalize(l+view);float nh=max(dot(normal,h),0.0),vh=max(dot(view,h),0.0);
        float den=nh*nh*(a2-1.0)+1.0,D=a2/(3.14159265*den*den),G=(nl/(nl*(1.0-k)+k))*(nv/(nv*(1.0-k)+k));float3 F=f0+(float3(f90)-f0)*pow(1.0-vh,5.0);
        specular+=el/d2*D*G*F/(4.0*nv);}
    float scale=light.color.w*window*window/max(samples,1u);
    terms.diffuse=diffuse*scale/(3.14159265*3.14159265);
    terms.specular=light.color.rgb*specular*scale/3.14159265;
    return terms;
}

bool shared_cluster_contains(FrameBlock* frame,uint cluster,uint lightIndex)
{
    uint packed=frame[0].cluster_grid.w==0u?0x80000000u:frame[0].cluster_counts[cluster];
    if((packed&0x80000000u)!=0u)return true;
    for(uint k=0u;k<packed;++k)if(frame[0].cluster_indices[cluster*frame[0].cluster_grid.w+k]==lightIndex)return true;
    return false;
}

float3 shared_area_specular(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
{
    float3 right=normalize(light.area_right.xyz),up=normalize(light.area_up.xyz),emitter=-normalize(cross(right,up)),sum=0.0;uint samples=0u;
    float window=shared_area_window(light,position,normal,right,up,emitter);if(window<=0.0)return float3(0.0);
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;if(light.meta.z==3u&&dot(q,q)>1.0)continue;
        float3 ray=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w-position;float d2=max(dot(ray,ray),1e-6);float3 l=ray*rsqrt(d2);
        float nl=max(dot(normal,l),0.0),el=max(dot(emitter,-l),0.0);samples++;if(nl<=0.0||el<=0.0)continue;float3 h=normalize(l+view);float nh=max(dot(normal,h),0.0),vh=max(dot(view,h),0.0);
        float den=nh*nh*(a2-1.0)+1.0,D=a2/(3.14159265*den*den),G=(nl/(nl*(1.0-k)+k))*(nv/(nv*(1.0-k)+k));float3 F=f0+(float3(f90)-f0)*pow(1.0-vh,5.0);
        sum+=el/d2*D*G*F/(4.0*nv);}
    return light.color.rgb*light.color.w*sum*window*window/(3.14159265*max(samples,1u));
}

// How much of the light reaches this point: 1 fully lit, 0 fully shadowed.
//
// Shared rather than copied into both templates: `mesh.slang` and
// `material.slang` splice this file in, so the built-in shading and a material's
// own body land in the same shadow by construction.
//
// ## The four early exits, and why each one answers "lit"
//
//  - **`params.w <= 0`** — no shadow pass ran this frame, or a script set the
//    intensity to zero. The map is the 1x1 blank and the taps below would all
//    answer the same thing; this is the branch that does not pay for them.
//  - **`ndc.z` outside [0, 1]** — the point is nearer the light than the fitted
//    box, or beyond it. Nothing was rendered there to occlude it.
//  - **`uv` outside the map** — the point is off to the side of the fitted box.
//    The sampler clamps to the edge, so **without this test a surface outside the
//    map would inherit the shadow of whatever sits on the nearest edge of it**,
//    smeared out to the horizon. That is the classic failure and it looks like a
//    bug in the geometry rather than in the lookup.
//
// The first is a branch this shader takes on every fragment of every frame that
// has no shadows, and the other three are the boundary of the one map. All four
// answer "lit" because a shadow map only ever knows about occluders it was shown,
// and an unlit default would darken everything it was not shown.
//
// ## The bias is two numbers and they do different jobs
//
// `params.z` moves the *sample point* along the surface normal before projecting
// it, in world units, which is what fixes acne on a surface nearly edge-on to the
// light: the point being asked about is lifted off the surface it is on, so its
// own depth stops competing with the texel that recorded it. It is derived from
// the fitted extent in `render/shadow.c3`, so it scales with the scene and there
// is no world size at which it is the wrong magnitude.
//
// `params.y` moves the *comparison* instead, in ndc depth units, and it is the
// one a script can set. Zero by default: the normal offset does the work, and a
// depth bias large enough to matter on its own is a shadow visibly detached from
// its caster.
float shadow_view_factor_filtered(uint index, float3 position, float3 normal, float filter_radius)
{
    if (index == 0xffffffffu) return 1.0;
    ShadowGpuView view = push.frame[0].shadow_views[index];
    if (view.params.w <= 0.0) return 1.0;
    // The projection's four columns, read rather than multiplied for: a `mul` by
    // a basis vector *is* a column, the normal offset is one add on the clip
    // position, and the receiver plane below is solved from the same three.
    float4x4 vp = view.view_projection;
    float4 cx = float4(vp[0][0], vp[1][0], vp[2][0], vp[3][0]);
    float4 cy = float4(vp[0][1], vp[1][1], vp[2][1], vp[3][1]);
    float4 cz = float4(vp[0][2], vp[1][2], vp[2][2], vp[3][2]);
    float4 clip = cx * position.x + cy * position.y + cz * position.z
        + float4(vp[0][3], vp[1][3], vp[2][3], vp[3][3]);
    if (clip.w <= 0.0) return 1.0;
    if (view.params.z != 0.0)
    {
        float distance = view.params.z;
        if (distance < 0.0)
        {
            // Convert receiver texels to world units at this exact perspective
            // depth. This keeps the offset useful far from a local light without
            // making it enormous close to the light.
            float2 ndc = clip.xy / clip.w;
            float invW = 1.0 / clip.w;
            float2 sx = (cx.xy - ndc * cx.w) * invW;
            float2 sy = (cy.xy - ndc * cy.w) * invW;
            float2 sz = (cz.xy - ndc * cz.w) * invW;
            float ndc_per_world = sqrt(max(max(dot(sx, sx), dot(sy, sy)), dot(sz, sz)));
            distance = (-view.params.z) * (2.0 * view.params.x) / max(ndc_per_world, 1e-6);
        }
        clip += distance * (cx * normal.x + cy * normal.y + cz * normal.z);
        if (clip.w <= 0.0) return 1.0;
    }
    float3 ndc = clip.xyz / clip.w;
    float2 local = float2(0.5 + 0.5 * ndc.x, 0.5 - 0.5 * ndc.y);
    if (ndc.z < 0.0 || ndc.z > 1.0 || any(local < 0.0) || any(local > 1.0)) return 1.0;
    float2 step = view.params.x * view.atlas.xy;
    float2 uv = local * view.atlas.xy + view.atlas.zw;
    // Half a texel in from the tile, so a bilinear tap never reaches a
    // neighbouring view's depth.
    float2 lo = view.atlas.zw + step * 0.5;
    float2 hi = view.atlas.zw + view.atlas.xy - step * 0.5;
    // The receiver plane's depth slope in ndc, so the depth of this same plane is
    // known at every tap without fragment derivatives inside a light-dependent
    // branch. The projection's derivative here has the three columns above for
    // its own columns; its cofactor carries the receiver normal into ndc, and a
    // plane's slope is minus that normal's xy over its z. Algebraically the same
    // number the two projected tangents used to solve for, and the same guard.
    float invW = 1.0 / clip.w;
    float3 jx = (cx.xyz - ndc * cx.w) * invW;
    float3 jy = (cy.xyz - ndc * cy.w) * invW;
    float3 jz = (cz.xyz - ndc * cz.w) * invW;
    float3 planeNdc = cross(jy, jz) * normal.x + cross(jz, jx) * normal.y + cross(jx, jy) * normal.z;
    float2 depthGradient = abs(planeNdc.z) > 1e-8 ? -planeNdc.xy / planeNdc.z : float2(0.0);
    // A tap's four texels sit half a texel either side of the point the plane is
    // read at, so the plane may drop this much under one of them. Without the
    // slack the receiver shadows itself.
    float texelNdc = view.params.x * 2.0;
    float slope = 0.5 * (abs(depthGradient.x) + abs(depthGradient.y)) * texelNdc;
    // Four taps of the comparison sampler, each one four texel comparisons
    // weighted in the texture unit: a texel out covers what the nine manual taps
    // covered, and the wide case keeps the disc of the sixteen.
    const float2 quad[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    float spread = filter_radius > 1.0 ? filter_radius * 0.6 : 1.0;
    float lit = 0.0;
    for (int i = 0; i < 4; i++)
    {
        float2 tap = quad[i] * spread;
        // Clamped as the sample below is, then snapped to the middle of the four
        // texels that tap weighs, so `slope` bounds the plane error at each.
        float2 tapLocal = clamp(local + tap * view.params.x, view.params.x * 0.5, 1.0 - view.params.x * 0.5);
        float2 footprint = (floor(tapLocal / view.params.x - 0.5) + 1.0) * view.params.x;
        float2 tapNdc = (footprint - local) * float2(2.0, -2.0);
        float reference = ndc.z + dot(depthGradient, tapNdc) - view.params.y - slope;
        lit += shadow_atlas_compare.SampleCmpLevelZero(clamp(uv + tap * step, lo, hi), reference);
    }
    return lerp(1.0, lit * 0.25, view.params.w);
}

float shared_point_shadow_factor(uint index,Light light,float3 position,float3 normal)
{
    uint view=light.meta.y;
    if(view==0xffffffffu)return 1.0;
    if(light.meta.z==1u)
    {
        float3 ray=position-light.direction.xyz;
        float3 a=abs(ray);
        uint face;
        if(a.x>=a.y&&a.x>=a.z)face=ray.x>=0.0?0u:1u;
        else if(a.y>=a.z)face=ray.y>=0.0?2u:3u;
        else face=ray.z>=0.0?4u:5u;
        view+=face;
    }
    if(light.meta.z==2u||light.meta.z==3u)
    {
        // The representative area view cannot reproduce a physical penumbra,
        // but its filter footprint follows the emitter's apparent size.
        float halfExtent=max(light.area_right.w,light.area_up.w);
        float receiverDistance=max(distance(position,light.direction.xyz),1e-4);
        float texel=push.frame[0].shadow_views[view].params.x;
        float radius=clamp(halfExtent/(receiverDistance*7.4641016*texel),1.0,6.0);
        return shadow_view_factor_filtered(view,position,normal,radius);
    }
    return shadow_view_factor(view,position,normal);
}

struct SharedLightTerms
{
    float3 diffuse;
    float3 specular;
};

float3 shared_punctual_specular(float3 normal,float3 view,float3 toward,float nl,float3 f0,float f90,float a2,float k,float nv)
{
    float3 h=normalize(toward+view);
    float nh=max(dot(normal,h),0.0),vh=max(dot(view,h),0.0);
    float den=nh*nh*(a2-1.0)+1.0;
    float D=a2/(3.14159265*den*den);
    float G=(nl/(nl*(1.0-k)+k))*(nv/(nv*(1.0-k)+k));
    float3 F=f0+(float3(f90)-f0)*pow(1.0-vh,5.0);
    return D*G*F/(4.0*nv);
}

// Standard shading walks every contributing light once. Visibility is a local
// value so diffuse and specular share it without a per-light temporary array.
SharedLightTerms shared_standard_lights(FrameBlock* frame,float4 screenPosition,float3 normal,float3 receiverNormal,float3 position,float3 albedo,float roughness,float metalness,float reflectance,float sunVisibility)
{
    float3 view=normalize(frame[0].camera.xyz-position);
    float3 f0=lerp(float3(0.16*reflectance*reflectance),albedo,metalness);
    float f90=clamp(dot(f0,float3(16.5)),0.0,1.0);
    float a=max(roughness*roughness,1e-3),a2=a*a,nv=max(dot(normal,view),1e-4),k=a*0.5;
    SharedLightTerms terms;terms.diffuse=0.0;terms.specular=0.0;
    uint count=(uint)frame[0].lighting.y;
    for(uint i=0u;i<count;++i)
    {
        Light light=frame[0].lights[i];if(light.meta.z!=0u)continue;
        float reach;float3 toward=light_toward(light.direction,position,reach);
        float nl=max(dot(normal,toward),0.0);if(nl*reach<=0.0)continue;
        float visibility=i==0u?sunVisibility:shared_point_shadow_factor(i,light,position,receiverNormal);
        float3 energy=light.color.rgb*light.color.w*reach*visibility;
        terms.diffuse+=energy*nl;
        terms.specular+=energy*shared_punctual_specular(normal,view,toward,nl,f0,f90,a2,k,nv);
    }
    uint cluster=shared_fragment_cluster(frame,screenPosition,position);
    uint packed=frame[0].cluster_grid.w==0u?0x80000000u:frame[0].cluster_counts[cluster];
    bool overflow=(packed&0x80000000u)!=0u;uint localCount=overflow?count:packed;
    for(uint kLocal=0u;kLocal<localCount;++kLocal)
    {
        uint i=overflow?kLocal:frame[0].cluster_indices[cluster*frame[0].cluster_grid.w+kLocal];
        Light light=frame[0].lights[i];
        if(light.meta.z==2u||light.meta.z==3u)
        {
            SharedAreaTerms area=shared_area_terms(light,position,normal,view,f0,f90,a2,k,nv);
            if(area.diffuse<=0.0&&dot(area.specular,float3(1.0))<=0.0)continue;
            float visibility=shared_point_shadow_factor(i,light,position,receiverNormal);
            terms.diffuse+=light.color.rgb*area.diffuse*visibility;
            terms.specular+=area.specular*visibility;
            continue;
        }
        if(light.meta.z!=1u&&light.meta.z!=4u)continue;
        float reach;float3 toward=light_toward(light.direction,position,reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,toward);
        float nl=max(dot(normal,toward),0.0);if(nl*reach<=0.0)continue;
        float visibility=shared_point_shadow_factor(i,light,position,receiverNormal);
        float3 energy=light.color.rgb*light.color.w*reach*visibility;
        terms.diffuse+=energy*nl;
        terms.specular+=energy*shared_punctual_specular(normal,view,toward,nl,f0,f90,a2,k,nv);
    }
    return terms;
}
