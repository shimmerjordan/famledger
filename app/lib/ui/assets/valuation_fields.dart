import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models/models.dart';
import '../../data/repos/assets_repo.dart';
import '../add_tx/picker_field.dart';
import 'asset_widgets.dart';

/// 物品表单里「估值」这一段的状态：方式、年折率、残值、手动估值锚点、计入净资产三态。
///
/// 表单页持有它（和名称、买价那些 controller 一样活到页面销毁），[ValuationFields] 只管画。
class ValuationEditor extends ChangeNotifier {
  String method = Asset.methodAuto;
  final TextEditingController rate = TextEditingController();
  final TextEditingController residual = TextEditingController();
  final TextEditingController manualValue = TextEditingController();

  /// 手动估值那天；填了金额却没挑日子时按「今天」。
  DateTime? manualOn;
  String netWorth = Asset.netWorthAuto;

  /// 编辑时库里原来的锚点（金额、日期）；「清掉」以后就没有了。
  int? _boundCents;
  DateTime? _boundOn;

  /// 用户自己挑过估值日期：之后改金额不再替他换日子。
  bool _dayPicked = false;

  /// 动过估值设置：编辑时据此直接展开这一段。
  bool get customized =>
      method != Asset.methodAuto ||
      rate.text.trim().isNotEmpty ||
      residual.text.trim().isNotEmpty ||
      hasManual ||
      netWorth != Asset.netWorthAuto;

  bool get hasManual => manualValue.text.trim().isNotEmpty;

  /// 编辑时带出原值。只在第一次画之前调一次，不通知。
  void bind(Asset asset) {
    method = asset.valuationMethod;
    rate.text = asset.rateBp == null ? '' : bpText(asset.rateBp!);
    residual.text = asset.residualBp == null ? '' : bpText(asset.residualBp!);
    manualValue.text = asset.manualValueCents == null
        ? ''
        : Money.plain(asset.manualValueCents!).replaceAll(',', '');
    manualOn = localDate(asset.manualValueOn);
    _boundCents = asset.manualValueCents;
    _boundOn = manualOn;
    netWorth = asset.netWorth;
  }

  void setMethod(String value) {
    method = value;
    notifyListeners();
  }

  void setNetWorth(String value) {
    netWorth = value;
    notifyListeners();
  }

  void setManualOn(DateTime day) {
    manualOn = day;
    _dayPicked = true;
    notifyListeners();
  }

  void clearManual() {
    manualValue.clear();
    manualOn = null;
    _boundCents = null;
    _boundOn = null;
    _dayPicked = false;
    notifyListeners();
  }

  /// 手动估值金额改了。原来有锚点、又没自己挑日子：金额一变就当今天重新估的（日期回到「今天」），
  /// 不然新金额会被当成旧日子的值、马上按折旧往下打，「N 个月未更新」也消不掉；改回原金额，
  /// 日期也回到原来那天。
  void manualEdited() {
    if (_boundCents != null && !_dayPicked) {
      manualOn = parseMoneyField(manualValue.text) == _boundCents ? _boundOn : null;
    }
    notifyListeners();
  }

  /// 文本框改了：说明文字和「现在约」跟着变。
  void touched() => notifyListeners();

  /// 点预设：方式、年折率、残值一起填好（锁定类预设把两个参数清掉）。
  void applyPreset(ValuationPreset preset) {
    method = preset.method;
    rate.text = preset.rateBp == null ? '' : bpText(preset.rateBp!);
    residual.text = preset.residualBp == null ? '' : bpText(preset.residualBp!);
    notifyListeners();
  }

  bool matches(ValuationPreset preset) =>
      method == preset.method &&
      _bpOrNull(rate.text, 9000) == preset.rateBp &&
      _bpOrNull(residual.text, 10000) == preset.residualBp;

  /// 在当前方式下实际用哪种算法（auto 看类别）。
  String effectiveMethod(String category) =>
      method == Asset.methodAuto ? categoryValuation(category).method : method;

