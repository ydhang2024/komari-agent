package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"komari/config"
	"komari/monitoring"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	localConfig, err := config.LoadConfig()
	if err != nil {
		log.Fatalln("Failed to load local config:", err)
	}
	if localConfig.IgnoreUnsafeCert {
		http.DefaultTransport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}

	remoteConfig, err := config.LoadRemoteConfig(localConfig.Endpoint, localConfig.Token)
	if err != nil {
		log.Fatalln("Failed to load remote config:", err)
	}

	//log.Println("Remote Config:", remoteConfig)

	err = uploadBasicInfo(localConfig.Endpoint, localConfig.Token)
	if err != nil {
		log.Fatalln("Failed to upload basic info:", err)
	}

	websocketEndpoint := strings.TrimSuffix(localConfig.Endpoint, "/") + "/ws/report"
	websocketEndpoint = "ws" + strings.TrimPrefix(websocketEndpoint, "http")

	var conn *websocket.Conn
	defer func() {
		if conn != nil {
			conn.Close()
		}
	}()

	ticker := time.NewTicker(time.Duration(remoteConfig.Interval * int(time.Second)))
	defer ticker.Stop()

	for range ticker.C {
		// If no connection, attempt to connect
		if conn == nil {
			log.Println("Attempting to connect to WebSocket...")
			retry := 0
			for retry < localConfig.MaxRetries {
				conn, err = connectWebSocket(websocketEndpoint, localConfig.Endpoint, localConfig.Token)
				if err == nil {
					log.Println("WebSocket connected")
					go handleWebSocketMessages(localConfig, remoteConfig, conn, make(chan struct{}))
					break
				}
				retry++
				time.Sleep(time.Duration(localConfig.ReconnectInterval) * time.Second)
			}

			if retry >= localConfig.MaxRetries {
				log.Println("Max retries reached, falling back to POST")
				// Send report via POST and continue
				data := report(localConfig, remoteConfig)
				if err := reportWithPOST(localConfig.Endpoint, data); err != nil {
					log.Println("Failed to send POST report:", err)
				}
				continue
			}
		}

		// Send report via WebSocket
		data := report(localConfig, remoteConfig)
		err = conn.WriteMessage(websocket.TextMessage, data)
		if err != nil {
			log.Println("Failed to send WebSocket message:", err)
			conn.Close()
			conn = nil // Mark connection as dead
			continue
		}

	}
}

// connectWebSocket attempts to establish a WebSocket connection and upload basic info
func connectWebSocket(websocketEndpoint, endpoint, token string) (*websocket.Conn, error) {
	dialer := &websocket.Dialer{
		HandshakeTimeout: 5 * time.Second,
	}
	conn, _, err := dialer.Dial(websocketEndpoint, nil)
	if err != nil {
		return nil, err
	}

	// Upload basic info after successful connection
	if err := uploadBasicInfo(endpoint, token); err != nil {
		log.Println("Failed to upload basic info:", err)
		// Note: We don't return error here to allow the connection to proceed
	}

	return conn, nil
}

func handleWebSocketMessages(localConfig config.LocalConfig, remoteConfig config.RemoteConfig, conn *websocket.Conn, done chan<- struct{}) {
	defer close(done)
	for {
		_, message_raw, err := conn.ReadMessage()
		if err != nil {
			log.Println("WebSocket read error:", err)
			return
		}
		// TODO: Remote config update
		// TODO: Handle incoming messages
		log.Println("Received message:", string(message_raw))
		message := make(map[string]interface{})
		err = json.Unmarshal(message_raw, &message)
		if err != nil {
			log.Println("Bad ws message:", err)
			continue
		}

	}
}

func reportWithPOST(endpoint string, data []byte) error {
	url := strings.TrimSuffix(endpoint, "/") + "/api/report"
	req, err := http.NewRequest("POST", url, strings.NewReader(string(data)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return err
	}
	return nil
}

func uploadBasicInfo(endpoint string, token string) error {
	cpu := monitoring.Cpu()
	osname := monitoring.OSName()
	data := map[string]interface{}{
		"token": token,
		"cpu": map[string]interface{}{
			"name":  cpu.CPUName,
			"cores": cpu.CPUCores,
			"arch":  cpu.CPUArchitecture,
		},
		"os": osname,
	}

	endpoint = strings.TrimSuffix(endpoint, "/") + "/api/nodeBasicInfo"
	payload, err := json.Marshal(data)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", endpoint, strings.NewReader(string(payload)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	message := string(body)

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status code: %d,%s", resp.StatusCode, message)
	}

	return nil
}

func report(localConfig config.LocalConfig, remoteConfig config.RemoteConfig) []byte {
	message := ""
	data := map[string]interface{}{
		"token": localConfig.Token,
	}
	if remoteConfig.Cpu {
		cpu := monitoring.Cpu()
		data["cpu"] = map[string]interface{}{
			"usage": cpu.CPUUsage,
		}
	}
	if remoteConfig.Ram {
		ram := monitoring.Ram()
		data["ram"] = map[string]interface{}{
			"total": ram.Total,
			"used":  ram.Used,
		}
	}
	if remoteConfig.Swap {
		swap := monitoring.Swap()
		data["swap"] = map[string]interface{}{
			"total": swap.Total,
			"used":  swap.Used,
		}
	}
	if remoteConfig.Load {
		load := monitoring.Load()
		data["load"] = map[string]interface{}{
			"load1":  load.Load1,
			"load5":  load.Load5,
			"load15": load.Load15,
		}
	}
	if remoteConfig.Disk {
		disk := monitoring.Disk()
		data["disk"] = map[string]interface{}{
			"total": disk.Total,
			"used":  disk.Used,
		}
	}
	if remoteConfig.Network {
		totalUp, totalDown, networkUp, networkDown, err := monitoring.NetworkSpeed(remoteConfig.Interval)
		if err != nil {
			message += fmt.Sprintf("failed to get network speed: %v\n", err)
		}
		data["network"] = map[string]interface{}{
			"up":        networkUp,
			"down":      networkDown,
			"totalUp":   totalUp,
			"totalDown": totalDown,
		}
	}
	if remoteConfig.Connections {
		tcpCount, udpCount, err := monitoring.ConnectionsCount()
		if err != nil {
			message += fmt.Sprintf("failed to get connections: %v\n", err)
		}
		data["connections"] = map[string]interface{}{
			"tcp": tcpCount,
			"udp": udpCount,
		}
	}
	if remoteConfig.Uptime {
		uptime, err := monitoring.Uptime()
		if err != nil {
			message += fmt.Sprintf("failed to get uptime: %v\n", err)
		}
		data["uptime"] = uptime
	}
	if remoteConfig.Process {
		processcount := monitoring.ProcessCount()
		data["process"] = processcount
	}
	data["message"] = message

	s, err := json.Marshal(data)
	if err != nil {
		log.Println("Failed to marshal data:", err)
	}
	return s
}
