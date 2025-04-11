package monitoring

import (
	"bufio"
	"os"
	"runtime"
	"strings"

	"golang.org/x/sys/windows/registry"
)

func OSName() string {
	if runtime.GOOS == "windows" {
		key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE)
		if err != nil {
			return "Microsoft Windows"
		}
		defer key.Close()

		productName, _, err := key.GetStringValue("ProductName")
		if err != nil {
			return "Microsoft Windows"
		}

		return productName
	} else if runtime.GOOS == "linux" {
		file, err := os.Open("/etc/os-release")
		if err != nil {
			return "Linux"
		}
		defer file.Close()

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				return strings.Trim(line[len("PRETTY_NAME="):], `"`)
			}
		}

		if err := scanner.Err(); err != nil {
			return "Linux"
		}

		return "Linux"
	}

	return "Unknown"
}
