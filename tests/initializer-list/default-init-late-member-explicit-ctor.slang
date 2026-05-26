//TEST:SIMPLE:

#define SPECTRAL_N 4

struct SpectralSample
{
    float values[SPECTRAL_N];

    __init(const float f = 0.0f)
    {
        for (uint i = 0; i < SPECTRAL_N; ++i)
            values[i] = f;
    }
};

typedef SpectralSample ColorSample;

struct DiffuseBSDFData
{
    ColorSample tint;
    float roughness;
};

struct MicrofacetBSDFData
{
    ColorSample tint;
    float roughnessU;
};

struct FresnelLayerBSDFData
{
    MicrofacetBSDFData layer;
    WeightedLayerBSDFData base;
};

struct WeightedLayerBSDFData
{
    ColorSample weight;
    MicrofacetBSDFData layer;
    DiffuseBSDFData base;
};

struct Outer
{
    FresnelLayerBSDFData data;
};

void init(inout Outer outer)
{
    outer = {};
}

[shader("compute")]
[numthreads(1, 1, 1)]
void main()
{
    Outer outer;
    init(outer);
}
