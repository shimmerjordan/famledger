import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/perks/quota_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuotaEditor', () {
    test('预设：从已有额度认出是哪一种', () {
      expect(QuotaEditor().preset, QuotaPreset.unlimited);
      expect(QuotaEditor(const [PerkQuota('month', 4)]).preset, QuotaPreset.monthly);
      expect(QuotaEditor(const [PerkQuota('year', 6), PerkQuota('month', 2)]).preset, QuotaPreset.yearly);
      expect(QuotaEditor(const [PerkQuota('term', 1)]).preset, QuotaPreset.termOnce);
      expect(QuotaEditor(const [PerkQuota('total', 1)]).preset, QuotaPreset.once);
      expect(QuotaEditor(const [PerkQuota('term', 2)]).preset, QuotaPreset.custom);
      expect(QuotaEditor(const [PerkQuota('week', 2)]).preset, QuotaPreset.custom);
      expect(QuotaEditor(const [PerkQuota('week', 2)]).extraStart, 0, reason: '自定义时「高级」里列出全部');
      expect(QuotaEditor(const [PerkQuota('month', 2)]).extraStart, 1);
    });

    test('点预设：每月 ↔ 每年保留次数；会籍期 / 一次性固定 1 次；不限次清空；不动叠加的上限', () {
      final q = QuotaEditor();
      q.applyPreset(QuotaPreset.monthly);
      expect(q.read().quota, const [PerkQuota('month', 1)]);
      q.rows.first.count.text = '4';
      q.applyPreset(QuotaPreset.yearly);
      expect(q.read().quota, const [PerkQuota('year', 4)]);
      q.addExtra();
      q.rows[1].count.text = '2';
      expect(q.read().quota, const [PerkQuota('year', 4), PerkQuota('month', 2)], reason: '叠加的周期取第一个没用过的');
      q.applyPreset(QuotaPreset.termOnce);
      expect(q.read().quota, const [PerkQuota('term', 1), PerkQuota('month', 2)]);
      q.applyPreset(QuotaPreset.monthly);
      expect(q.read().quota, const [PerkQuota('month', 1)], reason: '和叠加的那条同周期：那条拿掉，不留两条每月');
      q.applyPreset(QuotaPreset.unlimited);
      expect(q.read().quota, isEmpty);
      expect(q.canAddExtra, isFalse, reason: '不限次时没有「另外」可叠加');
    });

    test('最多 3 条；填错的次数、重复的周期给一句话', () {
      final q = QuotaEditor(const [PerkQuota('year', 6)]);
      q.addExtra();
      q.addExtra();
      expect(q.rows, hasLength(3));
      expect(q.canAddExtra, isFalse);
      q.addExtra();
      expect(q.rows, hasLength(3));

      q.rows[1].count.text = '';
      expect(q.read().error, '次数填 1 到 9999 的整数');
      q.rows[1].count.text = '0';
      expect(q.read().error, '次数填 1 到 9999 的整数');
      q.rows[1].count.text = 'abc';
      expect(q.read().error, '次数填 1 到 9999 的整数');
      q.rows[1].count.text = '10000';
      expect(q.read().error, '次数填 1 到 9999 的整数');
      q.rows[1].count.text = '2';
      q.rows[2].count.text = '1';
      q.setPeriod(2, 'month');
      expect(q.read().error, '同一个周期只能写一条上限');
      q.removeAt(2);
      expect(q.read().quota, const [PerkQuota('year', 6), PerkQuota('month', 2)]);
    });
  });
}
