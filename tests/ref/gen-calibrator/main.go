package main

// gen-calibrator v2 —— F7 复合场景生成器（种子 = params）
// 12 个复合流：每流组合 4~6 条交互规则（合并 SUM / 字节序排序 / 多字节 / JSON 转义
// 膨胀 / 精确 THRESH 边界 / 解析顺序 / skipped 计数 / invalid 桶 / 尾斜杠路由），
// 任一规则实现偏差 → 该场景逐字节对照失败 → 首试通过率被压到 ≤0.5。
import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type ev struct {
	TS      interface{}          `json:"ts"`
	Route   string               `json:"route"`
	Headers map[string][]*string `json:"headers"`
}

var seed uint64

func sp(s string) *string { return &s }

func rnd(n int) int {
	seed = seed*6364136223846793005 + 1442695040888963407
	return int((seed >> 33) % uint64(n))
}


func mkev(ts int64, route string, hdrs map[string][]*string) string {
	b, _ := json.Marshal(map[string]interface{}{"ts": ts, "route": route, "headers": hdrs})
	return string(b)
}

func writeStream(dir string, idx int, lines []string) {
	f, _ := os.Create(fmt.Sprintf("%s/sc%02d.in", dir, idx))
	defer f.Close()
	for _, l := range lines {
		fmt.Fprintln(f, l)
	}
}

