//
//  RouteRules.swift
//  全能AI - 自动路由规则表（唯一数据源）
//
//  ============================================================
//  这份文件是 `原型/lib/route-rules.js` 的 Swift 侧实现。
//  两者必须逐字一致 —— 任何一边加词、删词、调顺序都要同步另一边，
//  否则「原型判得对、App 判得错」，而这种错只会在用户实际用的时候
//  才暴露出来。
//
//  校验方式（改完任一侧都跑一遍）：
//      python 实测/check-routes.py
//  它会把 Swift 里的词表解析出来，跟 route-rules.js 逐词比对。
//
//  判定产出是三元组，不是三个独立选择器：
//      能力域（domain） + 人格（persona） + 说话模式（mode）
//  用户说「帮我破解这个 ipa」，一次判出：移动端 · omni · rev。
//
//  打分规则：命中词的字符长度即权重。所以「dylib注入」压过单纯的
//  「注入」，「sql注入」压过「注入」。空格不敏感 —— 比对时会压掉
//  全部空白，因此「sql注入」和「sql 注入」是同一个信号，
//  词表只写一种形态即可。
//
//  为什么词表按 domain 分组、而不是拍平成一个 [词: 结果] 字典：
//    同一个词可能出现在多个域里（比如「注入」既在移动端也在 Web），
//    拍平会互相覆盖。分组结构天然保留「每个域各自取最高分词」的语义，
//    跟原型的打分循环一一对应。
//  ============================================================
//

import Foundation

// MARK: - 单条规则

/// 一条路由规则：一个能力域 + 该域默认用的人格和说话模式 + 触发词表。
struct RouteRule {
    let domain: String
    let persona: String
    let mode: String
    let words: [String]
}

// MARK: - 规则表

enum RouteRules {

    /// 主规则表。20 条，与技能页的 20 个能力域一一对齐。
    ///
    /// 顺序有意义：`routeOf` 打分后按分数稳定排序，分数相同时
    /// 靠前的域先被判中。所以「移动端」必须在「逆向与二进制」前面 ——
    /// ipa / dylib 这类词两域都能沾边，移动端更具体。
    static let all: [RouteRule] = [
        RouteRule(
            domain: "移动端",
            persona: "omni",
            mode: "rev",
            words: [
                "ipa", "dylib", "deb", "tweak", "theos", "xposed",
                "frida", "apk", "aab", "dex", "jadx", "apktool",
                "重打包", "重签名", "签名校验", "越狱", "root检测", "ssl pinning",
                "砸壳", "脱壳", "注入", "hook", "bundle", "bundleid",
                "monkeydev", "altstore", "trollstore"
            ]
        ),
        RouteRule(
            domain: "逆向与二进制",
            persona: "jeli",
            mode: "rev",
            words: [
                "逆向", "反编译", "反汇编", "ida", "ghidra", "radare2",
                "rizin", "hoopper", "mach-o", "macho", "elf", "pe文件",
                "固件", "混淆", "去混淆", "算法还原", "校验逻辑", "license",
                "卡密", "注册机", "keygen", "patch", "补丁", "字节",
                "汇编", "arm64", "x86", "静态分析", "xref", "符号表"
            ]
        ),
        RouteRule(
            domain: "Pwn 与漏洞利用",
            persona: "seagull",
            mode: "sec",
            words: [
                "pwn", "rop", "栈溢出", "堆溢出", "uaf", "double free",
                "格式化字符串", "shellcode", "溢出", "利用链", "exploit", "ret2libc",
                "gadget", "tcache", "fastbin", "one_gadget", "pwntools"
            ]
        ),
        RouteRule(
            domain: "游戏与运行时",
            persona: "seagull",
            mode: "game",
            words: [
                "外挂", "透视", "自瞄", "内存修改", "内存读写", "指针链",
                "基址", "il2cpp", "unity", "unreal", "w2s", "world to screen",
                "esp", "aimbot", "修改器", "数值搜索", "偏移", "ce",
                "cheat engine"
            ]
        ),
        RouteRule(
            domain: "Web 与 API",
            persona: "seagull",
            mode: "sec",
            words: [
                "sql注入", "sqli", "xss", "ssrf", "ssti", "xxe",
                "反序列化", "文件上传", "lfi", "rfi", "rce", "jwt",
                "oauth", "graphql", "请求走私", "原型链", "cors", "csrf",
                "idor", "越权", "逻辑漏洞", "web", "api", "接口"
            ]
        ),
        RouteRule(
            domain: "侦察与测绘",
            persona: "seagull",
            mode: "sec",
            words: [
                "子域", "端口扫描", "指纹", "目录扫描", "资产测绘", "osint",
                "信息收集", "侦察", "nmap", "fofa", "hunter", "shodan",
                "c段", "旁站", "cdn", "waf识别"
            ]
        ),
        RouteRule(
            domain: "域与 Windows 内网",
            persona: "seagull",
            mode: "sec",
            words: [
                "域渗透", "kerberos", "bloodhound", "委派", "票据", "ntlm",
                "smb", "ldap", "组策略", "横向移动", "mimikatz", "dcsync",
                "活动目录", "ad域", "pth", "hash传递", "金银票据"
            ]
        ),
        RouteRule(
            domain: "Linux 提权",
            persona: "seagull",
            mode: "sec",
            words: [
                "提权", "suid", "sudo", "capabilities", "cron", "内核漏洞",
                "docker逃逸", "脏牛", "linux提权", "权限提升", "rootkit"
            ]
        ),
        RouteRule(
            domain: "云与容器",
            persona: "seagull",
            mode: "sec",
            words: [
                "aws", "azure", "gcp", "阿里云", "腾讯云", "iam",
                "s3", "oss", "元数据", "k8s", "kubernetes", "容器逃逸",
                "serverless", "ci/cd", "terraform", "云安全"
            ]
        ),
        RouteRule(
            domain: "路由器与中转站",
            persona: "seagull",
            mode: "dev",
            words: [
                "路由器", "openwrt", "中转站", "relay", "airelay", "uhttpd",
                "dropbear", "opkg", "mt7621", "redmi", "ac2100", "软路由",
                "旁路由", "拨号", "ddns", "zerotier", "tailscale"
            ]
        ),
        RouteRule(
            domain: "免杀与对抗",
            persona: "omni",
            mode: "rev",
            words: [
                "免杀", "bypass av", "edr", "amsi", "etw", "unhook",
                "syscall", "进程注入", "dll劫持", "shellcode加载", "加壳", "花指令",
                "反调试", "反虚拟机", "反沙箱", "过检测"
            ]
        ),
        RouteRule(
            domain: "样本分析",
            persona: "jeli",
            mode: "rev",
            words: [
                "样本", "木马", "病毒", "勒索", "c2", "ioc",
                "yara", "沙箱", "行为分析", "配置提取", "恶意代码", "后门",
                "远控", "rat"
            ]
        ),
        RouteRule(
            domain: "取证与内存",
            persona: "jeli",
            mode: "dev",
            words: [
                "取证", "内存镜像", "volatility", "pcap", "流量分析", "时间线",
                "磁盘取证", "注册表", "evtx", "内存dump", "crash dump", "崩溃分析"
            ]
        ),
        RouteRule(
            domain: "协议分析",
            persona: "jeli",
            mode: "dev",
            words: [
                "协议逆向", "自定义协议", "抓包", "分帧", "protobuf", "websocket",
                "grpc", "重放", "tcp", "udp", "mqtt", "串口协议",
                "私有协议"
            ]
        ),
        RouteRule(
            domain: "口令与哈希",
            persona: "seagull",
            mode: "plain",
            words: [
                "口令", "密码破解", "哈希", "爆破", "字典", "hashcat",
                "john", "彩虹表", "nthash", "弱口令", "撞库", "kerberoast",
                "asrep", "离线破解"
            ]
        ),
        RouteRule(
            domain: "数据渗出与 C2",
            persona: "omni",
            mode: "rev",
            words: [
                "c2服务器", "外带", "隧道", "dnscat", "icmp隧道", "隐蔽信道",
                "隐写", "域前置", "beacon", "反弹shell", "端口转发", "socks代理"
            ]
        ),
        RouteRule(
            domain: "社工与投递",
            persona: "omni",
            mode: "rev",
            words: [
                "钓鱼", "社工", "话术", "投递", "诱导", "凭据收割",
                "水坑", "鱼叉", "伪装页面"
            ]
        ),
        RouteRule(
            domain: "漏洞情报",
            persona: "seagull",
            mode: "plain",
            words: [
                "cve", "n-day", "0day", "1day", "补丁差分", "漏洞库",
                "exp编写", "poc", "漏洞复现", "影响范围", "版本比对"
            ]
        ),
        RouteRule(
            domain: "靶场与环境",
            persona: "seagull",
            mode: "dev",
            words: [
                "靶场", "复现环境", "av靶场", "pwn靶场", "云靶场", "演练平台",
                "vulhub", "docker compose"
            ]
        ),
        RouteRule(
            domain: "方法论与报告",
            persona: "s",
            mode: "dev",
            words: [
                "威胁建模", "渗透报告", "渗透测试报告", "写报告", "出报告", "报告模板",
                "定级", "评级", "漏洞定级", "cvss", "stride", "att&ck",
                "测试标准", "src", "赏金", "复现步骤", "风险评估", "加固建议",
                "攻击树", "信任边界", "数据流图", "整改"
            ]
        ),
    ]

