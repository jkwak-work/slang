//TEST:SIMPLE(filecheck=CHECK): -target wgsl -stage fragment -entry fragmentMain

// Regression test for issue #10802.
//
// A struct carrying SV_TARGET semantics that is NOT used directly as an
// entry-point parameter/return type (here it is only produced by a helper
// function) must still get unique @location indices in WGSL output. Previously
// both fields were emitted as @location(0), which is invalid WGSL.

struct FragmentColorOutput
{
    //CHECK: @location(0) color
    float4 color : SV_TARGET0;

    //CHECK: @location(1) target1
    float4 target1 : SV_TARGET1;
};

FragmentColorOutput helperFunction(float4 inColor)
{
    FragmentColorOutput output;
    output.color = inColor;
    output.target1 = float4(0.5, 0.5, 1.0, 1.0);
    return output;
}

// Entry point returns a DIFFERENT struct that wraps the helper result.
struct FragmentOut
{
    //CHECK: @location(0) color
    float4 color : SV_TARGET0;

    //CHECK: @location(1) target1
    float4 target1 : SV_TARGET1;

    //CHECK: @builtin(frag_depth) depth
    float depth : SV_DEPTH;
};

[shader("fragment")]
FragmentOut fragmentMain(float4 inColor : COLOR)
{
    FragmentOut output;
    FragmentColorOutput helperOut = helperFunction(inColor);
    output.color = helperOut.color;
    output.target1 = helperOut.target1;
    output.depth = 0.5;
    return output;
}
