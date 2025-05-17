#pragma once
#include <cstdint>
#include <string>

namespace Slang
{
// Forward declaration to avoid circular dependency
struct IRInst;

class TrackUID {
public:
    TrackUID(const char* event, IRInst* inst);
    ~TrackUID();
    static void log(const char* event, IRInst* inst);
private:
    static void logToFile(const std::string& msg);
    static thread_local int s_indentLevel;
    std::string m_event;
    uint64_t m_uid;
};

}
