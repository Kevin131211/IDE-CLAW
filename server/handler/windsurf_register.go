package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Windsurf 官方注册流程（绕开 willxin666 / indevs.in 这俩已被 Cloudflare 1027 封死的代理）
//
// 协议来源：反编译 windsurf cascade extension `dist/extension.js` 找到：
//
//	const t = (0, n.createConnectTransport)({baseUrl: getRegisterApiServerUrl(),
//	                                          useBinaryFormat: !0, httpVersion: "1.1"}),
//	      a = (0, i.createPromiseClient)(g.SeatManagementService, t);
//	return await a.registerUser({firebaseIdToken: A});
//
// proto 定义（来自 extension.js 的 newFieldList）：
//
//	message RegisterUserRequest  { string firebase_id_token = 1; }
//	message RegisterUserResponse { string api_key = 1; string name = 2; string api_server_url = 3; }
//
// HTTP wire:
//
//	POST https://register.windsurf.com/exa.seat_management_pb.SeatManagementService/RegisterUser
//	Content-Type: application/proto
//	Connect-Protocol-Version: 1
//	body = protobuf binary of RegisterUserRequest

const (
	windsurfRegisterEndpoint = "https://register.windsurf.com/exa.seat_management_pb.SeatManagementService/RegisterUser"
	windsurfRegisterTimeout  = 30 * time.Second
)

// WindsurfRegisterResult 服务端返回的可用凭据
type WindsurfRegisterResult struct {
	APIKey       string `json:"api_key"`        // devin-session-token$<JWT>
	Name         string `json:"name"`           // 用户名（windsurf 后端给的）
	APIServerURL string `json:"api_server_url"` // 例如 https://server.self-serve.windsurf.com
}

// RegisterWindsurfUser 用 Firebase ID token (浏览器 OAuth 登录后拿到的 access_token)
// 调 Windsurf 官方 register.windsurf.com 注册当前会话，返回 apiKey + 用户信息
func RegisterWindsurfUser(ctx context.Context, firebaseIDToken string) (*WindsurfRegisterResult, error) {
	if firebaseIDToken == "" {
		return nil, fmt.Errorf("firebase_id_token 不能为空")
	}

	// 编码 protobuf RegisterUserRequest{ firebase_id_token = 1 (string) }
	reqBody := encodeProtoStringFieldN(1, firebaseIDToken)

	httpReq, err := http.NewRequestWithContext(ctx, "POST", windsurfRegisterEndpoint, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("构造请求失败: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/proto")
	httpReq.Header.Set("Connect-Protocol-Version", "1")
	httpReq.Header.Set("Accept", "application/proto")
	httpReq.Header.Set("User-Agent", "ide-claw/1.0 (windsurf-pool)")

	client := &http.Client{Timeout: windsurfRegisterTimeout}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("调用 register.windsurf.com 失败: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读取响应失败: %w", err)
	}

	if resp.StatusCode != 200 {
		// 错误响应是 Connect-RPC JSON: {"code":"...","message":"..."}
		var errResp struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		if json.Unmarshal(respBody, &errResp) == nil && errResp.Code != "" {
			return nil, fmt.Errorf("windsurf 注册失败 [%d %s]: %s", resp.StatusCode, errResp.Code, errResp.Message)
		}
		preview := string(respBody)
		if len(preview) > 200 {
			preview = preview[:200] + "..."
		}
		return nil, fmt.Errorf("windsurf 注册失败 [%d]: %s", resp.StatusCode, preview)
	}

	// 成功响应是 protobuf binary。解码 RegisterUserResponse
	apiKey, name, apiServerURL, err := decodeRegisterUserResponse(respBody)
	if err != nil {
		return nil, fmt.Errorf("解析响应失败: %w (raw len=%d)", err, len(respBody))
	}
	if apiKey == "" {
		return nil, fmt.Errorf("响应中 api_key 为空（windsurf 服务端异常）")
	}
	return &WindsurfRegisterResult{APIKey: apiKey, Name: name, APIServerURL: apiServerURL}, nil
}

// readVarint 读 protobuf varint，返回 (value, bytes_consumed)
func readVarint(b []byte) (uint64, int, error) {
	var v uint64
	var shift uint
	for i := 0; i < len(b); i++ {
		bt := b[i]
		v |= uint64(bt&0x7f) << shift
		if bt&0x80 == 0 {
			return v, i + 1, nil
		}
		shift += 7
		if shift >= 64 {
			return 0, 0, fmt.Errorf("varint 超过 64 位")
		}
	}
	return 0, 0, fmt.Errorf("varint 截断")
}

// decodeRegisterUserResponse 解码 protobuf RegisterUserResponse
//
//	field 1 string api_key
//	field 2 string name
//	field 3 string api_server_url
func decodeRegisterUserResponse(b []byte) (apiKey, name, apiServerURL string, err error) {
	for len(b) > 0 {
		tag, n, e := readVarint(b)
		if e != nil {
			return "", "", "", fmt.Errorf("读 tag: %w", e)
		}
		b = b[n:]
		fieldNum := uint32(tag >> 3)
		wireType := uint32(tag & 7)
		if wireType != 2 {
			// 非 LEN，跳过（这里所有字段都是 string，不应该出现）
			// 但兼容性起见跳过 varint/fixed 类型
			switch wireType {
			case 0: // varint
				_, n, e := readVarint(b)
				if e != nil {
					return "", "", "", fmt.Errorf("跳过 varint: %w", e)
				}
				b = b[n:]
			case 1: // fixed64
				if len(b) < 8 {
					return "", "", "", fmt.Errorf("fixed64 截断")
				}
				b = b[8:]
			case 5: // fixed32
				if len(b) < 4 {
					return "", "", "", fmt.Errorf("fixed32 截断")
				}
				b = b[4:]
			default:
				return "", "", "", fmt.Errorf("未知 wire_type %d", wireType)
			}
			continue
		}
		// LEN
		length, n, e := readVarint(b)
		if e != nil {
			return "", "", "", fmt.Errorf("读 length: %w", e)
		}
		b = b[n:]
		if uint64(len(b)) < length {
			return "", "", "", fmt.Errorf("LEN 字段截断 (need=%d have=%d)", length, len(b))
		}
		val := string(b[:length])
		b = b[length:]
		switch fieldNum {
		case 1:
			apiKey = val
		case 2:
			name = val
		case 3:
			apiServerURL = val
		}
	}
	return apiKey, name, apiServerURL, nil
}