  /// 表单值 → 请求里的估值字段；填错给一句话。看不见的字段（不折旧时的折率和残值、
  /// 匀速折旧时的折率）不校验也不发。
  ValuationRead read({
    required String category,
    required DateTime purchasedOn,
    required DateTime today,
  }) {
    final effective = effectiveMethod(category);
    int? rateBp;
    if (effective == Asset.methodDeclining) {
      rateBp = parsePercentBp(rate.text, maxBp: 9000);
      if (rateBp == -1) return const ValuationRead.fail('年折率填 0 到 90 之间的数，例如 25');
    }
    int? residualBp;
    if (effective != Asset.methodLocked) {
      residualBp = parsePercentBp(residual.text, maxBp: 10000);
      if (residualBp == -1) {
        return const ValuationRead.fail('残值/保底填 0 到 100 之间的数，例如 10');
      }
    }
    final manual = parseMoneyField(manualValue.text);
    if (manual == -1) return const ValuationRead.fail('手动估值填得不对，例如 4000');
    final on = manual == null ? null : _day(manualOn ?? today);
    if (on != null && on.isBefore(_day(purchasedOn))) {
      return const ValuationRead.fail('估值日期不能早于买入日期');
    }
    return ValuationRead.ok(
      ValuationInput(
        method: method,
        rateBp: rateBp,
        residualBp: residualBp,
        manualValueCents: manual,
        manualValueOn: on == null ? null : Dates.isoDate(on),
        netWorth: netWorth,
      ),
    );
  }

  /// 拿表单现在的样子拼一件临时物品，给「现在约 ¥…」和说明文字用；填错的字段按没填算。
  Asset preview({
    required String category,
    required int priceCents,
    required DateTime purchasedOn,
    int? expectedDays,
    String status = Asset.statusInUse,
    required DateTime today,
  }) {
    final manual = parseMoneyField(manualValue.text);
    final hasValue = manual != null && manual >= 0;
    return Asset(
      id: 'draft',
      name: '',
      category: category,
      priceCents: priceCents,
      purchasedOn: Dates.isoDate(purchasedOn),
      expectedDays: expectedDays,
      status: status,
      valuationMethod: method,
      rateBp: _bpOrNull(rate.text, 9000),
      residualBp: _bpOrNull(residual.text, 10000),
      manualValueCents: hasValue ? manual : null,
      manualValueOn: hasValue ? Dates.isoDate(manualOn ?? today) : null,
      netWorth: netWorth,
    );
  }

  @override
  void dispose() {
    rate.dispose();
    residual.dispose();
    manualValue.dispose();
    super.dispose();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static int? _bpOrNull(String text, int maxBp) {
    final bp = parsePercentBp(text, maxBp: maxBp);
    return bp == null || bp < 0 ? null : bp;
  }
}

/// [ValuationEditor.read] 的结果：要么一份估值字段，要么一句错误。
class ValuationRead {
  const ValuationRead.ok(ValuationInput this.input) : error = null;
  const ValuationRead.fail(String this.error) : input = null;

  final ValuationInput? input;
  final String? error;
}

/// 表单里可折叠的「估值」：方式（下面一句人话）、预设、高级参数、手动估值、计入净资产三态。
class ValuationFields extends StatelessWidget {
  const ValuationFields({
    super.key,
    required this.editor,
    required this.category,
    required this.priceCents,
    required this.purchasedOn,
    required this.expectedDays,
    required this.now,
    this.status = Asset.statusInUse,
    this.netWorthSwitchOn = true,
    this.initiallyExpanded = false,
  });

  final ValuationEditor editor;
  final String category;

  /// 买价还没填对时是 null（标题下只说一句用途）。
  final int? priceCents;
  final DateTime purchasedOn;
  final int? expectedDays;
  final DateTime now;

  /// 编辑已卖出、已退役的物品时估值归零，标题下不写「现在约」。
  final String status;

  /// 家庭设置里「实物计入净资产」的总开关；关着时三态下面说一句「怎么选都暂不计入」。
  final bool netWorthSwitchOn;
  final bool initiallyExpanded;

  static const Map<String, String> methodLabels = {
    Asset.methodAuto: '跟随类别',
    Asset.methodStraight: '匀速折旧',
    Asset.methodDeclining: '每年打折',
    Asset.methodLocked: '不折旧',
  };

