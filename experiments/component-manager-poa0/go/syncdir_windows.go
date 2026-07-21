//go:build windows

package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	genericWrite            = 0x40000000
	fileShareRead           = 0x00000001
	fileShareWrite          = 0x00000002
	fileShareDelete         = 0x00000004
	openExisting            = 3
	fileFlagBackupSemantics = 0x02000000
)

var (
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	createFileW      = kernel32.NewProc("CreateFileW")
	flushFileBuffers = kernel32.NewProc("FlushFileBuffers")
)

func syncDir(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("directory sync target is not a directory: %s", path)
	}

	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	handle, _, openErr := createFileW.Call(
		uintptr(unsafe.Pointer(name)),
		genericWrite,
		fileShareRead|fileShareWrite|fileShareDelete,
		0,
		openExisting,
		fileFlagBackupSemantics,
		0,
	)
	if handle == uintptr(syscall.InvalidHandle) {
		return fmt.Errorf("open directory for durability sync: %w", openErr)
	}
	directory := syscall.Handle(handle)
	defer syscall.CloseHandle(directory)

	ok, _, flushErr := flushFileBuffers.Call(handle)
	if ok == 0 {
		return fmt.Errorf("flush directory for durability sync: %w", flushErr)
	}
	return nil
}
