// unit-test-front-end-ir-cache.cpp

// Tests the `-use-shared-front-end-ir` optimization (slang issue 11176): when enabled, the
// lowered, target-agnostic IR for a command-line translation unit is cached on the session and
// reused by a later compilation of the same source with the same front-end options (e.g. for a
// different target). This test asserts that reuse is *correctness-preserving*: the generated
// artifacts are byte-identical whether the IR is recomputed from scratch or loaded from the
// cache, including across different targets sharing one front-end result.

#include "core/slang-io.h"
#include "slang-com-ptr.h"
#include "slang.h"
#include "slang/slang-internal.h"
#include "unit-test/slang-unit-test.h"

#include <stdio.h>
#include <stdlib.h>

using namespace Slang;

namespace
{
void _appendDiagnostic(char const* message, void* userData)
{
    ((StringBuilder*)userData)->append(message);
}

// Compile entry point `computeMain` of `path` to `targetName`, writing the result to `outPath`,
// through the slangc command-line compile path (an `ICompileRequest` in command-line mode) so
// that the front-end IR cache hooks are exercised exactly as they are by slang-test. Optionally
// enables the shared front-end IR cache. Returns the generated artifact ("" on failure).
String compileToTarget(
    slang::IGlobalSession* globalSession,
    const char* path,
    const char* targetName,
    const char* outPath,
    bool useCache)
{
    SlangCompileRequest* request = spCreateCompileRequest(globalSession);
    if (!request)
        return String();

    StringBuilder diagnostics;
    spSetDiagnosticCallback(request, _appendDiagnostic, &diagnostics);
    spSetCommandLineCompilerMode(request);

    List<const char*> args;
    args.add(path);
    args.add("-target");
    args.add(targetName);
    args.add("-entry");
    args.add("computeMain");
    args.add("-stage");
    args.add("compute");
    args.add("-o");
    args.add(outPath);
    if (useCache)
        args.add("-use-shared-front-end-ir");

    SlangResult result =
        spProcessCommandLineArguments(request, args.getBuffer(), (int)args.getCount());
    if (SLANG_SUCCEEDED(result))
        result = spCompile(request);
    spDestroyCompileRequest(request);

    if (SLANG_FAILED(result))
    {
        fprintf(stderr, "front-end-ir-cache: compile failed: %s\n", diagnostics.getBuffer());
        return String();
    }

    String contents;
    if (SLANG_FAILED(File::readAllText(outPath, contents)))
        return String();
    return contents;
}
} // namespace

