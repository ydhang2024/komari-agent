package monitoring

import (
	"runtime"
	"strings"
	"time"

	"github.com/shirou/gopsutil/cpu"
)

type CpuInfo struct {
	CPUName         string  `json:"cpu_name"`
	CPUArchitecture string  `json:"cpu_architecture"`
	CPUCores        int     `json:"cpu_cores"`
	CPUUsage        float64 `json:"cpu_usage"`
}

func Cpu() CpuInfo {
	cpuinfo := CpuInfo{}
	info, err := cpu.Info()
	if err != nil {
		cpuinfo.CPUName = "Unknown"
	}
	// multiple CPU
	// 多个 CPU
	if len(info) > 1 {
		for _, cpu := range info {
			cpuinfo.CPUName += cpu.ModelName + ", "
		}
		cpuinfo.CPUName = cpuinfo.CPUName[:len(cpuinfo.CPUName)-2] // Remove trailing comma and space
	} else if len(info) == 1 {
		cpuinfo.CPUName = info[0].ModelName
	}

	cpuinfo.CPUName = strings.TrimSpace(cpuinfo.CPUName)

	cpuinfo.CPUArchitecture = runtime.GOARCH

	cores, err := cpu.Counts(true)
	if err != nil {
		cpuinfo.CPUCores = 1 // Error case
	}
	cpuinfo.CPUCores = cores

	// Get CPU Usage
	percentages, err := cpu.Percent(1*time.Second, false)
	if err != nil {
		cpuinfo.CPUUsage = 0.0 // Error case
	} else {
		cpuinfo.CPUUsage = percentages[0]
	}
	return cpuinfo
}
