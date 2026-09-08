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
