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
	root      string // 所有运行共用的上层目录
	base      string // 这次运行自己的 run-<进程号> 子目录：同时开两份软件也互不影响
	onChange  func()
}

func newManager() *Manager {
	root := filepath.Join(os.TempDir(), "WuhenDuokai")
	base := filepath.Join(root, fmt.Sprintf("run-%d", os.Getpid()))
	// 只清理已经退出的那些运行留下的目录（异常退出、强制结束）；还在运行的另一份软件的目录不碰。
	// 旧版本直接放在上层目录里的浏览器目录也一并清掉。
	if entries, err := os.ReadDir(root); err == nil {
		for _, e := range entries {
			var pid int
			if n, _ := fmt.Sscanf(e.Name(), "run-%d", &pid); n == 1 && processAlive(pid) {
				continue
			}
			os.RemoveAll(filepath.Join(root, e.Name()))
		}
	}
	os.MkdirAll(base, 0o700)
	return &Manager{root: root, base: base}
}

// 进程是否还在：打不开说明不存在（参数无效）；打开了再看退出码是不是 STILL_ACTIVE
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	const processQueryLimitedInformation = 0x1000
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return err != syscall.Errno(87) // ERROR_INVALID_PARAMETER = 没有这个进程；其他错误（如拒绝访问）说明进程存在
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if syscall.GetExitCodeProcess(h, &code) != nil {
		return true
	}
	return code == 259 // STILL_ACTIVE
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
	// 缩放比例来自本机保存的设置，限制在 25%–500%：0 或负数会让 log() 得出无效值，浏览器配置写坏
	zoom = min(max(zoom, 25), 500)
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
	os.RemoveAll(m.base) // 只删自己这次运行的目录
	os.Remove(m.root)    // 上层目录空了才会删掉；别的运行还在就保留
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

// ---------- 界面（薄荷绿主题） ----------

var zoomChoices = []int{25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150}

var (
	colWindow = walk.RGB(0xF3, 0xFA, 0xF7) // 窗口背景：极浅薄荷
	colCard   = walk.RGB(0xFF, 0xFF, 0xFF) // 卡片：白
	colDeep   = walk.RGB(0x0B, 0x7A, 0x5A) // 深薄荷：标题、提示文字
	colMuted  = walk.RGB(0x6B, 0x7B, 0x75) // 次要文字
)

