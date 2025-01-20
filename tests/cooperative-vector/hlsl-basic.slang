//TEST:SIMPLE(filecheck=GDC):  -entry computeMain -target hlsl -profile cs_6_8
//TEST:SIMPLE(filecheck=GDC_NEGATIVE): -entry computeMain -target hlsl -profile cs_6_8
//T-EST(compute):COMPARE_COMPUTE(filecheck-buffer=BUF): -dx12 -entry computeMain -compute -output-using-type -use-dxil -profile cs_6_8

// Currently DXC crashes when a global variable is called with its member
// method, CopyFrom.
//
#define TEST_when_global_variable_initialization_works

// Currently DXC doesn't support scalar values for clamp function
#define TEST_when_clamp_works_with_scalar

#define COOP_VEC_SIZE 64
#define THREAD_COUNT 64

static int threadID;
// GDC-DAG: static int [[threadID:threadID[0-9_]*]]

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9], stride=4):name=inputByteBuffer
ByteAddressBuffer inputByteBuffer;
// GDC-DAG: ByteAddressBuffer [[IBB:inputByteBuffer[0-9_]*]]

//TEST_INPUT:ubuffer(data=[0 0 0 0 0 0 0 0 0 0], stride=4):name=outputRWByteBuffer
RWByteAddressBuffer outputRWByteBuffer;
// GDC-DAG: RWByteAddressBuffer [[ORWBB:outputRWByteBuffer[0-9_]*]]

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15], stride=4):name=matByteBuffer
ByteAddressBuffer matByteBuffer;
// GDC-DAG: ByteAddressBuffer [[MBB:matByteBuffer[0-9_]*]]

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7], stride=4):name=biasByteBuffer
ByteAddressBuffer biasByteBuffer;
// GDC-DAG: ByteAddressBuffer [[BBB:biasByteBuffer[0-9_]*]]

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9], stride=2):name=inputBuffer_i16
ByteAddressBuffer inputBuffer_i16;

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9], stride=4):name=inputBuffer_i32
ByteAddressBuffer inputBuffer_i32;

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9], stride=2):name=inputBuffer_u16
ByteAddressBuffer inputBuffer_u16;

//TEST_INPUT:ubuffer(data=[0 1 2 3 4 5 6 7 8 9], stride=4):name=inputBuffer_u32
ByteAddressBuffer inputBuffer_u32;

//TEST_INPUT:ubuffer(data=[0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0], stride=2):name=inputBuffer_f16
ByteAddressBuffer inputBuffer_f16;

//TEST_INPUT:ubuffer(data=[0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0], stride=4):name=inputBuffer_f32
ByteAddressBuffer inputBuffer_f32;

//TEST_INPUT:ubuffer(data=[0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0], stride=8):name=inputBuffer_f64
ByteAddressBuffer inputBuffer_f64;

//TEST_INPUT:ubuffer(data=[0 0 0 0], stride=4):out,name=outputBuffer
RWStructuredBuffer<uint> outputBuffer;

// Testing groupshared. Document says:
//   "groupshared" arrays load/stores have a start offset specified in
//   array elements. The amount of data loaded depends on the type and
//   dimensions of the cooperative vector. The type of the cooperative
//   vector should match the type of the groupshared array.
groupshared int16_t  sharedData_i16[THREAD_COUNT];
groupshared uint16_t sharedData_u16[THREAD_COUNT];
groupshared int      sharedData_i32[THREAD_COUNT];
groupshared uint     sharedData_u32[THREAD_COUNT];
groupshared half     sharedData_f16[THREAD_COUNT];
groupshared float    sharedData_f32[THREAD_COUNT];
groupshared double   sharedData_f64[THREAD_COUNT];

// Testing CoopVector as a global variable. Document says:
//   Cooperative vectors can be global or local variables.
static CoopVector<uint, COOP_VEC_SIZE> cv_global;
static CoopVector<int, 4> cv_global_fromInitializer = { 0, 1, 2, 3 };

#if defined(TEST_when_global_variable_initialization_works)
static CoopVector<uint, COOP_VEC_SIZE> cv_global_fromScalar = uint(1);
static CoopVector<uint, COOP_VEC_SIZE> cv_global_copyConstructed = cv_global_fromScalar;
#endif // #if defined(TEST_when_global_variable_initialization_works)

__generic<T:__BuiltinArithmeticType>
T ReadFromBuffer(int value)
{
    if (__type_equals<T,uint>())          return __slang_noop_cast<T>(inputBuffer_u32.Load<uint>(value * sizeof(uint)));
    else if (__type_equals<T,int>())      return __slang_noop_cast<T>(inputBuffer_i32.Load<int>(value * sizeof(int)));
    else if (__type_equals<T,float>())    return __slang_noop_cast<T>(inputBuffer_f32.Load<float>(value * sizeof(float)));
    else if (__type_equals<T,int16_t>())  return __slang_noop_cast<T>(inputBuffer_i16.Load<int16_t>(value * sizeof(int16_t)));
    else if (__type_equals<T,uint16_t>()) return __slang_noop_cast<T>(inputBuffer_u16.Load<uint16_t>(value * sizeof(uint16_t)));
    else if (__type_equals<T,half>())     return __slang_noop_cast<T>(inputBuffer_f16.Load<half>(value * sizeof(half)));
    else if (__type_equals<T,double>())   return __slang_noop_cast<T>(inputBuffer_f64.Load<double>(value * sizeof(double)));
    return T(0);
}

__generic<T:__BuiltinArithmeticType, let N:int>
void InitValueSameAsIndex(out CoopVector<T,N> cv)
{
    if (__type_equals<T,uint>())          cv.Load(inputBuffer_u32, 0);
    else if (__type_equals<T,int>())      cv.Load(inputBuffer_i32, 0);
    else if (__type_equals<T,float>())    cv.Load(inputBuffer_f32, 0);
    else if (__type_equals<T,int16_t>())  cv.Load(inputBuffer_i16, 0);
    else if (__type_equals<T,uint16_t>()) cv.Load(inputBuffer_u16, 0);
    else if (__type_equals<T,half>())     cv.Load(inputBuffer_f16, 0);
    else if (__type_equals<T,double>())   cv.Load(inputBuffer_f64, 0);
    else
    {
        for (int i = 0; i < N; ++i)
            cv[i] = T(i);
    }
}

