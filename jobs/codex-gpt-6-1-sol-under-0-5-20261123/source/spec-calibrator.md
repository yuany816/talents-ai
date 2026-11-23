# calibrator 规格书（F7 实现题 · v6）

交付物：可执行文件 `/app/ops/bin/calibrator`（任意语言，静态编译，判分环境直接执行）。
输入：stdin，行分隔事件流。输出：stdout，按本规格**逐字节**确定的摘要。
调用：`calibrator <THRESH>`（argv[1] = 告警阈值，字节整数）。

## 输入行
- 事件行（JSON 单行）：`{"ts":<毫秒整数>,"route":"<字符串>","headers":{<名:[值...]>}}`
  - 名与非空值可为任意 UTF-8（含多字节）；同一名可多值；值也可为 JSON `null`，规范化时保留为 `null`。
  - `ts` 的有效范围为有符号 64 位整数；超出范围按无效事件处理。
  - `headers` 缺失或为 `null` 时规范化为 `{}`。
- 非事件行（空行、注释 `#...`、垃圾文本）：跳过，计入 `skipped`。

## 观测口径（bytes）
每事件的 observed = 以下**规范化再序列化**的字节长度（UTF-8 字节数，非 rune 数）：
`{"ts":T,"route":R,"headers":{K1:[...],K2:[...]}}`
- headers 的键按**字节序升序**重排；每个键的值数组保持输入顺序；
- 无空格紧凑序列化（逗号/冒号后无空格）；
- `< > &` 不作 HTML 转义；`U+2028/U+2029` 分别转义为 `\u2028/\u2029`；
- ts/route 使用输入原值（整数不补零、route 原样转义）。

## 合并规则
- **route 与 ts（毫秒）完全相同**的多条事件合并为一条：observed 取**合并后总和**
  （即各事件规范化字节长之和），计入 events=1；headers 不合并（以 observed 总和为准）。

## 分桶与排序
- ts 或 route 缺失，或 ts 为 JSON `null` → 非事件行，跳过并计入 `skipped`；
- ts 存在但非整数、负数或超出有符号 64 位范围 → 归入 route=`<invalid>` 桶
  （按无效事件处理，observed=0）；
- 输出行按 route **字节序升序**；同 route 内按该桶**最早 ts** 升序；
  `<invalid>` 桶固定排最后（若存在），只输出一行汇总。

## 输出格式（逐字节）
- 每桶一行：`<route> events=<n> bytes=<B> over=<k> max_observed=<M> verdict=<OK|OVER>`
  - n=该桶事件数（合并后）；B=observed 总和；k=observed ≥ THRESH 的事件数；
    M=该桶最大 observed；verdict=OVER 当 k>0，否则 OK；
- 末行 trailer：`skipped=<n> invalid=<0|1>`
  - invalid=1 当存在 `<invalid>` 桶，否则 0；无事件且无垃圾时输出仅 trailer；
- 不输出多余空行；行尾 LF。

## 隐性验收
判分以隐性生成流（含多字节、同 route 同 ts、乱序、垃圾行、缺/null ts、
空 headers、null header 值、`U+2028/U+2029`、int64 溢出、THRESH 边界恰等）
逐字节对照参考实现——**12 个复合场景按通过比例计分**。
