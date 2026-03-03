#
# Toolchain for building LSMS on a generic Linux system withour GPU
#

message(STATUS "Use toolchain file generic-cpu")

set(BUILD_TESTING OFF)

set(MST_LINEAR_SOLVER_DEFAULT 0x0005)
set(MST_BUILD_KKR_MATRIX_DEFAULT 0x1000)

set(CMAKE_CXX_COMPILER "clang++")
set(CMAKE_C_COMPILER "clang")
set(CMAKE_Fortran_COMPILER "flang-new")

# Help CMake find MPI
set(MPI_CXX_COMPILER "mpicxx")
set(MPI_C_COMPILER "mpicc")
set(MPI_Fortran_COMPILER "mpifort")

set(CMAKE_BUILD_TYPE Release)
set(CMAKE_CXX_FLAGS "")
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG")
set(CMAKE_Fortran_FLAGS "")
set(CMAKE_Fortran_FLAGS_RELEASE "-O2 -DNDEBUG")

# OpenMP flags for clang/flang-new
set(OpenMP_C_FLAGS "-fopenmp")
set(OpenMP_CXX_FLAGS "-fopenmp")
set(OpenMP_Fortran_FLAGS "-fopenmp")
set(OpenMP_C_LIB_NAMES "omp")
set(OpenMP_CXX_LIB_NAMES "omp")
set(OpenMP_Fortran_LIB_NAMES "omp")
set(OpenMP_omp_LIBRARY "/usr/lib/llvm-18/lib/libomp.so" CACHE PATH "libomp path")

set(NUGGET_FUNCTION_CMAKE "${CMAKE_CURRENT_LIST_DIR}/../../nugget-function.cmake" CACHE PATH
    "Path to nugget-function.cmake")
include(${NUGGET_FUNCTION_CMAKE})
set(USE_NUGGET ON)

set(NUGGET_BASE_HOOK_SOURCE "${CMAKE_CURRENT_LIST_DIR}/hooks/base.c")
include(${CMAKE_CURRENT_LIST_DIR}/hooks/hooks.cmake)
nugget_compile_hook_bc("${NUGGET_BASE_HOOK_SOURCE}" base-hook-bc)

set(NUGGET_PASS_LIBRARY "${CMAKE_CURRENT_LIST_DIR}/../../../Nugget-LLVM-passes/build/NuggetPasses.so")

set(NUGGET_BUILD_BBID_PASS ON)
set(NUGGET_BUILD_BBID_PASS_CMD "-load-pass-plugin=${NUGGET_PASS_LIBRARY} -passes=ir-bb-label-pass<output_csv=lsms-ir-bb.csv>")
