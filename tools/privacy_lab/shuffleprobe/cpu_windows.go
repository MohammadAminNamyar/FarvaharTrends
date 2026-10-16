package main

import (
	"golang.org/x/sys/windows"
	"time"
)

func cpuTime() time.Duration {
	var created, exited, kernel, user windows.Filetime
	must(windows.GetProcessTimes(windows.CurrentProcess(), &created, &exited, &kernel, &user))
	ticks := uint64(kernel.HighDateTime)<<32 | uint64(kernel.LowDateTime)
	ticks += uint64(user.HighDateTime)<<32 | uint64(user.LowDateTime)
	return time.Duration(ticks) * 100
}
