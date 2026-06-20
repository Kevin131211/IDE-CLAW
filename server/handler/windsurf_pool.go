package handler

// 星火无痕换号集成：账号池 CRUD + 第三方代理登录 + 额度刷新 + 自动切换调度
//
// 设计：
//   - 客户端（手机/桌面）通过这些 endpoint 管理 Windsurf 账号池
//   - 服务端调第三方代理 (willxin666.xyz / indevs.in) 拿 auth1Token + idToken
//   - 服务端调 web-backend.windsurf.com/exa.seat_management_pb.SeatManagementService/* 拿 quota
//   - 实际"切号"由桌面端 ide_claw.exe 接 WS 命令后修补本地 Windsurf extension.js + 重启
//
// 注意：第三方代理是黑盒，能看到 email + password 明文，使用时用户自担风险。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"push-server/config"
	"push-server/store"
	"push-server/ws"
)

// 第三方登录代理（按顺序尝试，前者失败则 fallback）
var windsurfLoginProxies = []string{
	"https://api.willxin666.xyz",
	"https://windsurf.aiapi.indevs.in",
}

// Windsurf 官方 PostAuth（exchange auth1 -> session JWT）
const windsurfPostAuthURL = "https://web-backend.windsurf.com/exa.seat_management_pb.SeatManagementService/WindsurfPostAuth"

// 默认自动切换阈值（百分比）
const defaultAutoSwitchThreshold = 5.0

// LoginResult 代理登录返回的字段集（兼容多种命名）
type windsurfLoginResult struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	Auth1Token   string `json:"auth1_token"`
	AccountID    string `json:"account_id"`
	PrimaryOrgID string `json:"primary_org_id"`
}

// loginWindsurfViaProxy 调第三方代理登录，按顺序尝试所有代理
func loginWindsurfViaProxy(email, password string) (*windsurfLoginResult, error) {
	if email == "" || password == "" {
		return nil, fmt.Errorf("email + password 必填")
	}
	var lastErr error
	for _, base := range windsurfLoginProxies {
		url := base + "/_devin-auth/password/login"
		payload := map[string]string{"email": email, "password": password}
		body, _ := json.Marshal(payload)
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("User-Agent", windsurfBrowserUA)

		client := &http.Client{Timeout: 20 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("代理 %s 不可达: %w", base, err)
			continue
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			lastErr = fmt.Errorf("代理 %s HTTP %d: %s", base, resp.StatusCode, string(raw))
			continue
		}
		var data map[string]interface{}
		if err := json.Unmarshal(raw, &data); err != nil {
			lastErr = fmt.Errorf("代理 %s 响应解析失败: %w", base, err)
			continue
		}

		// 兼容多种命名（token/idToken; auth1Token/auth1; account_id/accountId; primaryOrgId/orgId）
		pickStr := func(keys ...string) string {
			for _, k := range keys {
				if v, ok := data[k].(string); ok && v != "" {
					return v
				}
			}
			return ""
		}
		result := &windsurfLoginResult{
			IDToken:      pickStr("idToken", "id_token", "token"),
			RefreshToken: pickStr("refreshToken", "refresh_token"),
			Auth1Token:   pickStr("auth1Token", "auth1_token", "auth1"),
			AccountID:    pickStr("accountId", "account_id"),
			PrimaryOrgID: pickStr("primaryOrgId", "primary_org_id", "orgId", "org_id"),
		}
		// refreshToken 兜底用 idToken
		if result.RefreshToken == "" {
			result.RefreshToken = result.IDToken
		}
		// auth1Token 兜底用 idToken
		if result.Auth1Token == "" {
			result.Auth1Token = result.IDToken
		}
		if result.IDToken == "" && result.Auth1Token == "" {
			lastErr = fmt.Errorf("代理 %s 响应未含 token: %s", base, string(raw))
			continue
		}
		return result, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("所有代理都失败")
	}
	return nil, lastErr
}