  Future<void> _pickManualDay(BuildContext context) async {
    final picked = await pickPastDay(
      context,
      initial: editor.manualOn ?? now,
      first: DateTime(purchasedOn.year, purchasedOn.month, purchasedOn.day),
      help: '哪天估的',
    );
    if (picked != null) editor.setManualOn(picked);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final theme = Theme.of(context);
      final cat = categoryValuation(category);
      final draft = editor.preview(
        category: category,
        priceCents: priceCents ?? 0,
        purchasedOn: purchasedOn,
        expectedDays: expectedDays,
        status: status,
        today: now,
      );
      final method = editor.effectiveMethod(category);
      final presets = presetsFor(category);
      // 卖掉、退役的估值归零（和详情页、列表一个口径），不写「现在约」。
      final headline = draft.isEnded
          ? '${status == Asset.statusSold ? '已卖出' : '已退役'}，估值归零（处置盈亏见详情）'
          : priceCents == null
          ? '按类别自动折旧，也能手动估'
          : '现在约 ${Money.format(currentValue(draft, now))}';
      final netWorthLabels = {
        Asset.netWorthAuto: '跟随类别（${cat.netWorth ? '计入' : '不计入'}）',
        Asset.netWorthInclude: '计入',
        Asset.netWorthExclude: '不计入',
      };
      return ExpansionTile(
        key: const ValueKey('asset-valuation'),
        initiallyExpanded: initiallyExpanded,
        // DESIGN.md：200ms emphasizedDecelerate，系统关了动画就瞬切。
        expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : AnimationStyle(
                duration: const Duration(milliseconds: 200),
                curve: Easing.emphasizedDecelerate,
              ),
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: LedgerLayout.pagePadding),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: const Text('估值'),
        subtitle: Text(headline, key: const ValueKey('valuation-preview')),
        children: [
          PickerField(
            label: '方式',
            topGap: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in methodLabels.entries)
                      ChoiceChip(
                        key: ValueKey('valuation-method-${entry.key}'),
                        selected: editor.method == entry.key,
                        onSelected: (_) => editor.setMethod(entry.key),
                        label: Text(entry.value),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  valuationExplain(draft),
                  key: const ValueKey('valuation-explain'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (presets.isNotEmpty)
            PickerField(
              label: '预设',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in presets)
                    ChoiceChip(
                      key: ValueKey('valuation-preset-${preset.key}'),
                      selected: editor.matches(preset),
                      onSelected: (_) => editor.applyPreset(preset),
                      label: Text(preset.label),
                    ),
                ],
              ),
            ),
          if (method != Asset.methodLocked)
            PickerField(
              label: '高级参数（选填）',
              trailing: Text('留空跟随类别', style: theme.textTheme.bodySmall),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (method == Asset.methodDeclining) ...[
                    Expanded(
                      child: TextField(
                        key: const ValueKey('valuation-rate'),
                        controller: editor.rate,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => editor.touched(),
                        decoration: InputDecoration(
                          labelText: '年折率',
                          suffixText: '%',
                          hintText: bpText(cat.rateBp),
                        ),
                      ),
                    ),
                    const SizedBox(width: LedgerLayout.itemGap),
                  ],
                  Expanded(
                    child: TextField(
                      key: const ValueKey('valuation-residual'),
                      controller: editor.residual,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => editor.touched(),
                      decoration: InputDecoration(
                        labelText: method == Asset.methodDeclining ? '保底' : '残值',
                        suffixText: '%',
                        hintText: bpText(cat.residualBp),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          PickerField(
            label: '手动估值（选填）',
            trailing: editor.hasManual
                ? TextButton(
                    key: const ValueKey('valuation-manual-clear'),
                    onPressed: editor.clearManual,
                    child: const Text('清掉'),
                  )
                : Text('填了就从那天起算', style: theme.textTheme.bodySmall),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('valuation-manual'),
                  controller: editor.manualValue,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => editor.manualEdited(),
                  decoration: const InputDecoration(prefixText: '¥ ', hintText: '例如 4000'),
                ),
                if (editor.hasManual) ...[
                  const SizedBox(height: 8),
                  KeyedSubtree(
                    key: const ValueKey('valuation-manual-on'),
                    child: DayButton(
                      day: editor.manualOn ?? now,
                      onPressed: () => _pickManualDay(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          PickerField(
            label: '计入净资产',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in netWorthLabels.entries)
                      ChoiceChip(
                        key: ValueKey('valuation-networth-${entry.key}'),
                        selected: editor.netWorth == entry.key,
                        onSelected: (_) => editor.setNetWorth(entry.key),
                        label: Text(entry.value),
                      ),
                  ],
                ),
                if (!netWorthSwitchOn) ...[
                  const SizedBox(height: 8),
                  Text(
                    '总开关「实物计入净资产」关着，这里怎么选都暂不计入；管理员可以在资产页顶上的净资产里打开。',
                    key: const ValueKey('valuation-networth-switch-off'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: LedgerLayout.itemGap),
        ],
      );
    },
  );
}
