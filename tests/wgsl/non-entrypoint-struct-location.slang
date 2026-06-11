//TEST:SIMPLE(filecheck=WGSL): -target wgsl -stage fragment -entry fragmentMain
//TEST:SIMPLE(filecheck=SPIRV): -target wgsl-spirv-asm -stage fragment -entry fragmentMain

//SPIRV: %fragmentMain = OpFunction

struct HelperOutput
{
    //WGSL-LABEL: struct HelperOutput
    //WGSL-DAG: @location(0) helperTarget0
    float4 helperTarget0 : SV_TARGET0;

    //WGSL-DAG: @location(1) helperTarget1
    //WGSL: }
    float4 helperTarget1 : SV_TARGET1;
};

struct FragmentOutput
{
    //WGSL-LABEL: struct FragmentOutput
    //WGSL-DAG: @location(0) entryTarget0
    float4 entryTarget0 : SV_TARGET0;

    //WGSL-DAG: @location(1) entryTarget1
    //WGSL: }
    float4 entryTarget1 : SV_TARGET1;
};

HelperOutput makeHelperOutput()
{
    HelperOutput output;
    output.helperTarget0 = float4(1.0);
    output.helperTarget1 = float4(0.0);
    return output;
}

FragmentOutput fragmentMain()
{
    HelperOutput helperOutput = makeHelperOutput();

    FragmentOutput output;
    output.entryTarget0 = helperOutput.helperTarget0;
    output.entryTarget1 = helperOutput.helperTarget1;
    return output;
}