__generic<T:__BuiltinArithmeticType, let N:int>
void avoidCodeOptimization_noop(CoopVector<T,N> cv)
{}

__generic<T:__BuiltinArithmeticType, let N:int>
bool isAllEqual(const CoopVector<T,N> cv, const T val)
{
    for (int i = 0; i < N; ++i)
    {
        if (cv[i] != val)
            return false;
    }
    return true;
}

__generic<T:__BuiltinArithmeticType, let N:int>
bool isAllEqual(const CoopVector<T,N> lhs, const CoopVector<T,N> rhs)
{
    for (int i = 0; i < N; ++i)
    {
        if (lhs[i] != rhs[i])
            return false;
    }
    return true;
}

__generic<T:__BuiltinArithmeticType, let N:int>
bool isAllEqual(const T arr[N], const T val)
{
    for (int i = 0; i < N; ++i)
    {
        if (arr[i] != val)
            return false;
    }
    return true;
}

__generic<T:__BuiltinArithmeticType, let N:int, let offset:int>
bool isValueSameAsIndex(const CoopVector<T,N> cv)
{
    for (int i = 0; i < N; ++i)
    {
        if (cv[i] != T(i) + T(offset))
            return false;
    }
    return true;
}

__generic<T:__BuiltinArithmeticType, let N:int, let offset:int>
bool isValueSameAsIndex(const T arr[N])
{
    for (int i = 0; i < N; ++i)
    {
        if (arr[i] != T(i) + T(offset))
            return false;
    }
    return true;
}

// ===================
// MatMulAdd(
//        CoopVector<T, K> InputVector,
//        uint Ii,
//        (RW)ByteAddressBuffer Matrix,
//        uint MatrixOffset,
//        uint Mi,
//        (RW)ByteAddressBuffer Bias,
//        uint BiasOffset,
//        uint Bi,
//        uint M,
//        uint K,
//        uint  Layout,
//        bool Transpose,
//        uint  MatrixStride);

__generic<T:__BuiltinArithmeticType, let matOffset:int, let biasOffset:int>
bool test_MatMulAdd()
{
    if (CoopVectorTypeInterpretationFromType<T>() == CoopVectorTypeInterpretation::Unsupported)
        return true; // double is not supported yet

    CoopVector<T,4> input;
    InitValueSameAsIndex(input);

    CoopVector<T,3> result;

    // TODO: we may want to test against different types of matrix and bias
    result.MatMulAdd(
        input,
        CoopVectorTypeInterpretationFromType<T>(), // Ii
        matByteBuffer,
        matOffset,
        CoopVectorTypeInterpretationFromType<uint>(), // Mi
        biasByteBuffer,
        biasOffset,
        CoopVectorTypeInterpretationFromType<uint>(), // Bi
        3, // M
        4, // K
        0, // Layout
        false, // transpose
        12 // MatrixStride
        );

    const uint mo = matOffset / sizeof(uint);
    const uint bo = biasOffset / sizeof(uint);

    return true
        && (result[0] == T((1 + mo) + 2 * (2 + mo) + 3 * (3 + mo) + bo))
        && (result[1] == T((5 + mo) + 2 * (6 + mo) + 3 * (7 + mo) + bo))
        && (result[2] == T((9 + mo) + 2 * (10+ mo) + 3 * (11+ mo) + bo))
        ;

    // GDC-LABEL: bool test_MatMulAdd_0()
    // GDC: .MatMulAdd(
    // GDC-SAME: [[MBB]]
    // GDC-SAME: [[BBB]]
    // GDC: bool test_MatMulAdd_1()
}

