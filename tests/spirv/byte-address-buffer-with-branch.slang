//TEST:COMPARE_COMPUTE(filecheck-buffer=SPIRV): -vk -shaderobj -output-using-type
//TEST:COMPARE_COMPUTE(filecheck-buffer=SPIRV_BRANCH): -vk -shaderobj -output-using-type -Xslang -DBRANCH

// This tests if a dynamic branching works for the legalization from ByteAddressBuffer to StructurredBuffer.

//TEST_INPUT:ubuffer(data=[0 0]):out,name outputBuffer
RWStructuredBuffer<int> outputBuffer;

//TEST_INPUT:ubuffer(data=[10 11], stride=4):name input
ByteAddressBuffer input;

//TEST_INPUT:ubuffer(data=[100 101], stride=4):name input2
ByteAddressBuffer input2;

[numthreads(1, 1, 1)]
void computeMain(int3 tid : SV_DispatchThreadID)
{
    ByteAddressBuffer buf = input;

#if defined(BRANCH)
    if (tid.x == 0)
        buf = input2;
#endif
    // When `BRANCH` is not defined, it is easy to inline the global-param, `input`, and remove `buf`.
    //
    // When `BRANCH` is defined, we cannot inline the global-param, because it is unknown which one
    // should be inlined until the runtime.
    //
    // From the IR perspecitve, the merging-point will take an IRParam and its type needs to be
    // legalized from ByteAddressBuffer to StructuredBuffer.
    // The IR dump will look something like the following:
    // ```
    //     ifElse(%22, %23, %24, %25)
    //   block %24:
    //     unconditionalBranch(%25, %input)
    //   block %23:
    //     unconditionalBranch(%25, %input2)
    //   block %25(
    //       [nameHint("buf")]
    //       param %buf      : ByteAddressBuffer # <== Need to be legalized
    //       ):
    //   let %26 : Int = byteAddressBufferLoad(%buf, 0 : UInt, 0 : UInt)
    // ```

    outputBuffer[0] = buf.Load<int>(0);
    outputBuffer[1] = buf.Load<int>(4);

    // SPIRV: 10
    // SPIRV-NEXT: 11
    // SPIRV_BRANCH: 100
    // SPIRV_BRANCH-NEXT: 101
}
