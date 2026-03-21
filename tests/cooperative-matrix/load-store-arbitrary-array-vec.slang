//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=CHECK):-vk -emit-spirv-directly

// DXC doesn't support groupshared yet. It says:
// dxc 1.10: : error : error: Load/Store of LinAlg Matrices to/from groupshared unsupported yet.
//DISABLE_TEST(compute):SIMPLE(filecheck=DXIL):-target dxil -profile cs_6_10 -entry computeMain -dxc-path dxc-sm610/ -Xdxc -Idxc-sm610/include
//DXIL: result code = 0

// CHECK: 1
// CHECK-NEXT: 2
// CHECK-NEXT: 3
// CHECK-NEXT: 4
// CHECK-NEXT: 5
// CHECK-NEXT: 6
// CHECK-NEXT: 7
// CHECK-NEXT: 8
// CHECK-NEXT: 9
// CHECK-NEXT: A
// CHECK-NEXT: B
// CHECK-NEXT: C
// CHECK-NEXT: D
// CHECK-NEXT: E
// CHECK-NEXT: F
// CHECK-NEXT: 10

//TEST_INPUT:ubuffer(data=[1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16], stride=4, count=256):name=input
RWByteAddressBuffer input;

//TEST_INPUT:ubuffer(stride=4, count=256):out,name=outputBuffer
RWStructuredBuffer<uint32_t> outputBuffer;

using namespace linalg;

typealias CoopMatType = CoopMat<uint32_t, MemoryScope.Subgroup, 16, 16, CoopMatMatrixUse.MatrixAccumulator>;

groupshared float3[128] tempShared;

[numthreads(32, 1, 1)]
void computeMain()
{
    let stride = 16;
    let mat = coopMatLoad<uint32_t, MemoryScope.Subgroup, 16, 16, CoopMatMatrixUse.MatrixAccumulator, CoopMatMatrixLayout.RowMajor>(input, 0, stride);
    mat.Store<CoopMatMatrixLayout.RowMajor>(tempShared, 0, stride);

    let result = CoopMatType.Load<CoopMatMatrixLayout.RowMajor>(tempShared, 0, stride);
    result.Store<CoopMatMatrixLayout.RowMajor>(outputBuffer, 0, stride);
}
