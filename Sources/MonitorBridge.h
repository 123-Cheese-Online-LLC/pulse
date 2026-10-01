#ifndef PULSE_MONITOR_H
#define PULSE_MONITOR_H
#include <stdint.h>
typedef struct {
    uint64_t user, system, idle, nice;
    uint64_t memory_total, memory_used, compressed, swap_used;
    int cpu_valid, memory_valid, swap_valid, pressure;
} PulseHost;
typedef struct {
    int32_t pid, parent_pid;
    uint64_t start, cpu_time, memory;
    char path[4096];
} PulseProcess;
void pulse_host(PulseHost *output);
int pulse_processes(PulseProcess *output, int capacity, int *skipped);
/* Owner uid of a live process (or -1 if gone/unreadable); start receives its start time, same units as PulseProcess.start. */
int pulse_owner(int32_t pid, uint64_t *start);
#endif
