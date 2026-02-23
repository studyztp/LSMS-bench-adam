# grab MPI include flags (prints: -I... -I...)
MPI_INC="$(mpicxx --showme:compile 2>/dev/null || mpicxx -show 2>/dev/null)"

# pick the actual libomp.so (adjust if yours differs)
OMP_LIB=/usr/lib/llvm-18/lib/libomp.so

cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchain/nugget-cpu.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  --log-level=debug

# cmake --build build --parallel