__generic<T:__BuiltinArithmeticType, let matOffset:int>
bool test_MatMul()
{
    if (CoopVectorTypeInterpretationFromType<T>() == CoopVectorTypeInterpretation::Unsupported)
        return true; // double is not supported yet

    CoopVector<T,4> input;
    InitValueSameAsIndex(input);

    CoopVector<T,3> result;

    // TODO: we may want to test against different types of matrix
    result.MatMul(
        input,
        CoopVectorTypeInterpretationFromType<T>(), // Ii
        matByteBuffer,
        matOffset,
        CoopVectorTypeInterpretationFromType<uint>(), // Mi
        3, // M
        4, // K
        0, // Layout
        false, // transpose
        12 // MatrixStride
        );

    const uint mo = matOffset / sizeof(uint);

    return true
        && (result[0] == T((1 + mo) + 2 * (2 + mo) + 3 * (3 + mo)))
        && (result[1] == T((5 + mo) + 2 * (6 + mo) + 3 * (7 + mo)))
        && (result[2] == T((9 + mo) + 2 * (10+ mo) + 3 * (11+ mo)))
        ;

    // GDC-LABEL: bool test_MatMul_0()
    // GDC: .MatMul(
    // GDC-SAME: [[MBB]]
    // GDC: bool test_MatMul_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_to_itself()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    cv = cv;

    return isValueSameAsIndex<T,COOP_VEC_SIZE,0>(cv);

    // GDC-LABEL: bool test_assign_to_itself_0()
    // GDC-NOT: .WriteToIndex(
    // GDC-NOT: .ReadFromIndex(
    // GDC-NOT: .CopyFrom(
    // GDC: bool test_assign_to_itself_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,COOP_VEC_SIZE> test_assign_fromCoopVectorFunction_helper()
{
    CoopVector<T,COOP_VEC_SIZE> var = ReadFromBuffer<T>(0);
    return var;
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromCoopVectorFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    cv = test_assign_fromCoopVectorFunction_helper<T>();

    return isValueSameAsIndex<T,COOP_VEC_SIZE,0>(cv);

    // GDC-LABEL: bool test_assign_fromCoopVectorFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // G-DC-NOT: .
    // GDC: bool test_assign_fromCoopVectorFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromCoopVectorVariable()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    CoopVector<T, COOP_VEC_SIZE> src;
    InitValueSameAsIndex(src);

    cv = src;
    src[0] = T(1);

    return isValueSameAsIndex<T,COOP_VEC_SIZE,0>(cv);

    // GDC-LABEL: bool test_assign_fromCoopVectorVariable_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // G-DC-NOT: .
    // GDC: .WriteToIndex(
    // GDC: bool test_assign_fromCoopVectorVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromInitializerList()
{
    CoopVector<T, 4> cv;
    InitValueSameAsIndex(cv);

    cv = { T(0), T(1), T(2), T(3) };

    return isValueSameAsIndex<T,4,0>(cv);

    // GDC-LABEL: bool test_assign_fromInitializerList_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(0, {{.*0.*}});
    // GDC-NEXT: .WriteToIndex(1, {{.*1.*}});
    // GDC-NEXT: .WriteToIndex(2, {{.*2.*}});
    // GDC-NEXT: .WriteToIndex(3, {{.*3.*}});
    // G-DC-NOT: .
    // GDC: bool test_assign_fromInitializerList_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromScalarVariable()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    T var = ReadFromBuffer<T>(0) + T(1);
    cv = var;

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_assign_fromScalarVariable_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: bool test_assign_fromScalarVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromScalarFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    cv = ReadFromBuffer<T>(0);

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_assign_fromScalarFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: bool test_assign_fromScalarFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_assign_fromScalarLiteral()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    cv = T(1);

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_assign_fromScalarLiteral_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: bool test_assign_fromScalarLiteral_1()
}

__generic<T:__BuiltinArithmeticType, let offset:int>
bool test_Store()
{
    // Document says,
    //   offset must be a multiple of 16.

    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    // Store([RW]ByteAddressBuffer outputResource, uint startOffsetInBytes, uint alignment = 0);
    // TODO: it must be a typo that "Store" can take non-rw version of ByteAddressBuffer
    cv.Store(outputRWByteBuffer, offset);

    for (int i = 0; i < COOP_VEC_SIZE; ++i)
    {
        if (outputRWByteBuffer.Load<T>(sizeof(T) * i + offset) != T(i))
            return false;
    }
    return true;

    // GDC-LABEL: bool test_Store_0()
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Store([[ORWBB]], {{[0-9]+}}U, 0U);
    // GDC: bool test_Store_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_builtin_clamp()
{
    const T cval = T(3);
    const T clow = T(1);
    const T chigh = T(2);
    CoopVector<T,COOP_VEC_SIZE> val = cval;
    CoopVector<T,COOP_VEC_SIZE> low = clow;
    CoopVector<T,COOP_VEC_SIZE> high = chigh;

    return true
        && isAllEqual(clamp(val, low, high), T(2))
#if defined(TEST_when_clamp_works_with_scalar)
        && isAllEqual(clamp(val, clow, high), T(2))
        && isAllEqual(clamp(val, low, chigh), T(2))
        && isAllEqual(clamp(val, clow, chigh), T(2))
#endif // #if defined(TEST_when_clamp_works_with_scalar)
        ;

    // GDC-LABEL: bool test_builtin_clamp_0()
    // GDC: .Clamp
    // GDC: .{{(Scalar)?}}Clamp
    // GDC: .{{(Scalar)?}}Clamp
    // GDC: .ScalarClamp
    // GDC: bool test_builtin_clamp_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_builtin_min()
{
    const T clhs = T(3);
    const T crhs = T(2);
    CoopVector<T,COOP_VEC_SIZE> lhs = clhs;
    CoopVector<T,COOP_VEC_SIZE> rhs = crhs;

    return true
        && isAllEqual(min(lhs, rhs), T(3))
        && isAllEqual(min(lhs, crhs), T(3))
        && isAllEqual(min(clhs, rhs), T(2))
        ;

    // GDC-LABEL: bool test_builtin_min_0()
    // GDC: .Min
    // GDC: .ScalarMin
    // GDC: .ScalarMin
    // GDC: bool test_builtin_min_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_arithmetic()
{
    const T clhs = T(3);
    const T crhs = T(2);
    CoopVector<T,COOP_VEC_SIZE> lhs = clhs;
    CoopVector<T,COOP_VEC_SIZE> rhs = crhs;

    return true
        // operator X(CoopVector<T,N>, CoopVector<T,N>)
        && isAllEqual(lhs + rhs, clhs + crhs)
        && isAllEqual(lhs - rhs, clhs - crhs)
        && isAllEqual(lhs * rhs, clhs * crhs)
        && isAllEqual(lhs / rhs, clhs / crhs)
        && isAllEqual(lhs % rhs, clhs % crhs)
        // operator X(CoopVector<T,N>, Scalar)
        && isAllEqual(lhs + crhs, clhs + crhs)
        && isAllEqual(lhs - crhs, clhs - crhs)
        && isAllEqual(lhs * crhs, clhs * crhs)
        && isAllEqual(lhs / crhs, clhs / crhs)
        && isAllEqual(lhs % crhs, clhs % crhs)
        // operator X(Scalar, CoopVector<T,N>)
        && isAllEqual(clhs + rhs, clhs + crhs)
        && isAllEqual(clhs - rhs, clhs - crhs)
        && isAllEqual(clhs * rhs, clhs * crhs)
        && isAllEqual(clhs / rhs, clhs / crhs)
        && isAllEqual(clhs % rhs, clhs % crhs)
        ;

    // GDC-LABEL: bool test_arithmetic_0()
    // GDC: .Add(
    // GDC: .Subtract(
    // GDC: .Multiply(
    // GDC: .Divide(
    // GDC: .Mod(

    // GDC: .ScalarAdd(
    // GDC: .ScalarSubtract(
    // GDC: .ScalarMultiply(
    // GDC: .ScalarDivide(
    // GDC: .ScalarMod(

    // GDC: .{{(Scalar)?}}Add(
    // GDC: .Subtract(
    // GDC: .{{(Scalar)?}}Multiply(
    // GDC: .Divide(
    // GDC: .Mod(
    // GDC: bool test_arithmetic_1()
}

__generic<T:__BuiltinArithmeticType, let N:int>
void test_functionArgument_helper(inout CoopVector<T,N> cv, int idx, T val)
{
    // Testing as a function argument. Document says:
    //   CoopVector objects can be passed as arguments to internal linkage functions.
    //   Internal linkage refers to static functions defined within the same module
    //   that are not export functions.

    cv[idx] = val;
}

__generic<T:__BuiltinArithmeticType, let N:int>
T test_functionArgument_helper(in const CoopVector<T,N> cv, int idx)
{
    return cv[idx];
}

__generic<T:__BuiltinArithmeticType>
bool test_functionArgument_fromCoopVectorVariable()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    test_functionArgument_helper(cv, 0, T(9));
    return cv[0] == T(9);

    // GDC-LABEL: bool test_functionArgument_fromCoopVectorVariable_0()
    // GDC: test_functionArgument_helper{{(_[0-9]+)?}}(
    // GDC: bool test_functionArgument_fromCoopVectorVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_functionArgument_fromInitializerList()
{
    T result = test_functionArgument_helper<T,4>({ T(0), T(1), T(2), T(3) }, 3);
    return result == T(3);

    // GDC-LABEL: bool test_functionArgument_fromInitializerList_0()
    // GDC: test_functionArgument_helper{{(_[0-9]+)?}}(
    // GDC: bool test_functionArgument_fromInitializerList_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_functionArgument_fromScalarVariable()
{
    T var = ReadFromBuffer<T>(0) + T(1);
    T result = test_functionArgument_helper<T,COOP_VEC_SIZE>(var, 0);
    return result == T(1);

    // GDC-LABEL: bool test_functionArgument_fromScalarVariable_0()
    // GDC: test_functionArgument_helper{{(_[0-9]+)?}}(
    // GDC: bool test_functionArgument_fromScalarVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_functionArgument_fromScalarFunction()
{
    T result = test_functionArgument_helper<T,COOP_VEC_SIZE>(ReadFromBuffer<T>(0), 0);
    return result == T(1);

    // GDC-LABEL: bool test_functionArgument_fromScalarFunction_0()
    // GDC: test_functionArgument_helper{{(_[0-9]+)?}}(
    // GDC: bool test_functionArgument_fromScalarFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_functionArgument_fromScalarLiteral()
{
    T result = test_functionArgument_helper<T,COOP_VEC_SIZE>(T(1), 0);
    return result == T(1);

    // GDC-LABEL: bool test_functionArgument_fromScalarLiteral_0()
    // GDC: test_functionArgument_helper{{(_[0-9]+)?}}(
    // GDC: bool test_functionArgument_fromScalarLiteral_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_indexing_write()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    cv[0] = T(9);

    return cv[0] == T(9);

    // GDC-LABEL: bool test_indexing_write_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: ReadFromIndex(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_indexing_write_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_indexing_read()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    InitValueSameAsIndex(cv);

    return cv[COOP_VEC_SIZE -1] == T(COOP_VEC_SIZE -1);

    // GDC-LABEL: bool test_indexing_read_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: ReadFromIndex(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_indexing_read_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Fill()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    cv.Fill(T(1));
    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_Fill_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: Fill(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_Fill_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_length()
{
    const CoopVector<T, COOP_VEC_SIZE> cv;
    return cv.length() == 5;
}

__generic<T:__BuiltinArithmeticType>
bool test_Cast_from_uint8()
{
    CoopVector<T, COOP_VEC_SIZE> cv1 = uint8_t(0);

    CoopVector<uint8_t, COOP_VEC_SIZE> cvFrom;
    InitValueSameAsIndex(cvFrom);

    CoopVector<T, COOP_VEC_SIZE> cv2 = CoopVector<T, COOP_VEC_SIZE>(cvFrom);

    return cv1[0] == T(0) && cv2[0] == T(0);

    // GDC-LABEL: bool test_Cast_from_uint8_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: InitValueSameAsIndex
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom
    // GDC-NOT: .WriteToIndex
    // GDC-LABEL: bool test_Cast_from_uint8_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_implicit()
{
    CoopVector<T, COOP_VEC_SIZE> cv1 = uint8_t(0);

    return cv1[0] == T(0);

    // GDC-LABEL: bool test_Constructor_implicit_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: bool test_Constructor_implicit_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_explicit()
{
    CoopVector<T, COOP_VEC_SIZE> cv1 = CoopVector<T, COOP_VEC_SIZE>(T(1));
    CoopVector<T, COOP_VEC_SIZE> cv2 = CoopVector<T, COOP_VEC_SIZE>(cv1);

    return cv1[0] == T(1) && cv2[0] == T(1);

    // GDC-LABEL: bool test_Constructor_explicit_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex
    // GDC: .CopyFrom
    // GDC: bool test_Constructor_explicit_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T, COOP_VEC_SIZE> test_ConstructorOnReturn_fromCoopVectorFunction_helper()
{
    CoopVector<T, COOP_VEC_SIZE> var = ReadFromBuffer<T>(0);
    return var;
}

__generic<T:__BuiltinArithmeticType>
bool test_ConstructorOnReturn_fromCoopVectorFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv = test_ConstructorOnReturn_fromCoopVectorFunction_helper<T>();

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_ConstructorOnReturn_fromCoopVectorFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_ConstructorOnReturn_fromCoopVectorFunction_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,4> test_ConstructorOnReturn_fromInitializerList_helper()
{
    return { T(0), T(1), T(2), T(3) };
}

__generic<T:__BuiltinArithmeticType>
bool test_ConstructorOnReturn_fromInitializerList()
{
    CoopVector<T, 4> cv = test_ConstructorOnReturn_fromInitializerList_helper<T>();
    avoidCodeOptimization_noop(cv); // avoid inlining

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_ConstructorOnReturn_fromInitializerList_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_ConstructorOnReturn_fromInitializerList_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,COOP_VEC_SIZE> test_ConstructorOnReturn_fromScalarVariable_helper()
{
    T var = ReadFromBuffer<T>(0) + T(1);
    return T(1);
}

__generic<T:__BuiltinArithmeticType>
bool test_ConstructorOnReturn_fromScalarVariable()
{
    CoopVector<T, COOP_VEC_SIZE> cv = test_ConstructorOnReturn_fromScalarVariable_helper<T>();

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_ConstructorOnReturn_fromScalarVariable_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_ConstructorOnReturn_fromScalarVariable_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,COOP_VEC_SIZE> test_ConstructorOnReturn_fromScalarFunction_helper()
{
    return ReadFromBuffer<T>(0);
}

__generic<T:__BuiltinArithmeticType>
bool test_ConstructorOnReturn_fromScalarFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv = test_ConstructorOnReturn_fromScalarFunction_helper<T>();

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_ConstructorOnReturn_fromScalarFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_ConstructorOnReturn_fromScalarFunction_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,COOP_VEC_SIZE> test_ConstructorOnReturn_fromScalarLiteral_helper()
{
    return T(1);
}

__generic<T:__BuiltinArithmeticType>
bool test_ConstructorOnReturn_fromScalarLiteral()
{
    CoopVector<T, COOP_VEC_SIZE> cv = test_ConstructorOnReturn_fromScalarLiteral_helper<T>();

    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_ConstructorOnReturn_fromScalarLiteral_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_ConstructorOnReturn_fromScalarLiteral_1()
}

__generic<T:__BuiltinArithmeticType>
CoopVector<T,COOP_VEC_SIZE> test_CopyConstruct_fromCoopVectorFunction_helper()
{
    CoopVector<T,COOP_VEC_SIZE> cv = T(1);
    return cv;
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_fromCoopVectorFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv = CoopVector<T, COOP_VEC_SIZE>(test_CopyConstruct_fromCoopVectorFunction_helper<T>());
    return isAllEqual(cv, T(0));

    // GDC-LABEL: bool test_CopyConstruct_fromCoopVectorFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // G-DC-NOT: .
    // GDC: bool test_CopyConstruct_fromCoopVectorFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_fromInitializerList()
{
    CoopVector<T, 4> src = { T(0), T(1), T(2), T(3) };

    CoopVector<T, 4> cv = src;
    src[0] = ReadFromBuffer<T>(0);

    return isAllEqual(src, cv);

    // GDC-LABEL: bool test_CopyConstruct_fromInitializerList_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC-COUNT-7: .WriteToIndex(
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_CopyConstruct_fromInitializerList_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_fromScalarVariable()
{
    T var = ReadFromBuffer<T>(0);

    CoopVector<T, 4> cv = CoopVector<T, 4>(var);

    return isAllEqual(cv, T(0));

    // GDC-LABEL: bool test_CopyConstruct_fromScalarVariable_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_CopyConstruct_fromScalarVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_fromScalarFunction()
{
    CoopVector<T, 4> cv = CoopVector<T, 4>(ReadFromBuffer<T>(0));

    return isAllEqual(cv, T(0));

    // GDC-LABEL: bool test_CopyConstruct_fromScalarFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_CopyConstruct_fromScalarFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_fromScalarLiteral()
{
    CoopVector<T, COOP_VEC_SIZE> cv = CoopVector<T, COOP_VEC_SIZE>(T(0));

    return isAllEqual(cv, T(0));

    // GDC-LABEL: bool test_CopyConstruct_fromScalarLiteral_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_CopyConstruct_fromScalarLiteral_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_asLoad()
{
    CoopVector<T, COOP_VEC_SIZE> src;
    InitValueSameAsIndex(src);

    CoopVector<T, COOP_VEC_SIZE> cv = src;
    src[0] = T(0);

    return isAllEqual(src, cv);

    // GDC-LABEL: bool test_CopyConstruct_asLoad_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_CopyConstruct_asLoad_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_CopyConstruct_asExplicitCopy()
{
    CoopVector<T, COOP_VEC_SIZE> src;
    InitValueSameAsIndex(src);

    CoopVector<T, COOP_VEC_SIZE> cv = CoopVector<T, COOP_VEC_SIZE>(src);
    src[0] = T(0);

    return isAllEqual(src, cv);

    // GDC-LABEL: bool test_CopyConstruct_asExplicitCopy_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: CopyFrom(
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // G-DC-NOT: .
    // GDC: bool test_CopyConstruct_asExplicitCopy_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_fromInitializerList()
{
    CoopVector<T, 4> cv = { T(0), T(1), T(2), T(2) + T(1) };

    return isValueSameAsIndex<T, 4, 0>(cv);

    // GDC-LABEL: bool test_Constructor_fromInitializerList_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(0, {{.*}}0));
    // GDC-NEXT: .WriteToIndex(1, {{.*}}1));
    // GDC-NEXT: .WriteToIndex(2, {{.*}}2));
    // GDC-NEXT: .WriteToIndex(3, {{.*}}3));
    // GDC-NOT: .{{[A-Za-z_]}}
    // GDC: bool test_Constructor_fromInitializerList_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_fromScalarVariable()
{
    T var = ReadFromBuffer<T>(0) + T(1);
    CoopVector<T, COOP_VEC_SIZE> cv = var;
    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_Constructor_fromScalarVariable_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_Constructor_fromScalarVariable_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_fromScalarFunction()
{
    CoopVector<T, COOP_VEC_SIZE> cv = ReadFromBuffer<T>(0);
    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_Constructor_fromScalarFunction_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_Constructor_fromScalarFunction_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_fromScalarLiteral()
{
    CoopVector<T, COOP_VEC_SIZE> cv = T(1);
    return isAllEqual(cv, T(1));

    // GDC-LABEL: bool test_Constructor_fromScalarLiteral_0()
    // GDC: {{[A-Za-z_][A-Za-z_0-9]*}}.
    // GDC-SAME: WriteToIndex(
    // GDC: bool test_Constructor_fromScalarLiteral_1()
}

__generic<T:__BuiltinArithmeticType>
bool test_Constructor_supportedTypes()
{
    CoopVector<T, COOP_VEC_SIZE> cv;
    return true;
}

bool test_scope_global_variable_uninitialized()
{
    cv_global[0] = uint(1);
    return cv_global[0] == uint(1);

    // GDC-LABEL: bool test_scope_global_variable_uninitialized_0()
    // GDC: cv_global
}

bool test_scope_global_variable_initialized()
{
    return isValueSameAsIndex<int, 4, 0>(cv_global_fromInitializer)
#if defined(TEST_when_global_variable_initialization_works)
        && isAllEqual(cv_global_fromScalar, uint(1))
        && isAllEqual(cv_global_copyConstructed, uint(1))
#endif // #if defined(TEST_when_global_variable_initialization_works)
        ;

    // GDC-LABEL: bool test_scope_global_variable_initialized_0()
    // GDC: cv_global_fromInitializer
    // GDC: cv_global_fromScalar
    // GDC: cv_global_copyConstructed
}

__generic<let offset:int>
bool test_Load_i16()
{
    CoopVector<int16_t, 10> cv;
    cv.Load(inputByteBuffer, offset);

    return (0 + offset/4 == (cv[0] << 16) + cv[1])
        && (1 + offset/4 == (cv[2] << 16) + cv[3])
        && (2 + offset/4 == (cv[4] << 16) + cv[5])
        && (3 + offset/4 == (cv[6] << 16) + cv[7])
        && (4 + offset/4 == (cv[8] << 16) + cv[9])
        ;

    // GDC-LABEL: bool test_Load_i16_0()
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load([[IBB]]
    // GDC: bool test_Load_i16_1()
}

__generic<let offset:int>
bool test_Load_i32()
{
    CoopVector<int, 4> cv;
    cv.Load(inputByteBuffer, offset);

    return (0 + offset/4 == cv[0])
        && (1 + offset/4 == cv[1])
        && (2 + offset/4 == cv[2])
        && (3 + offset/4 == cv[3])
        ;

    // GDC-LABEL: bool test_Load_i32_0()
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load([[IBB]]
    // GDC: bool test_Load_i32_1()
}

__generic<let offset:int>
bool test_Load_f16()
{
    CoopVector<half, 4> cv;
    cv.Load(inputByteBuffer, offset);

    return (0 + offset/4 == asint(cv[0]))
        && (1 + offset/4 == asint(cv[1]))
        && (2 + offset/4 == asint(cv[2]))
        && (3 + offset/4 == asint(cv[3]))
        ;

    // GDC-LABEL: bool test_Load_f16_0()
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load([[IBB]]
    // GDC: bool test_Load_f16_1()
}

__generic<let offset:int>
bool test_Load_f32()
{
    CoopVector<float, 4> cv;
    cv.Load(inputByteBuffer, offset);

    return (0 + offset/4 == asint(cv[0]))
        && (1 + offset/4 == asint(cv[1]))
        && (2 + offset/4 == asint(cv[2]))
        && (3 + offset/4 == asint(cv[3]))
        ;

    // GDC-LABEL: bool test_Load_f32_0()
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load([[IBB]]
    // GDC: bool test_Load_f32_1()
}

__generic<let offset:int>
bool test_Load_groupshared_i16()
{
    typealias T = int16_t;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_i16[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_i16, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_i16_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_i16_1(
}

__generic<let offset:int>
bool test_Load_groupshared_u16()
{
    typealias T = uint16_t;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_u16[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_u16, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_u16_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_u16_1(
}

__generic<let offset:int>
bool test_Load_groupshared_i32()
{
    typealias T = int32_t;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_i32[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_i32, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_i32_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_i32_1(
}

__generic<let offset:int>
bool test_Load_groupshared_u32()
{
    typealias T = uint32_t;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_u32[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_u32, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_u32_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_u32_1(
}

__generic<let offset:int>
bool test_Load_groupshared_f16()
{
    typealias T = half;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_f16[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_f16, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_f16_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_f16_1(
}

__generic<let offset:int>
bool test_Load_groupshared_f32()
{
    typealias T = float;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_f32[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_f32, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_f32_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_f32_1(
}

__generic<let offset:int>
bool test_Load_groupshared_f64()
{
    typealias T = double;
    CoopVector<T, THREAD_COUNT - offset> cv;

    sharedData_f64[threadID] = T(threadID);
    GroupMemoryBarrierWithGroupSync();

    cv.Load(sharedData_f64, offset);

    return isValueSameAsIndex<T,THREAD_COUNT - offset,offset>(cv);

    // GDC-LABEL: bool test_Load_groupshared_f64_0(
    // GDC: CoopVector<{{[^>]+}}> [[CV:cv[_0-9]+]];
    // GDC: [[CV]].Load(sharedData{{.*}}, {{[0-9]+}}U);
    // GDC-LABEL: bool test_Load_groupshared_f64_1(
}

bool test_Store_groupshared_i16()
{
    typealias T = int16_t;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_i16, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_i16, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_i16_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_u16()
{
    typealias T = uint16_t;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_u16, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_u16, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_u16_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_i32()
{
    typealias T = int32_t;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_i32, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_i32, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_i32_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_u32()
{
    typealias T = uint32_t;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_u32, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_u32, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_u32_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_f16()
{
    typealias T = half;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_f16, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_f16, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_f16_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_f32()
{
    typealias T = float;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_f32, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_f32, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_f32_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_f64()
{
    typealias T = double;
    CoopVector<T, THREAD_COUNT> cv = T(THREAD_COUNT);

    cv.Store(sharedData_f64, 0);
    GroupMemoryBarrierWithGroupSync();

    return isAllEqual(sharedData_f64, T(THREAD_COUNT));

    // GDC-LABEL: bool test_Store_groupshared_f64_0(
    // GDC: .Store(sharedData{{.*}}, 0U);
}

bool test_Store_groupshared_offset_i16()
{
    typealias T = int16_t;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_i16, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_i16);

    // GDC-LABEL: bool test_Store_groupshared_offset_i16_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_u16()
{
    typealias T = uint16_t;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_u16, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_u16);

    // GDC-LABEL: bool test_Store_groupshared_offset_u16_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_i32()
{
    typealias T = int32_t;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_i32, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_i32);

    // GDC-LABEL: bool test_Store_groupshared_offset_i32_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_u32()
{
    typealias T = uint32_t;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_u32, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_u32);

    // GDC-LABEL: bool test_Store_groupshared_offset_u32_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_f16()
{
    typealias T = half;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_f16, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_f16);

    // GDC-LABEL: bool test_Store_groupshared_offset_f16_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_f32()
{
    typealias T = float;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_f32, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_f32);

    // GDC-LABEL: bool test_Store_groupshared_offset_f32_0(
    // GDC: .Store(sharedData
}

bool test_Store_groupshared_offset_f64()
{
    typealias T = double;
    CoopVector<T, 1> cv = T(threadID);

    cv.Store(sharedData_f64, uint(threadID));
    GroupMemoryBarrierWithGroupSync();

    return isValueSameAsIndex<T,THREAD_COUNT,0>(sharedData_f64);

    // GDC-LABEL: bool test_Store_groupshared_offset_f64_0(
    // GDC: .Store(sharedData
}

__generic<T:__BuiltinIntegerType>
bool test_bitwise()
{
    CoopVector<T,8> lhs = { T(0), T(1), T(2), T(3), T(4), T(5), T(6), T(7) };
    CoopVector<T,8> rhs = T(3);

    CoopVector<T,8> expectedAnd = { T(0), T(1), T(2), T(3), T(0), T(1), T(2), T(3) };
    CoopVector<T,8> expectedOr  = { T(3), T(3), T(3), T(3), T(7), T(7), T(7), T(7) };
    CoopVector<T,8> expectedXor = { T(3), T(2), T(1), T(0), T(7), T(6), T(5), T(4) };
    CoopVector<T,8> expectedLshift = { T(0) << 3, T(1) << 3, T(2) << 3, T(3) << 3, T(4) << 3, T(5) << 3, T(6) << 3, T(7) << 3 };
    CoopVector<T,8> expectedRshift = { T(0) >> 3, T(1) >> 3, T(2) >> 3, T(3) >> 3, T(4) >> 3, T(5) >> 3, T(6) >> 3, T(7) >> 3 };

    return true
        // operator X(CoopVector, CoopVector)
        && isAllEqual(lhs & rhs, expectedAnd)
        && isAllEqual(lhs | rhs, expectedOr)
        && isAllEqual(lhs ^ rhs, expectedXor)
        // operator X(CoopVector, Scalar)
        && isAllEqual(lhs & T(3), expectedAnd)
        && isAllEqual(lhs | T(3), expectedOr)
        && isAllEqual(lhs ^ T(3), expectedXor)
        && isAllEqual(lhs << int(3), expectedLshift)
        && isAllEqual(lhs >> int(3), expectedRshift)
        // operator X(Scalar, CoopVector)
        && isAllEqual(T(3) & lhs, expectedAnd)
        && isAllEqual(T(3) | lhs, expectedOr)
        && isAllEqual(T(3) ^ lhs, expectedXor)
        ;

    // GDC-LABEL: bool test_bitwise_0()
    // GDC: .BitwiseOR(
    // GDC: .BitwiseXOR(
    // GDC: .{{(Scalar)?}}BitwiseAND(
    // GDC: .{{(Scalar)?}}BitwiseOR(
    // GDC: .{{(Scalar)?}}BitwiseXOR(
    // GDC: .{{(Scalar)?}}SHL(
    // GDC: .{{(Scalar)?}}SHR(
    // GDC: .ScalarBitwiseAND(
    // GDC: .ScalarBitwiseOR(
    // GDC: .ScalarBitwiseXOR(
    // GDC: bool test_bitwise_1()
}

bool test_bitwise_not_16bit()
{
    CoopVector<int16_t,8>  iLHS;
    CoopVector<uint16_t,8> uLHS;
    InitValueSameAsIndex(iLHS);
    InitValueSameAsIndex(uLHS);

    // Workaround for an issue that operator~() cannot be overriden.
    // It seems that slang is confused it as a destructor.
    CoopVector<int16_t,8>  iActual = iLHS;
    CoopVector<uint16_t,8> uActual = uLHS;

    iActual.NOT();
    uActual.NOT();

    CoopVector<int16_t,8>  iExpected = { ~0, ~1, ~2, ~3, ~4, ~5, ~6, ~7};
    CoopVector<uint16_t,8> uExpected = { ~0, ~1, ~2, ~3, ~4, ~5, ~6, ~7};

    return true
        && isAllEqual(iActual, iExpected)
        && isAllEqual(uActual, uExpected)
        ;

    // GDC-LABEL: bool test_bitwise_not_16bit_0()
    // GDC-NOT: .WriteToIndex(
    // GDC-NOT: .ReadFromIndex(
    // GDC-COUNT-2: .NOT(
}

bool test_bitwise_not_32bit()
{
    CoopVector<int,8>      iLHS;
    CoopVector<uint,8>     uLHS;
    InitValueSameAsIndex(iLHS);
    InitValueSameAsIndex(uLHS);

    // Workaround for an issue that operator~ cannot be overriden.
    // It seems that slang is confused it as a destructor.
    CoopVector<int,8>      iActual = iLHS;
    CoopVector<uint,8>     uActual = uLHS;

    iActual.NOT();
    uActual.NOT();

    CoopVector<int,8>      iExpected = { ~0, ~1, ~2, ~3, ~4, ~5, ~6, ~7};
    CoopVector<uint,8>     uExpected = { ~0, ~1, ~2, ~3, ~4, ~5, ~6, ~7};

    return true
        && isAllEqual(iActual, iExpected)
        && isAllEqual(uActual, uExpected)
        ;

    // GDC-LABEL: bool test_bitwise_not_32bit_0()
    // GDC-NOT: .WriteToIndex(
    // GDC-NOT: .ReadFromIndex(
    // GDC-COUNT-2: .NOT(
}

__generic<T:__BuiltinArithmeticType>
bool testCoopVector_ForeachType()
{
    // Calling test functions in a reverse order to get FileChecker working.
    // It appears that slangc generates the output source in a reverse order
    // of when they were called. In other words, functions called first appear
    // at the bottom of the source.
    // This reordering causes a problem for FileChecker to function properly.
    // In order to avoid it, the functions are called in a specific order that
    // FileChecker can function properly.
    return true
        && test_Constructor_supportedTypes<T>()
        && test_Constructor_fromScalarLiteral<T>()
        && test_Constructor_fromScalarFunction<T>()
        && test_Constructor_fromScalarVariable<T>()
        && test_Constructor_fromInitializerList<T>()
        && test_CopyConstruct_asExplicitCopy<T>()
        && test_CopyConstruct_asLoad<T>()
        && test_CopyConstruct_fromScalarLiteral<T>()
        && test_CopyConstruct_fromScalarFunction<T>()
        && test_CopyConstruct_fromScalarVariable<T>()
        && test_CopyConstruct_fromInitializerList<T>()
        && test_CopyConstruct_fromCoopVectorFunction<T>()
        && test_ConstructorOnReturn_fromScalarLiteral<T>()
        && test_ConstructorOnReturn_fromScalarFunction<T>()
        && test_ConstructorOnReturn_fromScalarVariable<T>()
        && test_ConstructorOnReturn_fromInitializerList<T>()
        && test_ConstructorOnReturn_fromCoopVectorFunction<T>()
        && test_Constructor_explicit<T>()
        && test_Constructor_implicit<T>()
        && test_Cast_from_uint8<T>()
        && test_length<T>()
        && test_Fill<T>()
        && test_indexing_read<T>()
        && test_indexing_write<T>()
        && test_functionArgument_fromScalarLiteral<T>()
        && test_functionArgument_fromScalarFunction<T>()
        && test_functionArgument_fromScalarVariable<T>()
        && test_functionArgument_fromInitializerList<T>()
        && test_functionArgument_fromCoopVectorVariable<T>()
        //&& test_functionArgument_fromCoopVectorFunction<T>() // TODO
        && test_arithmetic<T>()
        && test_builtin_min<T>()
        && test_builtin_clamp<T>()
        && test_Store<T,0>()
        && test_Store<T,16>() // offset 16
        && test_assign_fromScalarLiteral<T>()
        && test_assign_fromScalarFunction<T>()
        && test_assign_fromScalarVariable<T>()
        && test_assign_fromInitializerList<T>()
        && test_assign_fromCoopVectorVariable<T>()
        && test_assign_fromCoopVectorFunction<T>()
        && test_assign_to_itself<T>()
        && test_MatMul<T,0>()
        && test_MatMul<T,16>() // matOffset 16
        && test_MatMulAdd<T,0,0>()
        && test_MatMulAdd<T,16,0>() // matOffset 16
        && test_MatMulAdd<T,0,16>() // biasOffset 16
        ;
}

bool testCoopVector_SpecialCases()
{
    return true
        && test_scope_global_variable_uninitialized()
        && test_scope_global_variable_initialized()
        && test_Load_i16<0>()
        && test_Load_i16<16>() // offset 16 byte
        && test_Load_i32<0>()
        && test_Load_i32<16>() // offset 16 byte
        && test_Load_f16<0>()
        && test_Load_f16<16>() // offset 16 byte
        && test_Load_f32<0>()
        && test_Load_f32<16>() // offset 16 byte
        && test_Load_groupshared_i16<0>()
        && test_Load_groupshared_i16<1>() // offset 1 element
        && test_Load_groupshared_u16<0>()
        && test_Load_groupshared_u16<1>() // offset 1 element
        && test_Load_groupshared_i32<0>()
        && test_Load_groupshared_i32<1>() // offset 1 element
        && test_Load_groupshared_u32<0>()
        && test_Load_groupshared_u32<1>() // offset 1 element
        && test_Load_groupshared_f16<0>()
        && test_Load_groupshared_f16<1>() // offset 1 element
        && test_Load_groupshared_f32<0>()
        && test_Load_groupshared_f32<1>() // offset 1 element
        && test_Load_groupshared_f64<0>()
        && test_Load_groupshared_f64<1>() // offset 1 element
        && test_Store_groupshared_i16()
        && test_Store_groupshared_u16()
        && test_Store_groupshared_i32()
        && test_Store_groupshared_u32()
        && test_Store_groupshared_f16()
        && test_Store_groupshared_f32()
        && test_Store_groupshared_f64()
        && test_Store_groupshared_offset_i16()
        && test_Store_groupshared_offset_u16()
        && test_Store_groupshared_offset_i32()
        && test_Store_groupshared_offset_u32()
        && test_Store_groupshared_offset_f16()
        && test_Store_groupshared_offset_f32()
        && test_Store_groupshared_offset_f64()
        && test_bitwise<int16_t>()
        && test_bitwise<uint16_t>()
        && test_bitwise_not_16bit()
        && test_bitwise<int32_t>()
        && test_bitwise<uint32_t>()
        && test_bitwise_not_32bit()
        ;
}

[numthreads(THREAD_COUNT, 1, 1)]
void computeMain(int3 dispatchThreadID : SV_DispatchThreadID)
{
    threadID = dispatchThreadID.x;

    bool result = true
        && testCoopVector_ForeachType<int16_t>()
        && testCoopVector_ForeachType<uint16_t>()
        && testCoopVector_ForeachType<int>()
        && testCoopVector_ForeachType<uint>()
        && testCoopVector_ForeachType<half>()
        && testCoopVector_ForeachType<float>()
        && testCoopVector_ForeachType<double>()
        && testCoopVector_SpecialCases()
        ;

    outputBuffer[0] = uint(result);

    // GDC-LABEL: void computeMain(
    // GDC: [[CV:cv_global_fromInitializer[_0-9]+]].CopyFrom(
    // GDC: [[CV:cv_global_fromScalar[_0-9]+]].CopyFrom(
    // GDC: [[CV:cv_global_copyConstructed[_0-9]+]].CopyFrom(

    // GDC_NEGATIVE-NOT: CoopVector<{{[^>]+}}>{{.*}} = {{.+}};

    // BUF: 1
}

