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

// `Light.meta.w` bit 18 — `light.baked`. A lightmapped receiver has this light's
// direct diffuse in its tile already and must not add it a second time; every
// other receiver shades it in real time as though it were never baked.
static const uint LIGHT_BAKED = 0x40000u;
bool shared_light_is_baked(Light light) { return (light.meta.w & LIGHT_BAKED) != 0u; }

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

struct SharedAreaTerms
{
    float diffuse;
    float3 specular;
};

// Material export keeps the numeric path as a standalone reference. Lightmap
// baking selects the view-independent polygon diffuse below instead.
#if defined(THREE_BAKE) && !defined(THREE_AREA_REFERENCE)
#define THREE_AREA_REFERENCE 1
#endif

float shared_area_reference_diffuse(Light light,float3 position,float3 normal)
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

SharedAreaTerms shared_area_reference_terms(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
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

float3 shared_area_reference_specular(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
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

// Linearly transformed cosines — Heitz et al. 2016.
//
// A polygon lit by a cosine distribution has a closed-form integral; a polygon
// lit by GGX does not. The fit says the GGX lobe at one roughness and one view
// angle is a cosine seen through a linear map, so the integral becomes:
// transform the polygon's corners by the fitted inverse, then take the cosine
// integral of the shape that comes out. Two texture reads replace the loop above.
//
// `ltc_lut` is one 64x128 image: rows 0-63 are the fitted inverse (four numbers
// of a five-entry sparse matrix, the middle one normalised to 1), rows 64-127
// the two halves of the GGX directional albedo that a Schlick Fresnel splits
// into. The column is perceptual roughness and the row is sqrt(1 - N.V), which
// is the published parameterisation. `src/render/ltc.c3` uploads it and
// `FrameBlock.lighting.w` says whether it is there — zero falls back to numeric
// specular integration while diffuse keeps the same polygon integral.
static const float LTC_LUT_SCALE = 63.0 / 64.0;
static const float LTC_LUT_BIAS  = 0.5 / 64.0;

// The vector form factor of one edge: `cross(v1,v2)` scaled by the angle between
// them over its sine. The rational approximation is Hill's and is exact enough
// that no version of this ever used `acos`.
float3 shared_ltc_edge(float3 v1,float3 v2)
{
    float x=dot(v1,v2),y=abs(x);
    float a=0.8543985+(0.4965155+0.0145206*y)*y;
    float b=3.4175940+(4.1616724+y)*y;
    float v=a/b;
    float theta_sintheta=x>0.0?v:0.5*rsqrt(max(1.0-x*x,1e-7))-v;
    return cross(v1,v2)*theta_sintheta;
}

// The horizon-clipped cosine integral, as a fraction of a full hemisphere.
// Hill's sphere approximation rather than a real polygon clip: the vector form
// factor already carries the whole geometry, and reading it as a sphere of the
// same solid angle costs a length where clipping costs five vertices and a
// branch per edge.
float shared_ltc_clipped(float3 f,float3 axis)
{
    float l=length(f);
    return max((l*l+dot(f,axis))/(l+1.0),0.0);
}

// The emitter as a polygon of directions from the shading point, plus the shared
// scale both lobes end up multiplied by. `scale` is zero when the range window
// or either early-out has already answered.
//
// Six corners always: a rectangle repeats its last one, which makes the two
// extra edges zero-length and lets every loop below unroll against constant
// indices. A disk is a hexagon of the same area — the emitter's shape stops
// being visible in the result long before six corners do, and a corner costs a
// normalise and an edge.
struct SharedAreaShape
{
    float3 corner[6];
    float scale;
};

SharedAreaShape shared_area_shape(Light light,float3 position,float3 normal)
{
    SharedAreaShape shape;
    shape.scale=0.0;
    float3 right=normalize(light.area_right.xyz),up=normalize(light.area_up.xyz);
    float3 emitter=-normalize(cross(right,up));
    float window=shared_area_window(light,position,normal,right,up,emitter);
    [unroll] for(uint i=0u;i<6u;++i)shape.corner[i]=float3(0.0,0.0,1.0);
    if(window<=0.0)return shape;

    float3 centre=light.direction.xyz-position;
    float3 r=right*light.area_right.w,u=up*light.area_up.w;
    float area;
    if(light.meta.z==3u)
    {
        // 1.0996 is the circumradius that gives a hexagon the ellipse's own area.
        const float grow=1.0996;
        const float3 cosines=float3(1.0,0.5,-0.5);
        const float3 sines=float3(0.0,0.86602540,0.86602540);
        shape.corner[0]=centre+(r*cosines.x+u*sines.x)*grow;
        shape.corner[1]=centre+(r*cosines.y+u*sines.y)*grow;
        shape.corner[2]=centre+(r*cosines.z+u*sines.z)*grow;
        shape.corner[3]=centre-(r*cosines.x+u*sines.x)*grow;
        shape.corner[4]=centre-(r*cosines.y+u*sines.y)*grow;
        shape.corner[5]=centre-(r*cosines.z+u*sines.z)*grow;
        area=3.14159265*light.area_right.w*light.area_up.w;
    }
    else
    {
        // Wound so the form factor comes out positive on the side the emitter
        // faces; the window above has already answered for the other side.
        shape.corner[0]=centre-r-u;
        shape.corner[1]=centre+r-u;
        shape.corner[2]=centre+r+u;
        shape.corner[3]=centre-r+u;
        shape.corner[4]=shape.corner[3];
        shape.corner[5]=shape.corner[3];
        area=4.0*light.area_right.w*light.area_up.w;
    }
    [unroll] for(uint i=0u;i<6u;++i)shape.corner[i]=normalize(shape.corner[i]);
    // Convert the polygon form factor back to the emitter's power-per-area scale.
    // The horizon term below is an approximation, so parity comes from sharing
    // this path rather than claiming identity with the numeric reference.
    shape.scale=light.color.w*window*window/(3.14159265*max(area,1e-6));
    return shape;
}

// Diffuse is the polygon's cosine form factor. It is view independent and does
// not use the LTC fit texture; only the specular lobe needs that approximation.
float shared_area_polygon_diffuse(SharedAreaShape shape,float3 normal)
{
    float3 sum=float3(0.0);
    [unroll] for(uint i=0u;i<6u;++i)sum+=shared_ltc_edge(shape.corner[i],shape.corner[i==5u?0u:i+1u]);
    return shape.scale*shared_ltc_clipped(sum,normal);
}

#ifndef THREE_AREA_REFERENCE
struct SharedAreaLtcContext
{
    // The fit's own frame: x along the view's tangential part, z the normal.
    float3 row0;
    float3 row1;
    float3 row2;
    float3 fresnel;
};

SharedAreaLtcContext shared_area_ltc_context(float3 normal,float3 view,float3 f0,float f90,float alpha,float nv)
{
    SharedAreaLtcContext context;
    float3 tangential=view-normal*dot(view,normal);
    float len2=dot(tangential,tangential);
    float3 t1=len2>1e-8?tangential*rsqrt(len2)
        :normalize(abs(normal.z)<0.999?cross(normal,float3(0.0,0.0,1.0)):float3(1.0,0.0,0.0));
    float3 t2=cross(normal,t1);

    float2 uv=float2(sqrt(alpha),sqrt(saturate(1.0-nv)))*LTC_LUT_SCALE+LTC_LUT_BIAS;
    float4 m=ltc_lut.SampleLevel(float2(uv.x,uv.y*0.5),0.0);
    float4 norm=ltc_lut.SampleLevel(float2(uv.x,0.5+uv.y*0.5),0.0);

    // The three rows of the fitted inverse already multiplied by the frame, so a
    // corner is three dot products rather than a change of basis and a matrix.
    context.row0=m.x*t1+m.y*normal;
    context.row1=t2;
    context.row2=m.z*t1+m.w*normal;
    context.fresnel=f0*norm.x+(float3(f90)-f0)*norm.y;
    return context;
}

float3 shared_area_ltc_specular(SharedAreaShape shape,SharedAreaLtcContext context)
{
    float3 local[6];
    [unroll] for(uint i=0u;i<6u;++i)
    {
        float3 c=shape.corner[i];
        local[i]=normalize(float3(dot(context.row0,c),dot(context.row1,c),dot(context.row2,c)));
    }
    float3 sum=float3(0.0);
    [unroll] for(uint i=0u;i<6u;++i)sum+=shared_ltc_edge(local[i],local[i==5u?0u:i+1u]);
    float form=shared_ltc_clipped(sum,float3(0.0,0.0,1.0));
    return shape.scale*form*context.fresnel;
}

#endif

float shared_area_diffuse(Light light,float3 position,float3 normal)
{
#if defined(THREE_AREA_REFERENCE) && !defined(THREE_LIGHTMAP_BAKE)
    return shared_area_reference_diffuse(light,position,normal);
#else
    SharedAreaShape shape=shared_area_shape(light,position,normal);
    if(shape.scale<=0.0)return 0.0;
    return shared_area_polygon_diffuse(shape,normal);
#endif
}

float3 shared_area_specular(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
{
#ifdef THREE_AREA_REFERENCE
    return shared_area_reference_specular(light,position,normal,view,f0,f90,a2,k,nv);
#else
    if(push.frame[0].lighting.w<=0.0)return shared_area_reference_specular(light,position,normal,view,f0,f90,a2,k,nv);
    SharedAreaShape shape=shared_area_shape(light,position,normal);
    if(shape.scale<=0.0)return float3(0.0);
    // `k` is half the GGX alpha at every caller, which is the axis the fit is
    // tabulated against.
    SharedAreaLtcContext context=shared_area_ltc_context(normal,view,f0,f90,k*2.0,nv);
    return light.color.rgb*shared_area_ltc_specular(shape,context);
#endif
}

// Both lobes for built-in shading. Custom lambert and specular calls keep the
// single-lobe helpers above and below, so they only calculate what was asked for.
SharedAreaTerms shared_area_terms(Light light,float3 position,float3 normal,float3 view,float3 f0,float f90,float a2,float k,float nv)
{
#ifdef THREE_AREA_REFERENCE
    return shared_area_reference_terms(light,position,normal,view,f0,f90,a2,k,nv);
#else
    SharedAreaTerms terms;terms.diffuse=0.0;terms.specular=float3(0.0);
    SharedAreaShape shape=shared_area_shape(light,position,normal);
    if(shape.scale<=0.0)return terms;
    if(push.frame[0].lighting.w<=0.0)
    {
        terms=shared_area_reference_terms(light,position,normal,view,f0,f90,a2,k,nv);
        terms.diffuse=shared_area_polygon_diffuse(shape,normal);
        return terms;
    }
    SharedAreaLtcContext context=shared_area_ltc_context(normal,view,f0,f90,k*2.0,nv);
    terms.diffuse=shared_area_polygon_diffuse(shape,normal);
    terms.specular=light.color.rgb*shared_area_ltc_specular(shape,context);
    return terms;
#endif
}

#ifndef THREE_AREA_REFERENCE
SharedAreaTerms shared_area_terms_cached(Light light,SharedAreaShape shape,float3 normal,SharedAreaLtcContext context,bool diffuse)
{
    SharedAreaTerms terms;terms.diffuse=0.0;terms.specular=float3(0.0);
    if(diffuse)terms.diffuse=shared_area_polygon_diffuse(shape,normal);
    terms.specular=light.color.rgb*shared_area_ltc_specular(shape,context);
    return terms;
}
#endif

bool shared_cluster_contains(FrameBlock* frame,uint cluster,uint lightIndex)
{
    uint packed=frame[0].cluster_grid.w==0u?0x80000000u:frame[0].cluster_counts[cluster];
    if((packed&0x80000000u)!=0u)return true;
    for(uint k=0u;k<packed;++k)if(frame[0].cluster_indices[cluster*frame[0].cluster_grid.w+k]==lightIndex)return true;
    return false;
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
float shared_shadow_compare(bool cached,float2 uv,float reference)
{
    return cached
        ? shadow_atlas_static_compare.SampleCmpLevelZero(uv,reference)
        : shadow_atlas_compare.SampleCmpLevelZero(uv,reference);
}

float shadow_view_factor_filtered_from(uint index, float3 position, float3 normal, float filter_radius,
    bool cached)
{
    if (index == 0xffffffffu) return 1.0;
    ShadowGpuView view = push.frame[0].shadow_views[index];
    if (view.params.w <= 0.0) return 1.0;
    // The projection's four columns, read rather than multiplied: a `mul` by a
    // basis vector *is* a column, and the normal offset is one add on the clip
    // position.
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
    // Half a texel in from the tile, so a tap never reaches a neighbouring
    // view's depth.
    float2 lo = view.atlas.zw + step * 0.5;
    float2 hi = view.atlas.zw + view.atlas.xy - step * 0.5;
    // The receiver plane's depth slope in ndc, so the depth of this same plane is
    // known at every tap without fragment derivatives inside a light-dependent
    // branch. The ndc Jacobian is a rank-one update of the projection's 3x3, so
    // its cofactor applied to the normal — the normal carried into ndc, whose xy
    // over z is minus the slope — falls out of the view's frame constants: the
    // cofactor rows in `plane_*.xyz` and the inverse-transposed w row in their w.
    //
    // Read here rather than out of `view` above, so the three loads sit after
    // the early-outs instead of ahead of them; that is worth more than the maths.
    // `planeNdc` is the ndc normal times `clip.w` squared, which the slope
    // divides out and only the grazing-angle guard has to put back.
    float invW = 1.0 / clip.w;
    float4 planeX = push.frame[0].shadow_views[index].plane_x;
    float4 planeY = push.frame[0].shadow_views[index].plane_y;
    float4 planeZ = push.frame[0].shadow_views[index].plane_z;
    float3 planeW = float3(planeX.w, planeY.w, planeZ.w);
    float3 planeN = float3(dot(planeX.xyz, normal), dot(planeY.xyz, normal), dot(planeZ.xyz, normal));
    float3 planeNdc = planeN * (1.0 - dot(ndc, planeW)) + planeW * dot(ndc, planeN);
    float2 depthGradient = abs(planeNdc.z) * (invW * invW) > 1e-8 ? -planeNdc.xy / planeNdc.z : float2(0.0);
    // Four taps of the comparison sampler, each landed on a texel centre so the
    // hardware weighs one texel and the plane depth above is the exact depth of
    // that texel. A tap left between texels weighs four depths against one
    // reference and needs half a texel of the plane's drop as slack — which under
    // a local light's perspective is more ndc depth than a crate is tall, so the
    // contact shadows go with it.
    const float2 quad[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    if(filter_radius<=1.0)
    {
        const float2 adjacent[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
        float2 texelPosition=local/view.params.x-0.5;
        float2 fraction=frac(texelPosition);
        float2 base=floor(texelPosition);
        float samples[4];
        [unroll] for(int i=0;i<4;i++)
        {
            float2 tapLocal=clamp((base+adjacent[i]+0.5)*view.params.x,
                view.params.x*0.5,1.0-view.params.x*0.5);
            float2 tapNdc=(tapLocal-local)*float2(2.0,-2.0);
            float reference=ndc.z+dot(depthGradient,tapNdc)-view.params.y;
            samples[i]=shared_shadow_compare(cached,
                clamp(tapLocal*view.atlas.xy+view.atlas.zw,lo,hi),reference);
        }
        float lit=lerp(lerp(samples[0],samples[1],fraction.x),
            lerp(samples[2],samples[3],fraction.x),fraction.y);
        return lerp(1.0,lit,view.params.w);
    }

    float spread = filter_radius > 1.0 ? filter_radius * 0.6 : 1.0;
    float lit = 0.0;
    for (int i = 0; i < 4; i++)
    {
        float2 tap = quad[i] * spread;
        float2 tapLocal = clamp((floor(local / view.params.x + tap) + 0.5) * view.params.x,
            view.params.x * 0.5, 1.0 - view.params.x * 0.5);
        float2 tapNdc = (tapLocal - local) * float2(2.0, -2.0);
        float reference = ndc.z + dot(depthGradient, tapNdc) - view.params.y;
        lit += shared_shadow_compare(cached,
            clamp(tapLocal * view.atlas.xy + view.atlas.zw, lo, hi), reference);
    }
    return lerp(1.0, lit * 0.25, view.params.w);
}

float shadow_view_factor_filtered(uint index,float3 position,float3 normal,float filter_radius)
{
    return shadow_view_factor_filtered_from(index,position,normal,filter_radius,false);
}

float shared_point_shadow_factor_from(uint index,Light light,float3 position,float3 normal,bool cached)
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
        return shadow_view_factor_filtered_from(view,position,normal,radius,cached);
    }
    return shadow_view_factor_filtered_from(view,position,normal,1.0,cached);
}

float shared_point_shadow_factor(uint index,Light light,float3 position,float3 normal)
{
    return shared_point_shadow_factor_from(index,light,position,normal,false);
}

// Add only the visibility lost to moving casters. The projected box is a cheap
// gate; comparing the static and combined maps keeps the cached baseline intact.
float3 shared_baked_dynamic_delta(FrameBlock* frame,float3 normal,float3 receiverNormal,float3 position)
{
    float3 delta=float3(0.0);
    uint count=(uint)frame[0].lighting.y;
    for(uint i=0u;i<count;++i)
    {
        Light light=frame[0].lights[i];
        if(!shared_light_is_baked(light)||light.meta.y==0xffffffffu)continue;
        uint parts=light.meta.z==1u?6u:1u;
        bool inside=false;
        for(uint part=0u;part<parts&&!inside;++part)
        {
            ShadowGpuView view=frame[0].shadow_views[light.meta.y+part];
            float4 rect=view.dynamic_rect;
            if(rect.z<=rect.x||rect.w<=rect.y)continue;
            float4 clip=mul(view.view_projection,float4(position,1.0));
            if(clip.w<=0.0)continue;
            float2 ndc=clip.xy/clip.w;
            float2 uv=float2(0.5+0.5*ndc.x,0.5-0.5*ndc.y);
            inside=all(uv>=rect.xy)&&all(uv<=rect.zw);
        }
        if(!inside)continue;
        float live=shared_point_shadow_factor_from(i,light,position,receiverNormal,false);
        float cached=shared_point_shadow_factor_from(i,light,position,receiverNormal,true);
        float visibility=min(live-cached,0.0);
        if(visibility>=0.0)continue;
        if(light.meta.z==2u||light.meta.z==3u)
        {
            SharedAreaShape shape=shared_area_shape(light,position,normal);
            float area=shape.scale>0.0?shared_area_polygon_diffuse(shape,normal):0.0;
            delta+=light.color.rgb*area*visibility;
            continue;
        }
        float reach;float3 toward=light_toward(light.direction,position,reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,toward);
        float nl=max(dot(normal,toward),0.0);
        delta+=light.color.rgb*light.color.w*reach*nl*visibility;
    }
    return delta;
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
SharedLightTerms shared_standard_lights(FrameBlock* frame,float4 screenPosition,float3 normal,float3 receiverNormal,float3 position,float3 albedo,float roughness,float metalness,float reflectance,float sunVisibility,bool skipBakedDiffuse)
{
    float3 view=normalize(frame[0].camera.xyz-position);
    float3 f0=lerp(float3(0.16*reflectance*reflectance),albedo,metalness);
    float f90=clamp(dot(f0,float3(16.5)),0.0,1.0);
    float a=max(roughness*roughness,1e-3),a2=a*a,nv=max(dot(normal,view),1e-4),k=a*0.5;
    SharedLightTerms terms;terms.diffuse=0.0;terms.specular=0.0;
#ifndef THREE_AREA_REFERENCE
    SharedAreaLtcContext areaContext = {};
    bool areaContextReady=false;
#endif
    uint count=(uint)frame[0].lighting.y;
    for(uint i=0u;i<count;++i)
    {
        Light light=frame[0].lights[i];if(light.meta.z!=0u)continue;
        bool skipDiffuse=skipBakedDiffuse&&shared_light_is_baked(light);
        float reach;float3 toward=light_toward(light.direction,position,reach);
        float nl=max(dot(normal,toward),0.0);if(nl*reach<=0.0)continue;
        float visibility=i==0u?sunVisibility:shared_point_shadow_factor(i,light,position,receiverNormal);
        float3 energy=light.color.rgb*light.color.w*reach*visibility;
        if(!skipDiffuse)terms.diffuse+=energy*nl;
        terms.specular+=energy*shared_punctual_specular(normal,view,toward,nl,f0,f90,a2,k,nv);
    }
    uint cluster=shared_fragment_cluster(frame,screenPosition,position);
    uint packed=frame[0].cluster_grid.w==0u?0x80000000u:frame[0].cluster_counts[cluster];
    bool overflow=(packed&0x80000000u)!=0u;uint localCount=overflow?count:packed;
    for(uint kLocal=0u;kLocal<localCount;++kLocal)
    {
        uint i=overflow?kLocal:frame[0].cluster_indices[cluster*frame[0].cluster_grid.w+kLocal];
        Light light=frame[0].lights[i];
        bool skipDiffuse=skipBakedDiffuse&&shared_light_is_baked(light);
        if(light.meta.z==2u||light.meta.z==3u)
        {
#ifdef THREE_AREA_REFERENCE
            SharedAreaTerms area=shared_area_terms(light,position,normal,view,f0,f90,a2,k,nv);
#else
            SharedAreaTerms area;
            if(push.frame[0].lighting.w<=0.0)
                area=shared_area_reference_terms(light,position,normal,view,f0,f90,a2,k,nv);
            else
            {
                SharedAreaShape shape=shared_area_shape(light,position,normal);
                if(shape.scale<=0.0)continue;
                if(!areaContextReady)
                {
                    areaContext=shared_area_ltc_context(normal,view,f0,f90,k*2.0,nv);
                    areaContextReady=true;
                }
                area=shared_area_terms_cached(light,shape,normal,areaContext,!skipDiffuse);
            }
#endif
            if(area.diffuse<=0.0&&dot(area.specular,float3(1.0))<=0.0)continue;
            float visibility=shared_point_shadow_factor(i,light,position,receiverNormal);
            if(!skipDiffuse)terms.diffuse+=light.color.rgb*area.diffuse*visibility;
            terms.specular+=area.specular*visibility;
            continue;
        }
        if(light.meta.z!=1u&&light.meta.z!=4u)continue;
        float reach;float3 toward=light_toward(light.direction,position,reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,toward);
        float nl=max(dot(normal,toward),0.0);if(nl*reach<=0.0)continue;
        float visibility=shared_point_shadow_factor(i,light,position,receiverNormal);
        float3 energy=light.color.rgb*light.color.w*reach*visibility;
        if(!skipDiffuse)terms.diffuse+=energy*nl;
        terms.specular+=energy*shared_punctual_specular(normal,view,toward,nl,f0,f90,a2,k,nv);
    }
    return terms;
}

// What one lightmap texel holds: the direct diffuse of every baked light, times
// its shadow, with no albedo and no specular in it. Term for term the diffuse
// half of `shared_standard_lights` restricted to the baked lights, which is what
// makes adding the tile back and shading in real time the same picture.
//
// Every light rather than the fragment's cluster: a bake has no camera and so no
// cluster grid to index.
float3 shared_baked_diffuse(FrameBlock* frame,float3 normal,float3 receiverNormal,float3 position)
{
    float3 sum=float3(0.0);
    uint count=(uint)frame[0].lighting.y;
    for(uint i=0u;i<count;++i)
    {
        Light light=frame[0].lights[i];
        if(!shared_light_is_baked(light))continue;
        if(light.meta.z==2u||light.meta.z==3u)
        {
            float area=shared_area_diffuse(light,position,normal);
            if(area<=0.0)continue;
            sum+=light.color.rgb*area*shared_point_shadow_factor(i,light,position,receiverNormal);
            continue;
        }
        float reach;float3 toward=light_toward(light.direction,position,reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,toward);
        float nl=max(dot(normal,toward),0.0);if(nl*reach<=0.0)continue;
        sum+=light.color.rgb*light.color.w*reach*nl*shared_point_shadow_factor(i,light,position,receiverNormal);
    }
    return sum;
}
