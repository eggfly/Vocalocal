// 规则测试：TextCleanup（语气词、格式）和 PhoneticGuard（发音相近校验）。用例取自真实录音。
// 运行：./tests/run.sh
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("✓ \(name)") } else { failures += 1; print("✗ \(name)  \(detail())") }
}
func cleanup(_ input: String, _ expected: String) {
    let got = TextCleanup.apply(input)
    check("cleanup: \(input)", got == expected, "得到「\(got)」，期望「\(expected)」")
}
func guardCase(_ from: String, _ to: String, _ expected: Bool, hotwords: [String] = []) {
    let r = PhoneticGuard.accept(from: from, to: to, hotwords: hotwords)
    check("guard: \(from)→\(to.isEmpty ? "(删)" : to) \(expected ? "接受" : "拦下")", r.ok == expected,
          String(format: "相似度 %.2f", r.similarity))
}

// 语气词
cleanup("然后派送和欧拉玛也打包成呃内置的服务", "然后派送和欧拉玛也打包成内置的服务")
cleanup("并且现在呢，嗯，效果是最好的", "并且现在呢，效果是最好的")
cleanup("嗯，哈士Type互联网已经有了", "哈士Type互联网已经有了")
cleanup("能确定嗯这九个问题", "能确定这九个问题")
cleanup("是吧？不能排除啊，不能确定啊，啊，不能确定。", "是吧？不能排除啊，不能确定啊，不能确定。")
cleanup("呃，写一下push到这个仓库", "写一下push到这个仓库")
cleanup("额，好吧", "好吧")
// 应该保留
cleanup("你现在能获取上下文了，很牛啊！", "你现在能获取上下文了，很牛啊！")
cleanup("测试一下啊。", "测试一下啊。")
cleanup("额度用完了", "额度用完了")
cleanup("啊。", "啊。")
cleanup("嗯", "嗯")
// 格式
cleanup("有什么 B P C 的新闻？", "有什么 BPC 的新闻？")
cleanup("内存占用只有五G B，没有达到十七G B", "内存占用只有5GB，没有达到17GB")
cleanup("四G网络", "4G网络")
cleanup("一百二十八GB的硬盘", "128GB的硬盘")
cleanup("ESP 三二上报", "ESP 三二上报")

// 发音校验：应该接受
let vocab = ["Python", "Ollama", "Vocalocal", "API", "Typeless"]
guardCase("派送", "Python", true, hotwords: vocab)
guardCase("欧拉玛", "Ollama", true, hotwords: vocab)
guardCase("考", "拷", true)
guardCase("李依晨", "李一辰", true)
guardCase("嗯", "", true)
guardCase("test flight", "TestFlight", true)
guardCase("随便数", "随便说", true)
// 应该拦下
guardCase("改低一下那个", "改高一下那个", false)
guardCase("SSD", "机械硬盘", false)
guardCase("思维", "Vocalocal", false, hotwords: vocab)
guardCase("virtual file", "Typeless", false, hotwords: vocab)
guardCase("飞书登录", "登录", false)
guardCase("push", "推送", false)
guardCase("美国的", "美国工作的", false)
guardCase("APP版", "Swift", false)

print(failures == 0 ? "\n全部通过" : "\n\(failures) 个失败")
exit(failures == 0 ? 0 : 1)
