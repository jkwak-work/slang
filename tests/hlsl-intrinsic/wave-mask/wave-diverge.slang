//TEST_CATEGORY(wave-mask, compute)
//DISABLE_TEST:COMPARE_COMPUTE_EX:-cpu -compute -shaderobj
//DISABLE_TEST:COMPARE_COMPUTE_EX:-slang -compute -shaderobj
//TEST:COMPARE_COMPUTE_EX:-slang -compute -dx12 -use-dxil -profile cs_6_5 -shaderobj
//TEST(vulkan):COMPARE_COMPUTE_EX:-vk -compute -shaderobj
//TEST:COMPARE_COMPUTE_EX:-cuda -compute -shaderobj

//TEST_INPUT:ubuffer(data=[0 0 0 0], stride=4):out,name outputBuffer
RWStructuredBuffer<int> outputBuffer;

[numthreads(4, 1, 1)]
void computeMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const WaveMask mask0 = 0xf;
    
    int idx = int(dispatchThreadID.x);
    
    int value = 0;
    
    const WaveMask mask1 = WaveMaskBallot(mask0, idx == 2);
    
    if (idx == 2)
    {
        // diverge
        return;
    }
    
    const WaveMask mask2 = mask0 & ~mask1;
    
    value = WaveMaskMin(mask2, idx + 1);
    
    outputBuffer[idx] = value;
}
