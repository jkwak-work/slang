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

/// Explicit cache control: drop all front-end IR blobs cached on this session, freeing their
/// memory. The hit count is left unchanged. Safe to call at any time; subsequent compilations
/// repopulate the cache as needed.
SLANG_API void slang_clearFrontEndIRCache(slang::IGlobalSession* globalSession);

/// Explicit cache control: enable or disable retention of new front-end IR cache entries on this
/// session. When disabled ("do-not-keep" mode), entries already present are still reused but no
/// new entries are stored, so memory stops growing. Defaults to enabled.
SLANG_API void slang_setFrontEndIRCacheEnabled(slang::IGlobalSession* globalSession, bool enabled);

#endif
