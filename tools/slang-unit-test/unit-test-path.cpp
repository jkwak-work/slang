// unit-test-path.cpp

#include "../../source/core/slang-io.h"
#include "unit-test/slang-unit-test.h"

using namespace Slang;

SLANG_UNIT_TEST(path)
{
#if SLANG_WINDOWS_FAMILY
    // Disable for now on non windows has some problems on *some* Linux based CI.
    {
        String path;
        SlangResult res = Path::getCanonical("source/slang", path);
        SLANG_CHECK(SLANG_SUCCEEDED(res));

        String parentPath;
        res = Path::getCanonical("source", parentPath);
        SLANG_CHECK(SLANG_SUCCEEDED(res));

        String parentPath2 = Path::getParentDirectory(path);
        SLANG_CHECK(parentPath == parentPath2);
    }

    {
        SLANG_CHECK(Path::isAbsolute("/mnt/c/projects"));
        SLANG_CHECK(Path::simplify("/mnt/c/projects/../shader.slang") == "C:/shader.slang");
    }

    {
        String currentPath = Path::getCurrentPath();
        UnownedStringSlice currentPathSlice = currentPath.getUnownedSlice();
        if (currentPath.getLength() >= 3 && Path::isDriveSpecification(currentPathSlice.head(2)) &&
            Path::isDelimiter(currentPath[2]))
        {
            StringBuilder wslPath;
            char driveLetter = currentPath[0];
            if (driveLetter >= 'A' && driveLetter <= 'Z')
            {
                driveLetter = char(driveLetter - 'A' + 'a');
            }

            wslPath.append("/mnt/");
            wslPath.appendChar(driveLetter);
            for (Index i = 2; i < currentPath.getLength(); ++i)
            {
                const char c = currentPath[i];
                wslPath.appendChar(Path::isDelimiter(c) ? '/' : c);
            }

            const String wslPathString = wslPath.produceString();
            String canonicalPath;
            SlangResult res = Path::getCanonical(wslPathString, canonicalPath);
            SLANG_CHECK(SLANG_SUCCEEDED(res));
            SLANG_CHECK(canonicalPath.equals(currentPath, false));
            SLANG_CHECK(File::exists(wslPathString));

            SlangPathType pathType;
            res = Path::getPathType(wslPathString, &pathType);
            SLANG_CHECK(SLANG_SUCCEEDED(res));
            SLANG_CHECK(pathType == SLANG_PATH_TYPE_DIRECTORY);
        }
    }
#endif
    // Test the paths
    {
        SLANG_CHECK(Path::simplify(".") == ".");
        SLANG_CHECK(Path::simplify("..") == "..");
        SLANG_CHECK(Path::simplify("blah/..") == ".");

        SLANG_CHECK(Path::simplify("blah/.././a") == "a");

        SLANG_CHECK(Path::simplify("a:/what/.././../is/./../this/.") == "a:/../this");

        SLANG_CHECK(Path::simplify("a:/what/.././../is/./../this/./") == "a:/../this");

        SLANG_CHECK(Path::simplify("a:\\what\\..\\.\\..\\is\\.\\..\\this\\.\\") == "a:/../this");

        SLANG_CHECK(
            Path::simplify("tests/preprocessor/.\\pragma-once-a.h") ==
            "tests/preprocessor/pragma-once-a.h");


        SLANG_CHECK(Path::hasRelativeElement("."));
        SLANG_CHECK(Path::hasRelativeElement(".."));
        SLANG_CHECK(Path::hasRelativeElement("blah/.."));

        SLANG_CHECK(Path::hasRelativeElement("blah/.././a"));
        SLANG_CHECK(Path::hasRelativeElement("a") == false);
        SLANG_CHECK(Path::hasRelativeElement("blah/a") == false);
        SLANG_CHECK(Path::hasRelativeElement("a:\\blah/a") == false);


        SLANG_CHECK(Path::hasRelativeElement("a:/what/.././../is/./../this/."));

        SLANG_CHECK(Path::hasRelativeElement("a:/what/.././../is/./../this/./"));

        SLANG_CHECK(Path::hasRelativeElement("a:\\what\\..\\.\\..\\is\\.\\..\\this\\.\\"));
    }
}