// AddWindsurfAccountPool 单个添加账号 + 自动登录拿 token
//
//	POST /api/windsurf/accounts/add  { email, password, [skip_login] }
func AddWindsurfAccountPool(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email     string `json:"email"`
			Password  string `json:"password"`
			SkipLogin bool   `json:"skip_login"` // true = 仅写库不调代理
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		req.Email = strings.TrimSpace(req.Email)
		if req.Email == "" || req.Password == "" {
			errorJSON(w, 400, "email + password 必填")
			return
		}
		// 写库
		if _, err := db.AddWindsurfAccount(req.Email, req.Password); err != nil {
			errorJSON(w, 500, "保存失败: "+err.Error())
			return
		}
		// 默认尝试登录拿 token + 拉额度
		var loginErr error
		if !req.SkipLogin {
			if lr, err := loginWindsurfViaProxy(req.Email, req.Password); err == nil {
				_ = db.UpdateWindsurfAccountTokens(req.Email,
					lr.IDToken, lr.RefreshToken, lr.Auth1Token, lr.AccountID, lr.PrimaryOrgID)
				// 拿到 token 后异步刷一次额度（不阻塞接口）
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					defer cancel()
					_ = refreshOneWindsurfAccount(ctx, db, req.Email)
				}()
			} else {
				loginErr = err
			}
		}
		resp := map[string]interface{}{
			"success": true,
			"email":   req.Email,
		}
		if loginErr != nil {
			resp["login_error"] = loginErr.Error()
			resp["note"] = "已保存到账号池但登录代理失败，可手动重试 refresh-quota"
		}
		writeJSON(w, 200, resp)
	}
}

