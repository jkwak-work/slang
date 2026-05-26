//TEST(compute):COMPARE_COMPUTE(filecheck-buffer=BUFFER):-cpu -shaderobj

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

bool isZeroColorSample(ColorSample value)
{
    bool result = true;
    for (uint i = 0; i < SPECTRAL_N; ++i)
        result = result && value.values[i] == 0.0f;
    return result;
}

bool isZeroDiffuse(DiffuseBSDFData value)
{
    return isZeroColorSample(value.tint) && value.roughness == 0.0f;
}

bool isZeroMicrofacet(MicrofacetBSDFData value)
{
    return isZeroColorSample(value.tint) && value.roughnessU == 0.0f;
}

bool isZeroWeightedLayer(WeightedLayerBSDFData value)
{
    return isZeroColorSample(value.weight) && isZeroMicrofacet(value.layer) &&
           isZeroDiffuse(value.base);
}

bool isZeroFresnelLayer(FresnelLayerBSDFData value)
{
    return isZeroMicrofacet(value.layer) && isZeroWeightedLayer(value.base);
}

bool isZeroOuter(Outer value)
{
    return isZeroFresnelLayer(value.data);
}

void init(inout Outer outer)
{
    outer = {};
}

//TEST_INPUT:ubuffer(data=[0], stride=4):out,name=outputBuffer
RWStructuredBuffer<int> outputBuffer;

[shader("compute")]
[numthreads(1, 1, 1)]
void computeMain()
{
    Outer outer;
    init(outer);

    outputBuffer[0] = isZeroOuter(outer) ? 1 : 0;
    // BUFFER: 1
}
