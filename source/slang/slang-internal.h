#ifndef SLANG_INTERNAL_H_INCLUDED
#define SLANG_INTERNAL_H_INCLUDED

#include "slang.h"

namespace Slang
{
struct GlobalSessionInternalDesc
{
    bool isBootstrap = false;
};
} // namespace Slang

SLANG_API SlangResult slang_createGlobalSessionImpl(
    const SlangGlobalSessionDesc* desc,
    const Slang::GlobalSessionInternalDesc* internalDesc,
    slang::IGlobalSession** outGlobalSession);

SLANG_API void spSetCommandLineCompilerMode(SlangCompileRequest* request);

/// Test/diagnostic hook: returns the number of times this global session reused front-end IR
/// from its cache (see the `UseSharedFrontEndIR` option). Used by unit tests to confirm the
/// optimization is actually engaged.
SLANG_API int64_t slang_getFrontEndIRCacheHitCount(slang::IGlobalSession* globalSession);

#endif