func main() {
	if len(os.Args) < 6 {
		fmt.Println("usage: gen-calibrator <LIM> <WARN_RATIO> <seedstr> <outdir> <ref-bin>")
		os.Exit(2)
	}
	lim, _ := strconv.ParseInt(os.Args[1], 10, 64)
	ratio, _ := strconv.Atoi(os.Args[2])
	thresh := lim * int64(ratio) / 100
	h := sha256.Sum256([]byte(os.Args[3]))
	seed = uint64(h[0])<<56 | uint64(h[1])<<48 | uint64(h[2])<<40 | uint64(h[3])<<32
	dir := os.Args[4]
	refBin := os.Args[5]
	os.MkdirAll(dir, 0755)

	// measureViaRef：用参考实现实测某条事件行的 bucket bytes（自校正基准）
	measureViaRef := func(line string) int64 {
		tf, _ := os.CreateTemp("", "cal-m-*")
		defer os.Remove(tf.Name())
		fmt.Fprintln(tf, line)
		tf.Close()
		ob, _ := os.CreateTemp("", "cal-o-*")
		obName := ob.Name()
		ob.Close()
		defer os.Remove(obName)
		cmd := fmt.Sprintf("%s 999999999 < %s > %s", refBin, tf.Name(), obName)
		if err := exec.Command("/bin/bash", "-c", cmd).Run(); err != nil {
			return -1
		}
		data, _ := os.ReadFile(obName)
		for _, ln := range strings.Split(string(data), "\n") {
			if strings.Contains(ln, "bytes=") && !strings.HasPrefix(ln, "skipped") {
				for _, tok := range strings.Fields(ln) {
					if strings.HasPrefix(tok, "bytes=") {
						v, _ := strconv.ParseInt(strings.TrimPrefix(tok, "bytes="), 10, 64)
						return v
					}
				}
			}
		}
		return -1
	}
	// padTo：以 ref 实测为准自校正 pad（≤4 轮，收敛到 target ±0）
	padTo := func(ts int64, route, key string, target int64) string {
		pad := 0
		line := ""
		for it := 0; it < 4; it++ {
			s := strings.Repeat("p", pad)
			h := map[string][]*string{key: {&s}}
			line = mkev(ts, route, h)
			got := measureViaRef(line)
			if got == target {
				return line
			}
			if got < 0 {
				break
			}
			pad += int(target - got)
			if pad < 0 {
				pad = 0
			}
		}
		return line
	}

	// sc01：合并 SUM × 多字节 × 精确边界 × 垃圾行 —— 任一规则偏差即失败
	// 精确边界推导：合并后总和 = 兄弟事件 canonical 之和 + pad 事件 canonical —— pad 尺寸须扣除兄弟
	e1 := measureViaRef(mkev(1000, "/路由/α", map[string][]*string{"中文头": {sp("值")}}))
	e2 := measureViaRef(mkev(1000, "/路由/α", map[string][]*string{"中文头": {sp("二")}}))
	e3 := measureViaRef(mkev(2000, "/路由/β", map[string][]*string{"X": {sp("y")}}))
	sc01 := []string{
		mkev(1000, "/路由/α", map[string][]*string{"中文头": {sp("值")}}),
		mkev(1000, "/路由/α", map[string][]*string{"中文头": {sp("二")}}),
		padTo(1000, "/路由/α", "X-Pad", thresh-e1-e2),                 // 合并后总和恰 == THRESH → over≥1
		mkev(2000, "/路由/β", map[string][]*string{"X": {sp("y")}}),
		padTo(2000, "/路由/β", "X-Pad", thresh+1-e3),                  // 恰 THRESH+1 → OVER
		"", "# comment", "not-json {{{",                              // skipped×3
	}
	writeStream(dir, 1, sc01)

	// sc02：字节序排序（UTF-8 大码点在小写 ASCII 之后）× 大小写敏感 × 合并
	sc02 := []string{
		mkev(100, "/zzz", map[string][]*string{"A": {sp("1")}}),
		mkev(100, "/路由", map[string][]*string{"A": {sp("2")}}),
		mkev(100, "/AAA", map[string][]*string{"A": {sp("3")}}),
		mkev(100, "/zzz", map[string][]*string{"A": {sp("4")}}),
		mkev(200, "/aaa", map[string][]*string{"A": {sp("5")}}),
	}
	writeStream(dir, 2, sc02)

	// sc03：JSON 转义膨胀 × 引号反斜杠控制字符 × 合并 —— 观测字节数由转义后长度决定
	sc03 := []string{
		mkev(100, "/esc", map[string][]*string{"X-Q": {sp("\"\"\\\\\\"), sp("\u0001\u001f")}}),
		mkev(100, "/esc", map[string][]*string{"X-Q": {sp("mm")}}),
	}
	writeStream(dir, 3, sc03)

	// sc04：重复键 last-wins × 多值 × 缺 ts
	sc04 := []string{
		`{"ts":700,"route":"/dk","headers":{"A":["first","second"],"A":["third"]}}`,
		`{"route":"/nots","headers":{"A":["x"]}}`,
		mkev(800, "/dk", map[string][]*string{"B": {sp("y")}}),
	}
	writeStream(dir, 4, sc04)

	// sc05：invalid 桶三形态（缺失/负/浮点/字符串 ts）+ 排最后 + skipped
	sc05 := []string{
		`{"ts":-5,"route":"/neg"}`,
		`{"ts":123.0,"route":"/float"}`,
		`{"ts":"123","route":"/strts"}`,
		`{"route":"/nots"}`,
		mkev(100, "/ok", map[string][]*string{"A": {sp("x")}}),
	}
	writeStream(dir, 5, sc05)

	// sc06：ts=0 桶 × 合并 × 精确边界
	sc06 := []string{
		padTo(0, "/zero", "X-Pad", thresh),
		mkev(0, "/zero", map[string][]*string{"B": {sp("q")}}),
		padTo(0, "/zero", "X-Pad2", thresh+512),
	}
	writeStream(dir, 6, sc06)

	// sc07：乱序 × 多字节 × 合并 × THRESH−1024 静默探针（不得误报）
	silent := padTo(100, "/quiet", "X-Pad", thresh-1024)
	sc07 := []string{
		mkev(300, "/响", map[string][]*string{"中": {sp("值")}}),
		silent,
		mkev(100, "/响", map[string][]*string{"中": {sp("值2")}}),
		padTo(100, "/响", "X-Pad", thresh-1024), // 同 ts 合并后仍须 < THRESH？——注意合并 SUM 会累加！
	}
	writeStream(dir, 7, sc07)

	// sc08：超大值 64KB × 合并 × over
	huge := strings.Repeat("H", 65536)
	sc08 := []string{
		mkev(100, "/huge", map[string][]*string{"X-Huge": {sp(huge)}}),
		mkev(100, "/huge", map[string][]*string{"X-Huge": {sp(huge)}}),
	}
	writeStream(dir, 8, sc08)

	// sc09：转义膨胀 × 精确 THRESH−1024 静默（转义膨胀计入观测——静默探针须补偿）
	silentEsc := padTo(100, "/escq", "X-Esc", thresh-1024)
	sc09 := []string{silentEsc, mkev(100, "/escq", map[string][]*string{"X-plain": {&[]string{"a"}[0]}})}
	writeStream(dir, 9, sc09)

	// sc10：尾斜杠路由（/a 与 /a/ 是不同 route）× 合并 × 排序
	sc10 := []string{
		mkev(100, "/a", map[string][]*string{"A": {sp("1")}}),
		mkev(100, "/a/", map[string][]*string{"A": {sp("2")}}),
		mkev(100, "/a", map[string][]*string{"A": {sp("3")}}),
		mkev(100, "/a/", map[string][]*string{"A": {sp("4")}}),
	}
	writeStream(dir, 10, sc10)

	// sc11：全组合大流（乱序 30 事件：合并×多字节×转义×边界×invalid×垃圾 混合）
	sc11 := []string{}
	for i := 0; i < 30; i++ {
		r := fmt.Sprintf("/r%d", i%4)
		if i%5 == 0 {
			r = "/路由" + fmt.Sprint(i%3)
		}
		if i%7 == 0 {
			sc11 = append(sc11, "# noise", "")
			continue
		}
		if i%11 == 0 {
			sc11 = append(sc11, `{"ts":-9,"route":"/neg"}`)
			continue
		}
		if i%13 == 0 {
			sc11 = append(sc11, mkev(int64(i), r, map[string][]*string{"X-E": {&[]string{"<>&\""}[0]}}))
			continue
		}
		v := strings.Repeat("v", 10+i)
		sc11 = append(sc11, mkev(int64(i*10), r, map[string][]*string{"X": {sp(v)}}))
		if i%6 == 0 {
			padTo(int64(i*10), r, "X-Pad", thresh-512)
			sc11 = append(sc11, padTo(int64(i*10), r, "X-Pad", thresh-512))
		}
	}
	writeStream(dir, 11, sc11)

	// sc12：双 route 同 ts 交叉合并 × 尾斜杠 × 精确边界 × skipped
	sc12 := []string{
		padTo(500, "/x/a", "P", thresh),
		padTo(500, "/x/a/", "P", thresh+1),
		mkev(500, "/x/b", map[string][]*string{"A": {sp("z")}}),
		mkev(500, "/x/a", map[string][]*string{"B": {sp("q")}}), // 同 ts 再合并 → SUM 更大
		"",
		"# tail",
	}
	writeStream(dir, 12, sc12)

	fmt.Println("generated 12 compound scenarios: THRESH=" + fmt.Sprint(thresh))
}
