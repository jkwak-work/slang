//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=CHECK):-vk -render-feature cooperative-vector -output-using-type -emit-spirv-directly
//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=CHECK):-dx12 -render-feature cooperative-vector -dx12-experimental -use-dxil -output-using-type -profile cs_6_8 -Xslang... -Xdxc -Vd -X. -capability hlsl_coopvec_poc
//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=CHECK):-cpu -output-using-type

// CHECK: type: float
// CHECK-NEXT: 0.000000
// CHECK-NEXT: 1.000000
// CHECK-NEXT: 1.584962
// CHECK-NEXT: 2.000000

//TEST_INPUT:ubuffer(data=[0 0 0 0], stride=4):out,name=outputBuffer
RWStructuredBuffer<float> outputBuffer;

//TEST_INPUT:ubuffer(data=[1.0 2.0 3.0 4.0], stride=4),name=input
ByteAddressBuffer input;

[numthreads(1, 1, 1)]
void computeMain()
{
    CoopVec<float, 4> vec = coopVecLoad<4, float>(input);

    CoopVec<float, 4> result = log2(vec);

    for(int i = 0; i < result.getCount(); ++i)
        outputBuffer[i] = result[i];
}
