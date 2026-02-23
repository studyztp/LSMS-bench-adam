#
# Toolchain for building LSMS on a generic Linux system withour GPU
#

message(STATUS "Use toolchain file generic-cpu")

set(BUILD_TESTING OFF)

set(MST_LINEAR_SOLVER_DEFAULT 0x0005)
set(MST_BUILD_KKR_MATRIX_DEFAULT 0x1000)

set(CMAKE_CXX_COMPILER "mpic++")
set(CMAKE_C_COMPILER "gcc")
set(CMAKE_Fortran_COMPILER "gfortran")

set(CMAKE_BUILD_TYPE Release)
set(CMAKE_CXX_FLAGS "-O2 -mtune=native -mcpu=native")
set(CMAKE_Fortran_FLAGS "-O2 -mtune=native -mcpu=native")
