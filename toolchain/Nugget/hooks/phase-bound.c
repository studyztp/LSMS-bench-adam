#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t warmup_threshold = 0;
static uint64_t start_threshold = 0;
static uint64_t end_threshold = 0;

static uint64_t counter = 0;

static int if_warmup_not_met = 0;
static int if_start_not_met = 0;
static int if_end_not_met = 0;

static struct timespec roi_start_ts;
static struct timespec roi_end_ts;

static uint64_t calculate_nsec_difference(struct timespec start,
                                          struct timespec end) {
    long long nsec_diff = end.tv_nsec - start.tv_nsec;
    long long sec_diff = end.tv_sec - start.tv_sec;
    return (uint64_t)(sec_diff * 1000000000LL + nsec_diff);
}

static void warmup_event(void) {
    printf("Warmup event\n");
}

static void start_event(void) {
    printf("Start event\n");
    clock_gettime(CLOCK_MONOTONIC, &roi_start_ts);
}

static void end_event(void) {
    clock_gettime(CLOCK_MONOTONIC, &roi_end_ts);
    uint64_t time_diff = calculate_nsec_difference(roi_start_ts, roi_end_ts);
    printf("Time taken: %llu ns\n", (unsigned long long)time_diff);

    FILE* fptr = fopen("result.txt", "w");
    if (fptr == NULL) {
        printf("Failed to open result.txt\n");
        exit(1);
    }
    fprintf(fptr, "Time taken: %llu ns\n", (unsigned long long)time_diff);
    fclose(fptr);

    exit(0);
}

void nugget_init(uint64_t warmup_count, uint64_t start_count,
                 uint64_t end_count) {
    warmup_threshold = warmup_count;
    start_threshold = start_count;
    end_threshold = end_count == 0 ? 1 : end_count;

    printf("Warmup threshold: %llu\n", (unsigned long long)warmup_threshold);
    printf("Start threshold: %llu\n", (unsigned long long)start_threshold);
    printf("End threshold: %llu\n", (unsigned long long)end_threshold);

    // State-machine init runs AFTER nugget_roi_begin_'s body, because the pass
    // inserts this call before nugget_roi_begin_'s terminator. We pick the
    // starting state from the thresholds:
    //
    //   warmup==0 && start==0  ->  no markers fire; start_event runs now
    //                              (used when the measured region begins at
    //                              nugget_roi_begin_ itself).
    //   warmup==0              ->  skip warmup, arm start.
    //   otherwise              ->  arm warmup; normal flow.
    if (warmup_threshold == 0 && start_threshold == 0) {
        printf("Start marker met (immediate, at nugget_roi_begin_)\n");
        start_event();
        if_end_not_met = 1;
    } else if (warmup_threshold == 0) {
        if (start_threshold == 0) start_threshold = 1;
        if_start_not_met = 1;
    } else {
        if (start_threshold == 0) start_threshold = 1;
        if_warmup_not_met = 1;
    }
}

void nugget_roi_begin_(void) {
    printf("ROI begin\n");
}

void nugget_roi_end_(void) {
    printf("ROI end\n");
}

void nugget_warmup_marker_hook(void) {
    if (if_warmup_not_met) {
        counter++;
        if (counter == warmup_threshold) {
            if_warmup_not_met = 0;
            printf("Warm up marker met\n");
            warmup_event();
            counter = 0;
            if_start_not_met = 1;
        }
    }
}

void nugget_start_marker_hook(void) {
    if (if_start_not_met) {
        counter++;
        if (counter == start_threshold) {
            if_start_not_met = 0;
            printf("Start marker met\n");
            start_event();
            counter = 0;
            if_end_not_met = 1;
        }
    }
}

void nugget_end_marker_hook(void) {
    if (if_end_not_met) {
        counter++;
        if (counter == end_threshold) {
            if_end_not_met = 0;
            printf("End marker met\n");
            end_event();
        }
    }
}
