package handler

import (
	"net/http"
	"strconv"
	"strings"

	"push-server/store"
)

// SyncWorkspaceFiles dialog.py / 桌面端推送当前工作区文件清单
//   POST /api/sessions/files
//   { session_id, workspace_root, files: [{path, size}, ...] }
func SyncWorkspaceFiles(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID     string              `json:"session_id"`
			WorkspaceRoot string              `json:"workspace_root"`
			Files         []store.SessionFile `json:"files"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.SessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}
		// 上限保护：最多存 5000 个文件，超出截断
		if len(req.Files) > 5000 {
			req.Files = req.Files[:5000]
		}
		// 确保 session 存在
		db.GetOrCreateSession(req.SessionID, "")

		if err := db.ReplaceSessionFiles(req.SessionID, req.WorkspaceRoot, req.Files); err != nil {
			errorJSON(w, 500, "保存文件清单失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"count":   len(req.Files),
		})
	}
}

// GetWorkspaceFiles 客户端 @ 时拉取工作区文件列表
//   GET /api/sessions/files?session_id=xxx&q=keyword&limit=100
func GetWorkspaceFiles(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		query := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
		limitStr := r.URL.Query().Get("limit")
		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}
		limit := 100
		if v, err := strconv.Atoi(limitStr); err == nil && v > 0 {
			limit = v
		}

		files, root, err := db.SearchSessionFiles(sessionID, query, limit)
		if err != nil {
			errorJSON(w, 500, "查询文件失败: "+err.Error())
			return
		}
		if files == nil {
			files = []store.SessionFile{}
		}
		writeJSON(w, 200, map[string]interface{}{
			"files":          files,
			"count":          len(files),
			"workspace_root": root,
		})
	}
}
