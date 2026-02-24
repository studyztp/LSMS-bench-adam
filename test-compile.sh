# grab MPI include flags (prints: -I... -I...)
MPI_INC="$(mpicxx --showme:compile 2>/dev/null || mpicxx -show 2>/dev/null)"

# pick the actual libomp.so (adjust if yours differs)
OMP_LIB=/usr/lib/llvm-18/lib/libomp.so

cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchain/Nugget/nugget-cpu-base.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  --log-level=debug

cmake --build build --target lsms_main-base-exec

cmake -S . -B build-analysis \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/toolchain/Nugget/nugget-cpu-analysis.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  --log-level=debug

cp -r build/llvm-bc build-analysis/

cmake --build build-analysis --target lsms_main-analysis-exec

# cmake --build build --parallel
