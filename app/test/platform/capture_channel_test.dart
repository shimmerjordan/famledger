import 'package:famledger/platform/capture_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kCaptureChannelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isListenerEnabled':
          return true;
        case 'getAllowedPackages':
          return ['com.tencent.mm', 'com.eg.android.AlipayGphone'];
        case 'getInstalledApps':
          return [
            {'package': 'com.tencent.mm', 'label': '微信'},
            {'package': 'com.eg.android.AlipayGphone', 'label': '支付宝'},
          ];
        case 'notificationPermission':
          return 'denied';
        case 'deviceInfo':
          return {'manufacturer': 'Xiaomi', 'brand': 'Redmi', 'sdkInt': 33, 'debug': true};
        case 'postTestNotification':
          return true;
        case 'openAutoStartSettings':
          return 'miui_autostart';
        default:
          return null;
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Dart → Native：参数与返回值按契约映射', () async {
    final platform = MethodChannelCapturePlatform();
    addTearDown(platform.dispose);

    expect(platform.isSupported, isTrue);
    expect(await platform.isListenerEnabled(), isTrue);
    expect(await platform.getAllowedPackages(), ['com.tencent.mm', 'com.eg.android.AlipayGphone']);

    final apps = await platform.getInstalledApps();
    expect(apps.map((a) => a.label), ['微信', '支付宝']);

    expect(await platform.notificationPermission(), NotificationPermission.denied);
    final device = await platform.deviceInfo();
    expect(device.isMiui, isTrue);
    expect(device.sdkInt, 33);
    expect(device.debug, isTrue);

    await platform.setAllowedPackages(['com.unionpay']);
    expect(calls.last.method, 'setAllowedPackages');
    expect(calls.last.arguments, ['com.unionpay']);

    expect(await platform.postTestNotification('支付宝', '你有一笔35.00元的支出'), isTrue);
    expect(calls.last.arguments, {'title': '支付宝', 'text': '你有一笔35.00元的支出'});
    expect(await platform.openAutoStartSettings(), 'miui_autostart');
  });

  test('Native → Dart：onOpenCapture 进流，回调结果原样回给原生', () async {
    final handled = <String>[];
    final platform = MethodChannelCapturePlatform(
      onOpenCapture: (id) async {
        handled.add(id);
        return true;
      },
    );
    addTearDown(platform.dispose);
    final emitted = <String>[];
    platform.openCapture.listen(emitted.add);

    const codec = StandardMethodCodec();
    Object? reply;
    await messenger.handlePlatformMessage(
      kCaptureChannelName,
      codec.encodeMethodCall(const MethodCall('onOpenCapture', 'cap-1')),
      (data) => reply = data == null ? null : codec.decodeEnvelope(data),
    );
    await Future<void>.delayed(Duration.zero);
    expect(emitted, ['cap-1']);
    expect(handled, ['cap-1']);
    expect(reply, isTrue);
  });

  test('没有处理器时 onOpenCapture 回 false，让原生自己推路由', () async {
    final platform = MethodChannelCapturePlatform();
    addTearDown(platform.dispose);
    const codec = StandardMethodCodec();
    Object? reply;
    await messenger.handlePlatformMessage(
      kCaptureChannelName,
      codec.encodeMethodCall(const MethodCall('onOpenCapture', 'cap-2')),
      (data) => reply = data == null ? null : codec.decodeEnvelope(data),
    );
    expect(reply, isFalse);
  });

  test('不支持的平台一律说不', () async {
    const platform = UnsupportedCapturePlatform();
    expect(platform.isSupported, isFalse);
    expect(await platform.isListenerEnabled(), isFalse);
    expect(await platform.getAllowedPackages(), isEmpty);
    expect(await platform.notificationPermission(), NotificationPermission.notRequired);
    expect((await platform.deviceInfo()).isMiui, isFalse);
  });
}
