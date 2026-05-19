#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static struct timespec roi_start_ts;
static struct timespec roi_end_ts;

void nugget_roi_begin_(void) {
    printf("ROI begin\n");
    clock_gettime(CLOCK_MONOTONIC, &roi_start_ts);
}

void nugget_roi_end_(void) {
    clock_gettime(CLOCK_MONOTONIC, &roi_end_ts);

    long long nsec_diff = roi_end_ts.tv_nsec - roi_start_ts.tv_nsec;
    long long sec_diff  = roi_end_ts.tv_sec  - roi_start_ts.tv_sec;
    uint64_t time_diff  = (uint64_t)(sec_diff * 1000000000LL + nsec_diff);

    printf("Time taken: %llu ns\n", (unsigned long long)time_diff);

    FILE* fptr = fopen("result.txt", "w");
    if (fptr == NULL) {
        printf("Failed to open result.txt\n");
        exit(1);
    }
    fprintf(fptr, "Time taken: %llu ns\n", (unsigned long long)time_diff);
    fclose(fptr);

    printf("ROI end\n");
    exit(0);
}
