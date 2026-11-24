//go:build windows

// 一键多开无痕浏览器（Windows 版）—— 与 Mac 版功能一致：
// 每个窗口独立临时配置目录 + 无痕模式，九宫格排版，默认网址，默认缩放，关闭即清除。
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/lxn/walk"
	. "github.com/lxn/walk/declarative"
)

// ---------- Win32 ----------

var (
	user32                   = syscall.NewLazyDLL("user32.dll")
	procEnumWindows          = user32.NewProc("EnumWindows")
	procGetWindowThreadPID   = user32.NewProc("GetWindowThreadProcessId")
	procIsWindowVisible      = user32.NewProc("IsWindowVisible")
	procGetWindowTextLengthW = user32.NewProc("GetWindowTextLengthW")
	procGetWindow            = user32.NewProc("GetWindow")
	procShowWindow           = user32.NewProc("ShowWindow")
	procMoveWindow           = user32.NewProc("MoveWindow")
	procSetForegroundWindow  = user32.NewProc("SetForegroundWindow")
	procPostMessageW         = user32.NewProc("PostMessageW")
	procSystemParametersInfo = user32.NewProc("SystemParametersInfoW")
	procGetDpiForSystem      = user32.NewProc("GetDpiForSystem")
)

type rect struct{ Left, Top, Right, Bottom int32 }

var (
	enumMu     sync.Mutex
	enumPID    uint32
	enumResult []uintptr
	enumCB     = syscall.NewCallback(func(h uintptr, _ uintptr) uintptr {
		var pid uint32
		procGetWindowThreadPID.Call(h, uintptr(unsafe.Pointer(&pid)))
		if pid == enumPID {
			vis, _, _ := procIsWindowVisible.Call(h)
			owner, _, _ := procGetWindow.Call(h, 4) // GW_OWNER
			tl, _, _ := procGetWindowTextLengthW.Call(h)
			if vis != 0 && owner == 0 && tl > 0 {
				enumResult = append(enumResult, h)
			}
		}
		return 1
	})
)

// 某进程的可见顶层窗口
func windowsOf(pid uint32) []uintptr {
	enumMu.Lock()
	defer enumMu.Unlock()
	enumPID, enumResult = pid, nil
	procEnumWindows.Call(enumCB, 0)
	return enumResult
}

func workArea() rect {
	var r rect
	procSystemParametersInfo.Call(0x0030, 0, uintptr(unsafe.Pointer(&r)), 0) // SPI_GETWORKAREA
	return r
}

func systemScale() float64 {
	if procGetDpiForSystem.Find() == nil {
		if dpi, _, _ := procGetDpiForSystem.Call(); dpi > 0 {
			return float64(dpi) / 96
		}
	}
	return 1
}

// ---------- 九宫格 ----------

const cols, rows, gap = 3, 3, 4

func gridFrame(index int) (x, y, w, h int) {
	wa := workArea()
	W, H := int(wa.Right-wa.Left), int(wa.Bottom-wa.Top)
	w = (W - gap*(cols+1)) / cols
	h = (H - gap*(rows+1)) / rows
	slot, page := index%9, index/9
	off := page * 28
	x = int(wa.Left) + gap + (slot%cols)*(w+gap) + off
	y = int(wa.Top) + gap + (slot/cols)*(h+gap) + off
	return
}

func place(hwnd uintptr, index int) {
	x, y, w, h := gridFrame(index)
	procShowWindow.Call(hwnd, 9) // SW_RESTORE
	procMoveWindow.Call(hwnd, uintptr(x), uintptr(y), uintptr(w), uintptr(h), 1)
}

// ---------- 浏览器 ----------

type Browser struct {
	Name     string
	Chromium bool
	Exe      string
}

func findBrowsers() []*Browser {
	pf, pf86, local := os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), os.Getenv("LOCALAPPDATA")
	cands := []struct {
		name     string
		chromium bool
		paths    []string
	}{
		{"Google Chrome", true, []string{pf + `\Google\Chrome\Application\chrome.exe`, pf86 + `\Google\Chrome\Application\chrome.exe`, local + `\Google\Chrome\Application\chrome.exe`}},
		{"Microsoft Edge", true, []string{pf86 + `\Microsoft\Edge\Application\msedge.exe`, pf + `\Microsoft\Edge\Application\msedge.exe`}},
		{"Brave", true, []string{pf + `\BraveSoftware\Brave-Browser\Application\brave.exe`, local + `\BraveSoftware\Brave-Browser\Application\brave.exe`}},
		{"Firefox", false, []string{pf + `\Mozilla Firefox\firefox.exe`, pf86 + `\Mozilla Firefox\firefox.exe`}},
	}
	var out []*Browser
	for _, c := range cands {
		for _, p := range c.paths {
			if st, err := os.Stat(p); err == nil && !st.IsDir() {
				out = append(out, &Browser{c.name, c.chromium, p})
				break
			}
		}
	}
	return out
}

