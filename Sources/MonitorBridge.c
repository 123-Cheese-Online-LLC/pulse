#include "MonitorBridge.h"
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

void pulse_host(PulseHost *out) {
    memset(out, 0, sizeof(*out));
    out->pressure = -1;
    mach_port_t host = mach_host_self();
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
        out->user = cpu.cpu_ticks[CPU_STATE_USER];
        out->system = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        out->idle = cpu.cpu_ticks[CPU_STATE_IDLE];
        out->nice = cpu.cpu_ticks[CPU_STATE_NICE];
        out->cpu_valid = 1;
    }
    size_t size = sizeof(out->memory_total);
    sysctlbyname("hw.memsize", &out->memory_total, &size, NULL, 0);
    vm_statistics64_data_t vm;
    count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    host_page_size(host, &page);
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS && out->memory_total > 0) {
        uint64_t app_pages = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
        out->memory_used = (app_pages + vm.wire_count + vm.compressor_page_count) * page;
        if (out->memory_used > out->memory_total) out->memory_used = out->memory_total;
        out->compressed = (uint64_t)vm.compressor_page_count * page;
        out->memory_valid = 1;
    }
    struct xsw_usage swap;
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        out->swap_used = swap.xsu_used;
        out->swap_valid = 1;
    }
    int pressure = 0;
    size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) == 0) out->pressure = pressure;
    mach_port_deallocate(mach_task_self(), host);
}

int pulse_processes(PulseProcess *out, int capacity, int *skipped) {
    *skipped = 0;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    int needed = proc_listallpids(NULL, 0);
    if (needed <= 0) return -1;
    int allocated = needed + 512;
    pid_t *pids = calloc((size_t)allocated, sizeof(pid_t));
    if (!pids) return -1;
    int total = proc_listallpids(pids, allocated * (int)sizeof(pid_t));
    if (total < 0) { free(pids); return -1; }
    if (total > allocated) total = allocated;
    int written = 0;
    for (int i = 0; i < total; i++) {
        if (pids[i] <= 0) continue;
        if (written >= capacity) { (*skipped)++; continue; }
        struct proc_taskallinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != sizeof(info)) {
            (*skipped)++;
            continue;
        }
        PulseProcess *p = &out[written];
        memset(p, 0, sizeof(*p));
        p->pid = pids[i];
        p->parent_pid = info.pbsd.pbi_ppid;
        p->start = info.pbsd.pbi_start_tvsec * 1000000 + info.pbsd.pbi_start_tvusec;
        uint64_t ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system;
        p->cpu_time = (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom);
        struct rusage_info_v4 usage;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
            (*skipped)++;
            continue;
        }
        p->memory = usage.ri_phys_footprint;
        if (proc_pidpath(pids[i], p->path, sizeof(p->path)) <= 0) {
            snprintf(p->path, sizeof(p->path), "%s", info.pbsd.pbi_name[0] ? info.pbsd.pbi_name : info.pbsd.pbi_comm);
        }
        written++;
    }
    free(pids);
    return written;
}
