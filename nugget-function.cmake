# This is the function to apply the Nugget pipeline to the workload

# ----- Defined constants starts -----
set(LLVM_IR_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-ir")
set(LLVM_BC_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-bc")
set(LLVM_OBJ_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-obj")
set(LLVM_EXE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-exec")

# Compilers for IR emission — must be clang-based (gcc doesn't support -emit-llvm)
set(NUGGET_C_COMPILER "clang" CACHE STRING "C compiler for LLVM IR emission")
set(NUGGET_CXX_COMPILER "clang++" CACHE STRING "C++ compiler for LLVM IR emission")
set(NUGGET_Fortran_COMPILER "flang-new" CACHE STRING "Fortran compiler for LLVM IR emission")

# ----- Defined constants ends -----

# ----- Helper functions starts -----
# Functions here are used to help the main function

function(nugget_helper_extract_file_type FILE_NAME RESULT_VAR)
    if(FILE_NAME MATCHES ".*\\.(cpp|cc|cxx)$")
        set(_type "CXX")
    elseif(FILE_NAME MATCHES ".*\\.c$")
        set(_type "C")
    elseif(FILE_NAME MATCHES ".*\\.[fF](90)?$")
        set(_type "Fortran")
    elseif(FILE_NAME MATCHES ".*\\.cu$")
        set(_type "CUDA")
    elseif(FILE_NAME MATCHES ".*\\.(h|hpp|hxx)$")
        set(_type "Header")
    elseif(FILE_NAME MATCHES ".*\\.txt$")
        set(_type "Text")
    else()
        message(FATAL_ERROR "Unknown file type: ${FILE_NAME}")
    endif()
    set(${RESULT_VAR} "${_type}" PARENT_SCOPE)
endfunction()

function(nugget_helper_dump_target_properties TARGET)
    execute_process(COMMAND ${CMAKE_COMMAND} --help-property-list
                    OUTPUT_VARIABLE _all_props)
    string(REGEX REPLACE "\n" ";" _all_props "${_all_props}")

    message(STATUS "====== Properties for target: ${TARGET} ======")
    foreach(_p ${_all_props})
        string(STRIP "${_p}" _p)
        if(_p STREQUAL "" OR _p MATCHES "<" OR _p MATCHES "LOCATION")
            continue()
        endif()
        get_target_property(_val ${TARGET} ${_p})
        if(_val AND NOT _val STREQUAL "_val-NOTFOUND")
            message(STATUS "  ${_p} = ${_val}")
        endif()
    endforeach()
    message(STATUS "====== End properties for: ${TARGET} ======")
endfunction()

function(nugget_find_target_dependencies TARGET RESULT_VAR)
    set(dependent_properties MANUALLY_ADDED_DEPENDENCIES LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
    foreach(_dep_property ${dependent_properties})
        get_target_property(_dep ${TARGET} ${_dep_property})
        if(_dep)
            list(APPEND ${RESULT_VAR} ${_dep})
        endif()
    endforeach()
    list(REMOVE_DUPLICATES ${RESULT_VAR})
    set(${RESULT_VAR} "${${RESULT_VAR}}" PARENT_SCOPE)
endfunction()

function(nugget_recursive_find_target_dependencies TARGET)
    set(_deps "")
    nugget_find_target_dependencies(${TARGET} _deps)
    nugget_helper_dump_target_properties(${TARGET})
    foreach(_dep ${_deps})
        if(TARGET ${_dep})    
            nugget_recursive_find_target_dependencies(${_dep})
        endif()
    endforeach()
endfunction()

# Validate flags against the actual nugget compilers (clang/flang-new),
# not CMAKE_*_COMPILER which may be gcc/gfortran.
function(nugget_validate_compiler_option OPTIONS LANG OUT_FINAL_OPTIONS)
    if(LANG STREQUAL "C")
        set(_compiler "${NUGGET_C_COMPILER}")
        set(_test_src "${CMAKE_BINARY_DIR}/_nugget_test.c")
        file(WRITE "${_test_src}" "int main(void){return 0;}\n")
    elseif(LANG STREQUAL "CXX")
        set(_compiler "${NUGGET_CXX_COMPILER}")
        set(_test_src "${CMAKE_BINARY_DIR}/_nugget_test.cpp")
        file(WRITE "${_test_src}" "int main(){return 0;}\n")
    elseif(LANG STREQUAL "Fortran")
        set(_compiler "${NUGGET_Fortran_COMPILER}")
        set(_test_src "${CMAKE_BINARY_DIR}/_nugget_test.f90")
        file(WRITE "${_test_src}" "program test\nend program\n")
    else()
        message(WARNING "Nugget: Unknown language: ${LANG}")
        set(${OUT_FINAL_OPTIONS} "" PARENT_SCOPE)
        return()
    endif()

    set(_valid_options "")
    foreach(_opt ${OPTIONS})
        execute_process(
            COMMAND ${_compiler} ${_opt} -c "${_test_src}" -o /dev/null
            RESULT_VARIABLE _ret
            OUTPUT_QUIET ERROR_QUIET
        )
        if(_ret EQUAL 0)
            list(APPEND _valid_options "${_opt}")
        else()
            message(STATUS "Nugget: Dropping unsupported ${LANG} flag for ${_compiler}: ${_opt}")
        endif()
    endforeach()

    set(${OUT_FINAL_OPTIONS} "${_valid_options}" PARENT_SCOPE)
endfunction()

function(nugget_create_ir_file TARGET OUT_IR_FILE_LIST)
    get_target_property(SOURCE_FILES ${TARGET} SOURCES)
    get_target_property(_target_source_dir ${TARGET} SOURCE_DIR)

    # --- Classify source files by language ---
    set(C_FILES "")
    set(CXX_FILES "")
    set(Fortran_FILES "")
    foreach(SOURCE_FILE ${SOURCE_FILES})
        nugget_helper_extract_file_type(${SOURCE_FILE} FILE_TYPE)
        if(FILE_TYPE STREQUAL "C")
            list(APPEND C_FILES "${SOURCE_FILE}")
        elseif(FILE_TYPE STREQUAL "CXX")
            list(APPEND CXX_FILES "${SOURCE_FILE}")
        elseif(FILE_TYPE STREQUAL "Fortran")
            list(APPEND Fortran_FILES "${SOURCE_FILE}")
        endif()
    endforeach()

    list(LENGTH C_FILES _c_count)
    list(LENGTH CXX_FILES _cxx_count)
    list(LENGTH Fortran_FILES _f_count)
    message(STATUS "Nugget IR [${TARGET}]: ${_c_count} C, ${_cxx_count} C++, ${_f_count} Fortran files")

    # --- Collect and validate compile flags per language ---

    # Global flags: CMAKE_<LANG>_FLAGS + CMAKE_<LANG>_FLAGS_<CONFIG>
    string(TOUPPER "${CMAKE_BUILD_TYPE}" _bt)
    separate_arguments(_c_global UNIX_COMMAND "${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${_bt}}")
    separate_arguments(_cxx_global UNIX_COMMAND "${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${_bt}}")
    separate_arguments(_f_global UNIX_COMMAND "${CMAKE_Fortran_FLAGS} ${CMAKE_Fortran_FLAGS_${_bt}}")

    # Target compile options (skip generator expressions — they resolve at generate time)
    get_target_property(_target_opts ${TARGET} COMPILE_OPTIONS)
    if(NOT _target_opts)
        set(_target_opts "")
    endif()
    set(_plain_opts "")
    foreach(_opt ${_target_opts})
        if(NOT _opt MATCHES "\\$<")
            list(APPEND _plain_opts "${_opt}")
        endif()
    endforeach()

    # Validate combined flags per language
    nugget_validate_compiler_option("${_c_global};${_plain_opts}" "C" _c_valid)
    nugget_validate_compiler_option("${_cxx_global};${_plain_opts}" "CXX" _cxx_valid)
    nugget_validate_compiler_option("${_f_global};${_plain_opts}" "Fortran" _f_valid)

    # Append language standard flags
    if(CMAKE_C_STANDARD)
        list(APPEND _c_valid "-std=c${CMAKE_C_STANDARD}")
    endif()
    if(CMAKE_CXX_STANDARD)
        list(APPEND _cxx_valid "-std=c++${CMAKE_CXX_STANDARD}")
    endif()

    # --- Generate response files for include dirs and definitions ---
    # file(GENERATE) evaluates generator expressions at generate time,
    # so $<BUILD_INTERFACE:...> etc. are resolved correctly.
    string(REPLACE "::" "_" _safe_target "${TARGET}")
    set(_flags_dir "${CMAKE_BINARY_DIR}/nugget-flags/${_safe_target}")

    file(GENERATE
        OUTPUT "${_flags_dir}/c.rsp"
        CONTENT "$<$<BOOL:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>>:-I$<JOIN:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>,\n-I>>\n$<$<BOOL:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>>:-D$<JOIN:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>,\n-D>>"
    )

    file(GENERATE
        OUTPUT "${_flags_dir}/cxx.rsp"
        CONTENT "$<$<BOOL:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>>:-I$<JOIN:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>,\n-I>>\n$<$<BOOL:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>>:-D$<JOIN:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>,\n-D>>"
    )

    # Fortran also needs the module directory for .mod files
    get_target_property(_fortran_mod_dir ${TARGET} Fortran_MODULE_DIRECTORY)
    if(_fortran_mod_dir)
        set(_fortran_mod_flag "\n-I${_fortran_mod_dir}")
    else()
        set(_fortran_mod_flag "")
    endif()

    file(GENERATE
        OUTPUT "${_flags_dir}/fortran.rsp"
        CONTENT "$<$<BOOL:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>>:-I$<JOIN:$<TARGET_PROPERTY:${TARGET},INCLUDE_DIRECTORIES>,\n-I>>${_fortran_mod_flag}\n$<$<BOOL:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>>:-D$<JOIN:$<TARGET_PROPERTY:${TARGET},COMPILE_DEFINITIONS>,\n-D>>"
    )

    # --- Create custom commands for each source file ---
    # Sanitize target name for filesystem paths (:: breaks GNU Make)
    string(REPLACE "::" "_" _safe_target "${TARGET}")
    set(TARGET_LLVM_IR_OUTPUT_DIR "${LLVM_IR_OUTPUT_DIR}/${_safe_target}")
    set(_all_ir_files "")

    # C files → .ll
    foreach(_src ${C_FILES})
        nugget_add_ir_command("${_src}" "${_target_source_dir}"
            "${TARGET_LLVM_IR_OUTPUT_DIR}" "${NUGGET_C_COMPILER}"
            "${_c_valid}" "${_flags_dir}/c.rsp" "C" _ir_out)
        list(APPEND _all_ir_files "${_ir_out}")
    endforeach()

    # C++ files → .ll
    foreach(_src ${CXX_FILES})
        nugget_add_ir_command("${_src}" "${_target_source_dir}"
            "${TARGET_LLVM_IR_OUTPUT_DIR}" "${NUGGET_CXX_COMPILER}"
            "${_cxx_valid}" "${_flags_dir}/cxx.rsp" "CXX" _ir_out)
        list(APPEND _all_ir_files "${_ir_out}")
    endforeach()

    # Fortran files → .ll
    foreach(_src ${Fortran_FILES})
        nugget_add_ir_command("${_src}" "${_target_source_dir}"
            "${TARGET_LLVM_IR_OUTPUT_DIR}" "${NUGGET_Fortran_COMPILER}"
            "${_f_valid}" "${_flags_dir}/fortran.rsp" "Fortran" _ir_out)
        list(APPEND _all_ir_files "${_ir_out}")
    endforeach()

    list(LENGTH _all_ir_files _ir_count)
    set(${OUT_IR_FILE_LIST} "${_all_ir_files}" PARENT_SCOPE)
    message(STATUS "Nugget IR [${TARGET}]: ${_ir_count} IR files queued")
endfunction()

# Helper: add a custom command to compile a single source file to LLVM IR.
# Sets ${OUT_VAR} in parent scope to the output .ll path.
function(nugget_add_ir_command SRC SOURCE_DIR IR_DIR COMPILER VALID_FLAGS RSP_FILE LANG OUT_VAR)
    # Resolve to absolute path
    if(NOT IS_ABSOLUTE "${SRC}")
        set(_abs_src "${SOURCE_DIR}/${SRC}")
    else()
        set(_abs_src "${SRC}")
    endif()

    # Compute output path preserving source directory structure
    file(RELATIVE_PATH _rel "${SOURCE_DIR}" "${_abs_src}")
    get_filename_component(_rel_dir "${_rel}" DIRECTORY)
    get_filename_component(_name_we "${_rel}" NAME_WE)

    if(_rel_dir)
        set(_ir_out "${IR_DIR}/${_rel_dir}/${_name_we}.ll")
        set(_out_dir "${IR_DIR}/${_rel_dir}")
    else()
        set(_ir_out "${IR_DIR}/${_name_we}.ll")
        set(_out_dir "${IR_DIR}")
    endif()

    add_custom_command(
        OUTPUT "${_ir_out}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_out_dir}"
        COMMAND ${COMPILER}
            ${VALID_FLAGS}
            "@${RSP_FILE}"
            -emit-llvm -S
            "${_abs_src}" -o "${_ir_out}"
        DEPENDS "${_abs_src}"
        COMMENT "Nugget [${LANG}->IR]: ${_rel}"
        VERBATIM
    )
    set(${OUT_VAR} "${_ir_out}" PARENT_SCOPE)
endfunction()

function(nugget_recursive_create_ir_file TARGET OUT_IR_FILE_LIST OUT_SKIPPED_TARGETS)
    # Recurse into dependencies first (build from the bottom)
    set(_deps "")
    nugget_find_target_dependencies(${TARGET} _deps)
    foreach(_dep ${_deps})
        if(TARGET ${_dep})
            nugget_recursive_create_ir_file(${_dep} ${OUT_IR_FILE_LIST} ${OUT_SKIPPED_TARGETS})
        endif()
    endforeach()

    # Skip IMPORTED targets (pre-built external libraries like MPI, HDF5)
    get_target_property(_is_imported ${TARGET} IMPORTED)
    if(_is_imported)
        message(STATUS "Nugget: Skipping imported target: ${TARGET}")
        list(APPEND ${OUT_SKIPPED_TARGETS} "${TARGET}")
        set(${OUT_SKIPPED_TARGETS} "${${OUT_SKIPPED_TARGETS}}" PARENT_SCOPE)
        return()
    endif()

    # Skip INTERFACE libraries (no source files to compile, but may need linking)
    get_target_property(LIBRARY_TYPE ${TARGET} TYPE)
    if("${LIBRARY_TYPE}" STREQUAL "INTERFACE_LIBRARY")
        list(APPEND ${OUT_SKIPPED_TARGETS} "${TARGET}")
        set(${OUT_SKIPPED_TARGETS} "${${OUT_SKIPPED_TARGETS}}" PARENT_SCOPE)
        return()
    endif()

    # Skip targets whose source files are not under the project's src/ or include/.
    # This catches external libs (lua, mjson, libxc, fmt) that are built within the
    # project tree but aren't part of the LSMS source code.
    get_target_property(_sources ${TARGET} SOURCES)
    get_target_property(_src_dir ${TARGET} SOURCE_DIR)
    set(_has_project_sources FALSE)
    if(_sources)
        foreach(_s ${_sources})
            if(NOT IS_ABSOLUTE "${_s}")
                set(_s "${_src_dir}/${_s}")
            endif()
            string(FIND "${_s}" "${CMAKE_SOURCE_DIR}/src/" _pos)
            if(_pos EQUAL 0)
                set(_has_project_sources TRUE)
                break()
            endif()
        endforeach()
    endif()
    if(NOT _has_project_sources)
        message(STATUS "Nugget: Skipping non-project target: ${TARGET}")
        list(APPEND ${OUT_SKIPPED_TARGETS} "${TARGET}")
        set(${OUT_SKIPPED_TARGETS} "${${OUT_SKIPPED_TARGETS}}" PARENT_SCOPE)
        return()
    endif()

    # Create IR files for this target (use a distinct variable to avoid overwriting
    # the accumulated list from dependencies)
    set(_this_target_ir_files "")
    nugget_create_ir_file(${TARGET} _this_target_ir_files)

    # Accumulate this target's files into the output list
    list(APPEND ${OUT_IR_FILE_LIST} ${_this_target_ir_files})
    set(${OUT_IR_FILE_LIST} "${${OUT_IR_FILE_LIST}}" PARENT_SCOPE)
    set(${OUT_SKIPPED_TARGETS} "${${OUT_SKIPPED_TARGETS}}" PARENT_SCOPE)
endfunction()

# ----- Helper functions ends -----

# This function applies the correct compilation options to each file in the workload
function(nugget_create_bc_file TARGET OUTPUT_TARGET OUT_SKIPPED_TARGETS)
    set(_ir_file_list "")
    set(_skipped "")
    nugget_recursive_create_ir_file(${TARGET} _ir_file_list _skipped)

    list(REMOVE_DUPLICATES _skipped)

    string(REPLACE "::" "_" _safe_target "${TARGET}")
    set(_bc_out "${LLVM_BC_OUTPUT_DIR}/${_safe_target}.bc")
    add_custom_command(
        OUTPUT "${_bc_out}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${LLVM_BC_OUTPUT_DIR}"
        COMMAND llvm-link ${_ir_file_list} -o "${_bc_out}"
        DEPENDS ${_ir_file_list}
        COMMENT "Nugget [llvm-link]: ${TARGET}.bc"
        VERBATIM
    )
    add_custom_target(${OUTPUT_TARGET} DEPENDS "${_bc_out}")

    # Report skipped targets that need linking at the final stage
    message(STATUS "Nugget: Skipped targets that must be linked at final stage:")
    foreach(_t ${_skipped})
        message(STATUS "  - ${_t}")
    endforeach()

    set(${OUT_SKIPPED_TARGETS} "${_skipped}" PARENT_SCOPE)
endfunction(nugget_create_bc_file)
