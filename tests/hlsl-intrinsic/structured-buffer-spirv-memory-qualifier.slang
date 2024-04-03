//TEST:SIMPLE(filecheck=CHECK_SPV):-profile ps_4_0 -target spirv -emit-spirv-directly

// CHECK_SPV: OpDecorate {{.*}} NonWritable
StructuredBuffer<uint> x;

// CHECK_SPV: OpDecorate {{.*}} NonWritable
ByteAddressBuffer y;

float4 main() : SV_Target
{
    return x[0] + y.Load<uint>(0);
}