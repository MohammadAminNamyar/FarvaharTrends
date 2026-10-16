package main

import (
	"syscall"
	"time"
	"unsafe"
)

var processTimes = syscall.NewLazyDLL("kernel32.dll").NewProc("GetProcessTimes")

func cpuTime() time.Duration {
	var created, exited, kernel, user syscall.Filetime
	handle, e := syscall.GetCurrentProcess()
	must(e)
	ok, _, e := processTimes.Call(uintptr(handle), uintptr(unsafe.Pointer(&created)), uintptr(unsafe.Pointer(&exited)), uintptr(unsafe.Pointer(&kernel)), uintptr(unsafe.Pointer(&user)))
	if ok == 0 {
		panic(e)
	}
	ticks := (uint64(kernel.HighDateTime)<<32 | uint64(kernel.LowDateTime)) + (uint64(user.HighDateTime)<<32 | uint64(user.LowDateTime))
	return time.Duration(ticks) * 100
}
