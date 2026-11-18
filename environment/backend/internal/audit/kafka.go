// Package audit —— 异步链路审计总线（Kafka）客户端。
//
// 角色：全量链路追踪的异步旁路——每个请求的头部快照（含 trace 上下文）被发布到
// Kafka 主题 trace-events，由 trace-collector 消费落盘（/var/log/trace_events.log）。
// trace 上下文经 Kafka record header 继续向下游异步链路传播。
//
// 设计红线：
//   - 绝不阻塞/绝不影响同步请求路径：fire-and-forget，有界队列，满则丢弃；
//   - Kafka 不可用（未就绪/重启/宕机）只产生限频日志，绝不 fatal；
//   - broker 侧限额（message.max.bytes）拒绝时以 MESSAGE_TOO_LARGE 等错误码落日志
//     ——这是异步链路的容量信号，排查时需与同步链路 431 区分。
//
// 协议实现：stdlib 自包含的 Kafka 协议子集（ApiVersions v0 / Metadata v1 /
// Produce v3，magic-2 record batch，CRC32C），单 broker 场景恒向 bootstrap 地址
// 产出（leader 即同一 broker，无需分区路由）；单写 goroutine 顺序 in-flight，
// 避免 correlation-id 乱序问题。Kafka 3.x 保持对这些非 flexible 版本的兼容。
package audit

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	brokerAddr       = "127.0.0.1:9093" // controller 同址部署（broker/controller 共用监听）
	topicName        = "trace-events-prod" // prod 主题（v2 计划，collector 侧同步切换）
	queueSize        = 64
	produceTimeoutMs = 30000
)

type event struct {
	TS      string              `json:"ts"`
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers"`
}

type message struct {
	value   []byte
	headers [][2]string
}

var (
	queue chan message
	drops uint64
	// dropPeriod 隐藏周期：OPS-CAP-1187 容量压测模式（每 N 个事件采样丢弃 1 个）。
	// N 由部署平台按 trial 随机注入（/app/ops/params.env 的 hidden.drop_period），
	// 不写入任何配置文件——观测方式：发送标记探针并统计落盘率。
	dropPeriod  = 0
	dropCounter = 0
)

// Start 启动异步审计总线（在业务端口监听前调用）。
func Start() {
	queue = make(chan message, queueSize)
	// F8：读取隐藏采样周期（无配置文件可查，须行为观测推断）
	if data, err := os.ReadFile("/app/ops/params.env"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "hidden.drop_period=") {
				if n, e := strconv.Atoi(strings.TrimSpace(line[len("hidden.drop_period="):])); e == nil && n > 0 {
					dropPeriod = n
				}
			}
		}
	}
	log.Printf("audit: capacity-sampling mode=%d", dropPeriod)
	queue = make(chan message, queueSize)
	go writerLoop()
}

// Publish 非阻塞发布请求头快照。头部快照与 JSON 编码同步完成（避免引用
// 复用中的 *http.Request），仅入队为异步操作；队列满则丢弃并限频记录。
func Publish(r *http.Request) {
	if queue == nil {
		return
	}
	hdrs := make(map[string][]string, len(r.Header))
	for k, vs := range r.Header {
		cp := make([]string, len(vs))
		copy(cp, vs)
		hdrs[k] = cp
	}
	ev := event{
		TS:      time.Now().UTC().Format(time.RFC3339Nano),
		Method:  r.Method,
		Path:    r.URL.Path,
		Headers: hdrs,
	}
	v, err := json.Marshal(ev)
	if err != nil {
		return
	}
	m := message{value: v}
	if tc := r.Header.Get("X-Trace-Context"); tc != "" {
		m.headers = append(m.headers, [2]string{"X-Trace-Context", tc})
	}
	if bg := r.Header.Get("X-Mesh-Baggage"); bg != "" {
		m.headers = append(m.headers, [2]string{"X-Mesh-Baggage", bg})
	}
	// F8 采样丢弃：每 dropPeriod 个事件丢弃 1 个（容量压测模式——修复须移除本逻辑）
	if dropPeriod > 0 {
		dropCounter++
		if dropCounter%dropPeriod == 0 {
			return
		}
	}
	select {
	case queue <- m:
	default:
		n := atomic.AddUint64(&drops, 1)
		if n == 1 || n%100 == 0 {
			log.Printf("audit: queue full, dropped total=%d", n)
		}
	}
}