// ---------- 实例 ----------

type Instance struct {
	Num     int
	Browser *Browser
	Dir     string
	Cmd     *exec.Cmd
	Exited  chan struct{}
}

func (i *Instance) Label() string { return fmt.Sprintf("#%d  %s", i.Num, i.Browser.Name) }

type Manager struct {
	mu        sync.Mutex
	instances []*Instance
	counter   int
	base      string
	onChange  func()
}

func newManager() *Manager {
	base := filepath.Join(os.TempDir(), "WuhenDuokai")
	os.RemoveAll(base) // 清理上次异常退出的残留
	os.MkdirAll(base, 0o700)
	return &Manager{base: base}
}

func (m *Manager) list() []*Instance {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]*Instance(nil), m.instances...)
}

const firefoxPrefs = `user_pref("browser.privatebrowsing.autostart", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("browser.sessionstore.resume_from_crash", false);
`

func (m *Manager) Launch(b *Browser, count int, urls []string, zoom int) error {
	alive := len(m.list())
	for i := 0; i < count; i++ {
		m.mu.Lock()
		m.counter++
		num := m.counter
		m.mu.Unlock()
		slot := alive + i
		x, y, w, h := gridFrame(slot)
		dir := filepath.Join(m.base, fmt.Sprintf("%d-%d", num, time.Now().UnixNano()%1000000))
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		var args []string
		if b.Chromium {
			// 默认页面缩放：Chromium 缩放级别 = log(比例)/log(1.2)
			level := math.Log(float64(zoom)/100) / math.Log(1.2)
			os.MkdirAll(filepath.Join(dir, "Default"), 0o700)
			pref := fmt.Sprintf(`{"partition":{"default_zoom_level":{"x":%v}},"browser":{"has_seen_welcome_page":true}}`, level)
			os.WriteFile(filepath.Join(dir, "Default", "Preferences"), []byte(pref), 0o600)
			args = []string{"--user-data-dir=" + dir, "--incognito", "--no-first-run",
				"--no-default-browser-check", "--disable-sync", "--new-window",
				fmt.Sprintf("--window-position=%d,%d", x, y), fmt.Sprintf("--window-size=%d,%d", w, h)}
		} else {
			px := fmt.Sprintf("user_pref(\"layout.css.devPixelsPerPx\", \"%.3f\");\n", float64(zoom)/100*systemScale())
			os.WriteFile(filepath.Join(dir, "user.js"), []byte(firefoxPrefs+px), 0o600)
			args = []string{"-profile", dir, "-no-remote", "-new-instance", "-wait-for-browser"}
		}
		args = append(args, urls...)
		cmd := exec.Command(b.Exe, args...)
		if err := cmd.Start(); err != nil {
			os.RemoveAll(dir)
			return err
		}
		inst := &Instance{Num: num, Browser: b, Dir: dir, Cmd: cmd, Exited: make(chan struct{})}
		m.mu.Lock()
		m.instances = append(m.instances, inst)
		m.mu.Unlock()
		go func() {
			cmd.Wait()
			close(inst.Exited)
			for t := 0; t < 20; t++ { // 浏览器子进程释放文件需要一点时间
				if os.RemoveAll(inst.Dir) == nil {
					break
				}
				time.Sleep(500 * time.Millisecond)
			}
			m.mu.Lock()
			for k, v := range m.instances {
				if v == inst {
					m.instances = append(m.instances[:k], m.instances[k+1:]...)
					break
				}
			}
			m.mu.Unlock()
			if m.onChange != nil {
				m.onChange()
			}
		}()
		// 窗口出现后精确放进九宫格
		go func(pid uint32, slot int) {
			for t := 0; t < 30; t++ {
				time.Sleep(500 * time.Millisecond)
				if ws := windowsOf(pid); len(ws) > 0 {
					place(ws[0], slot)
					return
				}
			}
		}(uint32(cmd.Process.Pid), slot)
	}
	if m.onChange != nil {
		m.onChange()
	}
	return nil
}

func (m *Manager) Retile() {
	for i, inst := range m.list() {
		if ws := windowsOf(uint32(inst.Cmd.Process.Pid)); len(ws) > 0 {
			place(ws[0], i)
		}
	}
}

