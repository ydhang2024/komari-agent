package config

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type RemoteConfig struct {
	Cpu         bool `json:"cpu"`
	Gpu         bool `json:"gpu"`
	Ram         bool `json:"ram"`
	Swap        bool `json:"swap"`
	Load        bool `json:"load"`
	Uptime      bool `json:"uptime"`
	Temperature bool `json:"temp"`
	Os          bool `json:"os"`
	Disk        bool `json:"disk"`
	Network     bool `json:"net"`
	Process     bool `json:"process"`
	Interval    int  `json:"interval"`
	Connections bool `json:"connections"`
}

// 使用HTTP GET请求远程配置
//
// GET /api/getRemoteConfig
//
// Request the remote configuration
func LoadRemoteConfig(endpoint string, token string) (RemoteConfig, error) {
	const maxRetry = 3
	endpoint = strings.TrimSuffix(endpoint, "/") + "/api/getRemoteConfig" + "?token=" + token

	var resp *http.Response
	var err error

	for attempt := 1; attempt <= maxRetry; attempt++ {
		resp, err = http.Get(endpoint)
		if err == nil && resp.StatusCode == http.StatusOK {
			break
		}
		if resp != nil {
			resp.Body.Close()
		}
		if attempt == maxRetry {
			if err != nil {
				return RemoteConfig{}, fmt.Errorf("failed to fetchafter %d attempts: %v", maxRetry, err)
			}
			return RemoteConfig{}, fmt.Errorf("failed to fetch after %d attempts: %s", maxRetry, resp.Status)
		}
		time.Sleep(time.Second * time.Duration(attempt)) // Exponential backoff
	}

	defer resp.Body.Close()

	response, err := io.ReadAll(resp.Body)
	if err != nil {
		return RemoteConfig{}, err
	}

	var remoteConfig RemoteConfig
	if err := json.Unmarshal(response, &remoteConfig); err != nil {
		return RemoteConfig{}, err
	}

	return remoteConfig, nil
}
