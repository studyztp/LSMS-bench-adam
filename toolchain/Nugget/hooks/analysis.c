#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_SIZE 10000

static uint64_t IR_inst_counter = 0;

static int if_start = 0;
static int in_hook = 0;
static uint64_t region = 0;
static uint64_t total_num_bbs = 0;
static uint64_t total_IR_inst = 0;

static uint64_t** bbv_array = NULL;
static uint64_t** count_stamp_array = NULL;

static uint64_t* bbv = NULL;
static uint64_t* count_stamp = NULL;
static uint64_t* counter_array = NULL;

static uint64_t file_line_index = 0;
static uint64_t batch_index = 0;

static FILE* fptr = NULL;

static void write_down_data(uint64_t limit) {
    for (uint64_t i = 0; i < limit; i++) {
        fprintf(fptr, "bbv,%llu,0", (unsigned long long)file_line_index);
        for (uint64_t k = 0; k < total_num_bbs; k++) {
            if (bbv_array[i][k] != 0) {
                fprintf(fptr, ",%llu", (unsigned long long)bbv_array[i][k]);
            }
        }
        fprintf(fptr, "\n");
        fprintf(fptr, "csv,%llu,0", (unsigned long long)file_line_index);
        for (uint64_t k = 0; k < total_num_bbs; k++) {
            if (count_stamp_array[i][k] != 0) {
                fprintf(fptr, ",%llu", (unsigned long long)count_stamp_array[i][k]);
            }
        }
        fprintf(fptr, "\n");
        fprintf(fptr, "bb_id,%llu,0", (unsigned long long)file_line_index);
        for (uint64_t k = 0; k < total_num_bbs; k++) {
            if (bbv_array[i][k] != 0) {
                fprintf(fptr, ",%llu", (unsigned long long)k);
            }
        }
        fprintf(fptr, "\n");
        file_line_index++;
    }
    fprintf(fptr, "region_inst,N/A,N/A");
    for (uint64_t i = 0; i < limit; i++) {
        fprintf(fptr, ",%llu", (unsigned long long)counter_array[i]);
    }
    fprintf(fptr, "\n");
}

static void reset_array(void) {
    for (uint64_t i = 0; i < ARRAY_SIZE; i++) {
        memset(bbv_array[i], 0, total_num_bbs * sizeof(uint64_t));
        memset(count_stamp_array[i], 0, total_num_bbs * sizeof(uint64_t));
    }
}

static void delete_array(void) {
    for (uint64_t i = 0; i < ARRAY_SIZE; i++) {
        free(bbv_array[i]);
        free(count_stamp_array[i]);
    }
    free(bbv_array);
    free(count_stamp_array);
    free(counter_array);
}

static void process_data(void) {
    counter_array[batch_index] = IR_inst_counter;
    total_IR_inst += IR_inst_counter;
    region++;
    batch_index++;
    if (batch_index >= ARRAY_SIZE) {
        write_down_data(ARRAY_SIZE);
        reset_array();
        batch_index = 0;
    }
    bbv = bbv_array[batch_index];
    count_stamp = count_stamp_array[batch_index];
    IR_inst_counter = 0;
}

void nugget_init(uint64_t total_bb_count) {
    total_num_bbs = total_bb_count;
    bbv_array = (uint64_t**)malloc(ARRAY_SIZE * sizeof(uint64_t*));
    count_stamp_array = (uint64_t**)malloc(ARRAY_SIZE * sizeof(uint64_t*));
    counter_array = (uint64_t*)malloc(ARRAY_SIZE * sizeof(uint64_t));
    if (bbv_array == NULL || count_stamp_array == NULL || counter_array == NULL) {
        printf("Failed to allocate memory for analysis arrays\n");
        exit(1);
    }
    for (uint64_t i = 0; i < ARRAY_SIZE; i++) {
        bbv_array[i] = (uint64_t*)malloc(total_num_bbs * sizeof(uint64_t));
        count_stamp_array[i] = (uint64_t*)malloc(total_num_bbs * sizeof(uint64_t));
        if (bbv_array[i] == NULL || count_stamp_array[i] == NULL) {
            printf("Failed to allocate memory for analysis arrays\n");
            exit(1);
        }
        memset(bbv_array[i], 0, total_num_bbs * sizeof(uint64_t));
        memset(count_stamp_array[i], 0, total_num_bbs * sizeof(uint64_t));
    }
    bbv = bbv_array[0];
    count_stamp = count_stamp_array[0];
}

void nugget_roi_begin_(void) {
    if_start = 1;
    printf("ROI begin\n");
    fptr = fopen("analysis-output.csv", "w");
    if (fptr == NULL) {
        printf("Error: cannot open output file\n");
        exit(1);
    }
    fprintf(fptr, "type,region,thread,data\n");
}

void nugget_roi_end_(void) {
    if_start = 0;

    counter_array[batch_index] = IR_inst_counter;
    total_IR_inst += IR_inst_counter;
    region++;
    batch_index++;
    write_down_data(batch_index);

    printf("file_line_index: %llu\n", (unsigned long long)file_line_index);
    printf("region: %llu\n", (unsigned long long)region);

    fclose(fptr);
    delete_array();
    printf("ROI end\n");
    printf("Total IR instructions: %llu\n", (unsigned long long)total_IR_inst);
}

// Re-entrance guard: helper functions in this file will also be instrumented
// by PhaseAnalysisPass (they're not in the nugget_functions skip list), so
// nugget_bb_hook calls from within process_data/write_down_data must be ignored.
void nugget_bb_hook(uint64_t inst_count, uint64_t bb_id, uint64_t threshold) {
    if (in_hook) return;
    if (if_start) {
        in_hook = 1;
        IR_inst_counter += inst_count;
        bbv[bb_id] += 1;
        count_stamp[bb_id] = IR_inst_counter;
        if (IR_inst_counter > threshold) {
            process_data();
        }
        in_hook = 0;
    }
}
