package scan

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"localsend-cli/internal/crypto"
	"localsend-cli/internal/localsend"
	"localsend-cli/internal/localsend/utils"
	"localsend-cli/internal/models"
	"localsend-cli/internal/webrtc/signaling"
)

var (
	timeout int64
	legacy  bool
	webrtc  bool
	lan     bool
)

var Cmd = &cobra.Command{
	Use:   "scan",
	Short: "Scan local network for localsend instance",
	Long:  "Scan local network for localsend instance",
	Run: func(cmd *cobra.Command, args []string) {
		slog.Info("Start Scanning")

		scanner, err := localsend.NewDiscoverer(
			models.NewDeviceInfo(utils.GenAlias(), utils.GenFingerprint()),
			false)
		if err != nil {
			slog.Error("Fail to create advertiser", "error", err)
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), time.Second*time.Duration(timeout))
		defer cancel()

		// If no protocol flags are set, enable all discovery methods
		if !cmd.Flags().Changed("lan") && !cmd.Flags().Changed("legacy") && !cmd.Flags().Changed("webrtc") {
			lan = true
			legacy = true
			webrtc = true
		}

		var wg sync.WaitGroup
		if lan {
			slog.Info("Performing LAN discovery")
			wg.Add(1)
			go func() {
				defer wg.Done()
				_ = scanner.Listen()
			}()
		}

		if legacy {
			slog.Info("Performing legacy HTTP subnet scan")
			wg.Add(1)
			go func() {
				defer wg.Done()
				scanner.ScanSubnet(ctx)
			}()
		}

		// WebRTC signaling discovery
		var signalingPeers []signaling.ClientInfo
		if webrtc {
			slog.Info("Connecting to WebRTC signaling server")
			signalingPeers = discoverViaSignaling(ctx)
		}

		<-ctx.Done()
		slog.Info("Stop Scanning")
		_ = scanner.Shutdown()
		wg.Wait()

		devlist := scanner.GetAllDiscovered()

		if len(devlist) > 0 || len(signalingPeers) > 0 {
			_, _ = fmt.Fprintf(os.Stdout, "Found Devices: \n")

			// LAN devices
			for ip, info := range devlist {
				_, _ = fmt.Fprintf(os.Stdout, "\t[LAN] Name: %s, Version: %s, Address: %s:%d, Protocol: %s\n",
					info.Alias, info.Version, ip, info.Port, info.Protocol)
			}

			// WebRTC signaling peers
			for _, peer := range signalingPeers {
				_, _ = fmt.Fprintf(os.Stdout, "\t[WebRTC] Name: %s, Version: %s, ID: %s\n",
					peer.Alias, peer.Version, peer.ID)
			}
		} else {
			fmt.Fprintln(os.Stderr, "No device found")
		}
	},
}

func discoverViaSignaling(ctx context.Context) []signaling.ClientInfo {
	// Generate signing key and token
	_, token, err := crypto.GenerateKeyPairWithToken()
	if err != nil {
		slog.Error("Failed to generate key pair with token", "error", err)
		return nil
	}

	// Connect to signaling server
	info := signaling.NewClientInfo(utils.GenAlias(), token)

	client, err := signaling.Connect(signaling.DefaultSignalingServer, info)
	if err != nil {
		slog.Error("Failed to connect to signaling server", "error", err)
		return nil
	}
	defer func() { _ = client.Close() }()

	slog.Info("Connected to signaling server", "id", client.ClientID())

	// Wait for context or collect peers
	select {
	case <-ctx.Done():
	case <-time.After(2 * time.Second):
		// Give some time to receive JOIN messages
	}

	return client.GetPeers()
}

func init() {
	Cmd.PersistentFlags().Int64VarP(&timeout, "timeout", "t", 4, "scan duration in seconds")
	Cmd.PersistentFlags().BoolVarP(&legacy, "legacy", "l", false, "perform legacy HTTP subnet scan")
	Cmd.PersistentFlags().BoolVarP(&webrtc, "webrtc", "w", false, "discover peers via WebRTC signaling server")
	Cmd.PersistentFlags().BoolVarP(&lan, "lan", "n", false, "perform LAN discovery (mDNS/UDP)")
}
