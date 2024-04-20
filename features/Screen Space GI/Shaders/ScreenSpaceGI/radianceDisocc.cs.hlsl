#include "../Common/GBuffer.hlsli"
#include "../Common/VR.hlsli"
#include "common.hlsli"

Texture2D<half4> srcDiffuse : register(t0);
Texture2D<half4> srcPrevGI : register(t1);  // maybe half-res
Texture2D<half> srcCurrDepth : register(t2);
Texture2D<half4> srcCurrNormal : register(t3);
Texture2D<half3> srcPrevGeo : register(t4);  // maybe half-res
Texture2D<float4> srcMotionVec : register(t5);
Texture2D<half4> srcPrevGIAlbedo : register(t6);
Texture2D<unorm float> srcAccumFrames : register(t7);

RWTexture2D<float3> outRadianceDisocc : register(u0);
RWTexture2D<unorm float> outAccumFrames : register(u1);
RWTexture2D<float4> outRemappedPrevGI : register(u2);

#if (defined(GI) && defined(GI_BOUNCE)) || defined(TEMPORAL_DENOISER)
#	define REPROJECTION
#endif

[numthreads(8, 8, 1)] void main(const uint2 pixCoord
								: SV_DispatchThreadID) {
	const float2 uv = (pixCoord + .5) * RcpFrameDim;
	uint eyeIndex = GET_EYE_IDX(uv);
	const float2 screen_pos = ConvertToStereoUV(uv, eyeIndex);

	float2 prev_uv = uv;
#ifdef REPROJECTION
	prev_uv += FULLRES_LOAD(srcMotionVec, pixCoord, uv, samplerLinearClamp).xy;
#endif
	float2 prev_screen_pos = ConvertToStereoUV(prev_uv, eyeIndex);

	const float curr_depth = READ_DEPTH(srcCurrDepth, pixCoord);

	bool valid_history = false;

#ifdef REPROJECTION
	if ((curr_depth <= DepthFadeRange.y) && !(any(prev_screen_pos < 0) || any(prev_screen_pos > 1))) {
		float3 curr_normal = DecodeNormal(FULLRES_LOAD(srcCurrNormal, pixCoord, uv, samplerLinearClamp).xy);
		curr_normal = ViewToWorldVector(curr_normal, InvViewMatrix[eyeIndex]);
		float3 curr_pos = ScreenToViewPosition(screen_pos, curr_depth, eyeIndex);
		curr_pos = ViewToWorldPosition(curr_pos, InvViewMatrix[eyeIndex]);

		const half3 prev_geo = srcPrevGeo.SampleLevel(samplerPointClamp, prev_uv * res_scale, 0);
		const float prev_depth = prev_geo.x;
		const float3 prev_normal = DecodeNormal(prev_geo.yz);  // prev normal is already world
		float3 prev_pos = ScreenToViewPosition(prev_screen_pos, prev_depth, eyeIndex);
		prev_pos = ViewToWorldPosition(prev_pos, PrevInvViewMat[eyeIndex]);

		float3 delta_pos = curr_pos - prev_pos;
		float normal_prod = dot(curr_normal, prev_normal);

		bool depth_pass = dot(delta_pos, delta_pos) < DepthDisocclusion * DepthDisocclusion;
		bool normal_pass = normal_prod * normal_prod > NormalDisocclusion;
		valid_history = depth_pass && normal_pass;
	}
#endif

	half4 prev_gi_albedo = 0;
	half4 prev_gi = 0;

#ifdef REPROJECTION
	[branch] if (valid_history)
	{
#	if defined(GI) && defined(GI_BOUNCE)
		prev_gi_albedo = srcPrevGIAlbedo.SampleLevel(samplerLinearClamp, prev_uv, 0);
#	endif
#	ifdef TEMPORAL_DENOISER
		prev_gi = srcPrevGI.SampleLevel(samplerLinearClamp, prev_uv * res_scale, 0);
#	endif
	}
#endif

	half3 radiance = 0;
#ifdef GI
	radiance = FULLRES_LOAD(srcDiffuse, pixCoord, uv, samplerLinearClamp).rgb;
#	ifdef GI_BOUNCE
	radiance += prev_gi_albedo.rgb * GIBounceFade;
#	endif
	outRadianceDisocc[pixCoord] = radiance;
#endif

#ifdef TEMPORAL_DENOISER
	uint accum_frames = 0;
	[branch] if (valid_history)
		accum_frames = srcAccumFrames.SampleLevel(samplerLinearClamp, prev_uv * res_scale, 0) * 255;
	accum_frames = min(accum_frames + 1, MaxAccumFrames);

	outAccumFrames[pixCoord] = accum_frames / 255.0;
	outRemappedPrevGI[pixCoord] = prev_gi;
#endif
}