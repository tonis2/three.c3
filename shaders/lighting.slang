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

float shared_area_diffuse(Light light,float3 position,float3 normal)
{
    float3 right=normalize(light.area_right.xyz),up=normalize(light.area_up.xyz);
    float3 emitter=-normalize(cross(right,up));float sum=0.0;uint samples=0u;
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;
        if(light.meta.z==3u&&dot(q,q)>1.0)continue;float3 p=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w;
        float3 ray=p-position;float d2=max(dot(ray,ray),1e-6);float3 toward=ray*rsqrt(d2);
        sum+=max(dot(normal,toward),0.0)*max(dot(emitter,-toward),0.0)/d2;samples++;}
    float cd=distance(light.direction.xyz,position)/max(light.direction.w,1e-4),window=saturate(1.0-cd*cd*cd*cd);
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
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;if(light.meta.z==3u&&dot(q,q)>1.0)continue;
        float3 ray=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w-position;float d2=max(dot(ray,ray),1e-6);float3 l=ray*rsqrt(d2);
        float nl=max(dot(normal,l),0.0),el=max(dot(emitter,-l),0.0);diffuse+=nl*el/d2;samples++;if(nl<=0.0||el<=0.0)continue;
        float3 h=normalize(l+view);float nh=max(dot(normal,h),0.0),vh=max(dot(view,h),0.0);
        float den=nh*nh*(a2-1.0)+1.0,D=a2/(3.14159265*den*den),G=(nl/(nl*(1.0-k)+k))*(nv/(nv*(1.0-k)+k));float3 F=f0+(float3(f90)-f0)*pow(1.0-vh,5.0);
        specular+=el/d2*D*G*F/(4.0*nv);}
    float cd=distance(light.direction.xyz,position)/max(light.direction.w,1e-4),window=saturate(1.0-cd*cd*cd*cd);
    float scale=light.color.w*window*window/max(samples,1u);
    SharedAreaTerms terms;
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
    for(uint y=0u;y<4u;++y)for(uint x=0u;x<4u;++x){float2 q=(float2(x,y)+0.5)*0.5-1.0;if(light.meta.z==3u&&dot(q,q)>1.0)continue;
        float3 ray=light.direction.xyz+right*q.x*light.area_right.w+up*q.y*light.area_up.w-position;float d2=max(dot(ray,ray),1e-6);float3 l=ray*rsqrt(d2);
        float nl=max(dot(normal,l),0.0),el=max(dot(emitter,-l),0.0);samples++;if(nl<=0.0||el<=0.0)continue;float3 h=normalize(l+view);float nh=max(dot(normal,h),0.0),vh=max(dot(view,h),0.0);
        float den=nh*nh*(a2-1.0)+1.0,D=a2/(3.14159265*den*den),G=(nl/(nl*(1.0-k)+k))*(nv/(nv*(1.0-k)+k));float3 F=f0+(float3(f90)-f0)*pow(1.0-vh,5.0);
        sum+=el/d2*D*G*F/(4.0*nv);}
    float cd=distance(light.direction.xyz,position)/max(light.direction.w,1e-4),window=saturate(1.0-cd*cd*cd*cd);
    return light.color.rgb*light.color.w*sum*window*window/(3.14159265*max(samples,1u));
}

float shared_point_shadow_factor(uint index,Light light,float3 position)
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
    return shadow_view_factor(view,position,float3(0.0));
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
SharedLightTerms shared_standard_lights(FrameBlock* frame,float4 screenPosition,float3 normal,float3 position,float3 albedo,float roughness,float metalness,float reflectance,float sunVisibility)
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
        float nl=max(dot(normal,toward),0.0);if(nl<=0.0)continue;
        float visibility=i==0u?sunVisibility:shared_point_shadow_factor(i,light,position);
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
            float visibility=shared_point_shadow_factor(i,light,position);
            terms.diffuse+=light.color.rgb*area.diffuse*visibility;
            terms.specular+=area.specular*visibility;
            continue;
        }
        if(light.meta.z!=1u&&light.meta.z!=4u)continue;
        float reach;float3 toward=light_toward(light.direction,position,reach);
        if(light.meta.z==4u)reach*=shared_spot_reach(light,toward);
        float nl=max(dot(normal,toward),0.0);if(nl<=0.0)continue;
        float visibility=shared_point_shadow_factor(i,light,position);
        float3 energy=light.color.rgb*light.color.w*reach*visibility;
        terms.diffuse+=energy*nl;
        terms.specular+=energy*shared_punctual_specular(normal,view,toward,nl,f0,f90,a2,k,nv);
    }
    return terms;
}
