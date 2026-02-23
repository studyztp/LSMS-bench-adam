# grab MPI include flags (prints: -I... -I...)
MPI_INC="$(mpicxx --showme:compile 2>/dev/null || mpicxx -show 2>/dev/null)"

# pick the actual libomp.so (adjust if yours differs)
OMP_LIB=/usr/lib/llvm-18/lib/libomp.so

cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchain/nugget-cuda.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  \
  # DON'T lie to CMake about compilers; let it detect
  # (remove your *_COMPILER_WORKS and *_COMPILER_ID hacks)
  \
  # help FindMPI (not required, but makes it deterministic)
  -DMPI_C_COMPILER="$(command -v mpicc)" \
  -DMPI_CXX_COMPILER="$(command -v mpicxx)" \
  -DMPI_Fortran_COMPILER="$(command -v mpifort)" \
  \
  # clang + OpenMP
  -DOpenMP_C_FLAGS="-fopenmp" \
  -DOpenMP_CXX_FLAGS="-fopenmp" \
  -DOpenMP_omp_LIBRARY="${OMP_LIB}" \
  \
  # IMPORTANT: make mpi.h visible when compiling .cu
  -DCMAKE_CUDA_FLAGS="${MPI_INC}" \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  \
  # Make sure to use the openmpi version of hdf5
  -DHDF5_LIBRARIES="/usr/lib/x86_64-linux-gnu/hdf5/openmpi" \
  -DHDF5_INCLUDE_DIRS="/usr/include/hdf5/openmpi" \
  -DHDF5_PREFER_PARALLEL=ON \
  \
  # Some Openmp flags
  -DOpenMP_C_FLAGS="-fopenmp" \
    -DOpenMP_CXX_FLAGS="-fopenmp" \
    -DOpenMP_C_LIB_NAMES="omp" \
    -DOpenMP_CXX_LIB_NAMES="omp" 
  # \
  # # Nugget definitions
  # -DBUILD_NUGGET="ir-bb-label"

cmake --build build --parallel
