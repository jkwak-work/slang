//TEST:SIMPLE(filecheck=METAL): -target metal

// Metal cross-backend twin of tests/wgsl/non-entrypoint-struct-location.slang
// (issue #10802). The same legalization change is shared between WGSL and Metal,
// so lock the Metal behavior too.
//
// Unlike WGSL, Metal does not emit per-field location attributes on a plain
// (non-entry-point) struct, so `FragmentColorOutput` here is just a normal
// struct. The entry-point output struct must still get unique, ascending
// [[color(N)]] indices, and the shared helper struct must compile cleanly.

struct FragmentColorOutput
{
    float4 color : SV_TARGET0;
    float4 target1 : SV_TARGET1;
};

FragmentColorOutput helperFunction(float4 inColor)
{
    FragmentColorOutput output;
    output.color = inColor;
    output.target1 = float4(0.5, 0.5, 1.0, 1.0);
    return output;
}

struct FragmentOut
{
    float4 color : SV_TARGET0;
    float4 target1 : SV_TARGET1;
    float depth : SV_DEPTH;
};

// METAL: color(0)
// METAL: color(1)
// METAL: depth(any)

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
