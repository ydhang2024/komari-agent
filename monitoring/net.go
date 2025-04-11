package monitoring

import (
	"fmt"

	"github.com/shirou/gopsutil/net"
)

func ConnectionsCount() (tcpCount, udpCount int, err error) {
	tcps, err := net.Connections("tcp")
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get TCP connections: %w", err)
	}
	udps, err := net.Connections("udp")
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get UDP connections: %w", err)
	}

	return len(tcps), len(udps), nil
}

func NetworkSpeed() (upSpeed, downSpeed float64, err error) {
	// Get the network IO counters
	ioCounters, err := net.IOCounters(false)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get network IO counters: %w", err)
	}

	if len(ioCounters) == 0 {
		return 0, 0, fmt.Errorf("no network interfaces found")
	}

	for _, interfaceStats := range ioCounters {
		loopbackNames := []string{"lo", "lo0", "localhost", "brd0", "docker0", "docker1", "veth0", "veth1", "veth2", "veth3", "veth4", "veth5", "veth6", "veth7"}
		isLoopback := false
		for _, name := range loopbackNames {
			if interfaceStats.Name == name {
				isLoopback = true
				break
			}
		}
		if isLoopback {
			continue // Skip loopback interface
		}
		upSpeed += float64(interfaceStats.BytesSent) / float64(interfaceStats.PacketsSent)
		downSpeed += float64(interfaceStats.BytesRecv) / float64(interfaceStats.PacketsRecv)

	}

	return upSpeed, downSpeed, nil
}
