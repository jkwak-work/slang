// byte-address-buffer-scalar-aligned.slang

// Regression test for https://github.com/shader-slang/slang/issues/9958
//
// A manually-aligned vector load/store from a `(RW)ByteAddressBuffer` only
// requires the access to be aligned to the vector's *scalar* components, not
// to the full vector size. When the explicit alignment is smaller than the
// full vector size we must fall back to scalarized element loads/stores
// instead of diagnosing an error.

//TEST:SIMPLE(filecheck=CHECK):-target spirv -profile spirv_1_6 -entry computeMain -stage compute -fvk-use-c-layout
//TEST:SIMPLE(filecheck=CHECK):-target spirv -emit-spirv-directly -profile spirv_1_6 -entry computeMain -stage compute -fvk-use-c-layout

RWByteAddressBuffer buffer;

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain(uint3 tid : SV_DispatchThreadID)
{
    // The offset is not known at compile time, so the explicit alignment of
    // `2` is what drives the legalization. `uint16_t2` is 4 bytes wide but its
    // scalar components only need 2-byte alignment, so this must scalarize
    // into two `ushort` (16-bit) loads and two `ushort` stores rather than
    // emitting error 41300.
    int offset = int(tid.x);

    // CHECK-NOT: E41300
    // CHECK: OpLoad %ushort
    // CHECK: OpLoad %ushort
    // CHECK: OpStore {{.*}}
    // CHECK: OpStore {{.*}}
    uint16_t2 data = buffer.LoadAligned<uint16_t2>(offset, 2);
    buffer.Store(offset, data, 2);
}