// DeleteWindsurfAccountPool 删除账号
//
//	POST /api/windsurf/accounts/delete  { email }
func DeleteWindsurfAccountPool(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email string `json:"email"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Email == "" {
			errorJSON(w, 400, "email 不能为空")
			return
		}
		if err := db.DeleteWindsurfAccount(req.Email); err != nil {
			errorJSON(w, 500, "删除失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{"success": true})
	}
}

// refreshOneWindsurfAccount 拉单个账号的额度信息并写库
// 1. 如果有 idToken 直接用；否则先登录拿 token
// 2. 用 auth1Token 调 WindsurfPostAuth 换 session（暂存内存）
// 3. 调 windsurf 官方 quota API（这部分原插件用 gRPC-Web，我们尽力而为，失败则保留旧数据）
func refreshOneWindsurfAccount(ctx context.Context, db *store.DB, email string) error {
	acc, err := db.GetWindsurfAccountByEmail(email)
	if err != nil || acc == nil {
		return fmt.Errorf("账号不存在: %s", email)
	}

	// 1. 确保有 token；没有就先登录
	if acc.IdToken == "" || acc.Auth1Token == "" {
		if acc.Password == "" {
			return fmt.Errorf("账号 %s 缺少密码，无法登录刷新", email)
		}
		lr, err := loginWindsurfViaProxy(acc.Email, acc.Password)
		if err != nil {
			return fmt.Errorf("登录失败: %w", err)
		}
		acc.IdToken = lr.IDToken
		acc.RefreshToken = lr.RefreshToken
		acc.Auth1Token = lr.Auth1Token
		acc.AccountID = lr.AccountID
		acc.PrimaryOrgID = lr.PrimaryOrgID
		_ = db.UpdateWindsurfAccountTokens(email,
			lr.IDToken, lr.RefreshToken, lr.Auth1Token, lr.AccountID, lr.PrimaryOrgID)
	}

	// 2. 调 PostAuth 换 session token（gRPC-Web，content-type: application/grpc-web+json）
	// 注：星火插件用的是 gRPC-Web 二进制协议，但 web-backend.windsurf.com 也支持 JSON 包装
	postAuthBody := map[string]interface{}{
		"auth1Token": acc.Auth1Token,
	}
	body, _ := json.Marshal(postAuthBody)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, windsurfPostAuthURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/grpc-web+json")
	req.Header.Set("Accept", "application/grpc-web+json")
	req.Header.Set("X-Grpc-Web", "1")
	req.Header.Set("Origin", windsurfBrowserOrigin)
	req.Header.Set("Referer", windsurfBrowserReferer)
	req.Header.Set("User-Agent", windsurfBrowserUA)

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("PostAuth 请求失败: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		// PostAuth 失败时不阻塞——星火插件也有 fallback
		return fmt.Errorf("PostAuth HTTP %d: %s", resp.StatusCode, truncate(string(raw), 200))
	}

	// 3. 从响应里提取 quotaUsage 字段（兼容多种位置）
	var data map[string]interface{}
	if err := json.Unmarshal(raw, &data); err != nil {
		return fmt.Errorf("PostAuth 响应解析失败: %w", err)
	}

	dailyP, weeklyP, dailyReset, weeklyReset, planName := extractQuotaFromPostAuth(data)
	if dailyP < 0 && weeklyP < 0 {
		return fmt.Errorf("响应中未找到 quotaUsage")
	}
	return db.UpdateWindsurfAccountQuota(email, dailyP, weeklyP, dailyReset, weeklyReset, planName)
}

// extractQuotaFromPostAuth 兼容多种响应结构提取额度
//
// 可能的位置：
//
//	data.quotaUsage.{dailyRemainingPercent, weeklyRemainingPercent, dailyResetAtUnix, weeklyResetAtUnix}
//	data.userInfo.quotaUsage.{...}
//	data.{dailyQuotaRemainingPercent, weeklyQuotaRemainingPercent, dailyQuotaResetAtUnix, weeklyQuotaResetAtUnix}
//	data.planName 或 data.subscription.planName
func extractQuotaFromPostAuth(data map[string]interface{}) (daily, weekly float64, dailyReset, weeklyReset int64, plan string) {
	daily, weekly = -1, -1

	getFloat := func(m map[string]interface{}, keys ...string) float64 {
		for _, k := range keys {
			if v, ok := m[k]; ok {
				switch x := v.(type) {
				case float64:
					return x
				case json.Number:
					f, _ := x.Float64()
					return f
				}
			}
		}
		return -1
	}
	getInt := func(m map[string]interface{}, keys ...string) int64 {
		for _, k := range keys {
			if v, ok := m[k]; ok {
				switch x := v.(type) {
				case float64:
					return int64(x)
				case json.Number:
					i, _ := x.Int64()
					return i
				}
			}
		}
		return 0
	}
	getStr := func(m map[string]interface{}, keys ...string) string {
		for _, k := range keys {
			if v, ok := m[k].(string); ok && v != "" {
				return v
			}
		}
		return ""
	}

	// 顶层尝试
	if v := getFloat(data, "dailyQuotaRemainingPercent", "dailyRemainingPercent"); v >= 0 {
		daily = v
	}
	if v := getFloat(data, "weeklyQuotaRemainingPercent", "weeklyRemainingPercent"); v >= 0 {
		weekly = v
	}
	dailyReset = getInt(data, "dailyQuotaResetAtUnix", "dailyResetAtUnix")
	weeklyReset = getInt(data, "weeklyQuotaResetAtUnix", "weeklyResetAtUnix")
	plan = getStr(data, "planName", "plan")

	// 嵌套 quotaUsage / userInfo
	candidates := []string{"quotaUsage", "userInfo", "user", "seat", "subscription"}
	for _, key := range candidates {
		nested, ok := data[key].(map[string]interface{})
		if !ok {
			continue
		}
		if daily < 0 {
			daily = getFloat(nested, "dailyRemainingPercent", "dailyQuotaRemainingPercent")
		}
		if weekly < 0 {
			weekly = getFloat(nested, "weeklyRemainingPercent", "weeklyQuotaRemainingPercent")
		}
		if dailyReset == 0 {
			dailyReset = getInt(nested, "dailyResetAtUnix", "dailyQuotaResetAtUnix")
		}
		if weeklyReset == 0 {
			weeklyReset = getInt(nested, "weeklyResetAtUnix", "weeklyQuotaResetAtUnix")
		}
		if plan == "" {
			plan = getStr(nested, "planName", "plan", "name")
		}
		// 二层嵌套 quotaUsage 在 userInfo 内
		if inner, ok := nested["quotaUsage"].(map[string]interface{}); ok {
			if daily < 0 {
				daily = getFloat(inner, "dailyRemainingPercent")
			}
			if weekly < 0 {
				weekly = getFloat(inner, "weeklyRemainingPercent")
			}
			if dailyReset == 0 {
				dailyReset = getInt(inner, "dailyResetAtUnix")
			}
			if weeklyReset == 0 {
				weeklyReset = getInt(inner, "weeklyResetAtUnix")
			}
		}
	}
	return daily, weekly, dailyReset, weeklyReset, plan
}

// RefreshWindsurfQuota 手动触发某账号刷额度
//
//	POST /api/windsurf/accounts/refresh-quota  { email }
func RefreshWindsurfQuota(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email string `json:"email"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Email == "" {
			errorJSON(w, 400, "email 不能为空")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		if err := refreshOneWindsurfAccount(ctx, db, req.Email); err != nil {
			errorJSON(w, 500, "刷新失败: "+err.Error())
			return
		}
		acc, _ := db.GetWindsurfAccountByEmail(req.Email)
		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"account": sanitizeAccount(acc),
		})
	}
}

