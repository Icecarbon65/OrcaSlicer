cmake_minimum_required(VERSION 3.13)

set(_python_abi "312")

foreach(_var PYTHON_SOURCE_DIR PYTHON_BUILD_DIR PYTHON_DEST_DIR PYTHON_LAYOUT_ARCH)
    if(NOT DEFINED ${_var} OR "${${_var}}" STREQUAL "")
        message(FATAL_ERROR "${_var} is required")
    endif()
endforeach()

set(_python_exe "${PYTHON_BUILD_DIR}/python.exe")

if(NOT EXISTS "${_python_exe}")
    message(FATAL_ERROR "Built Python executable not found: ${_python_exe}")
endif()

file(REMOVE_RECURSE "${PYTHON_DEST_DIR}")
file(MAKE_DIRECTORY "${PYTHON_DEST_DIR}")

# CPython's Windows layout helper reads LICENSE.txt from the build output.
# Source archives ship this file as LICENSE, so provide the expected name.
if(EXISTS "${PYTHON_SOURCE_DIR}/LICENSE" AND NOT EXISTS "${PYTHON_BUILD_DIR}/LICENSE.txt")
    configure_file("${PYTHON_SOURCE_DIR}/LICENSE" "${PYTHON_BUILD_DIR}/LICENSE.txt" COPYONLY)
endif()

execute_process(
    COMMAND
        "${CMAKE_COMMAND}" -E env
            "PYTHONHOME="
            "PYTHONPATH=${PYTHON_SOURCE_DIR}/Lib"
            "${_python_exe}"
            "${PYTHON_SOURCE_DIR}/PC/layout"
            --source "${PYTHON_SOURCE_DIR}"
            --build "${PYTHON_BUILD_DIR}"
            --arch "${PYTHON_LAYOUT_ARCH}"
            --copy "${PYTHON_DEST_DIR}"
            --include-dev
    WORKING_DIRECTORY "${PYTHON_SOURCE_DIR}"
    RESULT_VARIABLE _layout_result
)

if(NOT _layout_result EQUAL 0)
    message(FATAL_ERROR "CPython Windows layout staging failed with exit code ${_layout_result}")
endif()

# CPython's layout helper copies vcruntime*.dll from its build directory.  On
# native ARM64 runners that directory can contain host-x64 runtime DLLs left by
# build-time tools, even though python.exe and python312.dll are ARM64.  Shipping
# either DLL makes Windows reject the embedded interpreter with 0xc0000020.
# Replace them with the redistributables selected by the active ARM64 toolchain.
if(PYTHON_LAYOUT_ARCH STREQUAL "arm64")
    file(TO_CMAKE_PATH "$ENV{VCToolsRedistDir}" _vc_redist_root)
    if(NOT _vc_redist_root OR NOT IS_DIRECTORY "${_vc_redist_root}/arm64")
        message(FATAL_ERROR
            "VCToolsRedistDir does not contain the ARM64 redistributables: "
            "'$ENV{VCToolsRedistDir}'")
    endif()

    file(GLOB _arm64_vcruntime_dlls
        "${_vc_redist_root}/arm64/Microsoft.VC*.CRT/vcruntime*.dll")
    list(FILTER _arm64_vcruntime_dlls EXCLUDE REGEX "_threads\\.dll$")
    if(NOT _arm64_vcruntime_dlls)
        message(FATAL_ERROR
            "No ARM64 vcruntime DLLs found under '${_vc_redist_root}/arm64'")
    endif()

    file(GLOB _staged_vcruntime_dlls "${PYTHON_DEST_DIR}/vcruntime*.dll")
    if(_staged_vcruntime_dlls)
        file(REMOVE ${_staged_vcruntime_dlls})
    endif()
    file(COPY ${_arm64_vcruntime_dlls} DESTINATION "${PYTHON_DEST_DIR}")
    message(STATUS "Staged ARM64 VC runtime DLLs: ${_arm64_vcruntime_dlls}")
endif()

set(_required_files
    "${PYTHON_DEST_DIR}/Lib/encodings/__init__.py"
    "${PYTHON_DEST_DIR}/include/Python.h"
    "${PYTHON_DEST_DIR}/python.exe"
    "${PYTHON_DEST_DIR}/python${_python_abi}.dll"
    "${PYTHON_DEST_DIR}/libs/python${_python_abi}.lib"
)

foreach(_required_file IN LISTS _required_files)
    if(NOT EXISTS "${_required_file}")
        message(FATAL_ERROR "Staged Python file missing: ${_required_file}")
    endif()
endforeach()
