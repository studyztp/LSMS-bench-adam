# Compile a standalone C hook source file into LLVM bitcode.
#
# The resulting target has NUGGET_BC_FILE and NUGGET_TARGET_TYPE properties,
# so it can be passed to nugget_merge_bc_files to link with other .bc targets.
#
# Usage:
#   nugget_compile_hook_bc(<source_file> <output_target>)
#
# Example:
#   nugget_compile_hook_bc(
#       "${CMAKE_CURRENT_LIST_DIR}/analysis.c"
#       analysis-hook-bc
#   )
#   nugget_merge_bc_files("lsms_main-base-bc;analysis-hook-bc" lsms_main-analysis-bc)
#
function(nugget_compile_hook_bc HOOK_SOURCE OUTPUT_TARGET)
    get_filename_component(_src_name "${HOOK_SOURCE}" NAME_WE)
    set(_bc_out "${LLVM_BC_OUTPUT_DIR}/${_src_name}-hook.bc")

    if(NOT TARGET ${OUTPUT_TARGET})
        add_custom_command(
            OUTPUT "${_bc_out}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${LLVM_BC_OUTPUT_DIR}"
            COMMAND ${NUGGET_C_COMPILER} -emit-llvm -c -O0
                    "${HOOK_SOURCE}" -o "${_bc_out}"
            DEPENDS "${HOOK_SOURCE}"
            COMMENT "Nugget [hook->BC]: ${_src_name}-hook.bc"
            VERBATIM
        )
        add_custom_target(${OUTPUT_TARGET} DEPENDS "${_bc_out}")
        set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_BC_FILE "${_bc_out}")
        set_target_properties(${OUTPUT_TARGET} PROPERTIES NUGGET_TARGET_TYPE "NUGGET_BC_TARGET")
    endif()
endfunction(nugget_compile_hook_bc)
