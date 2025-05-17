#include "slang-ir-track-uid.h"
#include "slang-ir.h"

#include <fstream>
#include <sstream>


namespace Slang
{

thread_local int TrackUID::s_indentLevel = 0;


namespace {
    std::ofstream& getLogFile() {
        // Use std::ofstream::out mode to truncate the file (create new) instead of append
        static std::ofstream file("ir-dump.txt", std::ios::out);
        return file;
    }
}

void TrackUID::logToFile(const std::string& msg) {
    getLogFile() << msg << std::endl;
}

void TrackUID::log(const char* event, IRInst* inst) {
#if SLANG_ENABLE_IR_BREAK_ALLOC
    uint64_t uid = inst ? inst->_debugUID : 0;
    std::ostringstream oss;
    oss << std::string(s_indentLevel * 2, ' ')
        << "+ Create: [" << event << "] UID: " << uid;
    logToFile(oss.str());
#endif
}

// Constructor: takes IRInst* and uses _debugUID
TrackUID::TrackUID(const char* event, IRInst* inst)
    : m_event(event)
{
#if SLANG_ENABLE_IR_BREAK_ALLOC
    m_uid = inst ? inst->_debugUID : 0;
    std::ostringstream oss;
    oss << std::string(s_indentLevel * 2, ' ')
        << "+ PUSH: [" << m_event << "] UID: " << m_uid;
    logToFile(oss.str());
    ++s_indentLevel;
#endif
}

TrackUID::~TrackUID() {
#if SLANG_ENABLE_IR_BREAK_ALLOC
    --s_indentLevel;
    std::ostringstream oss;
    oss << std::string(s_indentLevel * 2, ' ')
        << "- POP:  [" << m_event << "] UID: " << m_uid;
    logToFile(oss.str());
#endif
}

}