SLANG_UNIT_TEST(frontEndIRCache)
{
    // Write a small, target-agnostic compute shader to a real file so the cache (which keys on
    // the source path and content digest) has a stable identity to work with.
    const char* source = R"(
        RWStructuredBuffer<float> gBuffer;

        float helper(uint i)
        {
            float acc = 0.0f;
            for (uint k = 0; k < i; ++k)
                acc += float(k) * 0.5f;
            return acc;
        }

        [numthreads(4, 1, 1)]
        void computeMain(uint3 tid : SV_DispatchThreadID)
        {
            gBuffer[tid.x] = helper(tid.x) + float(tid.x) * 2.0f;
        }
    )";

    // Use unique temp paths (in the system temp dir) so parallel or retried runs cannot race on
    // shared filenames, and clean them up via RAII so nothing leaks if a check aborts.
    struct TempFiles
    {
        List<String> paths;
        ~TempFiles()
        {
            for (auto& p : paths)
                File::remove(p);
        }
    } tempFiles;

    String base;
    SLANG_CHECK_ABORT(
        SLANG_SUCCEEDED(File::generateTemporary(UnownedStringSlice("slang-fe-ir-cache"), base)));
    String tempPath = base + ".slang";
    String spirvOut = base + ".spirv-asm";
    String hlslOut = base + ".hlsl";
    tempFiles.paths.add(base);
    tempFiles.paths.add(tempPath);
    tempFiles.paths.add(spirvOut);
    tempFiles.paths.add(hlslOut);

    SLANG_CHECK_ABORT(SLANG_SUCCEEDED(File::writeAllText(tempPath, source)));

    ComPtr<slang::IGlobalSession> globalSession;
    SLANG_CHECK_ABORT(
        slang_createGlobalSession(SLANG_API_VERSION, globalSession.writeRef()) == SLANG_OK);

    const char* pathStr = tempPath.getBuffer();

    // Authoritative references computed with the cache disabled: these never touch the cache.
    String baselineSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), false);
    String baselineHlsl =
        compileToTarget(globalSession, pathStr, "hlsl", hlslOut.getBuffer(), false);
    SLANG_CHECK(baselineSpirv.getLength() != 0);
    SLANG_CHECK(baselineHlsl.getLength() != 0);
    // Disabled-cache compiles must not populate or consult the cache.
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == 0);

    // First cache-enabled compile: a miss that populates the cache with the lowered IR.
    String coldSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == 0);

    // Second cache-enabled compile of the same source/target: a hit that reuses the cached IR.
    int64_t hitsBeforeWarm = slang_getFrontEndIRCacheHitCount(globalSession);
    String warmSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeWarm + 1);

    // Cache-enabled compile for a *different* target: the front end is target-agnostic, so this
    // reuses the same cached IR (the core scenario from issue 11176).
    int64_t hitsBeforeCross = slang_getFrontEndIRCacheHitCount(globalSession);
    String warmHlsl = compileToTarget(globalSession, pathStr, "hlsl", hlslOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeCross + 1);

    // The whole point: reused IR must produce byte-identical artifacts to recomputed IR.
    SLANG_CHECK(coldSpirv == baselineSpirv);
    SLANG_CHECK(warmSpirv == baselineSpirv);
    SLANG_CHECK(warmHlsl == baselineHlsl);

    // --- Explicit cache controls (issue 11176) ----------------------------------------------
    // These let an embedder bound memory on a long-lived session.

    // clearFrontEndIRCache() drops cached entries: the next compile of an already-seen
    // source/target is a miss again (no new hit), and only the compile after that re-hits.
    int64_t hitsBeforeClear = slang_getFrontEndIRCacheHitCount(globalSession);
    slang_clearFrontEndIRCache(globalSession);
    String afterClearSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeClear);
    String reWarmSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeClear + 1);
    SLANG_CHECK(afterClearSpirv == baselineSpirv);
    SLANG_CHECK(reWarmSpirv == baselineSpirv);

    // Disabling retention ("do-not-keep" mode) stops new entries from being stored: after a
    // clear, repeated compiles never accumulate hits because nothing is retained.
    slang_setFrontEndIRCacheEnabled(globalSession, false);
    slang_clearFrontEndIRCache(globalSession);
    int64_t hitsBeforeDisabled = slang_getFrontEndIRCacheHitCount(globalSession);
    String disabledSpirv1 =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    String disabledSpirv2 =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeDisabled);
    SLANG_CHECK(disabledSpirv1 == baselineSpirv);
    SLANG_CHECK(disabledSpirv2 == baselineSpirv);

    // Re-enabling restores normal caching: the first compile repopulates (miss), the next hits.
    slang_setFrontEndIRCacheEnabled(globalSession, true);
    int64_t hitsBeforeReenable = slang_getFrontEndIRCacheHitCount(globalSession);
    String reenableMissSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeReenable);
    String reenableWarmSpirv =
        compileToTarget(globalSession, pathStr, "spirv-asm", spirvOut.getBuffer(), true);
    SLANG_CHECK(slang_getFrontEndIRCacheHitCount(globalSession) == hitsBeforeReenable + 1);
    SLANG_CHECK(reenableMissSpirv == baselineSpirv);
    SLANG_CHECK(reenableWarmSpirv == baselineSpirv);
}
