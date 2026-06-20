package main

import (
	"embed"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"time"

	"push-server/config"
	"push-server/handler"
	"push-server/store"
	"push-server/ws"
)

// 嵌入 web/ 目录里的静态资源（项目介绍页 + changelog.json）
// 使用 embed 而不是磁盘文件，避免部署时漏 copy。
//
//go:embed web
var webAssets embed.FS

func main() {
	cfg := config.Load()

	// 初始化数据库
	db, err := store.InitDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("数据库初始化失败: %v", err)
	}
	defer db.Close()

	// 定时清理3天前的数据
	go func() {
		for {
			n, err := db.CleanupOldData(3)
			if err != nil {
				log.Printf("数据清理失败: %v", err)
			} else if n > 0 {
				log.Printf("已清理 %d 条过期数据(>3天)", n)
			}
			time.Sleep(6 * time.Hour)
		}
	}()

	// 初始化 WebSocket Hub
	hub := ws.NewHub()
	go hub.Run()

	// 注册路由
	mux := http.NewServeMux()

	// 健康检查
	mux.HandleFunc("GET /api/health", handler.Health(cfg))

	// 版本检查（手机端每天调用，匿名访问）
	mux.HandleFunc("GET /api/version", handler.GetVersion(cfg))

	// 认证
	mux.HandleFunc("POST /api/auth/token", handler.AuthToken(db, cfg))

	// 推送消息（PC→服务器）
	mux.HandleFunc("POST /api/push", handler.RequireAuth(cfg, handler.PushMessage(db, hub)))
	mux.HandleFunc("POST /api/push/image", handler.RequireAuth(cfg, handler.PushImage(db, hub)))

	// 会话列表 & 元数据更新
	mux.HandleFunc("GET /api/sessions", handler.RequireAuth(cfg, handler.ListSessions(db)))
	mux.HandleFunc("POST /api/sessions/meta", handler.RequireAuth(cfg, handler.UpdateSessionMeta(db)))
	mux.HandleFunc("POST /api/sessions/mark_read", handler.RequireAuth(cfg, handler.MarkSessionRead(db)))
	mux.HandleFunc("POST /api/sessions/rename", handler.RequireAuth(cfg, handler.RenameSession(db, hub)))
	mux.HandleFunc("POST /api/sessions/delete", handler.RequireAuth(cfg, handler.DeleteSession(db, hub)))

	// 工作区文件清单（dialog.py 推送 + 客户端 @ 引用）
	mux.HandleFunc("POST /api/sessions/files", handler.RequireAuth(cfg, handler.SyncWorkspaceFiles(db)))
	mux.HandleFunc("GET /api/sessions/files", handler.RequireAuth(cfg, handler.GetWorkspaceFiles(db)))

	// P2P直连端点注册/发现
	mux.HandleFunc("POST /api/sessions/register-endpoint", handler.RequireAuth(cfg, handler.RegisterEndpoint(cfg)))
	mux.HandleFunc("GET /api/sessions/endpoint", handler.RequireAuth(cfg, handler.GetEndpoint(cfg)))

	// 拉取消息（手机端）
	mux.HandleFunc("GET /api/messages", handler.RequireAuth(cfg, handler.GetMessages(db)))
	mux.HandleFunc("POST /api/messages/{id}/ack", handler.RequireAuth(cfg, handler.AckMessage(db)))

	// 反向指令（手机→PC）
	mux.HandleFunc("POST /api/commands", handler.RequireAuth(cfg, handler.CreateCommand(db, hub)))
	mux.HandleFunc("GET /api/commands/pending", handler.RequireAuth(cfg, handler.GetPendingCommands(db)))
	mux.HandleFunc("POST /api/commands/{id}/result", handler.RequireAuth(cfg, handler.CommandResult(db)))

	// 文件上传/下载
	mux.HandleFunc("POST /api/files/upload", handler.RequireAuth(cfg, handler.UploadFile(db, hub)))
	mux.HandleFunc("GET /api/files/{id}", handler.RequireAuth(cfg, handler.DownloadFile(cfg)))

	// 公开下载（APK等）
	mux.Handle("GET /dl/", http.StripPrefix("/dl/", http.FileServer(http.Dir("data/uploads"))))

	// WebRTC信令
	mux.HandleFunc("POST /api/webrtc/signal", handler.RequireAuth(cfg, handler.PostSignal(hub, cfg)))
	mux.HandleFunc("GET /api/webrtc/signals", handler.RequireAuth(cfg, handler.GetSignals(cfg)))
	mux.HandleFunc("GET /api/webrtc/turn-credentials", handler.RequireAuth(cfg, handler.GetTurnCredentials(cfg)))

	// Windsurf 账号管理
	mux.HandleFunc("POST /api/windsurf/login", handler.RequireAuth(cfg, handler.WindsurfLogin(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/firebase/login", handler.RequireAuth(cfg, handler.WindsurfFirebaseLogin(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/auth-token", handler.RequireAuth(cfg, handler.WindsurfAuthToken(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/plan-status", handler.RequireAuth(cfg, handler.WindsurfPlanStatus(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/accounts", handler.RequireAuth(cfg, handler.ImportWindsurfAccounts(db, cfg)))
	mux.HandleFunc("GET /api/windsurf/accounts", handler.RequireAuth(cfg, handler.ListWindsurfAccounts(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/claim", handler.RequireAuth(cfg, handler.ClaimWindsurfAccount(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/release", handler.RequireAuth(cfg, handler.ReleaseWindsurfAccount(db, cfg)))
	mux.HandleFunc("GET /api/windsurf/status", handler.RequireAuth(cfg, handler.WindsurfAccountStatus(db, cfg)))

	// 星火无痕换号集成：账号池 CRUD + 登录代理 + 额度刷新 + 切换调度
	mux.HandleFunc("GET /api/windsurf/accounts/pool", handler.RequireAuth(cfg, handler.ListWindsurfAccountsPool(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/add", handler.RequireAuth(cfg, handler.AddWindsurfAccountPool(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/delete", handler.RequireAuth(cfg, handler.DeleteWindsurfAccountPool(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/refresh-quota", handler.RequireAuth(cfg, handler.RefreshWindsurfQuota(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/refresh-all-quotas", handler.RequireAuth(cfg, handler.RefreshAllWindsurfQuotas(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/switch", handler.RequireAuth(cfg, handler.SwitchWindsurfAccount(db, hub)))
	mux.HandleFunc("GET /api/windsurf/accounts/active", handler.RequireAuth(cfg, handler.GetActiveWindsurfAccountHandler(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/quota-exhausted", handler.RequireAuth(cfg, handler.QuotaExhaustedReport(db, hub)))
	mux.HandleFunc("GET /api/windsurf/accounts/credentials", handler.RequireAuth(cfg, handler.GetWindsurfCredentials(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/save-tokens", handler.RequireAuth(cfg, handler.SaveWindsurfTokens(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/register-with-token", handler.RequireAuth(cfg, handler.RegisterWindsurfWithToken(db)))
	mux.HandleFunc("POST /api/windsurf/accounts/save-register-result", handler.RequireAuth(cfg, handler.SaveWindsurfRegisterResult(db)))

	// WebSocket
	mux.HandleFunc("GET /ws", handler.WSHandler(hub, db, cfg))

	// 等待指令回复（PC端长轮询）
	mux.HandleFunc("GET /api/commands/wait", handler.RequireAuth(cfg, handler.WaitCommand(db)))

	// 项目介绍 / 下载主页（embed 进 binary，无需部署额外文件）
	// 用 fs.Sub 把 embed.FS 的 "web" 子目录作为根，让 /index.html 和 /changelog.json 直接可访问
	webRoot, err := fs.Sub(webAssets, "web")
	if err != nil {
		log.Fatalf("embed web 子目录加载失败: %v", err)
	}
	mux.Handle("GET /", http.FileServer(http.FS(webRoot)))

	// CORS 中间件
	wrapped := corsMiddleware(mux)

	addr := fmt.Sprintf(":%d", cfg.Port)
	fmt.Printf("🚀 Push Server 启动: http://127.0.0.1%s\n", addr)
	fmt.Printf("   POST /api/push       — 推送消息\n")
	fmt.Printf("   GET  /ws             — WebSocket\n")
	fmt.Printf("   GET  /api/health     — 健康检查\n")

	if err := http.ListenAndServe(addr, wrapped); err != nil {
		log.Fatalf("服务启动失败: %v", err)
	}
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func init() {
	// 确保日志输出到 stdout
	log.SetOutput(os.Stdout)
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}