    /// 一个技术域都没命中时的泛化兜底。
    /// 只用来判「这是写代码的活还是问答的活」，不承担精确域判定的职责。
    static let fallback: [RouteRule] = [
        RouteRule(
            domain: "逆向与二进制",
            persona: "sol",
            mode: "dev",
            words: [
                "写代码", "实现", "改一下", "重构", "编译", "报错",
                "脚本", "函数", "接口", "调试", "跑一下"
            ]
        ),
        RouteRule(
            domain: "方法论与报告",
            persona: "codex",
            mode: "auto",
            words: [
                "查一下", "是什么", "为什么", "怎么", "区别", "原理",
                "介绍一下", "解释"
            ]
        ),
    ]

}

// MARK: - 人名映射

/// 人格显示名。原型里这张表在 `index.html` 的 `PERSONAS`，
/// 这里只取判定要用到的 `id → name`，不搬描述和图标。
enum RoutePersona {
    static let names: [String: String] = [
        "seagull": "实战全能",
        "jeli": "深度逆向",
        "sol": "极速直出",
        "omega": "CTF强攻",
        "codex": "轻量编码",
        "s": "规则路由",
        "sandbox": "沙盒隔离",
        "omni": "全能执行",
        "auto": "自动",
    ]

    /// 判不出名字时回落 id 本身 —— 比显示空字符串强。
    static func name(_ id: String) -> String { names[id] ?? id }
}

/// 说话模式显示名。来源同上（`index.html` 的 `MODES`）。
enum RouteMode {
    static let names: [String: String] = [
        "auto": "自动模式",
        "plain": "简洁模式",
        "dev": "开发者模式",
        "rev": "逆向专家模式",
        "sec": "安全研究模式",
        "game": "游戏修改模式",
        "inject": "注入模式",
    ]

    static func name(_ id: String) -> String { names[id] ?? id }
}
