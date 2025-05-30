//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=CHECK):-vk -output-using-type -emit-spirv-directly

// CHECK: type: float
// CHECK-NEXT: 1.000000
// CHECK-NEXT: 2.000000
// CHECK-NEXT: 3.000000
// CHECK-NEXT: 4.000000
// CHECK-NEXT: 5.000000
// CHECK-NEXT: 6.000000
// CHECK-NEXT: 7.000000
// CHECK-NEXT: 8.000000

//TEST_INPUT:ubuffer(data=[1.0 2.0 3.0 4.0], stride=4, count=256),name=input1
ByteAddressBuffer input1;

//TEST_INPUT:ubuffer(data=[5.0 6.0 7.0 8.0], stride=4, count=256),name=input2
ByteAddressBuffer input2;

//TEST_INPUT:ubuffer(stride=4, count=256):out,name=outputBuffer
RWStructuredBuffer<float> outputBuffer;

using namespace linalg;

typealias CoopMatType = CoopMat<float, MemoryScope.Subgroup, 16, 16, CoopMatMatrixUse::MatrixAccumulator>;

struct MyStruct
{
    CoopMatType mat1;
    CoopMatType mat2;
};

[numthreads(32, 1, 1)]
void computeMain()
{
    let stride = 16;
    let matrixLayout = CoopMatMatrixLayout::RowMajor;

    MyStruct s;
    s.mat1 = CoopMatType.Load<CoopMatMatrixLayout::RowMajor>(input1, 0, stride);
    s.mat2 = CoopMatType.Load<CoopMatMatrixLayout::RowMajor>(input2, 0, stride);

    s.mat1.Store<CoopMatMatrixLayout::RowMajor>(outputBuffer, 0, stride);
    s.mat2.Store<CoopMatMatrixLayout::RowMajor>(outputBuffer, 4, stride);
}
