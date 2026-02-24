# This is the function to apply the Nugget pipeline to the workload

# ----- Defined constants starts -----
set(LLVM_IR_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-ir")
set(LLVM_BC_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-bc")
set(LLVM_OBJ_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-obj")
set(LLVM_EXE_OUTPUT_DIR "${CMAKE_BINARY_DIR}/llvm-exec")

# Compilers for IR emission — must be clang-based (gcc doesn't support -emit-llvm)
set(NUGGET_C_COMPILER "clang" CACHE STRING "C compiler for LLVM IR emission")
set(NUGGET_CXX_COMPILER "clang++" CACHE STRING "C++ compiler for LLVM IR emission")
find_program(_nugget_default_flang NAMES flang-new flang)
if(NOT _nugget_default_flang)
    set(_nugget_default_flang "flang-new")
endif()
set(NUGGET_Fortran_COMPILER "${_nugget_default_flang}" CACHE STRING "Fortran compiler for LLVM IR emission")

# LLVM tools
set(NUGGET_LLVM_LINK "llvm-link" CACHE STRING "Path to llvm-link binary")
set(NUGGET_LLVM_OPT "opt" CACHE STRING "Path to LLVM opt binary")
set(NUGGET_LLVM_LLC "llc" CACHE STRING "Path to LLVM llc binary")

# Directories containing project source code. Targets whose sources are not
# under any of these directories are treated as external and skipped.
# Override this before including nugget-function.cmake or via -D on the command line.
set(NUGGET_PROJECT_SOURCE_DIRS "${CMAKE_SOURCE_DIR}/src" CACHE STRING
    "Semicolon-separated list of directories containing project source code")

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
    elseif(FILE_NAME MATCHES ".*\\.(txt|md|rst)$")
        set(_type "Text")
    else()
        message(FATAL_ERROR "Unknown file type: ${FILE_NAME}")
    endif()
    set(${RESULT_VAR} "${_type}" PARENT_SCOPE)
endfunction(nugget_helper_extract_file_type)

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
endfunction(nugget_helper_dump_target_properties)

# Determine whether a target's sources would be compiled to IR by the Nugget
# pipeline.  Both the IR-creation and link-dependency stages use this so they
# stay in sync even when they run on different machines.
function(nugget_is_ir_included_target TARGET RESULT_VAR)
    get_target_property(_is_imported ${TARGET} IMPORTED)
    if(_is_imported)
        set(${RESULT_VAR} FALSE PARENT_SCOPE)
        return()
    endif()

    get_target_property(_type ${TARGET} TYPE)
    if("${_type}" STREQUAL "INTERFACE_LIBRARY")
        set(${RESULT_VAR} FALSE PARENT_SCOPE)
        return()
    endif()

    get_target_property(_sources ${TARGET} SOURCES)
    get_target_property(_src_dir ${TARGET} SOURCE_DIR)
    set(_has_project_sources FALSE)
    if(_sources)
        foreach(_s ${_sources})
            if(NOT IS_ABSOLUTE "${_s}")
                set(_s "${_src_dir}/${_s}")
            endif()
            string(FIND "${_s}" "${CMAKE_BINARY_DIR}/" _bin_pos)
            if(_bin_pos EQUAL 0)
                continue()
            endif()
            foreach(_proj_dir ${NUGGET_PROJECT_SOURCE_DIRS})
                string(FIND "${_s}" "${_proj_dir}/" _pos)
                if(_pos EQUAL 0)
                    set(_has_project_sources TRUE)
                    break()
                endif()
            endforeach()
            if(_has_project_sources)
                break()
            endif()
        endforeach()
    endif()
    set(${RESULT_VAR} ${_has_project_sources} PARENT_SCOPE)
endfunction(nugget_is_ir_included_target)

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
endfunction(nugget_find_target_dependencies)

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
endfunction(nugget_validate_compiler_option)

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

    # Append language standard flags, respecting CMAKE_<LANG>_EXTENSIONS
    if(CMAKE_C_STANDARD)
        if(NOT DEFINED CMAKE_C_EXTENSIONS OR CMAKE_C_EXTENSIONS)
            list(APPEND _c_valid "-std=gnu${CMAKE_C_STANDARD}")
        else()
            list(APPEND _c_valid "-std=c${CMAKE_C_STANDARD}")
        endif()
    endif()
    if(CMAKE_CXX_STANDARD)
        if(NOT DEFINED CMAKE_CXX_EXTENSIONS OR CMAKE_CXX_EXTENSIONS)
            list(APPEND _cxx_valid "-std=gnu++${CMAKE_CXX_STANDARD}")
        else()
            list(APPEND _cxx_valid "-std=c++${CMAKE_CXX_STANDARD}")
        endif()
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
endfunction(nugget_create_ir_file)

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
endfunction(nugget_add_ir_command)

function(nugget_recursive_create_ir_file TARGET OUT_IR_FILE_LIST OUT_SKIPPED_TARGETS)
    # Recurse into dependencies first (build from the bottom)
    set(_deps "")
    nugget_find_target_dependencies(${TARGET} _deps)
    foreach(_dep ${_deps})
        if(TARGET ${_dep})
            nugget_recursive_create_ir_file(${_dep} ${OUT_IR_FILE_LIST} ${OUT_SKIPPED_TARGETS})
        endif()
    endforeach()

    nugget_is_ir_included_target(${TARGET} _is_ir_target)
    if(NOT _is_ir_target)
        message(STATUS "Nugget: Skipping target: ${TARGET}")
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
endfunction(nugget_recursive_create_ir_file)

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
        COMMAND ${NUGGET_LLVM_LINK} ${_ir_file_list} -o "${_bc_out}"
        DEPENDS ${_ir_file_list}
        COMMENT "Nugget [llvm-link]: ${TARGET}.bc"
        VERBATIM
    )
    add_custom_target(${OUTPUT_TARGET} DEPENDS "${_bc_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_BC_FILE "${_bc_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_TARGET_TYPE "NUGGET_BC_TARGET")

    # Report skipped targets that need linking at the final stage
    message(STATUS "Nugget: Skipped targets that must be linked at final stage:")
    foreach(_t ${_skipped})
        message(STATUS "  - ${_t}")
    endforeach()

    set(${OUT_SKIPPED_TARGETS} "${_skipped}" PARENT_SCOPE)
endfunction(nugget_create_bc_file)

function(nugget_apply_opt INPUT_TARGET CMD OUTPUT_TARGET)
    get_target_property(_input_bc ${INPUT_TARGET} NUGGET_BC_FILE)
    if(NOT _input_bc)
        message(FATAL_ERROR "Nugget: Target '${INPUT_TARGET}' has no NUGGET_BC_FILE property")
    endif()

    # CMD may be a space-separated string (e.g. from a cache variable).
    # Split it into a proper CMake list so add_custom_command treats each
    # token as a separate argument.  UNIX_COMMAND handles shell-style
    # quoting; angle brackets in -passes=... are preserved.
    separate_arguments(_cmd_list UNIX_COMMAND "${CMD}")

    set(_bc_out "${LLVM_BC_OUTPUT_DIR}/${OUTPUT_TARGET}.bc")
    add_custom_command(
        OUTPUT "${_bc_out}"
        COMMAND ${NUGGET_LLVM_OPT} ${_cmd_list} "${_input_bc}" -o "${_bc_out}"
        DEPENDS "${_input_bc}"
        COMMENT "Nugget [opt ${CMD}]: ${OUTPUT_TARGET}.bc"
        VERBATIM
    )
    add_custom_target(${OUTPUT_TARGET} DEPENDS "${_bc_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_BC_FILE "${_bc_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_TARGET_TYPE "NUGGET_BC_TARGET")
endfunction(nugget_apply_opt)

function(nugget_create_obj INPUT_TARGET CMD OUTPUT_TARGET)
    # Two types of INPUT_TARGET: 1) llvm bc, 2) target with source files
    # If it is llvm bc, then we use llc to compile to obj
    # If not, we use the corresponding compiler for it
    get_target_property(_target_type ${INPUT_TARGET} NUGGET_TARGET_TYPE)
    if (NOT _target_type) 
        message(FATAL_ERROR "Nugget: Target '${INPUT_TARGET}' has no NUGGET_TARGET_TYPE property")
    endif()

    get_target_property(_input_bc ${INPUT_TARGET} NUGGET_BC_FILE)
    separate_arguments(_cmd_list UNIX_COMMAND "${CMD}")
    set(_obj_out "${LLVM_OBJ_OUTPUT_DIR}/${OUTPUT_TARGET}.o")

    if (_target_type MATCHES NUGGET_BC_TARGET)
        add_custom_command(
            OUTPUT "${_obj_out}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${LLVM_OBJ_OUTPUT_DIR}"
            COMMAND ${NUGGET_LLVM_LLC} ${_cmd_list} --relocation-model=pic -filetype=obj "${_input_bc}" -o "${_obj_out}"
            DEPENDS "${_input_bc}"
            COMMENT "Nugget [llc ${CMD}]: ${OUTPUT_TARGET}.o"
            VERBATIM
        )
    else()
        message(FATAL_ERROR "Not implemented yet")
    endif()

    add_custom_target(${OUTPUT_TARGET} DEPENDS "${_obj_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_OBJ_FILE "${_obj_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_TARGET_TYPE "NUGGET_OBJ_TARGET")

endfunction(nugget_create_obj)

# Recursively walk a target's LINK_LIBRARIES / INTERFACE_LINK_LIBRARIES and
# accumulate link flags and build-time dependencies.
# Uses variable-name parameters so results propagate through recursion.
#   OUT_CMD  – variable name: list of linker arguments (objects, -l flags, paths)
#   OUT_DEPS – variable name: list of in-tree CMake targets that must be built
#   VISITED  – variable name: list of already-processed targets (cycle guard)
function(nugget_collect_link_deps TARGET OUT_CMD OUT_DEPS VISITED)
    list(FIND ${VISITED} "${TARGET}" _idx)
    if(NOT _idx EQUAL -1)
        return()
    endif()
    list(APPEND ${VISITED} "${TARGET}")

    get_target_property(_type ${TARGET} TYPE)
    get_target_property(_imported ${TARGET} IMPORTED)

    if(_type STREQUAL "INTERFACE_LIBRARY" OR _imported)
        get_target_property(_libs ${TARGET} INTERFACE_LINK_LIBRARIES)
    else()
        get_target_property(_libs ${TARGET} LINK_LIBRARIES)
    endif()

    if(NOT _libs)
        set(${OUT_CMD} "${${OUT_CMD}}" PARENT_SCOPE)
        set(${OUT_DEPS} "${${OUT_DEPS}}" PARENT_SCOPE)
        set(${VISITED} "${${VISITED}}" PARENT_SCOPE)
        return()
    endif()

    foreach(_lib ${_libs})
        # Generator expressions can't be inspected at configure time; pass through
        if(_lib MATCHES "^\\$<")
            list(APPEND ${OUT_CMD} "${_lib}")
            continue()
        endif()

        if(TARGET ${_lib})
            list(FIND ${VISITED} "${_lib}" _lib_idx)
            if(NOT _lib_idx EQUAL -1)
                continue()
            endif()

            get_target_property(_lib_type ${_lib} TYPE)
            get_target_property(_lib_imported ${_lib} IMPORTED)

            if(_lib_type STREQUAL "INTERFACE_LIBRARY")
                nugget_collect_link_deps(${_lib} ${OUT_CMD} ${OUT_DEPS} ${VISITED})
            elseif(_lib_imported)
                list(APPEND ${OUT_CMD} "$<TARGET_FILE:${_lib}>")
                nugget_collect_link_deps(${_lib} ${OUT_CMD} ${OUT_DEPS} ${VISITED})
            else()
                nugget_is_ir_included_target(${_lib} _is_ir)
                if(_is_ir)
                    nugget_collect_link_deps(${_lib} ${OUT_CMD} ${OUT_DEPS} ${VISITED})
                else()
                    list(APPEND ${OUT_CMD} "$<TARGET_FILE:${_lib}>")
                    list(APPEND ${OUT_DEPS} "${_lib}")
                    nugget_collect_link_deps(${_lib} ${OUT_CMD} ${OUT_DEPS} ${VISITED})
                endif()
            endif()
        else()
            # Plain string: -lm, -pthread, /path/to/lib.a, or bare name like "dl"
            if(_lib MATCHES "^[-/]" OR _lib MATCHES "\\.(a|so|dylib|lib)$")
                list(APPEND ${OUT_CMD} "${_lib}")
            else()
                list(APPEND ${OUT_CMD} "-l${_lib}")
            endif()
        endif()
    endforeach()

    set(${OUT_CMD} "${${OUT_CMD}}" PARENT_SCOPE)
    set(${OUT_DEPS} "${${OUT_DEPS}}" PARENT_SCOPE)
    set(${VISITED} "${${VISITED}}" PARENT_SCOPE)
endfunction(nugget_collect_link_deps)

# Builds the link command for a nugget executable.
#
# 1) Finds source files in ORIGINAL_TARGET that were skipped by the nugget IR
#    pipeline (e.g. .cu) and compiles them into objects.
# 2) Recursively collects all library dependencies.
#
# Outputs (set in PARENT_SCOPE):
#   OUT_LINK_CMD  – list of linker arguments (extra .o files + library flags)
#   OUT_LINK_DEPS – list of CMake targets that must be built before linking
function(nugget_create_link_cmd ORIGINAL_TARGET OUT_LINK_CMD OUT_LINK_DEPS)
    set(_link_cmd "")
    set(_link_deps "")
    set(_visited "")

    # --- Step 1: compile source files the IR pipeline skipped ----------------
    get_target_property(_sources ${ORIGINAL_TARGET} SOURCES)
    get_target_property(_src_dir ${ORIGINAL_TARGET} SOURCE_DIR)

    if(_sources)
        string(REPLACE "::" "_" _safe "${ORIGINAL_TARGET}")
        set(_skipped_obj_dir "${LLVM_OBJ_OUTPUT_DIR}/${_safe}-skipped")

        # Collect target compile definitions/includes for skipped-file compilation
        set(_flags_dir "${CMAKE_BINARY_DIR}/nugget-flags/${_safe}")
        file(GENERATE
            OUTPUT "${_flags_dir}/skipped.rsp"
            CONTENT "$<$<BOOL:$<TARGET_PROPERTY:${ORIGINAL_TARGET},INCLUDE_DIRECTORIES>>:-I$<JOIN:$<TARGET_PROPERTY:${ORIGINAL_TARGET},INCLUDE_DIRECTORIES>,\n-I>>\n$<$<BOOL:$<TARGET_PROPERTY:${ORIGINAL_TARGET},COMPILE_DEFINITIONS>>:-D$<JOIN:$<TARGET_PROPERTY:${ORIGINAL_TARGET},COMPILE_DEFINITIONS>,\n-D>>"
        )

        foreach(_src ${_sources})
            nugget_helper_extract_file_type("${_src}" _ftype)

            if(_ftype STREQUAL "CUDA")
                if(NOT IS_ABSOLUTE "${_src}")
                    set(_abs_src "${_src_dir}/${_src}")
                else()
                    set(_abs_src "${_src}")
                endif()
                get_filename_component(_name_we "${_src}" NAME_WE)
                set(_obj_out "${_skipped_obj_dir}/${_name_we}.o")

                add_custom_command(
                    OUTPUT "${_obj_out}"
                    COMMAND ${CMAKE_COMMAND} -E make_directory "${_skipped_obj_dir}"
                    COMMAND ${CMAKE_CUDA_COMPILER}
                        "@${_flags_dir}/skipped.rsp"
                        -c "${_abs_src}" -o "${_obj_out}"
                    DEPENDS "${_abs_src}"
                    COMMENT "Nugget [CUDA->obj]: ${_src}"
                    VERBATIM
                )
                list(APPEND _link_cmd "${_obj_out}")
            endif()
        endforeach()
    endif()

    # --- Step 2: recursively collect library dependencies --------------------
    nugget_collect_link_deps(${ORIGINAL_TARGET} _link_cmd _link_deps _visited)

    # Collect link options from the original target
    get_target_property(_link_opts ${ORIGINAL_TARGET} LINK_OPTIONS)
    if(_link_opts)
        list(APPEND _link_cmd ${_link_opts})
    endif()

    set(${OUT_LINK_CMD} "${_link_cmd}" PARENT_SCOPE)
    set(${OUT_LINK_DEPS} "${_link_deps}" PARENT_SCOPE)
endfunction(nugget_create_link_cmd)

# Links the nugget object file with extra objects and libraries into a final
# executable.
#   ORIGINAL_TARGET – the original CMake target (for linker language detection)
#   OBJ_TARGET      – nugget target that has a NUGGET_OBJ_FILE property
#   CMD 
#   LINK_CMD        – list of linker arguments (from nugget_create_link_cmd)
#   LINK_DEPS       – list of CMake build dependencies (from nugget_create_link_cmd)
#   OUTPUT_TARGET   – name of the CMake custom target to create
function(nugget_create_exe ORIGINAL_TARGET OBJ_TARGET CMD LINK_CMD LINK_DEPS OUTPUT_TARGET)
    get_target_property(_obj_file ${OBJ_TARGET} NUGGET_OBJ_FILE)
    if(NOT _obj_file)
        message(FATAL_ERROR "Nugget: Target '${OBJ_TARGET}' has no NUGGET_OBJ_FILE property")
    endif()

    # LINKER_LANGUAGE may not be computed at configure time.  Fall back to
    # enabled languages.  For mixed CXX+Fortran projects, prefer CXX to avoid
    # flang-new linking libFortran_main (which defines its own main()).
    get_target_property(_lang ${ORIGINAL_TARGET} LINKER_LANGUAGE)
    get_property(_enabled_langs GLOBAL PROPERTY ENABLED_LANGUAGES)

    if(NOT _lang OR "${_lang}" STREQUAL "_lang-NOTFOUND" OR "${_lang}" STREQUAL "NOTFOUND")
        if("CXX" IN_LIST _enabled_langs)
            set(_lang "CXX")
        elseif("Fortran" IN_LIST _enabled_langs)
            set(_lang "Fortran")
        else()
            set(_lang "C")
        endif()
    elseif(_lang STREQUAL "Fortran" AND "CXX" IN_LIST _enabled_langs)
        set(_lang "CXX")
    endif()

    if(_lang STREQUAL "CXX")
        set(_linker "${NUGGET_CXX_COMPILER}")
    elseif(_lang STREQUAL "Fortran")
        set(_linker "${NUGGET_Fortran_COMPILER}")
    else()
        set(_linker "${NUGGET_C_COMPILER}")
    endif()

    # When the linker is not flang-new, add the Fortran runtime explicitly
    # (FortranRuntime + FortranDecimal, but NOT Fortran_main).
    if("Fortran" IN_LIST _enabled_langs AND NOT _lang STREQUAL "Fortran")
        set(_fortran_lib_dir "")

        # Strategy 1: ask the compiler directly
        execute_process(
            COMMAND ${NUGGET_Fortran_COMPILER} --print-file-name=libFortranRuntime.a
            OUTPUT_VARIABLE _frt_path
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        if(_frt_path AND NOT "${_frt_path}" STREQUAL "libFortranRuntime.a"
                AND EXISTS "${_frt_path}")
            get_filename_component(_fortran_lib_dir "${_frt_path}" DIRECTORY)
        endif()

        # Strategy 2: resolve the compiler symlink and look in ../lib
        if(NOT _fortran_lib_dir)
            find_program(_flang_real NAMES ${NUGGET_Fortran_COMPILER})
            if(_flang_real)
                get_filename_component(_flang_real "${_flang_real}" REALPATH)
                get_filename_component(_flang_bin "${_flang_real}" DIRECTORY)
                get_filename_component(_flang_prefix "${_flang_bin}" DIRECTORY)
                if(EXISTS "${_flang_prefix}/lib/libFortranRuntime.a")
                    set(_fortran_lib_dir "${_flang_prefix}/lib")
                endif()
            endif()
        endif()

        message(STATUS "Nugget: Fortran runtime lib dir = ${_fortran_lib_dir}")
        if(_fortran_lib_dir)
            list(APPEND LINK_CMD "-L${_fortran_lib_dir}")
        else()
            message(WARNING "Nugget: Could not locate Fortran runtime libraries; link may fail.")
        endif()
        list(APPEND LINK_CMD "-lFortranRuntime" "-lFortranDecimal")
    endif()

    # Separate file dependencies from linker flags — DEPENDS only accepts
    # files, targets, and generator expressions, not flags like -fPIE or -lm.
    set(_file_deps "")
    foreach(_item ${LINK_CMD})
        if(NOT _item MATCHES "^-")
            list(APPEND _file_deps "${_item}")
        endif()
    endforeach()

    set(_exe_out "${LLVM_EXE_OUTPUT_DIR}/${OUTPUT_TARGET}")

    message(STATUS "Nugget link: linker      = ${_linker}")
    message(STATUS "Nugget link: lang        = ${_lang}")
    message(STATUS "Nugget link: obj         = ${_obj_file}")
    message(STATUS "Nugget link: flags       = ${CMD}")
    message(STATUS "Nugget link: link_cmd    = ${LINK_CMD}")
    message(STATUS "Nugget link: link_deps   = ${LINK_DEPS}")
    message(STATUS "Nugget link: output      = ${_exe_out}")

    add_custom_command(
        OUTPUT "${_exe_out}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${LLVM_EXE_OUTPUT_DIR}"
        COMMAND ${_linker} "${_obj_file}" ${CMD} ${LINK_CMD} -o "${_exe_out}"
        DEPENDS "${_obj_file}" ${_file_deps} ${LINK_DEPS}
        COMMENT "Nugget [link]: ${OUTPUT_TARGET}"
        VERBATIM
    )
    add_custom_target(${OUTPUT_TARGET} DEPENDS "${_exe_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_EXE_FILE "${_exe_out}")
    set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_TARGET_TYPE "NUGGET_EXE_TARGET")
endfunction(nugget_create_exe)
