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
class CaptureSettings {
  const CaptureSettings({
    this.defaultFundId,
    this.defaultAccountId,
    this.autoConfirmThreshold = 0.75,
    this.llmFallback = false,
    this.allowedApps = const [],
  });

  final String? defaultFundId;
  final String? defaultAccountId;
  final double autoConfirmThreshold;
  final bool llmFallback;
  final List<String> allowedApps;

  factory CaptureSettings.fromJson(Map<String, dynamic> json) => CaptureSettings(
    defaultFundId: jsonStringOrNull(json['defaultFundId']),
    defaultAccountId: jsonStringOrNull(json['defaultAccountId']),
    autoConfirmThreshold: jsonDouble(json['autoConfirmThreshold'], 0.75),
    llmFallback: jsonBool(json['llmFallback']),
    allowedApps: jsonStringList(json['allowedApps']),
  );

  Map<String, dynamic> toJson() => {
    'defaultFundId': defaultFundId,
    'defaultAccountId': defaultAccountId,
    'autoConfirmThreshold': autoConfirmThreshold,
    'llmFallback': llmFallback,
    'allowedApps': allowedApps,
  };

  CaptureSettings copyWith({
    String? defaultFundId,
    String? defaultAccountId,
    double? autoConfirmThreshold,
    bool? llmFallback,
    List<String>? allowedApps,
  }) => CaptureSettings(
    defaultFundId: defaultFundId ?? this.defaultFundId,
    defaultAccountId: defaultAccountId ?? this.defaultAccountId,
    autoConfirmThreshold: autoConfirmThreshold ?? this.autoConfirmThreshold,
    llmFallback: llmFallback ?? this.llmFallback,
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
