//go:build darwin

package main

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
#include <stdint.h>

static int poa_process_start_identity(int pid, uint64_t *identity) {
	struct proc_bsdinfo info;
	int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
	if (size != sizeof(info) || info.pbi_start_tvsec == 0 || info.pbi_start_tvusec >= 1000000) {
		return size;
	}
	if (info.pbi_start_tvsec > (UINT64_MAX - info.pbi_start_tvusec) / 1000000) {
		return -1;
	}
	*identity = info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
	return size;
}
*/
import "C"

import (
	"fmt"
	"os"
	"strconv"
)

func darwinProcessStartIdentity(pid int) (uint64, error) {
	var identity C.uint64_t
	if read := C.poa_process_start_identity(C.int(pid), &identity); read != C.int(C.sizeof_struct_proc_bsdinfo) {
		return 0, fmt.Errorf("proc_pidinfo failed for pid %d: returned %d", pid, read)
	}
	return uint64(identity), nil
}

func init() {
	if len(os.Args) < 2 || os.Args[1] != "process-start-identity" {
		return
	}
	if len(os.Args) != 4 || os.Args[2] != "--pid" {
		fmt.Fprintln(os.Stderr, "valid --pid required")
		os.Exit(1)
	}
	pid, err := strconv.ParseInt(os.Args[3], 10, 32)
	if err != nil || pid <= 0 {
		fmt.Fprintln(os.Stderr, "valid --pid required")
		os.Exit(1)
	}
	identity, err := darwinProcessStartIdentity(int(pid))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(identity)
	os.Exit(0)
}
