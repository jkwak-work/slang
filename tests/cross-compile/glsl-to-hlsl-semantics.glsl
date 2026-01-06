//TEST:SIMPLE(filecheck=CHECK_HLSL): -target hlsl -stage fragment -entry main -allow-glsl
//TEST:SIMPLE(filecheck=CHECK_HLSL_VS): -target hlsl -stage vertex -entry main -allow-glsl

// Test that GLSL shader inputs/outputs get HLSL semantics when compiling to HLSL/DXIL.
// This test verifies that struct field semantics are properly emitted from layout information.

//CHECK_HLSL: struct
//CHECK_HLSL: float4 outColor_0 : SV_TARGET;
//CHECK_HLSL: main(float2 inUV_0 : COLOR)

//CHECK_HLSL_VS: struct
//CHECK_HLSL_VS: float4 outColor_0 : COLOR;
//CHECK_HLSL_VS: main(float2 inUV_0 : VERTEX_IN_)

#version 450

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

void main()
{
    outColor = vec4(inUV, 0.0, 1.0);
}
