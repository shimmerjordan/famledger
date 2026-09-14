/// 默认允许监听的通知来源（spec §6）。用户可在设置里增删。
///
/// Debug 构建另外允许 `com.android.shell`，供 `adb shell cmd notification post`
/// 做端到端测试（由原生侧 Task 13 注入，不写死在这里）。
const List<String> kDefaultAllowedPackages = <String>[
  'com.eg.android.AlipayGphone', // 支付宝
  'com.tencent.mm', // 微信
  'com.unionpay', // 云闪付
  ...kSmsPackagesDefault,
  ...kBankAppPackages,
];

/// 默认勾选的短信 App（系统短信 App 因厂商而异，这里只放主流四个）。
const List<String> kSmsPackagesDefault = <String>[
  'com.miui.mms', // 小米短信
  'com.android.mms', // AOSP 短信
  'com.google.android.apps.messaging', // Google 信息
  'com.samsung.android.messaging', // 三星短信
];

/// 银行自家 App：推送格式与银行短信几乎一致，共用一套解析规则。
const List<String> kBankAppPackages = <String>[
  'cmb.pb', // 招商银行
  'com.chinamworld.main', // 建设银行
  'com.icbc', // 工商银行
  'com.chinamworld.bocmbci', // 中国银行
  'com.android.bankabc', // 农业银行
  'com.bankcomm.Bankcomm', // 交通银行
  'com.yitong.mbank.psbc', // 邮储银行
  'cn.com.spdb.mobilebank.per', // 浦发银行
  'com.chinamworld.bocmbci.cmbc', // 民生银行
  'com.pingan.paces.ccms', // 平安口袋银行
];

/// iOS 的三个导入来源。
///
/// 这些**不是通知包名** —— iOS 没有通知监听，文本来自 ShareExtension、
/// 快捷指令「记一笔」或 App 内「从剪贴板导入」，由调用方把来源名填进
/// `RawNotification.packageName`。因此它们**不进** [kDefaultAllowedPackages]
/// （那是安卓「允许监听哪些 App」的列表，放进去只会在设置页多出三个假 App）。
const String kIosShareSource = 'ios.share';
const String kIosShortcutSource = 'ios.shortcut';
const String kIosClipboardSource = 'ios.clipboard';

const List<String> kIosImportSources = <String>[
  kIosShareSource,
  kIosShortcutSource,
  kIosClipboardSource,
];

/// 短信类 App：银行短信解析走 `bank_sms` 渠道。
const Set<String> kSmsPackages = <String>{
  'com.miui.mms',
  'com.android.mms',
  'com.google.android.apps.messaging',
  'com.samsung.android.messaging',
  'com.android.messaging',
  'com.huawei.message',
  'com.oppo.mms',
  'com.vivo.mms',
};

/// 一类通知来源的解析画像。
class SourceProfile {
  const SourceProfile({
    required this.id,
    required this.channel,
    required this.displayName,
    required this.packages,
    required this.baseConfidence,
    this.appTitleNames = const <String>[],
    this.titleFallbackMerchant = true,
    this.penalizeMissingMerchant = true,
    this.paymentMarkers = const <String>[],
    this.requiredMarkers = const <String>[],
  });

  /// 画像标识，与 [channel] 同名，便于日志。
  final String id;

  /// 写进流水的渠道：alipay|wechat|unionpay|bank_sms|unknown。
  final String channel;

  /// 结果通知里的中文名。
  final String displayName;

  final Set<String> packages;

  /// 该来源解析成功时的基础置信度。
  final double baseConfidence;

  /// 兜底商户时需要从标题里剥掉的 App 名。
  final List<String> appTitleNames;

  /// 没有任何商户线索时，是否可以拿标题当商户。
  final bool titleFallbackMerchant;

  /// 抽不到商户时要不要扣置信度。
  /// 通知是模板化的，抽不到商户说明没看懂；用户自己选中的文本则不一定。
  final bool penalizeMissingMerchant;

  /// 必须命中其中之一才算支付通知（微信：聊天消息全是噪声）。
  final List<String> paymentMarkers;

  /// 必须命中其中之一才像该来源的真实通知（银行短信：必须有银行/卡号标记）。
  final List<String> requiredMarkers;

