# 经验：在 Windows 上静态逆向 iOS IPA（ObjC + chained fixups）

- 日期：2026-10-17
- 场景：只有一个 IPA，没有源码、没有 Mac、没有 IDA，要在 Windows 上把某个功能完整还原成可移植的 ObjC 代码
- 结论：**可行**。Mach-O 的 ObjC 元数据足够还原到「方法级 + 调用序列级」，关键是把三件事做对（见下）

---

## 1. 三个必须做对的地方

### 1.1 指针是 chained fixup，不是裸地址

iOS 15+ 的二进制用 `LC_DYLD_CHAINED_FIXUPS`。直接 `struct.unpack('<Q')` 读出来的值是
`next | bind | target`，不是地址。

- 判断：load command 里有 `0x80000034`（LC_DYLD_CHAINED_FIXUPS）
- rebase 指针还原：`image_base + (raw & 0xFFFFFFFF)`，`image_base` = `__TEXT` 段的 vmaddr（通常 `0x100000000`）
- **不要**用「第一个 offset==0 的 section 的 addr」当 image_base，会错（这次就错了，类名全空）
- bind 指针（GOT 槽）要另外解析：`raw >> 63` 是 bind 位，ordinal 在低 16 位（arm64e）或低 24 位（64_OFFSET），
  再用 imports 表映射到符号名

### 1.2 ObjC 的 relative method list：方法名指向 selref，不是字符串

`flags & 0x80000000` 表示 relative。12 字节一条：`nameOffset / typesOffset / impOffset`，各自**相对本字段**。

坑：`nameOffset` 指向的是 `__objc_selrefs` 里的一格，**要先读 8 字节指针，再解引用**才是选择器字符串。

```
name  = cstr( *(int64*)(entry + 0 + nameOffset) )   // 间接！
types = cstr( entry + 4 + typesOffset )             // 直接
imp   = entry + 8 + impOffset                       // 直接
```

判断方法：把算出来的地址和 `__objc_selrefs` 段范围一比，落进去就说明要再解一层。

### 1.3 CFString 常量要解，不能只靠 strings

URL、JSON 键名、提示语大多在 `__cfstring` 里。`strings` 只能看到零散片段（比如 `%@`、`%lld`），
拿不到 `https://apis.bilin.eu.org/history/%lld` 这种完整串。

CFString 常量布局（64 位）：`isa(8) | flags(8) | cstring*(8) | length(8)`。
解 `+16` 的指针（同样是 chained fixup）再读 C 串。

---

## 2. 工具选择（Windows）

| 需求 | 用什么 | 备注 |
|---|---|---|
| 解压 IPA | `unzip` | 就是 zip |
| 反汇编 | `pip install capstone`（5.0.7） | 够用；arm64 支持完整 |
| 符号表 | 自己解析 `LC_SYMTAB` | **MinGW 的 `nm` 不认 Mach-O**（`File format not recognized`） |
| 语法自检 | `pip install tree_sitter tree_sitter_objc` | 能查括号/语句级错误，比肉眼可靠 |
| 画图 | Pillow + 微软雅黑 | 比装 matplotlib 快，控制力也够 |

`capstone` 5.x 的坑：操作数类型是 **int 枚举**，不是 `.type.name`；
要 `from capstone.arm64 import ARM64_OP_IMM` 再比较。写成 `ops[1].type.name == 'IMM'` 会
`AttributeError: 'int' object has no attribute 'name'`。

---

## 3. 网络侧的坑（这次实际踩到）

- `curl` 走 schannel 时报 `CRYPT_E_NO_REVOCATION_CHECK`：加 `--ssl-no-revoke`
- `codeload.github.com/.../tar.gz` 在 5 MB 处被截断（这次稳定停在 5228292 字节），
  `gzip -t` 报 `unexpected end of file`。**改用 `raw.githubusercontent.com` 逐文件下载**
  （`curl -sSL --ssl-no-revoke` + 并发 10），270 个源码文件 1 分钟内拉完
- `git clone` 这种 28 MB 仓库在同样网络下 3 分钟只下了 317 KB，别硬等

---

## 4. 还原顺序（有效）

1. `strings` 先找**符号名**：`-[Class method]` 这种 ObjC 方法名字符串在 `__objc_methname` 里是明文的，
   一眼就能定位功能边界（这次靠 `downgrade_*` 直接锁定 11 个方法）
2. 解析 classlist，导出目标类的**完整方法表 + 类型编码**（类型编码能看出参数个数与类型）
3. 解析 `__cfstring`，把每个方法用到的常量全部列出来 —— 通常到这一步行为已经能猜出八成
4. 反汇编关键方法，**只关心三样**：调了哪些选择器、传了哪些常量、分支条件是什么
5. 有间接调用（`blr` / 函数指针）时，扫全 `__text` 找 `b`/`bl` 的 xref，别只看 `bl`
   （这次 `downgrade_trigger_in_springboard` 全是被 `b` 尾调用的，只扫 `bl` 会得到 0 个调用点）
6. block 的 invoke 指针在 `__const` 的 block 字面量里：`isa | flags | reserved | invoke | descriptor`，
   顺着 invoke 往下读才能看到真正的业务逻辑

---

## 5. 移植时的判断

- **payload 放哪**：先看它依赖的函数是不是 `static`。是，就只能放同一个编译单元，
  不要去改 `static`（会波及所有调用点）
- **Xcode 工程**：`objectVersion = 77` + `PBXFileSystemSynchronizedRootGroup` 的工程，
  新增文件自动进编译，**不用碰 project.pbxproj**。先查这个再决定要不要手改工程文件
- **原版的明显笔误**（比如 `stringWithFormat:@"%"`）不要盲目照抄，改成意图并在文档里写明

---

## 6. 自检清单

- [ ] 每个 `@selector` 都能在 `__objc_methname` 里找到
- [ ] 每个 URL / JSON 键名 / 提示语都来自 `__cfstring` 反解，不是猜的
- [ ] 新增文件 `parsecheck.py` 0 error
- [ ] 修改的文件 error 数与上游原文件一致
- [ ] 用到的外部符号在上游源码里都存在（`grep` 到声明）
- [ ] 无法验证的部分（编译、真机）在文档里明确写出来
