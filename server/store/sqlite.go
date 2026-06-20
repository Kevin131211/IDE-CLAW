package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type DB struct {
	conn *sql.DB
}

type Message struct {
	ID             string `json:"id"`
	SessionID      string `json:"session_id"`
	ConversationID string `json:"conversation_id,omitempty"`
	Content        string `json:"content"`
	MsgType        string `json:"msg_type"`
	ImageData      []byte `json:"-"`
	HasImage       bool   `json:"has_image,omitempty"`
	Sender         string `json:"sender"`
	ChunkIndex     int    `json:"chunk_index"`
	IsFinal        bool   `json:"is_final"`
	Status         string `json:"status"`
	CreatedAt      string `json:"created_at"`
}

type Command struct {
	ID        string `json:"id"`
	SessionID string `json:"session_id"`
	Command   string `json:"command"`
	Params    string `json:"params,omitempty"`
	Status    string `json:"status"`
	Result    string `json:"result,omitempty"`
	CreatedAt string `json:"created_at"`
}

type Session struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	PCToken     string `json:"pc_token,omitempty"`
	MobileToken string `json:"mobile_token,omitempty"`
	MachineName string `json:"machine_name,omitempty"`
	ProjectName string `json:"project_name,omitempty"`
	IDEType     string `json:"ide_type,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
	Description string `json:"description,omitempty"`
	TypingState bool   `json:"typing_state"`
	CreatedAt   string `json:"created_at"`
	LastActive  string `json:"last_active"`
}

type SessionEnriched struct {
	Session
	UnreadCount int    `json:"unread_count"`
	LastMessage string `json:"last_message,omitempty"`
	LastMsgTime string `json:"last_msg_time,omitempty"`
}

// WindsurfAccountInput 用于批量导入
type WindsurfAccountInput struct {
	Email        string `json:"email"`
	Password     string `json:"password"`
	AuthToken    string `json:"auth_token"`
	CreditsDairy int    `json:"credits_daily"`
	CreditsWeek  int    `json:"credits_weekly"`
	IsExpired    bool   `json:"is_expired"`
}

// WindsurfAccount 数据库行
type WindsurfAccount struct {
	ID           int    `json:"id"`
	Email        string `json:"email"`
	Password     string `json:"password,omitempty"`
	AuthToken    string `json:"auth_token,omitempty"`
	CreditsDairy int    `json:"credits_daily"`
	CreditsWeek  int    `json:"credits_weekly"`
	IsExpired    bool   `json:"is_expired"`
	LockedBy     string `json:"locked_by"`
	LockedAt     string `json:"locked_at"`
	LoginCount   int    `json:"login_count"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`

	// 星火换号集成字段：额度百分比 + token 缓存
	DailyRemainingPercent  *float64 `json:"daily_remaining_percent,omitempty"`  // 0-100
	WeeklyRemainingPercent *float64 `json:"weekly_remaining_percent,omitempty"` // 0-100
	DailyResetAtUnix       int64    `json:"daily_reset_at_unix"`
	WeeklyResetAtUnix      int64    `json:"weekly_reset_at_unix"`
	PlanName               string   `json:"plan_name"`
	IdToken                string   `json:"id_token,omitempty"`
	RefreshToken           string   `json:"refresh_token,omitempty"`
	Auth1Token             string   `json:"auth1_token,omitempty"`
	AccountID              string   `json:"account_id,omitempty"`
	PrimaryOrgID           string   `json:"primary_org_id,omitempty"`
	QuotaUpdatedAt         string   `json:"quota_updated_at,omitempty"`
	AutoSwitchThreshold    float64  `json:"auto_switch_threshold"`
	IsActive               bool     `json:"is_active"` // 当前 PC 端激活的账号

	// Windsurf 官方 OAuth 注册返回（绕开第三方代理 Cloudflare 1027）
	WindsurfAPIKey string `json:"windsurf_api_key,omitempty"` // RegisterUser 返回的 apiKey (devin-session-token$<JWT>)
	WindsurfName   string `json:"windsurf_name,omitempty"`    // RegisterUser 返回的 name
	APIServerURL   string `json:"api_server_url,omitempty"`   // RegisterUser 返回的 apiServerUrl
}

func InitDB(dbPath string) (*DB, error) {
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}

	conn, err := sql.Open("sqlite", dbPath+"?_journal=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}

	if err := createTables(conn); err != nil {
		conn.Close()
		return nil, err
	}

	return &DB{conn: conn}, nil
}

func (d *DB) Close() error {
	return d.conn.Close()
}

func createTables(conn *sql.DB) error {
	schema := `
	CREATE TABLE IF NOT EXISTS sessions (
		id          TEXT PRIMARY KEY,
		name        TEXT NOT NULL DEFAULT '',
		pc_token    TEXT NOT NULL DEFAULT '',
		mobile_token TEXT NOT NULL DEFAULT '',
		machine_name TEXT NOT NULL DEFAULT '',
		project_name TEXT NOT NULL DEFAULT '',
		ide_type     TEXT NOT NULL DEFAULT '',
		display_name TEXT NOT NULL DEFAULT '',
		description  TEXT NOT NULL DEFAULT '',
		created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
		last_active DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS messages (
		id              TEXT PRIMARY KEY,
		session_id      TEXT NOT NULL,
		conversation_id TEXT DEFAULT '',
		content         TEXT NOT NULL DEFAULT '',
		msg_type        TEXT NOT NULL DEFAULT 'text',
		image_data      BLOB,
		sender          TEXT NOT NULL DEFAULT 'pc',
		chunk_index     INTEGER DEFAULT -1,
		is_final        BOOLEAN DEFAULT 1,
		status          TEXT DEFAULT 'pending',
		created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (session_id) REFERENCES sessions(id)
	);

	CREATE TABLE IF NOT EXISTS commands (
		id         TEXT PRIMARY KEY,
		session_id TEXT NOT NULL,
		command    TEXT NOT NULL,
		params     TEXT DEFAULT '{}',
		status     TEXT DEFAULT 'pending',
		result     TEXT DEFAULT '',
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (session_id) REFERENCES sessions(id)
	);

	CREATE INDEX IF NOT EXISTS idx_msg_session_status ON messages(session_id, status);
	CREATE INDEX IF NOT EXISTS idx_msg_session_time ON messages(session_id, created_at);
	CREATE INDEX IF NOT EXISTS idx_cmd_session_status ON commands(session_id, status);

	CREATE TABLE IF NOT EXISTS windsurf_accounts (
		id            INTEGER PRIMARY KEY AUTOINCREMENT,
		email         TEXT UNIQUE NOT NULL,
		password      TEXT NOT NULL DEFAULT '',
		auth_token    TEXT NOT NULL DEFAULT '',
		credits_daily  INTEGER DEFAULT 100,
		credits_weekly INTEGER DEFAULT 0,
		is_expired    INTEGER DEFAULT 0,
		locked_by     TEXT NOT NULL DEFAULT '',
		locked_at     DATETIME DEFAULT NULL,
		login_count   INTEGER DEFAULT 0,
		created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
		updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	CREATE INDEX IF NOT EXISTS idx_ws_acct_locked ON windsurf_accounts(locked_by);

	-- 工作区文件清单（dialog.py 推送，客户端 @ 时拉取）
	CREATE TABLE IF NOT EXISTS session_files (
		session_id TEXT NOT NULL,
		path       TEXT NOT NULL,
		size       INTEGER DEFAULT 0,
		updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (session_id, path)
	);
	CREATE INDEX IF NOT EXISTS idx_sf_session ON session_files(session_id);

	-- 工作区元数据（每 session 一行）
	CREATE TABLE IF NOT EXISTS session_workspace (
		session_id TEXT PRIMARY KEY,
		root       TEXT NOT NULL DEFAULT '',
		updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);
	`
	_, err := conn.Exec(schema)
	if err != nil {
		return err
	}
	// 迁移：为旧表添加新列（忽略已存在错误）
	migrations := []string{
		"ALTER TABLE sessions ADD COLUMN machine_name TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE sessions ADD COLUMN project_name TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE sessions ADD COLUMN ide_type TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE sessions ADD COLUMN display_name TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE sessions ADD COLUMN description TEXT NOT NULL DEFAULT ''",
		"ALTER TABLE sessions ADD COLUMN typing_state INTEGER NOT NULL DEFAULT 0",
		// 星火换号集成
		"ALTER TABLE windsurf_accounts ADD COLUMN daily_remaining_percent REAL DEFAULT NULL",
		"ALTER TABLE windsurf_accounts ADD COLUMN weekly_remaining_percent REAL DEFAULT NULL",
		"ALTER TABLE windsurf_accounts ADD COLUMN daily_reset_at_unix INTEGER DEFAULT 0",
		"ALTER TABLE windsurf_accounts ADD COLUMN weekly_reset_at_unix INTEGER DEFAULT 0",
		"ALTER TABLE windsurf_accounts ADD COLUMN plan_name TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN id_token TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN refresh_token TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN auth1_token TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN account_id TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN primary_org_id TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN quota_updated_at DATETIME DEFAULT NULL",
		"ALTER TABLE windsurf_accounts ADD COLUMN auto_switch_threshold REAL DEFAULT 5.0",
		"ALTER TABLE windsurf_accounts ADD COLUMN is_active INTEGER DEFAULT 0",
		// Windsurf 官方 OAuth 注册返回（绕开第三方代理）
		"ALTER TABLE windsurf_accounts ADD COLUMN windsurf_api_key TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN windsurf_name TEXT DEFAULT ''",
		"ALTER TABLE windsurf_accounts ADD COLUMN api_server_url TEXT DEFAULT ''",
	}
	for _, m := range migrations {
		conn.Exec(m) // 忽略 "duplicate column" 错误
	}
	return nil
}

func (d *DB) SetTypingState(sessionID string, typing bool) {
	val := 0
	if typing {
		val = 1
	}
	d.conn.Exec("UPDATE sessions SET typing_state = ? WHERE id = ?", val, sessionID)
}

// ==================== Session ====================

// GetSession 只读查询会话；不存在时返回 sql.ErrNoRows，不会自动创建。
// 供读接口（如拉历史消息）使用，避免已删除的会话被读操作复活。
func (d *DB) GetSession(id string) (*Session, error) {
	var s Session
	err := d.conn.QueryRow(`SELECT id, name, pc_token, mobile_token, machine_name, project_name, ide_type, display_name, description, typing_state, created_at, last_active FROM sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.Name, &s.PCToken, &s.MobileToken, &s.MachineName, &s.ProjectName, &s.IDEType, &s.DisplayName, &s.Description, &s.TypingState, &s.CreatedAt, &s.LastActive)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func (d *DB) GetOrCreateSession(id, name string) (*Session, error) {
	var s Session
	err := d.conn.QueryRow(`SELECT id, name, pc_token, mobile_token, machine_name, project_name, ide_type, display_name, description, typing_state, created_at, last_active FROM sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.Name, &s.PCToken, &s.MobileToken, &s.MachineName, &s.ProjectName, &s.IDEType, &s.DisplayName, &s.Description, &s.TypingState, &s.CreatedAt, &s.LastActive)
	if err == sql.ErrNoRows {
		now := time.Now().Format(time.RFC3339)
		_, err = d.conn.Exec("INSERT INTO sessions (id, name, created_at, last_active) VALUES (?, ?, ?, ?)", id, name, now, now)
		if err != nil {
			return nil, err
		}
		return &Session{ID: id, Name: name, CreatedAt: now, LastActive: now}, nil
	}
	return &s, err
}

func (d *DB) UpdateSessionMeta(id, machineName, projectName, ideType, displayName, description string) error {
	_, err := d.conn.Exec(`UPDATE sessions SET machine_name=?, project_name=?, ide_type=?, display_name=?, description=? WHERE id=?`,
		machineName, projectName, ideType, displayName, description, id)
	return err
}

// RenameSession 仅更新 display_name（用户重命名对话）
func (d *DB) RenameSession(id, displayName string) error {
	_, err := d.conn.Exec("UPDATE sessions SET display_name = ? WHERE id = ?", displayName, id)
	return err
}

// DeleteSession 删除 session 及其所有消息/命令（级联）
func (d *DB) DeleteSession(id string) error {
	tx, err := d.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM messages WHERE session_id = ?", id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM commands WHERE session_id = ?", id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM sessions WHERE id = ?", id); err != nil {
		return err
	}
	return tx.Commit()
}

func (d *DB) UpdateSessionTokens(id, pcToken, mobileToken string) error {
	_, err := d.conn.Exec("UPDATE sessions SET pc_token = ?, mobile_token = ? WHERE id = ?", pcToken, mobileToken, id)
	return err
}

func (d *DB) TouchSession(id string) {
	d.conn.Exec("UPDATE sessions SET last_active = ? WHERE id = ?", time.Now().Format(time.RFC3339), id)
}

func (d *DB) ListSessions() ([]Session, error) {
	rows, err := d.conn.Query(`SELECT id, name, pc_token, mobile_token, machine_name, project_name, ide_type, display_name, description, typing_state, created_at, last_active FROM sessions ORDER BY last_active DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []Session
	for rows.Next() {
		var s Session
		if err := rows.Scan(&s.ID, &s.Name, &s.PCToken, &s.MobileToken, &s.MachineName, &s.ProjectName, &s.IDEType, &s.DisplayName, &s.Description, &s.TypingState, &s.CreatedAt, &s.LastActive); err != nil {
			return nil, err
		}
		sessions = append(sessions, s)
	}
	return sessions, nil
}

func (d *DB) ListSessionsEnriched() ([]SessionEnriched, error) {
	sessions, err := d.ListSessions()
	if err != nil {
		return nil, err
	}
	var result []SessionEnriched
	for _, s := range sessions {
		e := SessionEnriched{Session: s}
		// 未读消息数
		d.conn.QueryRow(`SELECT COUNT(*) FROM messages WHERE session_id=? AND status='pending'`, s.ID).Scan(&e.UnreadCount)
		// 最新消息
		d.conn.QueryRow(`SELECT content, created_at FROM messages WHERE session_id=? AND is_final=1 ORDER BY created_at DESC LIMIT 1`, s.ID).Scan(&e.LastMessage, &e.LastMsgTime)
		if len(e.LastMessage) > 50 {
			e.LastMessage = e.LastMessage[:50] + "..."
		}
		result = append(result, e)
	}
	return result, nil
}

// ==================== Message ====================

func (d *DB) InsertMessage(m *Message) error {
	_, err := d.conn.Exec(`INSERT INTO messages (id, session_id, conversation_id, content, msg_type, image_data, sender, chunk_index, is_final, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.SessionID, m.ConversationID, m.Content, m.MsgType, m.ImageData, m.Sender, m.ChunkIndex, m.IsFinal, m.Status, m.CreatedAt)
	return err
}

func (d *DB) GetMessages(sessionID string, since string, limit int) ([]Message, error) {
	if limit <= 0 {
		limit = 100
	}
	// 取最新的N条（DESC），外层再按时间正序排列（ASC）
	rows, err := d.conn.Query(`SELECT id, session_id, conversation_id, content, msg_type, sender, chunk_index, is_final, status, created_at, has_image FROM (
		SELECT id, session_id, conversation_id, content, msg_type, sender, chunk_index, is_final, status, created_at,
		CASE WHEN image_data IS NOT NULL AND length(image_data) > 0 THEN 1 ELSE 0 END as has_image
		FROM messages WHERE session_id = ? AND created_at > ? ORDER BY created_at DESC LIMIT ?
	) sub ORDER BY created_at ASC`,
		sessionID, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.SessionID, &m.ConversationID, &m.Content, &m.MsgType, &m.Sender, &m.ChunkIndex, &m.IsFinal, &m.Status, &m.CreatedAt, &m.HasImage); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, nil
}

func (d *DB) GetMessageImage(id string) ([]byte, error) {
	var data []byte
	err := d.conn.QueryRow("SELECT image_data FROM messages WHERE id = ?", id).Scan(&data)
	return data, err
}

func (d *DB) AckMessage(id string) error {
	_, err := d.conn.Exec("UPDATE messages SET status = 'delivered' WHERE id = ?", id)
	return err
}

func (d *DB) MarkSessionRead(sessionID string) error {
	_, err := d.conn.Exec("UPDATE messages SET status = 'delivered' WHERE session_id = ? AND status = 'pending'", sessionID)
	return err
}

func (d *DB) GetPendingMessages(sessionID string) ([]Message, error) {
	return d.GetMessages(sessionID, "1970-01-01T00:00:00Z", 500)
}

// ==================== Command ====================

func (d *DB) InsertCommand(c *Command) error {
	_, err := d.conn.Exec(`INSERT INTO commands (id, session_id, command, params, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		c.ID, c.SessionID, c.Command, c.Params, c.Status, c.CreatedAt)
	return err
}

func (d *DB) GetPendingCommands(sessionID string) ([]Command, error) {
	rows, err := d.conn.Query("SELECT id, session_id, command, params, status, result, created_at FROM commands WHERE session_id = ? AND status = 'pending' ORDER BY created_at ASC", sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var cmds []Command
	for rows.Next() {
		var c Command
		if err := rows.Scan(&c.ID, &c.SessionID, &c.Command, &c.Params, &c.Status, &c.Result, &c.CreatedAt); err != nil {
			return nil, err
		}
		cmds = append(cmds, c)
	}
	return cmds, nil
}

func (d *DB) UpdateCommandStatus(id, status, result string) error {
	_, err := d.conn.Exec("UPDATE commands SET status = ?, result = ? WHERE id = ?", status, result, id)
	return err
}

// ==================== Session Files (工作区文件清单) ====================

type SessionFile struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
}

// ReplaceSessionFiles 覆盖式更新 session 的文件清单
func (d *DB) ReplaceSessionFiles(sessionID, root string, files []SessionFile) error {
	tx, err := d.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec("DELETE FROM session_files WHERE session_id = ?", sessionID); err != nil {
		return err
	}

	stmt, err := tx.Prepare("INSERT INTO session_files (session_id, path, size) VALUES (?, ?, ?)")
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, f := range files {
		if _, err := stmt.Exec(sessionID, f.Path, f.Size); err != nil {
			return err
		}
	}

	// upsert workspace root
	if _, err := tx.Exec(`INSERT INTO session_workspace (session_id, root, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(session_id) DO UPDATE SET root = excluded.root, updated_at = CURRENT_TIMESTAMP`,
		sessionID, root); err != nil {
		return err
	}

	return tx.Commit()
}

// SearchSessionFiles 按关键字模糊匹配 path（不区分大小写），返回最多 limit 条
func (d *DB) SearchSessionFiles(sessionID, query string, limit int) ([]SessionFile, string, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}

	var root string
	d.conn.QueryRow("SELECT root FROM session_workspace WHERE session_id = ?", sessionID).Scan(&root)

	var rows *sql.Rows
	var err error
	if query == "" {
		rows, err = d.conn.Query(
			"SELECT path, size FROM session_files WHERE session_id = ? ORDER BY path LIMIT ?",
			sessionID, limit)
	} else {
		rows, err = d.conn.Query(
			"SELECT path, size FROM session_files WHERE session_id = ? AND LOWER(path) LIKE ? ORDER BY path LIMIT ?",
			sessionID, "%"+query+"%", limit)
	}
	if err != nil {
		return nil, root, err
	}
	defer rows.Close()

	var result []SessionFile
	for rows.Next() {
		var f SessionFile
		if err := rows.Scan(&f.Path, &f.Size); err != nil {
			return nil, root, err
		}
		result = append(result, f)
	}
	return result, root, nil
}

// CleanupOldData 清理超过指定天数的消息和命令
func (d *DB) CleanupOldData(retentionDays int) (int64, error) {
	cutoff := time.Now().AddDate(0, 0, -retentionDays).Format(time.RFC3339)
	var total int64

	res, err := d.conn.Exec("DELETE FROM messages WHERE created_at < ?", cutoff)
	if err != nil {
		return 0, fmt.Errorf("清理消息失败: %w", err)
	}
	n, _ := res.RowsAffected()
	total += n

	res, err = d.conn.Exec("DELETE FROM commands WHERE created_at < ?", cutoff)
	if err != nil {
		return total, fmt.Errorf("清理命令失败: %w", err)
	}
	n, _ = res.RowsAffected()
	total += n

	return total, nil
}

// ==================== Windsurf Accounts ====================

func (d *DB) UpsertWindsurfAccounts(accounts []WindsurfAccountInput) (int, error) {
	tx, err := d.conn.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	count := 0
	for _, a := range accounts {
		if a.Email == "" {
			continue
		}
		expired := 0
		if a.IsExpired {
			expired = 1
		}
		_, err := tx.Exec(`
			INSERT INTO windsurf_accounts (email, password, auth_token, credits_daily, credits_weekly, is_expired)
			VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(email) DO UPDATE SET
				password = CASE WHEN excluded.password != '' THEN excluded.password ELSE windsurf_accounts.password END,
				auth_token = CASE WHEN excluded.auth_token != '' THEN excluded.auth_token ELSE windsurf_accounts.auth_token END,
				credits_daily = excluded.credits_daily,
				credits_weekly = excluded.credits_weekly,
				is_expired = excluded.is_expired,
				updated_at = CURRENT_TIMESTAMP
		`, a.Email, a.Password, a.AuthToken, a.CreditsDairy, a.CreditsWeek, expired)
		if err != nil {
			return count, err
		}
		count++
	}
	return count, tx.Commit()
}

func (d *DB) ClaimWindsurfAccount(machineID string) (*WindsurfAccount, error) {
	// 先释放该机器之前锁定的账号（30分钟超时自动释放）
	d.conn.Exec(`UPDATE windsurf_accounts SET locked_by = '', locked_at = NULL
		WHERE locked_by = ? OR (locked_by != '' AND locked_at < datetime('now', '-30 minutes'))`, machineID)

	// 选择 credits 最多的可用账号
	row := d.conn.QueryRow(`
		SELECT id, email, password, auth_token, credits_daily, credits_weekly, is_expired,
		       locked_by, COALESCE(locked_at,'') as locked_at, login_count,
		       created_at, updated_at
		FROM windsurf_accounts
		WHERE locked_by = '' AND is_expired = 0 AND (credits_daily + credits_weekly) > 0
		ORDER BY (credits_daily + credits_weekly) DESC
		LIMIT 1
	`)
	var a WindsurfAccount
	err := row.Scan(&a.ID, &a.Email, &a.Password, &a.AuthToken, &a.CreditsDairy, &a.CreditsWeek,
		&a.IsExpired, &a.LockedBy, &a.LockedAt, &a.LoginCount, &a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return nil, nil // 没有可用账号
	}

	// 锁定
	_, err = d.conn.Exec(`UPDATE windsurf_accounts SET locked_by = ?, locked_at = CURRENT_TIMESTAMP,
		login_count = login_count + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?`, machineID, a.ID)
	if err != nil {
		return nil, err
	}
	a.LockedBy = machineID
	return &a, nil
}

func (d *DB) ReleaseWindsurfAccount(email, machineID string, creditsDaily, creditsWeekly int) error {
	_, err := d.conn.Exec(`UPDATE windsurf_accounts SET locked_by = '', locked_at = NULL,
		credits_daily = ?, credits_weekly = ?, updated_at = CURRENT_TIMESTAMP
		WHERE email = ?`, creditsDaily, creditsWeekly, email)
	return err
}

func (d *DB) ListWindsurfAccounts() ([]WindsurfAccount, error) {
	// 拉全字段（含星火集成的额度/token），按"剩余额度高 + 未锁定"优先
	rows, err := d.conn.Query(`
		SELECT id, email, '' as password, '' as auth_token, credits_daily, credits_weekly, is_expired,
		       locked_by, COALESCE(locked_at,'') as locked_at, login_count, created_at, updated_at,
		       daily_remaining_percent, weekly_remaining_percent,
		       COALESCE(daily_reset_at_unix, 0), COALESCE(weekly_reset_at_unix, 0),
		       COALESCE(plan_name, ''), '' as id_token, '' as refresh_token, '' as auth1_token,
		       COALESCE(account_id, ''), COALESCE(primary_org_id, ''),
		       COALESCE(quota_updated_at, ''), COALESCE(auto_switch_threshold, 5.0),
		       COALESCE(is_active, 0),
		       '' as windsurf_api_key, COALESCE(windsurf_name, ''), COALESCE(api_server_url, '')
		FROM windsurf_accounts
		ORDER BY is_active DESC, COALESCE(daily_remaining_percent, -1) DESC, credits_daily + credits_weekly DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []WindsurfAccount
	for rows.Next() {
		var a WindsurfAccount
		var dailyP, weeklyP sql.NullFloat64
		if err := rows.Scan(&a.ID, &a.Email, &a.Password, &a.AuthToken, &a.CreditsDairy, &a.CreditsWeek,
			&a.IsExpired, &a.LockedBy, &a.LockedAt, &a.LoginCount, &a.CreatedAt, &a.UpdatedAt,
			&dailyP, &weeklyP,
			&a.DailyResetAtUnix, &a.WeeklyResetAtUnix,
			&a.PlanName, &a.IdToken, &a.RefreshToken, &a.Auth1Token,
			&a.AccountID, &a.PrimaryOrgID,
			&a.QuotaUpdatedAt, &a.AutoSwitchThreshold, &a.IsActive,
			&a.WindsurfAPIKey, &a.WindsurfName, &a.APIServerURL); err != nil {
			return nil, err
		}
		if dailyP.Valid {
			v := dailyP.Float64
			a.DailyRemainingPercent = &v
		}
		if weeklyP.Valid {
			v := weeklyP.Float64
			a.WeeklyRemainingPercent = &v
		}
		result = append(result, a)
	}
	return result, nil
}

// AddWindsurfAccount 添加单个账号（email + password 必填，返回 id）
// 如果 email 已存在则更新 password
func (d *DB) AddWindsurfAccount(email, password string) (int64, error) {
	if email == "" {
		return 0, fmt.Errorf("email 不能为空")
	}
	res, err := d.conn.Exec(`
		INSERT INTO windsurf_accounts (email, password) VALUES (?, ?)
		ON CONFLICT(email) DO UPDATE SET
			password = CASE WHEN excluded.password != '' THEN excluded.password ELSE windsurf_accounts.password END,
			updated_at = CURRENT_TIMESTAMP
	`, email, password)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// DeleteWindsurfAccount 通过 email 删除账号
func (d *DB) DeleteWindsurfAccount(email string) error {
	if email == "" {
		return fmt.Errorf("email 不能为空")
	}
	_, err := d.conn.Exec("DELETE FROM windsurf_accounts WHERE email = ?", email)
	return err
}

// GetWindsurfAccountByEmail 拉单个账号（含密码 + token，调用方需注意脱敏）
func (d *DB) GetWindsurfAccountByEmail(email string) (*WindsurfAccount, error) {
	row := d.conn.QueryRow(`
		SELECT id, email, password, COALESCE(auth_token,''), credits_daily, credits_weekly, is_expired,
		       locked_by, COALESCE(locked_at,''), login_count, created_at, updated_at,
		       daily_remaining_percent, weekly_remaining_percent,
		       COALESCE(daily_reset_at_unix, 0), COALESCE(weekly_reset_at_unix, 0),
		       COALESCE(plan_name, ''), COALESCE(id_token, ''), COALESCE(refresh_token, ''),
		       COALESCE(auth1_token, ''), COALESCE(account_id, ''), COALESCE(primary_org_id, ''),
		       COALESCE(quota_updated_at, ''), COALESCE(auto_switch_threshold, 5.0),
		       COALESCE(is_active, 0),
		       COALESCE(windsurf_api_key, ''), COALESCE(windsurf_name, ''), COALESCE(api_server_url, '')
		FROM windsurf_accounts WHERE email = ?
	`, email)
	var a WindsurfAccount
	var dailyP, weeklyP sql.NullFloat64
	if err := row.Scan(&a.ID, &a.Email, &a.Password, &a.AuthToken, &a.CreditsDairy, &a.CreditsWeek,
		&a.IsExpired, &a.LockedBy, &a.LockedAt, &a.LoginCount, &a.CreatedAt, &a.UpdatedAt,
		&dailyP, &weeklyP,
		&a.DailyResetAtUnix, &a.WeeklyResetAtUnix,
		&a.PlanName, &a.IdToken, &a.RefreshToken, &a.Auth1Token,
		&a.AccountID, &a.PrimaryOrgID,
		&a.QuotaUpdatedAt, &a.AutoSwitchThreshold, &a.IsActive,
		&a.WindsurfAPIKey, &a.WindsurfName, &a.APIServerURL); err != nil {
		return nil, err
	}
	if dailyP.Valid {
		v := dailyP.Float64
		a.DailyRemainingPercent = &v
	}
	if weeklyP.Valid {
		v := weeklyP.Float64
		a.WeeklyRemainingPercent = &v
	}
	return &a, nil
}

// UpdateWindsurfAccountFromRegister 写入 windsurf 官方 RegisterUser 返回的 apiKey/name/apiServerUrl
// 这是「真正可用」的凭据：apiKey 形如 devin-session-token$<JWT>，可直接调 server.codeium.com 各 API
func (d *DB) UpdateWindsurfAccountFromRegister(email, apiKey, name, apiServerURL string) error {
	if email == "" {
		return fmt.Errorf("email 不能为空")
	}
	_, err := d.conn.Exec(`
		UPDATE windsurf_accounts SET
			windsurf_api_key = ?,
			windsurf_name    = CASE WHEN ? != '' THEN ? ELSE windsurf_name END,
			api_server_url   = CASE WHEN ? != '' THEN ? ELSE api_server_url END,
			updated_at       = CURRENT_TIMESTAMP
		WHERE email = ?
	`, apiKey, name, name, apiServerURL, apiServerURL, email)
	return err
}

// UpdateWindsurfAccountTokens 写入登录代理拿到的 token 信息
func (d *DB) UpdateWindsurfAccountTokens(email, idToken, refreshToken, auth1Token, accountID, primaryOrgID string) error {
	_, err := d.conn.Exec(`
		UPDATE windsurf_accounts SET
			id_token = ?, refresh_token = ?, auth1_token = ?,
			account_id = ?, primary_org_id = ?,
			updated_at = CURRENT_TIMESTAMP
		WHERE email = ?
	`, idToken, refreshToken, auth1Token, accountID, primaryOrgID, email)
	return err
}

// UpdateWindsurfAccountQuota 写入 QuotaMonitor 拉到的额度信息
//
//	dailyPercent / weeklyPercent: 0-100，传 -1 表示不更新（此次未拉到）
func (d *DB) UpdateWindsurfAccountQuota(email string, dailyPercent, weeklyPercent float64,
	dailyResetUnix, weeklyResetUnix int64, planName string) error {
	var dPtr, wPtr interface{}
	if dailyPercent >= 0 {
		dPtr = dailyPercent
	}
	if weeklyPercent >= 0 {
		wPtr = weeklyPercent
	}
	_, err := d.conn.Exec(`
		UPDATE windsurf_accounts SET
			daily_remaining_percent  = COALESCE(?, daily_remaining_percent),
			weekly_remaining_percent = COALESCE(?, weekly_remaining_percent),
			daily_reset_at_unix      = ?,
			weekly_reset_at_unix     = ?,
			plan_name                = CASE WHEN ? != '' THEN ? ELSE plan_name END,
			quota_updated_at         = CURRENT_TIMESTAMP,
			updated_at               = CURRENT_TIMESTAMP
		WHERE email = ?
	`, dPtr, wPtr, dailyResetUnix, weeklyResetUnix, planName, planName, email)
	return err
}

// SetActiveWindsurfAccount 标记 email 为当前激活账号（其他账号 is_active=0）
func (d *DB) SetActiveWindsurfAccount(email string) error {
	tx, err := d.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("UPDATE windsurf_accounts SET is_active = 0"); err != nil {
		return err
	}
	if _, err := tx.Exec("UPDATE windsurf_accounts SET is_active = 1 WHERE email = ?", email); err != nil {
		return err
	}
	return tx.Commit()
}

// GetActiveWindsurfAccount 拉当前激活账号（PC 端正在用的）
func (d *DB) GetActiveWindsurfAccount() (*WindsurfAccount, error) {
	row := d.conn.QueryRow(`SELECT email FROM windsurf_accounts WHERE is_active = 1 LIMIT 1`)
	var email string
	if err := row.Scan(&email); err != nil {
		return nil, nil // 没激活也不报错
	}
	return d.GetWindsurfAccountByEmail(email)
}

// FindNextAvailableWindsurfAccount 找下一个可用账号（daily% > 阈值，跳过 currentEmail）
func (d *DB) FindNextAvailableWindsurfAccount(currentEmail string, threshold float64) (*WindsurfAccount, error) {
	rows, err := d.conn.Query(`
		SELECT email FROM windsurf_accounts
		WHERE email != ? AND is_expired = 0
		  AND (daily_remaining_percent IS NULL OR daily_remaining_percent >= ?)
		  AND (weekly_remaining_percent IS NULL OR weekly_remaining_percent >= ?)
		ORDER BY COALESCE(daily_remaining_percent, 100) DESC, login_count ASC
		LIMIT 1
	`, currentEmail, threshold, threshold)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, nil
	}
	var email string
	if err := rows.Scan(&email); err != nil {
		return nil, err
	}
	return d.GetWindsurfAccountByEmail(email)
}

func (d *DB) GetWindsurfAccountStatus() (map[string]interface{}, error) {
	var total, available, locked, expired, totalCredits int
	d.conn.QueryRow(`SELECT COUNT(*) FROM windsurf_accounts`).Scan(&total)
	d.conn.QueryRow(`SELECT COUNT(*) FROM windsurf_accounts WHERE locked_by = '' AND is_expired = 0 AND (credits_daily+credits_weekly) > 0`).Scan(&available)
	d.conn.QueryRow(`SELECT COUNT(*) FROM windsurf_accounts WHERE locked_by != ''`).Scan(&locked)
	d.conn.QueryRow(`SELECT COUNT(*) FROM windsurf_accounts WHERE is_expired = 1`).Scan(&expired)
	d.conn.QueryRow(`SELECT COALESCE(SUM(credits_daily + credits_weekly), 0) FROM windsurf_accounts WHERE is_expired = 0`).Scan(&totalCredits)
	return map[string]interface{}{
		"total":         total,
		"available":     available,
		"locked":        locked,
		"expired":       expired,
		"total_credits": totalCredits,
	}, nil
}

func (d *DB) WaitForCommand(sessionID string, timeout time.Duration) (*Command, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cmds, err := d.GetPendingCommands(sessionID)
		if err != nil {
			return nil, err
		}
		if len(cmds) > 0 {
			// 标记为已发送
			d.UpdateCommandStatus(cmds[0].ID, "sent", "")
			return &cmds[0], nil
		}
		time.Sleep(1 * time.Second)
	}
	return nil, nil // 超时，无指令
}