  static const SourceProfile alipay = SourceProfile(
    id: 'alipay',
    channel: 'alipay',
    displayName: '支付宝',
    packages: <String>{'com.eg.android.AlipayGphone'},
    baseConfidence: 0.92,
    appTitleNames: <String>['支付宝'],
  );

  static const SourceProfile wechat = SourceProfile(
    id: 'wechat',
    channel: 'wechat',
    displayName: '微信',
    packages: <String>{'com.tencent.mm'},
    baseConfidence: 0.92,
    appTitleNames: <String>['微信支付', '微信'],
    paymentMarkers: <String>['微信支付', '收款成功', '付款成功', '微信收款', '支付成功'],
  );

  static const SourceProfile unionpay = SourceProfile(
    id: 'unionpay',
    channel: 'unionpay',
    displayName: '云闪付',
    packages: <String>{'com.unionpay'},
    baseConfidence: 0.90,
    appTitleNames: <String>['云闪付', '银联'],
  );

  static const SourceProfile bankSms = SourceProfile(
    id: 'bank_sms',
    channel: 'bank_sms',
    displayName: '银行短信',
    packages: kSmsPackages,
    baseConfidence: 0.95,
    // 标题是短信发送方（银行名），不能当商户。
    titleFallbackMerchant: false,
    requiredMarkers: <String>['银行', '信用卡', '储蓄卡', '尾号', '卡号'],
  );

  /// 银行自家 App：内容与银行短信同源（消费/入账 + 尾号 + 商户），
  /// 但标题是 App 名而不是商户，所以同样不做标题兜底。
  static const SourceProfile bankApp = SourceProfile(
    id: 'bank_app',
    channel: 'bank_app',
    displayName: '银行App',
    packages: <String>{...kBankAppPackages},
    baseConfidence: 0.95,
    titleFallbackMerchant: false,
  );

  /// iOS：用户主动分享/粘贴进来的文本。
  ///
  /// 和通知不同，这段文字是人挑的，格式五花八门（抽不到商户很正常，因此不扣分），
  /// 但「要不要记这一笔」已经由用户表过态了，所以基础置信度比通用兜底高。
  /// 三个来源共用 `share` 渠道，只是展示名不同。
  static const SourceProfile iosShare = SourceProfile(
    id: 'ios_share',
    channel: 'share',
    displayName: '分享导入',
    packages: <String>{kIosShareSource},
    baseConfidence: 0.85,
    titleFallbackMerchant: false,
    penalizeMissingMerchant: false,
  );

  static const SourceProfile iosShortcut = SourceProfile(
    id: 'ios_shortcut',
    channel: 'share',
    displayName: '快捷指令',
    packages: <String>{kIosShortcutSource},
    baseConfidence: 0.85,
    titleFallbackMerchant: false,
    penalizeMissingMerchant: false,
  );

  static const SourceProfile iosClipboard = SourceProfile(
    id: 'ios_clipboard',
    channel: 'share',
    displayName: '剪贴板',
    packages: <String>{kIosClipboardSource},
    baseConfidence: 0.85,
    titleFallbackMerchant: false,
    penalizeMissingMerchant: false,
  );

  static const SourceProfile generic = SourceProfile(
    id: 'generic',
    channel: 'unknown',
    displayName: '通知',
    packages: <String>{},
    baseConfidence: 0.60,
  );

  static const List<SourceProfile> all = <SourceProfile>[
    alipay,
    wechat,
    unionpay,
    bankSms,
    bankApp,
    iosShare,
    iosShortcut,
    iosClipboard,
  ];

  static SourceProfile forPackage(String packageName) {
    for (final profile in all) {
      if (profile.packages.contains(packageName)) return profile;
    }
    return generic;
  }

  /// 渠道 → 结果通知里的中文名。
  static String displayNameOfChannel(String channel) {
    for (final profile in all) {
      if (profile.channel == channel) return profile.displayName;
    }
    return generic.displayName;
  }

  /// 来源 → 结果通知里的中文名（同一渠道的三个 iOS 来源各有各的名字）。
  static String displayNameOfSource(String packageName) =>
      forPackage(packageName).displayName;
}