func (m *Manager) Focus(inst *Instance) {
	if ws := windowsOf(uint32(inst.Cmd.Process.Pid)); len(ws) > 0 {
		procShowWindow.Call(ws[0], 9)
		procSetForegroundWindow.Call(ws[0])
	}
}

// 先礼貌关窗口，3 秒内没退出再强制结束
func (m *Manager) Close(inst *Instance) {
	for _, h := range windowsOf(uint32(inst.Cmd.Process.Pid)) {
		procPostMessageW.Call(h, 0x0010, 0, 0) // WM_CLOSE
	}
	go func() {
		select {
		case <-inst.Exited:
		case <-time.After(3 * time.Second):
			exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(inst.Cmd.Process.Pid)).Run()
		}
	}()
}

func (m *Manager) CloseAll() {
	for _, inst := range m.list() {
		m.Close(inst)
	}
}

func (m *Manager) Shutdown() {
	m.onChange = nil
	all := m.list()
	for _, inst := range all {
		m.Close(inst)
	}
	deadline := time.After(5 * time.Second)
	for _, inst := range all {
		select {
		case <-inst.Exited:
		case <-deadline:
		}
	}
	time.Sleep(500 * time.Millisecond)
	os.RemoveAll(m.base)
}

// 只接受 http/https 网址：以 "-" 开头的行会被浏览器当成启动参数（例如能运行程序的开关）。
// 不带协议的补上 https://，其余一律拒绝。
func safeURL(line string) (string, bool) {
	s := line
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	if strings.HasPrefix(line, "-") {
		return "", false
	}
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", false
	}
	return u.String(), true
}

// ---------- 设置 ----------

const defaultURLs = "https://platform.muse.ai/\r\nhttps://muse.ai/?activation_view=setup"

type Settings struct {
	Browser string `json:"browser"`
	Count   int    `json:"count"`
	Zoom    int    `json:"zoom"`
	URLs    string `json:"urls"`
}

func settingsPath() string {
	return filepath.Join(os.Getenv("APPDATA"), "WuhenDuokai", "settings.json")
}

func loadSettings() Settings {
	s := Settings{Count: 9, Zoom: 50, URLs: defaultURLs}
	if b, err := os.ReadFile(settingsPath()); err == nil {
		json.Unmarshal(b, &s)
	}
	return s
}

func saveSettings(s Settings) {
	os.MkdirAll(filepath.Dir(settingsPath()), 0o700)
	b, _ := json.MarshalIndent(s, "", "  ")
	os.WriteFile(settingsPath(), b, 0o600)
}

// ---------- 界面 ----------

var zoomChoices = []int{25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150}