// RefreshAllWindsurfQuotas 并发刷所有账号
//
//	POST /api/windsurf/accounts/refresh-all-quotas
func RefreshAllWindsurfQuotas(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		accounts, err := db.ListWindsurfAccounts()
		if err != nil {
			errorJSON(w, 500, "查询失败: "+err.Error())
			return
		}
		var (
			wg       sync.WaitGroup
			mu       sync.Mutex
			ok, fail int
			errors   = []string{}
		)
		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()
		for _, a := range accounts {
			if a.IsExpired {
				continue
			}
			wg.Add(1)
			go func(email string) {
				defer wg.Done()
				if err := refreshOneWindsurfAccount(ctx, db, email); err != nil {
					mu.Lock()
					fail++
					errors = append(errors, fmt.Sprintf("%s: %s", email, err.Error()))
					mu.Unlock()
				} else {
					mu.Lock()
					ok++
					mu.Unlock()
				}
			}(a.Email)
		}
		wg.Wait()
		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"ok":      ok,
			"fail":    fail,
			"errors":  errors,
		})
	}
}

// SwitchWindsurfAccount 切换到指定账号（或自动找下一个）
//
//	POST /api/windsurf/accounts/switch  { email, [reason], [target_session_id] }
//	→ 标记 is_active + WS 广播 cmd=windsurf_switch 给 PC 桌面端，由它修补 extension.js + 重启
func SwitchWindsurfAccount(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email           string `json:"email"`            // 空 = 自动找下一个
			Reason          string `json:"reason"`           // "manual" / "quota_low" / "quota_exhausted" / "out_of_credits"
			TargetSessionID string `json:"target_session_id"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}

		var target *store.WindsurfAccount
		if req.Email != "" {
			t, err := db.GetWindsurfAccountByEmail(req.Email)
			if err != nil || t == nil {
				errorJSON(w, 404, "账号不存在: "+req.Email)
				return
			}
			target = t
		} else {
			// 自动找下一个
			active, _ := db.GetActiveWindsurfAccount()
			currentEmail := ""
			if active != nil {
				currentEmail = active.Email
			}
			t, err := db.FindNextAvailableWindsurfAccount(currentEmail, defaultAutoSwitchThreshold)
			if err != nil {
				errorJSON(w, 500, "查询下一个账号失败: "+err.Error())
				return
			}
			if t == nil {
				errorJSON(w, 404, "没有可用账号（全部 < 阈值或已过期）")
				return
			}
			target = t
		}

		if err := db.SetActiveWindsurfAccount(target.Email); err != nil {
			errorJSON(w, 500, "标记激活失败: "+err.Error())
			return
		}

		// WS 广播命令给 PC 桌面端去执行实际 patch
		// 桌面端 ide_claw.exe 监听 type='windsurf_switch' 命令，调用本地 IPC 13800 让外部脚本/dialog.py 执行补丁
		broadcastTarget := req.TargetSessionID
		if broadcastTarget == "" {
			broadcastTarget = "ide-claw-001" // 默认 session
		}
		hub.BroadcastToSession(broadcastTarget, map[string]interface{}{
			"type": "windsurf_switch",
			"data": map[string]interface{}{
				"email":         target.Email,
				"id_token":      target.IdToken,
				"refresh_token": target.RefreshToken,
				"auth1_token":   target.Auth1Token,
				"account_id":    target.AccountID,
				"reason":        req.Reason,
				"timestamp":     time.Now().Unix(),
			},
		})

		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"email":   target.Email,
			"reason":  req.Reason,
			"account": sanitizeAccount(target),
		})
	}
}

// GetActiveWindsurfAccountHandler 返回当前激活账号
//
//	GET /api/windsurf/accounts/active
func GetActiveWindsurfAccountHandler(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		acc, err := db.GetActiveWindsurfAccount()
		if err != nil {
			errorJSON(w, 500, err.Error())
			return
		}
		if acc == nil {
			writeJSON(w, 200, map[string]interface{}{"active": nil})
			return
		}
		writeJSON(w, 200, map[string]interface{}{"active": sanitizeAccount(acc)})
	}
}

// QuotaExhaustedReport PC 端上报"额度用尽"事件 → 触发自动切换
//
//	POST /api/windsurf/accounts/quota-exhausted  { email, error_message, [target_session_id] }
func QuotaExhaustedReport(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email           string `json:"email"`
			ErrorMessage    string `json:"error_message"`
			TargetSessionID string `json:"target_session_id"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		// 先标记当前账号 daily=0（即时反映）
		if req.Email != "" {
			_ = db.UpdateWindsurfAccountQuota(req.Email, 0, -1, 0, 0, "")
		}
		// 找下一个可用账号
		next, err := db.FindNextAvailableWindsurfAccount(req.Email, defaultAutoSwitchThreshold)
		if err != nil {
			errorJSON(w, 500, "查找下一账号失败: "+err.Error())
			return
		}
		if next == nil {
			writeJSON(w, 200, map[string]interface{}{
				"success":      true,
				"switched":     false,
				"reason":       "no_available_account",
				"current_zero": req.Email,
			})
			return
		}
		_ = db.SetActiveWindsurfAccount(next.Email)
		// 广播切换命令
		broadcastTarget := req.TargetSessionID
		if broadcastTarget == "" {
			broadcastTarget = "ide-claw-001"
		}
		hub.BroadcastToSession(broadcastTarget, map[string]interface{}{
			"type": "windsurf_switch",
			"data": map[string]interface{}{
				"email":         next.Email,
				"id_token":      next.IdToken,
				"refresh_token": next.RefreshToken,
				"auth1_token":   next.Auth1Token,
				"account_id":    next.AccountID,
				"reason":        "quota_exhausted",
				"timestamp":     time.Now().Unix(),
			},
		})
		writeJSON(w, 200, map[string]interface{}{
			"success":      true,
			"switched":     true,
			"reason":       "quota_exhausted",
			"current_zero": req.Email,
			"new_email":    next.Email,
			"new_account":  sanitizeAccount(next),
		})
	}
}

