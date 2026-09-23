import 'json_utils.dart';

/// 家庭级设置（`GET /settings`）。
class Settings {
  const Settings({
    this.name = '',
    this.currency = 'CNY',
    this.capture = const CaptureSettings(),
    this.ui = const UiSettings(),
  });

  final String name;
  final String currency;
  final CaptureSettings capture;
  final UiSettings ui;

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    name: jsonString(json['name']),
    currency: jsonString(json['currency'], 'CNY'),
    capture: CaptureSettings.fromJson(jsonMap(json['capture'])),
    ui: UiSettings.fromJson(jsonMap(json['ui'])),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'currency': currency,
    'capture': capture.toJson(),
    'ui': ui.toJson(),
  };

  Settings copyWith({
    String? name,
    String? currency,
    CaptureSettings? capture,
    UiSettings? ui,
  }) => Settings(
    name: name ?? this.name,
    currency: currency ?? this.currency,
    capture: capture ?? this.capture,
    ui: ui ?? this.ui,
  );
}

/// 自动记账设置。`allowedApps` 服务端只是存着，真正生效在设备上。
///
/// [aiTrigger] 是 `off|manual|auto` 三选一的字符串，与 `lib/capture` 的
/// `AiTrigger` 枚举一一对应——这层刻意只存字符串（跟 `defaultFundId` 这类
/// 字段一样是「服务端 JSON 的形状」），真正转成枚举是
/// `platform/capture_adapters.dart` 这个适配层的活，`lib/data` 不反过来
/// 依赖 `lib/capture`。
class CaptureSettings {
  const CaptureSettings({
    this.defaultFundId,
    this.defaultAccountId,
    this.autoConfirmThreshold = 0.75,
    this.aiTrigger = 'off',
    this.aiAutoConfirm = false,
    this.aiProviderId,
    this.allowedApps = const [],
  });

  final String? defaultFundId;
  final String? defaultAccountId;
  final double autoConfirmThreshold;

  /// off|manual|auto。
  final String aiTrigger;

  /// AI 给出的结果能不能像本地模型一样直接自动入账。
  final bool aiAutoConfirm;

  /// 记账兜底专用的 AI 渠道；null = 跟聊天/月报一样用默认渠道。
  final String? aiProviderId;

  final List<String> allowedApps;

  factory CaptureSettings.fromJson(Map<String, dynamic> json) => CaptureSettings(
    defaultFundId: jsonStringOrNull(json['defaultFundId']),
    defaultAccountId: jsonStringOrNull(json['defaultAccountId']),
    autoConfirmThreshold: jsonDouble(json['autoConfirmThreshold'], 0.75),
    aiTrigger: jsonString(json['aiTrigger'], 'off'),
    aiAutoConfirm: jsonBool(json['aiAutoConfirm']),
    aiProviderId: jsonStringOrNull(json['aiProviderId']),
    allowedApps: jsonStringList(json['allowedApps']),
  );

  Map<String, dynamic> toJson() => {
    'defaultFundId': defaultFundId,
    'defaultAccountId': defaultAccountId,
    'autoConfirmThreshold': autoConfirmThreshold,
    'aiTrigger': aiTrigger,
    'aiAutoConfirm': aiAutoConfirm,
    'aiProviderId': aiProviderId,
    'allowedApps': allowedApps,
  };

  CaptureSettings copyWith({
    String? defaultFundId,
    String? defaultAccountId,
    double? autoConfirmThreshold,
    String? aiTrigger,
    bool? aiAutoConfirm,
    String? aiProviderId,
    List<String>? allowedApps,
  }) => CaptureSettings(
    defaultFundId: defaultFundId ?? this.defaultFundId,
    defaultAccountId: defaultAccountId ?? this.defaultAccountId,
    autoConfirmThreshold: autoConfirmThreshold ?? this.autoConfirmThreshold,
    aiTrigger: aiTrigger ?? this.aiTrigger,
    aiAutoConfirm: aiAutoConfirm ?? this.aiAutoConfirm,
    aiProviderId: aiProviderId ?? this.aiProviderId,
    allowedApps: allowedApps ?? this.allowedApps,
  );
}

class UiSettings {
  const UiSettings({this.firstDayOfMonth = 1});

  /// 月账单从每月第几天开始（工资日不是 1 号的家庭会改）。
  final int firstDayOfMonth;

  factory UiSettings.fromJson(Map<String, dynamic> json) =>
      UiSettings(firstDayOfMonth: jsonInt(json['firstDayOfMonth'], 1));

  Map<String, dynamic> toJson() => {'firstDayOfMonth': firstDayOfMonth};
}
