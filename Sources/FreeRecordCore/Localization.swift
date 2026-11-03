import Foundation

// 用户可见文案的本地化入口。约定：key 就是中文原文，英文在包内
// Contents/Resources/en.lproj/Localizable.strings 里给（由 scripts/build.sh 从 Resources/ 拷进去）。
// 查不到词条时显示 key 本身，也就是中文 —— 漏翻译只会退回中文，不会出现空白或键名。
// 中文系统的 Localizable.strings 是空的，同样靠这条退路。
//
// SwiftUI 的 Text("中文") / Button("中文") / .help("中文") 这类接受 LocalizedStringKey 的位置
// 自己就会走同一张表，不需要包；只有 AppKit 与程序化赋值需要显式调用 L / LF。

/// 取一条用户可见文案。
public func L(_ key: String) -> String {
    NSLocalizedString(key, value: key, comment: "")
}

/// 带占位符的文案：key 里按参数类型写 %lld / %@ / %.1f，参数按顺序填。
public func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// App 在当前语言下的显示名，和 Finder / Dock / 关于面板 / 系统设置列表用的是同一个值
/// （取自各 .lproj/InfoPlist.strings 的 CFBundleDisplayName）。界面里提到"本 App"的名字都用它，
/// 免得代码里再写死一份中文名跟系统侧对不上。
public var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FreeRecord"
}
