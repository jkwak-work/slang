//TEST(compute):COMPARE_COMPUTE_EX:-slang -compute -shaderobj -output-using-type
//TEST:SIMPLE(filecheck=CHECK): -target hlsl -profile cs_5_0 -entry computeMain -line-directive-mode none

//TEST_INPUT:ubuffer(data=[0 0 0 0 0], stride=4):out,name=outputBuffer
RWStructuredBuffer<float> outputBuffer;

typedef DifferentialPair<float> dpfloat;
typedef float.Differential dfloat;

// Test that compute does not have a context.
// CHECK-NOT: struct {{[a-zA-Z0-9_]*}}_compute_{{[a-zA-Z0-9_]*}}

[BackwardDifferentiable]
[PreferRecompute]
float compute(float x, float y, out float k)
{
    k = y * 2;
    return x * y;
}

[BackwardDifferentiable]
[ForceInline]
float infinitesimal(float x)
{
    return x - detach(x);
}

// Test that computeLoop compiles to just return 0.
// CHECK: float computeLoop{{[_0-9]*}}(float y{{[_0-9]*}})
// CHECK-NOT: for{{.*}}
// CHECK: return 0

// Test that computeLoop's intermediates have no float sitting
// around (must not cache the outvar from 'compute()')
// 
// Further, if loop exit value inference is working correctly, 
// then there should be no context type at all.
// 
// CHECK-NOT: struct s_bwd_prop_computeLoop_Intermediates
//
// Check that the signature of the s_bwd_prop_computeLoop function only
// contains an inout DiffPair_float_0 and a float.
//
// CHECK: void s_bwd_prop_computeLoop{{[_0-9]*}}(inout DiffPair_float{{[_0-9]*}} dpy{{[_0-9]*}}, float {{[_a-zA-Z0-9]*}})
//

[BackwardDifferentiable]
[PreferRecompute]
float computeLoop(float y)
{
    float w = 0;

    for (int i = 0; i < 8; i++)
    {
        float k = float(0.f);
        w += compute(i, y, k);
        w += k * k;
    }

    return w - detach(w);
}

// Since computeLoop is recomputed, test_simple_loop should have nothing to store
// therefore we check that there is no intermediate context type generated for test_simple_loop.

// CHECK-NOT: struct {{[a-zA-Z0-9_]*}}test_simple_loop{{[a-zA-Z0-9_]*}}
[BackwardDifferentiable]
float test_simple_loop(float y)
{  
    float x = computeLoop(y);
    return y + x;
}

[numthreads(1, 1, 1)]
void computeMain(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    {
        dpfloat dpa = dpfloat(1.0, 0.0);

        __bwd_diff(test_simple_loop)(dpa, 1.0f);
        outputBuffer[0] = dpa.d; // Expect: 29.0
    }

    {
        dpfloat dpa = dpfloat(0.4, 0.0);

        __bwd_diff(test_simple_loop)(dpa, 0.5f);
        outputBuffer[1] = dpa.d; // Expect: 14.5
    }

    outputBuffer[2] = computeLoop(1.0);
}