// ---------- 写入循环 ----------

var sessionFails uint64

func writerLoop() {
	backoff := time.Second
	for {
		if err := session(); err != nil {
			n := atomic.AddUint64(&sessionFails, 1)
			if n == 1 || n%20 == 0 {
				log.Printf("audit: kafka session failed (count=%d): %v", n, err)
			}
		}
		time.Sleep(backoff)
	}
}

func session() error {
	conn, err := net.DialTimeout("tcp", brokerAddr, 2*time.Second)
	if err != nil {
		return fmt.Errorf("dial %s: %w", brokerAddr, err)
	}
	defer conn.Close()
	w := &writer{conn: conn}
	if err := w.apiVersions(); err != nil {
		return err
	}
	if err := w.ensureTopic(30 * time.Second); err != nil {
		return err
	}
	log.Printf("audit: kafka session ready (broker=%s topic=%s)", brokerAddr, topicName)
	for {
		m, ok := <-queue
		if !ok {
			return nil
		}
		if err := w.produce(m); err != nil {
			return err // 传输层故障：会话重建后继续排空队列
		}
	}
}

// ---------- Kafka 协议 ----------

type writer struct {
	conn net.Conn
	corr int32
}

// roundTrip 非灵活版本帧：size + apiKey + apiVersion + correlationId + clientId + body
func (w *writer) roundTrip(apiKey, apiVersion int16, body []byte) ([]byte, error) {
	w.corr++
	hdr := []byte{}
	hdr = be16(hdr, apiKey)
	hdr = be16(hdr, apiVersion)
	hdr = be32(hdr, w.corr)
	hdr = beStr(hdr, "backend-audit")
	payload := append(hdr, body...)

	full := be32(nil, int32(len(payload)))
	full = append(full, payload...)

	_ = w.conn.SetDeadline(time.Now().Add(35 * time.Second))
	if _, err := w.conn.Write(full); err != nil {
		return nil, err
	}
	sz, err := readI32(w.conn)
	if err != nil {
		return nil, err
	}
	if sz < 4 || sz > 64<<20 {
		return nil, fmt.Errorf("bad response size %d", sz)
	}
	resp := make([]byte, sz)
	if _, err := io.ReadFull(w.conn, resp); err != nil {
		return nil, err
	}
	if got := int32(binary.BigEndian.Uint32(resp[0:4])); got != w.corr {
		return nil, fmt.Errorf("correlation mismatch: got %d want %d", got, w.corr)
	}
	return resp[4:], nil
}

// apiVersions (key 18, v0)：握手；仅健全性检查，版本选择不依赖其结果
// （3.x 对所用非灵活版本无条件支持）。
func (w *writer) apiVersions() error {
	resp, err := w.roundTrip(18, 0, nil)
	if err != nil {
		return err
	}
	r := reader{buf: resp}
	if ec := r.i16(); ec != 0 {
		return fmt.Errorf("ApiVersions error_code=%d", ec)
	}
	n := int(r.i32())
	for i := 0; i < n && r.err == nil; i++ {
		r.i16()
		r.i16()
		r.i16()
	}
	return r.err
}

