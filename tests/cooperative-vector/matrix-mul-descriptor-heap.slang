//TEST:SIMPLE(filecheck=CHECK): -target spirv-asm -entry computeMain -stage compute -capability spvDescriptorHeapEXT -capability spvCooperativeVectorNV

// CHECK-DAG: OpCapability CooperativeVectorNV
// CHECK-DAG: OpCapability DescriptorHeapEXT
// CHECK-DAG: OpExtension "SPV_EXT_descriptor_heap"
// CHECK-DAG: BuiltIn ResourceHeapEXT
// CHECK: OpBufferPointerEXT
// CHECK: OpCooperativeVectorLoadNV
// CHECK: OpBufferPointerEXT
// CHECK: OpCooperativeVectorMatrixMulNV

RWStructuredBuffer<float16_t> outputBuffer;

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain(uint3 threadID: SV_DispatchThreadID)
{
    DescriptorHandle<RWByteAddressBuffer> input =
        DescriptorHandle<RWByteAddressBuffer>(uint2(3024, 0));
    DescriptorHandle<ByteAddressBuffer> weights =
        DescriptorHandle<ByteAddressBuffer>(uint2(3025, 0));

    let inputVec = coopVecLoad<4, float16_t>(input);
    let output = coopVecMatMul<float16_t, 4, 4>(
        inputVec,
        CoopVecComponentType::Float16,
        weights,
        0,
        CoopVecComponentType::Float16,
        CoopVecMatrixLayout::RowMajor,
        false,
        8);

    outputBuffer[threadID.x] = output[0];
}