func main() {
	mgr := newManager()
	browsers := findBrowsers()
	st := loadSettings()

	var (
		mw        *walk.MainWindow
		cbBrowser *walk.ComboBox
		neCount   *walk.NumberEdit
		cbZoom    *walk.ComboBox
		teURLs    *walk.TextEdit
		lbRunning *walk.ListBox
		lblStatus *walk.Label
		lblCount  *walk.Label
	)

	names := []string{}
	browserIdx := 0
	for i, b := range browsers {
		names = append(names, b.Name)
		if b.Name == st.Browser {
			browserIdx = i
		}
	}
	zoomNames := []string{}
	zoomIdx := 2
	for i, z := range zoomChoices {
		zoomNames = append(zoomNames, fmt.Sprintf("%d%%", z))
		if z == st.Zoom {
			zoomIdx = i
		}
	}

	var shown []*Instance
	refresh := func() {
		shown = mgr.list()
		items := make([]string, len(shown))
		for i, inst := range shown {
			items[i] = inst.Label()
		}
		lbRunning.SetModel(items)
		lblCount.SetText(fmt.Sprintf("运行中（%d）", len(shown)))
	}
	mgr.onChange = func() {
		if mw != nil {
			mw.Synchronize(refresh)
		}
	}
	current := func() Settings {
		s := Settings{Count: int(neCount.Value()), URLs: teURLs.Text(), Zoom: 50}
		if i := cbBrowser.CurrentIndex(); i >= 0 && i < len(browsers) {
			s.Browser = browsers[i].Name
		}
		if i := cbZoom.CurrentIndex(); i >= 0 {
			s.Zoom = zoomChoices[i]
		}
		return s
	}
	selected := func() *Instance {
		if i := lbRunning.CurrentIndex(); i >= 0 && i < len(shown) {
			return shown[i]
		}
		return nil
	}

	err := MainWindow{
		AssignTo: &mw,
		Title:    "一键多开无痕浏览器",
		MinSize:  Size{Width: 640, Height: 600},
		Size:     Size{Width: 700, Height: 680},
		Layout:   VBox{Margins: Margins{Left: 16, Top: 12, Right: 16, Bottom: 12}},
		Children: []Widget{
			Label{Text: "一键多开无痕浏览器", Font: Font{PointSize: 15, Bold: true}},
			Label{Text: "每个窗口独立配置 + 无痕模式，账号互不串号；关闭即清除全部数据。", TextColor: walk.RGB(110, 110, 110)},
			Composite{
				Layout: Grid{Columns: 2, MarginsZero: true},
				Children: []Widget{
					Label{Text: "浏览器"},
					ComboBox{AssignTo: &cbBrowser, Model: names, CurrentIndex: browserIdx},
					Label{Text: "数量"},
					NumberEdit{AssignTo: &neCount, MinValue: 1, MaxValue: 36, Decimals: 0, Value: float64(st.Count), SpinButtonsVisible: true},
					Label{Text: "默认缩放"},
					ComboBox{AssignTo: &cbZoom, Model: zoomNames, CurrentIndex: zoomIdx},
					Label{Text: "打开网址\n（每行一个）"},
					TextEdit{AssignTo: &teURLs, Text: st.URLs, VScroll: true, MinSize: Size{Height: 64}},
				},
			},
			Composite{
				Layout: HBox{MarginsZero: true},
				Children: []Widget{
					PushButton{Text: "一键打开", MinSize: Size{Width: 200}, OnClicked: func() {
						if len(browsers) == 0 {
							walk.MsgBox(mw, "提示", "没有找到 Chrome / Edge / Brave / Firefox", walk.MsgBoxIconWarning)
							return
						}
						s := current()
						saveSettings(s)
						var urls []string
						skipped := 0
						for _, line := range strings.Split(s.URLs, "\n") {
							if u := strings.TrimSpace(line); u != "" {
								if safe, ok := safeURL(u); ok {
									urls = append(urls, safe)
								} else {
									skipped++
								}
							}
						}
						if skipped > 0 {
							defer lblStatus.SetText(lblStatus.Text() + fmt.Sprintf("（跳过 %d 行不是 http/https 网址的内容）", skipped))
						}
						b := browsers[cbBrowser.CurrentIndex()]
						if err := mgr.Launch(b, s.Count, urls, s.Zoom); err != nil {
							lblStatus.SetText("启动失败：" + err.Error())
							return
						}
						lblStatus.SetText(fmt.Sprintf("已打开 %d 个 %s 无痕窗口", s.Count, b.Name))
					}},
					PushButton{Text: "九宫格排列", OnClicked: func() { mgr.Retile(); lblStatus.SetText("已按九宫格重新排列") }},
					PushButton{Text: "全部关闭", OnClicked: func() { mgr.CloseAll(); lblStatus.SetText("已关闭全部窗口，临时数据已清除") }},
					PushButton{Text: "恢复默认网址", OnClicked: func() { teURLs.SetText(defaultURLs) }},
				},
			},
			Label{AssignTo: &lblStatus, Text: ""},
			Label{AssignTo: &lblCount, Text: "运行中（0）", Font: Font{Bold: true}},
			ListBox{AssignTo: &lbRunning, MinSize: Size{Height: 160}},
			Composite{
				Layout: HBox{MarginsZero: true},
				Children: []Widget{
					HSpacer{},
					PushButton{Text: "前置所选", OnClicked: func() {
						if inst := selected(); inst != nil {
							mgr.Focus(inst)
						}
					}},
					PushButton{Text: "关闭所选", OnClicked: func() {
						if inst := selected(); inst != nil {
							mgr.Close(inst)
						}
					}},
				},
			},
		},
	}.Create()
	if err != nil {
		walk.MsgBox(nil, "错误", err.Error(), walk.MsgBoxIconError)
		return
	}
	if len(browsers) == 0 {
		lblStatus.SetText("没有找到已安装的 Chrome / Edge / Brave / Firefox")
	}
	// 窗口左上角和任务栏用 exe 里编进去的图标（app.rc 里的 1 号图标）
	if ic, err := walk.NewIconFromResourceId(1); err == nil {
		mw.SetIcon(ic)
	}
	mw.Closing().Attach(func(_ *bool, _ walk.CloseReason) {
		saveSettings(current())
	})
	mw.Run()
	mgr.Shutdown()
}