// sanitizeAccount 返回客户端显示用的账号信息（去除 password / 完整 token）
func sanitizeAccount(a *store.WindsurfAccount) map[string]interface{} {
	if a == nil {
		return nil
	}
	maskToken := func(t string) string {
		if t == "" {
			return ""
		}
		if len(t) <= 12 {
			return "***"
		}
		return t[:6] + "..." + t[len(t)-4:]
	}
	return map[string]interface{}{
		"id":                       a.ID,
		"email":                    a.Email,
		"is_expired":               a.IsExpired,
		"locked_by":                a.LockedBy,
		"locked_at":                a.LockedAt,
		"login_count":              a.LoginCount,
		"created_at":               a.CreatedAt,
		"updated_at":               a.UpdatedAt,
		"daily_remaining_percent":  a.DailyRemainingPercent,
		"weekly_remaining_percent": a.WeeklyRemainingPercent,
		"daily_reset_at_unix":      a.DailyResetAtUnix,
		"weekly_reset_at_unix":     a.WeeklyResetAtUnix,
		"plan_name":                a.PlanName,
		"id_token_masked":          maskToken(a.IdToken),
		"has_refresh_token":        a.RefreshToken != "",
		"has_auth1_token":          a.Auth1Token != "",
		"account_id":               a.AccountID,
		"primary_org_id":           a.PrimaryOrgID,
		"quota_updated_at":         a.QuotaUpdatedAt,
		"auto_switch_threshold":    a.AutoSwitchThreshold,
		"is_active":                a.IsActive,
	}
}