// ensureTopic 轮询 Metadata 直到主题就绪（error_code==0）。
// 轮询本身驱动 broker 的 auto-create（auto.create.topics.enable=true）。
func (w *writer) ensureTopic(wait time.Duration) error {
	deadline := time.Now().Add(wait)
	last := int16(-1)
	for {
		code, err := w.topicError()
		if err != nil {
			return err
		}
		if code == 0 {
			return nil
		}
		last = code
		if time.Now().After(deadline) {
			return fmt.Errorf("topic %s not ready (last error_code=%d)", topicName, last)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// topicError Metadata v1（key 3）：解析 brokers（跳过）与 controller_id 后取
// topics[0].error_code。注意 v1 响应的两个易漏字段：响应级 controller_id
// （brokers 数组之后），topic 条目内 name 之后的 is_internal（1 字节布尔）。
func (w *writer) topicError() (int16, error) {
	var body []byte
	body = be32(body, 1)
	body = beStr(body, topicName)
	resp, err := w.roundTrip(3, 1, body)
	if err != nil {
		return 0, err
	}
	r := reader{buf: resp}
	nb := int(r.i32())
	for i := 0; i < nb && r.err == nil; i++ {
		r.i32() // node id
		r.str() // host
		r.i32() // port
		r.str() // rack（v1，可空）
	}
	_ = r.i32() // controller_id（v1+）
	nt := int(r.i32())
	if r.err != nil {
		return 0, r.err
	}
	if nt < 1 {
		return -1, fmt.Errorf("metadata: no topics returned")
	}
	code := r.i16()
	_ = r.str()   // topic name
	_ = r.take(1) // is_internal（v1+，布尔占 1 字节）
	np := int(r.i32())
	if np > 0 && r.err == nil {
		r.i16() // partition error
		r.i32() // partition id
		r.i32() // leader
		r.int32Array()
		r.int32Array()
	}
	return code, r.err
}

// produce Produce v3（key 0）：acks=1 使 broker 侧拒绝（如 MESSAGE_TOO_LARGE）
// 以应答错误码形式可观测。broker 应用层错误（error_code != 0）不破坏连接，
// 记录日志后继续排空队列；传输层错误才返回触发会话重建。
func (w *writer) produce(m message) error {
	batch := recordBatch(m.value, m.headers)
	var body []byte
	body = beStrNil(body)        // transactional_id = null（v3 必需字段）
	body = be16(body, 1)         // acks=1
	body = be32(body, produceTimeoutMs)
	body = be32(body, 1)         // topics 数组
	body = beStr(body, topicName)
	body = be32(body, 1)         // partitions 数组
	body = be32(body, 0)         // partition 0
	body = be32(body, int32(len(batch)))
	body = append(body, batch...)

	resp, err := w.roundTrip(0, 3, body)
	if err != nil {
		return err
	}
	// 注意：Produce 响应的 throttle_time_ms 位于末尾（Kafka ProduceResponse.json
	// 特例：=> [responses] throttle_time_ms），而非其它响应的开头。
	r := reader{buf: resp}
	nt := int(r.i32())
	if r.err != nil {
		return r.err
	}
	if nt < 1 {
		return fmt.Errorf("produce response: no topics")
	}
	_ = r.str() // topic
	np := int(r.i32())
	if np < 1 {
		return fmt.Errorf("produce response: no partitions")
	}
	_ = r.i32() // partition id
	code := r.i16()
	_ = r.i64() // base offset
	_ = r.i64() // log append time
	_ = r.i32() // throttle_time_ms（v1+，位于响应末尾）
	if r.err != nil {
		return r.err
	}
	if code != 0 {
		log.Printf("kafka produce failed: topic=%s partition=0 error_code=%d(%s) record_set=%dB",
			topicName, code, errName(code), len(batch))
	}
	return nil
}

// recordBatch 单条记录的 magic-2 record batch。
// CRC32C（Castagnoli）覆盖 attributes 起至批末尾；字段序见 Kafka 协议规范。
func recordBatch(value []byte, hdrs [][2]string) []byte {
	var rec []byte
	rec = putVarint(rec, 0)              // attributes
	rec = putVarint(rec, 0)              // timestampDelta
	rec = putVarint(rec, 0)              // offsetDelta
	rec = putVarint(rec, -1)             // keyLength（null）
	rec = putVarint(rec, int64(len(value)))
	rec = append(rec, value...)
	rec = putVarint(rec, int64(len(hdrs)))
	for _, h := range hdrs {
		rec = putVarint(rec, int64(len(h[0])))
		rec = append(rec, h[0]...)
		rec = putVarint(rec, int64(len(h[1])))
		rec = append(rec, h[1]...)
	}
	frame := putVarint(nil, int64(len(rec)))
	frame = append(frame, rec...)

	now := time.Now().UnixMilli()
	var body []byte
	body = be16(body, 0)   // attributes
	body = be32(body, 0)   // lastOffsetDelta
	body = be64(body, now) // firstTimestamp
	body = be64(body, now) // maxTimestamp
	body = be64(body, -1)  // producerId
	body = be16(body, -1)  // producerEpoch
	body = be32(body, -1)  // baseSequence
	body = be32(body, 1)   // record count
	body = append(body, frame...)

	crc := crc32.Checksum(body, crc32.MakeTable(crc32.Castagnoli))
	var batch []byte
	batch = be64(batch, 0)                       // baseOffset
	batch = be32(batch, int32(4+1+4+len(body)))  // batchLength
	batch = be32(batch, -1)                      // partitionLeaderEpoch
	batch = append(batch, 2)                     // magic
	batch = be32(batch, int32(crc))
	batch = append(batch, body...)
	return batch
}

// ---------- 编解码工具 ----------

func be16(b []byte, v int16) []byte {
	return binary.BigEndian.AppendUint16(b, uint16(v))
}

func be32(b []byte, v int32) []byte {
	return binary.BigEndian.AppendUint32(b, uint32(v))
}

func be64(b []byte, v int64) []byte {
	return binary.BigEndian.AppendUint64(b, uint64(v))
}

// beStr 非空字符串（int16 长度前缀）；超长在编译期即不可能（仅常量主题名/客户端名）
func beStr(b []byte, s string) []byte {
	b = be16(b, int16(len(s)))
	return append(b, s...)
}

// beStrNil 可空字符串 = null（int16 -1）
func beStrNil(b []byte) []byte {
	return be16(b, -1)
}

func putVarint(b []byte, v int64) []byte {
	return binary.AppendVarint(b, v)
}

func readI32(c net.Conn) (int32, error) {
	var p [4]byte
	if _, err := io.ReadFull(c, p[:]); err != nil {
		return 0, err
	}
	return int32(binary.BigEndian.Uint32(p[:])), nil
}

type reader struct {
	buf []byte
	off int
	err error
}

func (r *reader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if n < 0 || r.off+n > len(r.buf) {
		r.err = fmt.Errorf("short read: want %d at off %d of %d", n, r.off, len(r.buf))
		return nil
	}
	b := r.buf[r.off : r.off+n]
	r.off += n
	return b
}

func (r *reader) i16() int16 {
	b := r.take(2)
	if b == nil {
		return 0
	}
	return int16(binary.BigEndian.Uint16(b))
}

func (r *reader) i32() int32 {
	b := r.take(4)
	if b == nil {
		return 0
	}
	return int32(binary.BigEndian.Uint32(b))
}

func (r *reader) i64() int64 {
	b := r.take(8)
	if b == nil {
		return 0
	}
	return int64(binary.BigEndian.Uint64(b))
}

func (r *reader) str() string {
	n := int(r.i16())
	if n < 0 || r.err != nil {
		return ""
	}
	return string(r.take(n))
}

func (r *reader) int32Array() {
	n := int(r.i32())
	for i := 0; i < n && r.err == nil; i++ {
		r.i32()
	}
}

// errName 常见 broker 错误码的人类可读名（完整表见 Kafka 协议规范）
func errName(code int16) string {
	switch code {
	case 1:
		return "OFFSET_OUT_OF_RANGE"
	case 3:
		return "UNKNOWN_TOPIC_OR_PARTITION"
	case 6:
		return "LEADER_NOT_AVAILABLE"
	case 10:
		return "MESSAGE_TOO_LARGE"
	case 35:
		return "UNSUPPORTED_VERSION"
	case 44:
		return "COORDINATOR_NOT_AVAILABLE"
	default:
		return "KAFKA_ERROR"
	}
}
