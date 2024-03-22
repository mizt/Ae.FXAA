#import <metal_stdlib>
using namespace metal;

#define FXAA_PC 1
#define FXAA_MSL 1
#define FXAA_GREEN_AS_LUMA 1
#define FXAA_QUALITY__PRESET 39

#import "FXAA3_11.h"

kernel void processimage(
    texture2d<float,access::sample> src[[texture(0)]],
    texture2d<float,access::write> dst[[texture(1)]],
    constant float2 &resolution[[buffer(0)]],
    uint2 gid[[thread_position_in_grid]]) {
    dst.write(float4(FxaaPixelShader(
        (float2(gid)+0.5)/resolution,
        float4(0.0),
        src,
        src,
        src,
        1.0/resolution,
        float4(0.0),
        float4(0.0),
        float4(0.0),
        0.166,
        0.0833,
        0.05,
        0.0,
        0.0,
        0.0,
        float4(0.0)
    ).rgb,1),gid);
}
