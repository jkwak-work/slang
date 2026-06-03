// Regression test for #10671: descriptor heap acceleration-structure entries
// store a uint64 device address, not an opaque acceleration-structure handle.

//TEST:SIMPLE(filecheck=CHECK): -target spirv-asm -entry computeMain -stage compute -capability spvDescriptorHeapEXT

// CHECK-NOT: OpLoad %RaytracingAccelerationStructure
// CHECK: %[[ADDR:[A-Za-z0-9_]+]] = OpLoad %ulong
// CHECK: %[[TLAS:[A-Za-z0-9_]+]] = OpConvertUToAccelerationStructureKHR {{.*}} %[[ADDR]]
// CHECK: OpRayQueryInitializeKHR %rayQuery{{.*}} %[[TLAS]]

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain(
    uniform RaytracingAccelerationStructure.Handle accelerationStructure,
    uniform DescriptorHandle<RWStructuredBuffer<uint>> output)
{
    RayDesc ray;
    ray.Origin = float3(0.0f, 0.0f, 0.0f);
    ray.Direction = float3(0.0f, 0.0f, 1.0f);
    ray.TMin = 0.0f;
    ray.TMax = 1.0f;

    RayQuery<RAY_FLAG_FORCE_NON_OPAQUE> rayQuery;
    rayQuery.TraceRayInline(accelerationStructure, RAY_FLAG_FORCE_NON_OPAQUE, 0xff, ray);
    output[0] = rayQuery.RayFlags();
}
