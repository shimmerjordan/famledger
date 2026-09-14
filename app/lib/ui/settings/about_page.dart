import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/theme.dart';

/// 拿不到包信息时的兜底版本号（跟 pubspec 保持一致）。
const String kFallbackVersion = '1.0.0';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<String> _version() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber;
      return build.isEmpty ? info.version : '${info.version}+$build';
    } catch (_) {
      return kFallbackVersion;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(LedgerLayout.pagePadding),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(LedgerShapes.card + 4),
              ),
              child: Text(
                '账',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: Text('家账', style: theme.textTheme.titleLarge)),
          const SizedBox(height: 4),
          Center(
            child: FutureBuilder<String>(
              future: _version(),
              builder: (context, snapshot) => Text(
                '版本 ${snapshot.data ?? kFallbackVersion}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: LedgerLayout.groupGap),
          Text(
            '把家里的钱分成看得见的模块，每一笔支出都知道该归谁、归哪一份。'
            '自动记账把「记」的成本降到接近零，AI 把「看」的门槛降到一句话。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: LedgerLayout.groupGap),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.storage_outlined),
            title: Text('自托管'),
            subtitle: Text('数据只存在你自己的服务器上，不上传任何第三方。'),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('开源许可'),
            subtitle: Text('MIT 许可证 · 依赖各自遵循其原始许可证'),
          ),
          const ListTile(
            leading: Icon(Icons.flutter_dash),
            title: Text('技术栈'),
            subtitle: Text('Flutter · Material 3 · Node + SQLite 后端'),
          ),
        ],
      ),
    );
  }
}