// RegisterWindsurfWithToken 用客户端浏览器 OAuth 登录后拿到的 firebase_id_token (access_token)
// 调 windsurf 官方 register.windsurf.com 注册账号，写入 apiKey 等信息到 DB
//
//	POST /api/windsurf/accounts/register-with-token
//	body: { email, firebase_id_token, password? }  // password 可选，仅作备份用
//	→ 1. 调 RegisterWindsurfUser 拿 apiKey/name/apiServerUrl
//	→ 2. 不存在则 insert，存在则更新
//	→ 3. UpdateWindsurfAccountFromRegister 写 apiKey
//	→ 4. 返回新账号信息
func RegisterWindsurfWithToken(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email           string `json:"email"`
			FirebaseIDToken string `json:"firebase_id_token"`
			Password        string `json:"password"` // 可选，仅备份
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		req.Email = strings.TrimSpace(req.Email)
		req.FirebaseIDToken = strings.TrimSpace(req.FirebaseIDToken)
		if req.Email == "" {
			errorJSON(w, 400, "email 必填")
			return
		}
		if req.FirebaseIDToken == "" {
			errorJSON(w, 400, "firebase_id_token 必填")
			return
		}
		// 调 windsurf 官方 register
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		result, err := RegisterWindsurfUser(ctx, req.FirebaseIDToken)
		if err != nil {
			errorJSON(w, 502, "windsurf 注册失败: "+err.Error())
			return
		}
		// 写库（email 不存在则插入，password 可空）
		if _, err := db.AddWindsurfAccount(req.Email, req.Password); err != nil {
			errorJSON(w, 500, "保存 email 失败: "+err.Error())
			return
		}
		if err := db.UpdateWindsurfAccountFromRegister(req.Email,
			result.APIKey, result.Name, result.APIServerURL); err != nil {
			errorJSON(w, 500, "写 apiKey 失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"success":        true,
			"email":          req.Email,
			"name":           result.Name,
			"api_server_url": result.APIServerURL,
			"has_api_key":    result.APIKey != "",
			"note":           "已通过 windsurf 官方 RegisterUser 注册成功（不依赖任何第三方代理）",
		})
	}
}

