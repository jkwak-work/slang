// Regression test for issue 11176: multiple //TEST: lines compile the same source for
// different targets while sharing the target-agnostic front-end IR (-use-shared-front-end-ir).
// Under slang-test's shared-library / test-server spawn modes the first line computes and
// caches the lowered IR and the later lines reuse it. This test verifies that sharing produces
// correct code generation for each target. (The option is passed explicitly so the test
// exercises sharing regardless of the slang-test default.)

//TEST:SIMPLE(filecheck=SPIRV): -target spirv-asm -stage compute -entry computeMain -use-shared-front-end-ir
//TEST:SIMPLE(filecheck=HLSL): -target hlsl -stage compute -entry computeMain -use-shared-front-end-ir
//TEST:SIMPLE(filecheck=GLSL): -target glsl -stage compute -entry computeMain -use-shared-front-end-ir

RWStructuredBuffer<float> gBuffer;

float helper(uint i)
{
    float acc = 0.0f;
    for (uint k = 0; k < i; ++k)
        acc += float(k) * 0.5f;
    return acc;
}

[numthreads(4, 1, 1)]
void computeMain(uint3 tid : SV_DispatchThreadID)
{
    gBuffer[tid.x] = helper(tid.x) + float(tid.x) * 2.0f;
}

//SPIRV: OpEntryPoint
//SPIRV: OpFunction

//HLSL: RWStructuredBuffer
//HLSL: void computeMain

//GLSL: buffer
//GLSL: void main(
