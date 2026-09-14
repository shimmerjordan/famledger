import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../platform/capture_channel.dart';
import 'capture_widgets.dart';

/// 「允许的应用」多选：可搜索，已选的排前面；已选但没装的也列出来（能取消）。
/// 返回 null 表示取消。
Future<List<String>?> showAllowedAppsSheet(
  BuildContext context, {
  required List<String> selected,
  required List<InstalledApp> installed,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => _AllowedAppsSheet(selected: selected, installed: installed),
);

class _AllowedAppsSheet extends StatefulWidget {
  const _AllowedAppsSheet({required this.selected, required this.installed});

  final List<String> selected;
  final List<InstalledApp> installed;

  @override
  State<_AllowedAppsSheet> createState() => _AllowedAppsSheetState();
}

class _AllowedAppsSheetState extends State<_AllowedAppsSheet> {
  late final Set<String> _selected = {...widget.selected};
  late final List<InstalledApp> _all = _merge();
  String _query = '';

  List<InstalledApp> _merge() {
    final byPackage = {for (final app in widget.installed) app.package: app};
    for (final pkg in widget.selected) {
      byPackage.putIfAbsent(
        pkg,
        () => InstalledApp(package: pkg, label: '${appLabelFor(pkg, const {})}（未安装）'),
      );
    }
    final list = byPackage.values.toList()
      ..sort((a, b) {
        final sa = widget.selected.contains(a.package) ? 0 : 1;
        final sb = widget.selected.contains(b.package) ? 0 : 1;
        if (sa != sb) return sa - sb;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? _all
        : _all
              .where((a) => a.label.toLowerCase().contains(q) || a.package.toLowerCase().contains(q))
              .toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LedgerLayout.pagePadding,
              0,
              LedgerLayout.pagePadding,
              LedgerLayout.itemGap,
            ),
            child: Row(
              children: [
                Expanded(child: Text('允许的应用', style: theme.textTheme.titleMedium)),
                Text('已选 ${_selected.length}', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索应用名或包名',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
          Expanded(
            child: visible.isEmpty
                ? Center(child: Text('没有匹配的应用', style: theme.textTheme.bodyMedium))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final app = visible[i];
                      return CheckboxListTile(
                        value: _selected.contains(app.package),
                        title: Text(app.label),
                        subtitle: Text(app.package, style: theme.textTheme.bodySmall),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (checked) => setState(() {
                          if (checked ?? false) {
                            _selected.add(app.package);
                          } else {
                            _selected.remove(app.package);
                          }
                        }),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(LedgerLayout.pagePadding),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected.toList()..sort()),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