func main() {
	mgr := newManager()
	browsers := findBrowsers()
	st := loadSettings()

	var (
		mw        *walk.MainWindow
		cbBrowser *walk.ComboBox
		cbCount   *walk.ComboBox
		cbZoom    *walk.ComboBox
		teURLs    *walk.TextEdit
		lbRunning *walk.ListBox
		lblStatus *walk.Label
		lblCount  *walk.Label
		btnLaunch *walk.PushButton
	)

	names := []string{}
	browserIdx := 0
	for i, b := range browsers {
		names = append(names, b.Name)
		if b.Name == st.Browser {
			browserIdx = i
		}
	}
	countNames := []string{}
	for n := 1; n <= 36; n++ {
		if n == 9 {
			countNames = append(countNames, "9 个（九宫格）")
		} else {
			countNames = append(countNames, fmt.Sprintf("%d 个", n))
		}
	}
	countIdx := min(max(st.Count, 1), 36) - 1
	zoomNames := []string{}
	zoomIdx := 2
	for i, z := range zoomChoices {
		if z == 100 {
			zoomNames = append(zoomNames, "100%（原始大小）")
		} else {
			zoomNames = append(zoomNames, fmt.Sprintf("%d%%", z))
		}
		if z == st.Zoom {
			zoomIdx = i
		}
	}

	var shown []*Instance
	refresh := func() {
		shown = mgr.list()
		items := make([]string, len(shown))
		for i, inst := range shown {
			items[i] = fmt.Sprintf("  #%d   %s   ·  无痕 · 独立配置", inst.Num, inst.Browser.Name)
		}
		lbRunning.SetModel(items)
		lblCount.SetText(fmt.Sprintf("运行中的窗口（%d）", len(shown)))
	}
	mgr.onChange = func() {
		if mw != nil {
			mw.Synchronize(refresh)
		}
	}
	current := func() Settings {
		s := Settings{Count: cbCount.CurrentIndex() + 1, URLs: teURLs.Text(), Zoom: 50}
		if i := cbBrowser.CurrentIndex(); i >= 0 && i < len(browsers) {
			s.Browser = browsers[i].Name
		}
		if i := cbZoom.CurrentIndex(); i >= 0 {
			s.Zoom = zoomChoices[i]
		}
		return s
	}
	launchText := func() string { return fmt.Sprintf("一键打开 %d 个无痕窗口", cbCount.CurrentIndex()+1) }
	selected := func() *Instance {
		if i := lbRunning.CurrentIndex(); i >= 0 && i < len(shown) {
			return shown[i]
		}
		return nil
	}
	fieldLabel := func(t string) Label { return Label{Text: t, TextColor: colMuted} }

	err := MainWindow{
		AssignTo:   &mw,
		Title:      "一键多开无痕浏览器",
		MinSize:    Size{Width: 640, Height: 600},
		Size:       Size{Width: 720, Height: 680},
		Background: SolidColorBrush{Color: colWindow},
		Layout:     VBox{Margins: Margins{Left: 18, Top: 14, Right: 18, Bottom: 14}, Spacing: 10},
		Children: []Widget{
			// 顶部：名称 + 说明
			Label{Text: "一键多开无痕浏览器", Font: Font{PointSize: 16, Bold: true}, TextColor: colDeep},
			Label{Text: "每个窗口独立配置 + 无痕模式，账号互不串号，关闭即清除数据", TextColor: colMuted},

			// 设置卡片：一行三个下拉框 + 网址
			Composite{
				Background: SolidColorBrush{Color: colCard},
				Layout:     VBox{Margins: Margins{Left: 14, Top: 12, Right: 14, Bottom: 12}, Spacing: 8},
				Children: []Widget{
					Composite{
						Layout: Grid{Columns: 3, MarginsZero: true, Spacing: 12},
						Children: []Widget{
							fieldLabel("浏览器"), fieldLabel("窗口数量"), fieldLabel("默认缩放"),
							ComboBox{AssignTo: &cbBrowser, Model: names, CurrentIndex: browserIdx,
								ToolTipText: "只列出这台电脑上已安装的浏览器"},
							ComboBox{AssignTo: &cbCount, Model: countNames, CurrentIndex: countIdx,
								ToolTipText: "1–36 个；超过 9 个时，下一组会稍微错开叠放",
								OnCurrentIndexChanged: func() {
									if btnLaunch != nil {
										btnLaunch.SetText(launchText())
									}
								}},
							ComboBox{AssignTo: &cbZoom, Model: zoomNames, CurrentIndex: zoomIdx,
								ToolTipText: "网页内容的显示比例"},
						},
					},
					fieldLabel("打开网址（每行一个，每个窗口各开一个标签页；只接受 http/https 网址）"),
					TextEdit{AssignTo: &teURLs, Text: st.URLs, VScroll: true, MinSize: Size{Height: 60}},
					Composite{
						Layout: HBox{MarginsZero: true},
						Children: []Widget{
							HSpacer{},
							LinkLabel{Text: `<a id="reset">恢复默认网址</a>`,
								OnLinkActivated: func(*walk.LinkLabelLink) { teURLs.SetText(defaultURLs) }},
						},
					},
				},
			},

			// 主按钮
			PushButton{AssignTo: &btnLaunch, Text: fmt.Sprintf("一键打开 %d 个无痕窗口", countIdx+1),
				MinSize: Size{Height: 42}, Font: Font{PointSize: 11, Bold: true},
				OnClicked: func() {
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
						lblStatus.SetTextColor(walk.RGB(0xD9, 0x3A, 0x3F))
						lblStatus.SetText("✕ 启动失败：" + err.Error())
						return
					}
					lblStatus.SetTextColor(colDeep)
					lblStatus.SetText(fmt.Sprintf("✓ 已打开 %d 个 %s 无痕窗口", s.Count, b.Name))
				}},

			// 次要操作 + 结果提示
			Composite{
				Layout: HBox{MarginsZero: true, Spacing: 8},
				Children: []Widget{
					PushButton{Text: "九宫格重新排列", OnClicked: func() {
						mgr.Retile()
						lblStatus.SetTextColor(colDeep)
						lblStatus.SetText("✓ 已按九宫格重新排列")
					}},
					PushButton{Text: "全部关闭并清除", OnClicked: func() {
						mgr.CloseAll()
						lblStatus.SetTextColor(colDeep)
						lblStatus.SetText("✓ 已关闭全部窗口，临时数据已清除")
					}},
					HSpacer{},
					Label{AssignTo: &lblStatus, Text: "", TextColor: colDeep},
				},
			},

			// 运行中的窗口
			Composite{
				Background: SolidColorBrush{Color: colCard},
				Layout:     VBox{Margins: Margins{Left: 14, Top: 12, Right: 14, Bottom: 12}, Spacing: 8},
				Children: []Widget{
					Label{AssignTo: &lblCount, Text: "运行中的窗口（0）", Font: Font{Bold: true}, TextColor: colDeep},
					ListBox{AssignTo: &lbRunning, MinSize: Size{Height: 150}},
					Composite{
						Layout: HBox{MarginsZero: true},
						Children: []Widget{
							Label{Text: "选中一行后可以切到那个窗口，或单独关闭它", TextColor: colMuted},
							HSpacer{},
							PushButton{Text: "切到所选窗口", OnClicked: func() {
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
			},
		},
	}.Create()
	if err != nil {
		walk.MsgBox(nil, "错误", err.Error(), walk.MsgBoxIconError)
		return
	}
	if len(browsers) == 0 {
		lblStatus.SetTextColor(walk.RGB(0xD9, 0x3A, 0x3F))
		lblStatus.SetText("没有找到已安装的 Chrome / Edge / Brave / Firefox")
		btnLaunch.SetEnabled(false)
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
