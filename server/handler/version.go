package handler

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"push-server/config"
)

// VersionInfo 版本元数据，对外通过 GET /api/version 暴露
type VersionInfo struct {
	LatestVersion     string `json:"latest_version"`
	LatestBuild       int    `json:"latest_build"`
	ApkURL            string `json:"apk_url"`
	ApkSize           int64  `json:"apk_size,omitempty"`
	ApkSHA256         string `json:"apk_sha256,omitempty"`
	ReleaseDate       string `json:"release_date,omitempty"`
	Changelog         string `json:"changelog,omitempty"`
	MinSupportedBuild int    `json:"min_supported_build,omitempty"`
	// 桌面端 (Windows zip) 自更新元数据
	DesktopURL    string `json:"desktop_url,omitempty"`
	DesktopSize   int64  `json:"desktop_size,omitempty"`
	DesktopSHA256 string `json:"desktop_sha256,omitempty"`
}

var (
	versionCache       *VersionInfo
	versionCacheMu     sync.RWMutex
	versionCacheLoaded time.Time
	versionCacheTTL    = 30 * time.Second
)

// resolveVersionFile 默认从 data/version.json 读，可被环境变量 VERSION_FILE 覆盖
func resolveVersionFile() string {
	if p := os.Getenv("VERSION_FILE"); p != "" {
		return p
	}
	return filepath.Join("data", "version.json")
}

// GetVersion 返回当前发布的最新版本信息（供手机/桌面端检查更新）
func GetVersion(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		info, err := loadVersionInfo()
		if err != nil {
			errorJSON(w, 503, "暂无版本信息: "+err.Error())
			return
		}
		writeJSON(w, 200, info)
	}
}

func loadVersionInfo() (*VersionInfo, error) {
	versionCacheMu.RLock()
	if versionCache != nil && time.Since(versionCacheLoaded) < versionCacheTTL {
		v := *versionCache
		versionCacheMu.RUnlock()
		return &v, nil
	}
	versionCacheMu.RUnlock()

	versionCacheMu.Lock()
	defer versionCacheMu.Unlock()
	// 双重检查
	if versionCache != nil && time.Since(versionCacheLoaded) < versionCacheTTL {
		v := *versionCache
		return &v, nil
	}

	path := resolveVersionFile()
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var info VersionInfo
	if err := json.NewDecoder(f).Decode(&info); err != nil {
		return nil, err
	}

	versionCache = &info
	versionCacheLoaded = time.Now()
	v := info
	return &v, nil
}