// SaveWindsurfRegisterResult 客户端**本地**调 register.windsurf.com 拿到 apiKey 后，
// POST 上来由服务端入库
//
// 为什么不在服务端调？
//   - push-server 跑在国内 VPS（push.shoot-game.cn = 阿里云）
//   - register.windsurf.com 是 Cloudflare CDN，国内 VPS 直连超时
//   - 客户端（用户本机/手机）能在浏览器登录拿到 token 就证明能访问 windsurf.com
//
//	POST /api/windsurf/accounts/save-register-result
//	body: { email, password?, api_key, name?, api_server_url? }
func SaveWindsurfRegisterResult(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email        string `json:"email"`
			Password     string `json:"password"`
			APIKey       string `json:"api_key"`
			Name         string `json:"name"`
			APIServerURL string `json:"api_server_url"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		req.Email = strings.TrimSpace(req.Email)
		req.APIKey = strings.TrimSpace(req.APIKey)
		if req.Email == "" {
			errorJSON(w, 400, "email 必填")
			return
		}
		if req.APIKey == "" {
			errorJSON(w, 400, "api_key 必填")
			return
		}
		// 写库：email 不存在则插入
		if _, err := db.AddWindsurfAccount(req.Email, req.Password); err != nil {
			errorJSON(w, 500, "保存 email 失败: "+err.Error())
			return
		}
		if err := db.UpdateWindsurfAccountFromRegister(req.Email,
			req.APIKey, req.Name, req.APIServerURL); err != nil {
			errorJSON(w, 500, "写 apiKey 失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"success":        true,
			"email":          req.Email,
			"name":           req.Name,
			"api_server_url": req.APIServerURL,
			"note":           "已保存客户端本地注册得到的 apiKey",
		})
	}
}

// SaveWindsurfTokens 客户端直连代理拿到 token 后，POST 上来保存到服务端
//
//	POST /api/windsurf/accounts/save-tokens  { email, password, id_token, refresh_token, auth1_token, account_id, primary_org_id }
//	→ 如果 email 不在库里则先 insert，然后写 token；最后异步刷一次额度
func SaveWindsurfTokens(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Email        string `json:"email"`
			Password     string `json:"password"`
			IdToken      string `json:"id_token"`
			RefreshToken string `json:"refresh_token"`
			Auth1Token   string `json:"auth1_token"`
			AccountID    string `json:"account_id"`
			PrimaryOrgID string `json:"primary_org_id"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		req.Email = strings.TrimSpace(req.Email)
		if req.Email == "" {
			errorJSON(w, 400, "email 必填")
			return
		}
		if req.IdToken == "" && req.Auth1Token == "" {
			errorJSON(w, 400, "id_token 和 auth1_token 至少要有一个")
			return
		}
		// 不存在则插入（password 可空，因为客户端直连代理时不一定要存）
		if _, err := db.AddWindsurfAccount(req.Email, req.Password); err != nil {
			errorJSON(w, 500, "保存失败: "+err.Error())
			return
		}
		// 兜底：refresh / auth1 缺失时用 idToken
		if req.RefreshToken == "" {
			req.RefreshToken = req.IdToken
		}
		if req.Auth1Token == "" {
			req.Auth1Token = req.IdToken
		}
		if err := db.UpdateWindsurfAccountTokens(req.Email,
			req.IdToken, req.RefreshToken, req.Auth1Token,
			req.AccountID, req.PrimaryOrgID); err != nil {
			errorJSON(w, 500, "写 token 失败: "+err.Error())
			return
		}
		// 异步刷额度（不阻塞接口返回）
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			_ = refreshOneWindsurfAccount(ctx, db, req.Email)
		}()
		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"email":   req.Email,
			"note":    "token 已保存，正在后台刷新额度",
		})
	}
}

// GetWindsurfCredentials 让桌面端拉某账号的 password + 完整 token（用于 patch 时注入）
// 注意：返回明文密码，仅供已认证的客户端使用
//
//	GET /api/windsurf/accounts/credentials?email=xxx
func GetWindsurfCredentials(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		email := r.URL.Query().Get("email")
		if email == "" {
			errorJSON(w, 400, "email 必填")
			return
		}
		acc, err := db.GetWindsurfAccountByEmail(email)
		if err != nil || acc == nil {
			errorJSON(w, 404, "账号不存在")
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"email":          acc.Email,
			"password":       acc.Password,
			"id_token":       acc.IdToken,
			"refresh_token":  acc.RefreshToken,
			"auth1_token":    acc.Auth1Token,
			"account_id":     acc.AccountID,
			"primary_org_id": acc.PrimaryOrgID,
		})
	}
}

// ListWindsurfAccountsPool 客户端 UI 用：列出账号池含完整额度信息（脱敏 token）
//
//	GET /api/windsurf/accounts/pool
func ListWindsurfAccountsPool(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		accounts, err := db.ListWindsurfAccounts()
		if err != nil {
			errorJSON(w, 500, "查询失败: "+err.Error())
			return
		}
		out := make([]map[string]interface{}, 0, len(accounts))
		for i := range accounts {
			out = append(out, sanitizeAccount(&accounts[i]))
		}
		// 同时返回当前激活账号
		var activeEmail string
		for _, a := range accounts {
			if a.IsActive {
				activeEmail = a.Email
				break
			}
		}
		writeJSON(w, 200, map[string]interface{}{
			"accounts":       out,
			"count":          len(out),
			"active_email":   activeEmail,
			"login_proxies":  windsurfLoginProxies,
			"default_thresh": defaultAutoSwitchThreshold,
		})
	}
}

// truncate 截断字符串（错误响应防爆）
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// 防止 config import 未使用警告
var _ = config.Config{}
