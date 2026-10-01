#include <sys/wait.h>
#include <signal.h>
#include "../Sources/MonitorBridge.h"
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <math.h>
#include <sys/mman.h>

static double cpu_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static uint64_t own_time(void) {
    PulseProcess *buffer = calloc(8192, sizeof(PulseProcess));
    int skipped;
    int count = pulse_processes(buffer, 8192, &skipped);
    uint64_t time = 0;
    for (int i = 0; i < count; i++) if (buffer[i].pid == getpid()) time = buffer[i].cpu_time;
    free(buffer);
    return time;
}
int main(void) {
    uint64_t before = own_time();
    double start = cpu_seconds();
    volatile unsigned long work = 0;
    while (cpu_seconds() - start < 0.3) { for (int i = 0; i < 10000; i++) work += i; }
    uint64_t after = own_time();
    double elapsed = cpu_seconds() - start;
    double measured = (after - before) / 1e9;
    double ratio = measured / elapsed;
    printf("Process CPU conversion: %.3fs measured / %.3fs clock = %.3f\n", measured, elapsed, ratio);
    if (ratio < 0.85 || ratio > 1.15) { puts("FAIL: libproc CPU ticks must be converted to nanoseconds"); return 1; }
    // Clean file-backed pages count toward resident size, but not physical footprint.
    char file[] = "/tmp/pulse-memory-test-XXXXXX";
    int fd = mkstemp(file);
    if (fd < 0 || ftruncate(fd, 32 * 1024 * 1024) != 0) return 1;
    unlink(file);
    volatile unsigned char *mapped = mmap(NULL, 32 * 1024 * 1024, PROT_READ, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) return 1;
    volatile unsigned char sink = 0;
    for (int offset = 0; offset < 32 * 1024 * 1024; offset += 4096) sink ^= mapped[offset];
    PulseProcess *readings = calloc(8192, sizeof(PulseProcess));
    int skipped;
    int count = pulse_processes(readings, 8192, &skipped);
    task_vm_info_data_t vm;
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vm_count) != KERN_SUCCESS) return 1;
    uint64_t own_memory = 0;
    for (int i = 0; i < count; i++) if (readings[i].pid == getpid()) own_memory = readings[i].memory;
    double difference = fabs((double)own_memory - (double)vm.phys_footprint);
    printf("Memory: Pulse %llu, independent task footprint %llu, delta %.0f bytes\n", (unsigned long long)own_memory, (unsigned long long)vm.phys_footprint, difference);
    free(readings);
    munmap((void *)mapped, 32 * 1024 * 1024);
    close(fd);
    if (!own_memory || difference > 2 * 1024 * 1024) { puts("FAIL: app memory must report physical footprint"); return 1; }
    PulseHost host;
    pulse_host(&host);
    if (!host.cpu_valid || !host.memory_valid || host.memory_used > host.memory_total) return 1;
    puts("Native CPU conversion and host metrics checks passed");

    // Ownership gates what Pulse may stop: self is ours, launchd is root's, a dead pid is gone,
    // and a child we start can be signalled and then reads as gone.
    uint64_t own_start = 0;
    if (pulse_owner(getpid(), &own_start) != (int)getuid() || !own_start) { puts("FAIL: own process owner"); return 1; }
    // launchd is root's; macOS may not even let us read it. Either way it must never look like ours.
    if (pulse_owner(1, NULL) == (int)getuid()) { puts("FAIL: launchd must never read as ours"); return 1; }
    if (pulse_owner(999999, NULL) != -1) { puts("FAIL: missing pid must read as gone"); return 1; }
    pid_t child = fork();
    if (child == 0) { execl("/bin/sleep", "sleep", "30", (char *)NULL); _exit(127); }
    if (pulse_owner(child, NULL) != (int)getuid() || kill(child, SIGTERM) != 0) { puts("FAIL: stop own child"); return 1; }
    int status = 0;
    waitpid(child, &status, 0);
    if (!WIFSIGNALED(status) || pulse_owner(child, NULL) != -1) { puts("FAIL: stopped child must be gone"); return 1; }
    puts("Process ownership checks passed");
    return 0;
}
