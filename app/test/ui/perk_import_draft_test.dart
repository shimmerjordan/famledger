import 'dart:convert';

import 'package:famledger/data/models/models.dart';
import 'package:famledger/ui/perk_import/perk_import_draft.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perk_import_fixtures.dart';

// PerkImportDraft（spec §6「预览」、§8「PerkImportDraft：勾选联动、批量操作、ambiguous 拦截、生成的提交体」）。纯逻辑，不起界面。

PerkImportDraft vip() => PerkImportDraft.fromJson(vip88Draft(), clientId: 'cid-1');
PerkImportDraft order() => PerkImportDraft.fromJson(orderDraft(), clientId: 'cid-2');

Map<String, dynamic> itemOf(Map<String, dynamic> body, String list, String key) =>
    (body[list] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['key'] == key);

void main() {
  test('树：平台 → 会员 → 权益（N 选 1 带选项）；只当领取平台用的不进树、进映射视图', () {
    final d = vip();
    expect(d.rootPlatforms.map((p) => p.key), ['p1']);
    expect(d.membershipsOf(d.node('p1')!).map((m) => m.key), ['m1']);
    expect(d.benefitsOf('key:m1').map((b) => b.name), ['优酷视频年卡', '饿了么超级会员年卡', '88 折购物券', '三选一']);
    expect(d.optionsOf(d.node('b7')!).map((b) => b.key), ['b4', 'b5', 'b6']);
    expect(d.claimRows.map((r) => [r.node.key, r.mode, r.benefits.length]), [
      ['p2', ClaimMode.create, 1],
      ['p3', ClaimMode.create, 1],
      ['p4', ClaimMode.create, 1],
      ['p5', ClaimMode.create, 1],
      ['p6', ClaimMode.create, 1],
    ]);
    expect(d.unowned, isEmpty);
    expect(d.sourceText, vip88Source);
    expect(d.includedCount, 14);
    expect(d.canSubmit, isTrue);
  });

  test('勾选联动：取消平台 → 卡和权益都取消；勾一个选项 → 新建的「N 选 1」和卡跟着勾上，并入已有的平台不跟', () {
    final d = vip();
    d.setChecked('p1', false);
    expect(d.all.where((n) => n.t != ImportNode.platform || n.key == 'p1').every((n) => !n.checked), isTrue);
    d.setChecked('b4', true);
    expect([d.node('b4')!.checked, d.node('b7')!.checked, d.node('m1')!.checked], [true, true, true]);
    expect(d.node('p1')!.checked, isFalse, reason: '淘宝是并入已有的，不用跟着勾');
    expect(d.node('b5')!.checked, isFalse, reason: '兄弟选项不动');
    // 卡引用一个没勾、并入已有的平台：提交体直接引用那个已有平台
    final body = d.toApplyBody();
    expect(itemOf(body, 'platforms', 'p1')['action'], 'skip');
    expect((itemOf(body, 'memberships', 'm1')['fields'] as Map)['platform'], 'id:tb');
  });

  test('只当领取平台用的平台跟着引用它的权益走：都不导了、改去别处领了它也不导（不在树里，免得导进去看不见的空平台）', () {
    final d = vip();
    d.setChecked('b2', false);
    expect(d.node('p3')!.checked, isFalse, reason: '饿了么只有 b2 在用');
    expect(itemOf(d.toApplyBody(), 'platforms', 'p3')['action'], 'skip');
    d.setChecked('b2', true);
    expect(d.node('p3')!.checked, isTrue, reason: '权益勾回来，平台跟着回来');
    d.setField('b1', 'claimPlatform', 'id:yk');
    expect(d.node('p2')!.checked, isFalse, reason: '改去已有的「优酷」领，补建的「优酷视频」没人用了');
    d.setChecked('m1', false);
    expect(d.includedCount, 1, reason: '整张卡都不导：只剩并入已有的淘宝（它在树里，自己能取消）');

    final json = vip88Draft();
    (json['platforms'] as List).add(importNode('p7', 'platform', {'name': '某停车', 'kind': 'other'}, implied: true));
    (json['benefits'] as List).add(importNode('b9', 'benefit', {'membership': null, 'parent': null, 'name': '免费停车', 'claimPlatform': 'key:p7', 'quota': <Object>[]}, checked: false));
    final e = PerkImportDraft.fromJson(json);
    expect(e.node('p7')!.checked, isFalse, reason: '唯一引用它的是没归属、默认不勾的权益');
    e.batchMoveTo(['b9'], 'key:m1');
    expect(e.node('p7')!.checked, isTrue, reason: '权益归了卡、勾上了，领取平台跟着勾上');
  });

  test('映射视图：并入… 写成 merge + 目标；就是会员本平台 → 权益的领取平台写 null、那个平台不导；全部确认让「待确认」消失', () {
    final d = vip();
    d.node('b1')!
      ..badges.add('claim_unsure')
      ..unverified.add('claimPlatformId');
    d.mapClaim('p2', ClaimMode.mergeInto, targetId: 'yk');
    expect(d.claimModeOf(d.node('p2')!), ClaimMode.mergeInto);
    expect(d.node('p2')!.badges, isNot(contains('maybe_dup')), reason: '选过就不再「可能重复」（Review ㉔）');
    expect(d.node('b1')!.badges, isNot(contains('claim_unsure')), reason: '选了映射就算确认过');
    expect(d.node('b1')!.unverified, isEmpty);
    d.mapClaim('p3', ClaimMode.self);
    final body = d.toApplyBody();
    expect(itemOf(body, 'platforms', 'p2'), containsPair('action', 'merge'));
    expect(itemOf(body, 'platforms', 'p2')['targetId'], 'yk');
    expect(itemOf(body, 'platforms', 'p3')['action'], 'skip');
    expect((itemOf(body, 'benefits', 'b2')['fields'] as Map)['claimPlatform'], isNull);
    expect((itemOf(body, 'benefits', 'b1')['fields'] as Map)['claimPlatform'], 'key:p2');
    expect(d.includedCount, 13, reason: '会员本平台那个不算进导入项');

    d.mapClaim('p3', ClaimMode.create);
    expect(itemOf(d.toApplyBody(), 'platforms', 'p3')['action'], 'create');
    d.node('b2')!.badges.add('claim_unsure');
    d.confirmAllClaims();
    expect(d.benefits.any((b) => b.badges.contains('claim_unsure')), isFalse);
  });

  test('批量：移到另一张卡（从未归属挪出来就勾上，选项跟着走）、设周期（跳过选项）、设价值、设领取平台、取消勾选', () {
    final json = vip88Draft();
    (json['benefits'] as List).add(importNode('b9', 'benefit', {'membership': null, 'parent': null, 'name': '免费停车', 'quota': <Object>[]}, checked: false, badges: const ['missing']));
    final d = PerkImportDraft.fromJson(json);
    expect(d.unowned.map((b) => b.key), ['b9']);
    expect(d.blockers, isEmpty, reason: '未归属默认不勾，不挡导入');
    d.batchMoveTo(['b9', 'b7'], 'id:old-card');
    expect([d.node('b9')!.checked, d.node('b9')!.fields['membership']], [true, 'id:old-card']);
    expect(d.optionsOf(d.node('b7')!).every((o) => o.fields['membership'] == 'id:old-card'), isTrue);
    expect(d.existingCardRefs, ['id:old-card']);
    d.batchQuota(['b1', 'b4'], const [PerkQuota('year', 2)]);
    expect(d.node('b1')!.fields['quota'], [{'p': 'year', 'n': 2}]);
    expect(d.node('b4')!.fields['quota'], isEmpty, reason: '选项不单独设额度');
    d.batchFaceValue(['b3'], 500);
    expect(d.node('b3')!.fields['faceValueCents'], 500);
    d.batchClaimPlatform(['b3'], 'key:p3');
    expect(d.node('b3')!.fields['claimPlatform'], 'key:p3');
    d.batchUncheck(['b7']);
    expect([d.node('b7')!.checked, d.node('b4')!.checked], [false, false]);
  });

  test('拦截：同名多张卡没选、勾着却缺必填项；选定 / 补上 / 取消勾选就放行', () {
    final json = vip88Draft();
    final m = (json['memberships'] as List).first as Map<String, dynamic>;
    m['action'] = 'pick';
    m['badges'] = ['ambiguous'];
    m['match'] = {
      'kind': 'ambiguous',
      'candidates': [
        {'id': 'c1', 'name': '88VIP', 'memberId': 'dad'},
        {'id': 'c2', 'name': '88VIP', 'memberId': 'mom'},
      ],
    };
    final d = PerkImportDraft.fromJson(json);
    expect(d.blockers.map((b) => b.reason), ['「88VIP」有同名的好几张，选一张更新或新建']);
    expect(d.canSubmit, isFalse);
    expect(d.countOf(ImportFilter.attention), 2, reason: '同名要选的这张 + 可能重复的优酷视频');
    d.pickMembership('m1', 'c2');
    expect([d.node('m1')!.action, d.node('m1')!.targetId], ['update', 'c2']);
    expect(d.canSubmit, isTrue);

    final o = order();
    o.setField('i1', 'priceCents', null);
    expect(o.blockers.single.reason, '「iPhone 16 Pro 256GB」缺价格');
    o.setField('i1', 'priceCents', 899900);
    o.setField('i1', 'purchasedOn', null);
    expect(o.blockers.single.reason, contains('缺购买日期'));
    o.setChecked('i1', false);
    expect(o.blockers, isEmpty);
    expect(o.canSubmit, isFalse, reason: '一项都没勾也不能导');
  });

  test('提交体：物品预设换成估值字段、关联 / 记账 / 不记账三种；更新只带勾了的差异；clientId 在草稿活着时不变', () {
    final o = order();
    var body = o.toApplyBody();
    expect(body['clientId'], 'cid-2');
    expect(body['importId'], 'imp-order');
    var item = itemOf(body, 'items', 'i1');
    expect(item['action'], 'create');
    expect(item['fields'], {
      'name': 'iPhone 16 Pro 256GB',
      'category': 'digital',
      'priceCents': 899900,
      'purchasedOn': '2026-09-20',
      'valuationMethod': 'declining',
      'rateBp': 2000,
      'residualBp': 1000,
    });
    expect(item['linkTransactionId'], 'tx-phone');
    expect(item.containsKey('recordTransaction'), isFalse);

    o.setLink('i1', ItemLink.record);
    o.setField('i1', 'netWorth', Asset.netWorthExclude);
    item = itemOf(o.toApplyBody(), 'items', 'i1');
    expect(item['recordTransaction'], <String, dynamic>{});
    expect(item.containsKey('linkTransactionId'), isFalse);
    expect((item['fields'] as Map)['netWorth'], 'exclude');
    o.setLink('i1', ItemLink.none);
    item = itemOf(o.toApplyBody(), 'items', 'i1');
    expect([item.containsKey('recordTransaction'), item.containsKey('linkTransactionId')], [false, false]);
    expect(o.toApplyBody()['clientId'], 'cid-2', reason: '重试沿用同一个 clientId');

    final json = vip88Draft();
    final m = (json['memberships'] as List).first as Map<String, dynamic>;
    m['action'] = 'update';
    m['targetId'] = 'old-vip';
    m['diff'] = [
      {'field': 'expiresOn', 'old': '2026-06-30', 'new': '2026-12-31', 'take': true},
      {'field': 'feeCents', 'old': 9900, 'new': 8800, 'take': false},
    ];
    final d = PerkImportDraft.fromJson(json);
    d.setDiffTake('m1', 'feeCents', true);
    d.setDiffTake('m1', 'expiresOn', false);
    body = d.toApplyBody();
    expect(itemOf(body, 'memberships', 'm1'), containsPair('targetId', 'old-vip'));
    expect(itemOf(body, 'memberships', 'm1')['take'], ['feeCents']);
    expect(itemOf(body, 'benefits', 'b1')['ev'], '优酷视频年卡，开通后去优酷 App「我的-会员中心」领取');
  });

  test('改字段就算确认过：unverified 拿掉、领取平台待确认消失；导入失败的错误标到节点上，改了就清掉', () {
    final d = vip();
    d.node('m1')!.unverified.add('expiresOn');
    d.node('b1')!
      ..unverified.add('claimPlatformId')
      ..badges.add('claim_unsure');
    d.setField('m1', 'expiresOn', '2027-01-31');
    d.setField('b1', 'claimPlatform', 'id:yk');
    expect(d.node('m1')!.unverified, isEmpty);
    expect([d.node('b1')!.unverified, d.node('b1')!.badges], [isEmpty, isEmpty]);

    d.setErrors([
      {'key': 'b2', 'field': 'membership', 'message': '会员卡没有导入'},
    ]);
    expect([d.errorOf('b2'), d.errorFieldOf('b2')], ['会员卡没有导入', 'membership']);
    expect(d.countOf(ImportFilter.attention), 2, reason: '出错的这项 + 可能重复的优酷视频');
    d.setField('b2', 'name', '饿了么超级会员');
    expect(d.errorOf('b2'), isNull);
  });

  test('筛选计数：全部 / 需确认 / 新建 / 更新 / 未勾选', () {
    final d = vip();
    expect(d.countOf(ImportFilter.all), 14);
    expect(d.countOf(ImportFilter.attention), 1, reason: '优酷视频可能重复');
    expect(d.countOf(ImportFilter.update), 1, reason: '淘宝并入');
    expect(d.countOf(ImportFilter.create), 13);
    d.setChecked('b3', false);
    expect(d.countOf(ImportFilter.unchecked), 1);
    expect(d.matches(d.node('b3')!, ImportFilter.create), isFalse);
  });

  test('更新已有的（Review ①⑨⑳）：表单改字段、批量设价值 / 周期 / 领取平台、映射视图都写进 take，差异里是改后的值；改过又取消勾就不写', () {
    final d = PerkImportDraft.fromJson(vipAgainJson());
    expect(itemOf(d.toApplyBody(), 'memberships', 'm1')['take'], isEmpty, reason: '没改、没差异：什么都不写');
    d.setField('m1', 'feeCents', 9900);
    d.setField('m1', 'tier', '黑卡');
    final m = itemOf(d.toApplyBody(), 'memberships', 'm1');
    expect(m['take'], ['feeCents', 'tier']);
    expect((m['fields'] as Map)['feeCents'], 9900);
    final fee = d.node('m1')!.diff.firstWhere((x) => x.field == 'feeCents');
    expect([fee.oldValue, fee.newValue, fee.take, fee.hasOld], [8800, 9900, true, true], reason: '服务端没列的差异补一条，原来的值取服务端给的 current');
    d.setField('m1', 'tier', null);
    expect(d.node('m1')!.diff.map((x) => x.field), ['feeCents'], reason: '改回和库里一样：不算差异，拿掉');
    expect(itemOf(d.toApplyBody(), 'memberships', 'm1')['take'], ['feeCents']);
    d.setField('m1', 'tier', '黑卡');

    d.batchFaceValue(['b3'], 500);
    d.batchQuota(['b3'], const [PerkQuota('month', 5)]);
    d.batchClaimPlatform(['b2'], 'key:p2');
    d.mapClaim('p4', ClaimMode.mergeInto, targetId: 'wy');
    var body = d.toApplyBody();
    expect(itemOf(body, 'benefits', 'b3')['take'], ['faceValueCents', 'quota']);
    expect(itemOf(body, 'benefits', 'b2')['take'], ['claimPlatform']);
    expect(itemOf(body, 'benefits', 'b4')['take'], ['claimPlatform'], reason: '映射视图定了去哪领，库里已有的那项也写');
    expect(itemOf(body, 'benefits', 'b1')['take'], isEmpty, reason: '没动的不写');
    d.setDiffTake('b3', 'quota', false);
    expect(itemOf(d.toApplyBody(), 'benefits', 'b3')['take'], ['faceValueCents'], reason: '改过又取消勾：照用户的');
    d.batchQuota(['b3'], const [PerkQuota('month', 4)]);
    expect(d.node('b3')!.diff.map((x) => x.field), ['faceValueCents'], reason: '额度改回库里的（键序不同也算一样）');
    // 领取平台按映射算：改去一个并入已有平台的，和库里一样就不写；映射成会员本平台、库里也是本平台，同样不写
    final again = PerkImportDraft.fromJson(vipAgainJson());
    again.node('b1')!.current['claimPlatform'] = 'id:yk';
    again.mapClaim('p2', ClaimMode.mergeInto, targetId: 'yk');
    expect(itemOf(again.toApplyBody(), 'benefits', 'b1')['take'], isEmpty, reason: '「优酷视频」并入「优酷」，库里本来就去优酷领');
    again.mapClaim('p2', ClaimMode.create);
    final claim = again.node('b1')!.diff.single;
    expect([claim.field, claim.oldValue, claim.newValue, claim.take], ['claimPlatform', 'id:yk', 'key:p2', true]);
    again.mapClaim('p3', ClaimMode.self);
    expect(itemOf(again.toApplyBody(), 'benefits', 'b2')['take'], isEmpty, reason: '库里的饿了么年卡本来就在会员本平台领');

    expect(d.batchMoveTo(['b3', 'b1'], 'id:other'), 2, reason: '库里已有的权益导入时不换卡，跳过并告诉界面');
    expect(d.node('b3')!.fields['membership'], 'key:m1');

    // 服务端列了差异、默认不勾的（费用不同）：改了就换成改后的值并勾上
    final json = vipAgainJson();
    ((json['memberships'] as List).first as Map<String, dynamic>)['diff'] = [
      {'field': 'feeCents', 'old': 9900, 'new': 8800, 'take': false},
    ];
    final e = PerkImportDraft.fromJson(json);
    e.setField('m1', 'feeCents', 12800);
    final d0 = e.node('m1')!.diff.single;
    expect([d0.oldValue, d0.newValue, d0.take, d0.hasOld], [9900, 12800, true, true]);

    // 新建的：改过的字段带在 edited 里（服务端重新比对转成更新时照写）
    final c = vip();
    c.setField('m1', 'feeCents', 9900);
    body = c.toApplyBody();
    expect(itemOf(body, 'memberships', 'm1')['edited'], ['feeCents']);
    expect(itemOf(body, 'benefits', 'b1').containsKey('edited'), isFalse);
  });

  test('「已存在」的物品（Review ②⑫㉒）：勾上就照样新建一件（计入导入数、提交体 create），取消又回到跳过', () {
    final json = orderDraft();
    ((json['items'] as List).first as Map<String, dynamic>)
      ..['action'] = 'skip'
      ..['checked'] = false
      ..['badges'] = ['exists']
      ..['match'] = {'kind': 'exists', 'id': 'a-old', 'name': 'iPhone 16 Pro 256GB'};
    final o = PerkImportDraft.fromJson(json);
    expect([o.includedCount, o.canSubmit], [0, false]);
    expect(itemOf(o.toApplyBody(), 'items', 'i1')['action'], 'skip');
    o.setChecked('i1', true);
    expect([o.node('i1')!.action, o.includedCount, o.canSubmit], ['create', 1, true]);
    expect(itemOf(o.toApplyBody(), 'items', 'i1')['action'], 'create');
    o.setChecked('i1', false);
    expect([o.node('i1')!.action, o.includedCount], ['skip', 0]);
  });

  test('同名多张卡选定（Review ⑧㉑）：换上那张的差异和「未提及」，卡下权益按 byCard 变成更新那项；改选「新建」都回到新建；人工改过的字段留着', () {
    final d = PerkImportDraft.fromJson(vipPickJson());
    d.setField('b3', 'claimHow', '首页领券');
    d.pickMembership('m1', 'c1');
    var body = d.toApplyBody();
    expect(itemOf(body, 'memberships', 'm1'), allOf(containsPair('action', 'update'), containsPair('targetId', 'c1')));
    expect(itemOf(body, 'memberships', 'm1')['take'], ['expiresOn'], reason: '爸爸那张的到期日更早，默认勾');
    expect(itemOf(body, 'benefits', 'b3')['action'], 'create', reason: '爸爸那张下面没有同名的');

    d.pickMembership('m1', 'c2');
    body = d.toApplyBody();
    expect(itemOf(body, 'memberships', 'm1')['take'], isEmpty);
    expect(d.node('m1')!.notMentioned.map((x) => x['name']), ['淘票票观影券']);
    final b3 = itemOf(body, 'benefits', 'b3');
    expect([b3['action'], b3['targetId'], b3['take']], ['update', 'c2-b3', ['faceValueCents', 'claimHow']], reason: '已有的那项更新、不再新建一份；改过的领取路径照写');
    final how = d.node('b3')!.diff.firstWhere((x) => x.field == 'claimHow');
    expect([how.oldValue, how.newValue, how.hasOld], ['券中心', '首页领券', true], reason: '旧值换成妈妈那张下那项现在的值');
    d.setField('m1', 'expiresOn', '2027-03-01');
    expect(d.node('m1')!.diff, isEmpty, reason: '到期日改成和妈妈那张一样：没差异了');
    d.pickMembership('m1', 'c1');
    expect(d.node('m1')!.diff.single.oldValue, '2026-10-01', reason: '换回爸爸那张：旧值跟着换');
    d.pickMembership('m1', 'c2');
    expect(itemOf(body, 'benefits', 'b1')['action'], 'create');

    d.pickMembership('m1', null);
    expect([d.node('m1')!.action, d.node('m1')!.diff, d.node('m1')!.notMentioned], ['create', isEmpty, isEmpty]);
    expect([d.node('b3')!.action, d.node('b3')!.targetId, d.node('b3')!.diff], ['create', null, isEmpty]);
  });

  test('不发出服务端必拒的请求（Review ③）：取消只当领取平台用的新建平台 → 那项权益按会员本平台发；勾回同名多张卡下的一条权益 → 卡也勾上、被「要选」挡住', () {
    final d = vip();
    d.setChecked('p3', false);
    expect(d.node('b2')!.checked, isTrue);
    var body = d.toApplyBody();
    expect(itemOf(body, 'platforms', 'p3')['action'], 'skip');
    expect((itemOf(body, 'benefits', 'b2')['fields'] as Map)['claimPlatform'], isNull);
    expect(d.claimRefOf(d.node('b2')!), isNull);

    final p = PerkImportDraft.fromJson(vipPickJson());
    p.setChecked('m1', false);
    expect(p.node('b3')!.checked, isFalse);
    p.setChecked('b3', true);
    expect(p.node('m1')!.checked, isTrue);
    expect(p.blockers.map((b) => b.reason), ['「88VIP」有同名的好几张，选一张更新或新建']);
  });

  test('单独的平台（Review ④）：没挂卡、也没人去它那领的默认不导（不悄悄加别名、不建空平台），单独列出来；选了是谁就勾上', () {
    final json = vip88Draft();
    (json['platforms'] as List)
      ..add(importNode('p7', 'platform', {'name': '天猫', 'kind': 'shopping'}, action: 'merge', targetId: 'tb', match: {'kind': 'alias', 'id': 'tb', 'name': '淘宝'}))
      ..add(importNode('p8', 'platform', {'name': '盒马', 'kind': 'food'}));
    final d = PerkImportDraft.fromJson(json);
    expect(d.standalonePlatforms.map((p) => p.key), ['p7', 'p8']);
    expect([d.node('p7')!.checked, d.node('p8')!.checked], [false, false]);
    expect(d.rootPlatforms.map((p) => p.key), ['p1']);
    expect(itemOf(d.toApplyBody(), 'platforms', 'p7')['action'], 'skip');
    expect(d.includedCount, 14);
    d.mapClaim('p8', ClaimMode.create);
    expect(d.node('p8')!.checked, isTrue);
    expect(itemOf(d.toApplyBody(), 'platforms', 'p8'), allOf(containsPair('action', 'create'), containsPair('match', 'none')));
  });

  test('平台带上预览时的比对结果（Review ㉓）：别名命中、用户选了「新建」的发 match=alias（服务端照建，不强并）', () {
    final json = vip88Draft();
    (json['platforms'] as List).add(importNode('p7', 'platform', {'name': '天猫', 'kind': 'shopping'}, action: 'merge', targetId: 'tb', match: {'kind': 'alias', 'id': 'tb', 'name': '淘宝'}));
    final d = PerkImportDraft.fromJson(json);
    expect(itemOf(d.toApplyBody(), 'platforms', 'p1'), allOf(containsPair('action', 'merge'), containsPair('targetId', 'tb'), containsPair('match', 'exact')));
    d.mapClaim('p7', ClaimMode.existing);
    expect(itemOf(d.toApplyBody(), 'platforms', 'p7'), allOf(containsPair('action', 'merge'), containsPair('targetId', 'tb'), containsPair('match', 'alias')));
    d.mapClaim('p7', ClaimMode.create);
    final p7 = itemOf(d.toApplyBody(), 'platforms', 'p7');
    expect([p7['action'], p7['match'], p7.containsKey('targetId')], ['create', 'alias', false]);
  });

  test('上限（Review ⑥⑰）：勾着的超过一次导入的上限就挡住、说清楚；取消到上限以内放行，没勾的照样发（skip）', () {
    final json = orderDraft();
    json['items'] = [
      for (var i = 0; i < 51; i++) importNode('i$i', 'item', {'name': '物品$i', 'category': 'other', 'priceCents': 100 + i, 'purchasedOn': '2026-09-20'}),
    ];
    final o = PerkImportDraft.fromJson(json);
    expect(o.blockers.single.reason, '一次最多导入物品 50 件，这次勾了 51 件，先取消一些或分两次导');
    o.setChecked('i0', false);
    expect(o.blockers, isEmpty);
    expect((o.toApplyBody()['items'] as List), hasLength(51));
  });

  test('没写平台的卡（Review ⑭）：选一个平台就放行，新建的平台跟着勾上；换到账本里已有的平台，原来那个没卡了跟着不导', () {
    final json = vip88Draft();
    (((json['memberships'] as List).first as Map<String, dynamic>)['fields'] as Map)['platform'] = null;
    (json['platforms'] as List).add(importNode('p9', 'platform', {'name': '淘宝网', 'kind': 'shopping'}));
    final d = PerkImportDraft.fromJson(json);
    expect(d.homelessMemberships.map((m) => m.key), ['m1']);
    expect(d.blockers.single.reason, '「88VIP」缺平台');
    d.setField('m1', 'platform', 'key:p9');
    expect([d.blockers, d.node('p9')!.checked, d.rootPlatforms.map((p) => p.key)], [isEmpty, true, ['p9']]);
    d.setField('m1', 'platform', 'id:yk');
    expect(d.node('p9')!.checked, isFalse, reason: '下面没卡了，不导一个空平台');
    expect(d.existingPlatformRefs, ['id:yk']);
    expect((itemOf(d.toApplyBody(), 'memberships', 'm1')['fields'] as Map)['platform'], 'id:yk');
  });

  test('物品改了价格或日期（Review ⑮）：默认关联的那笔对不上了就不再关联、候选不列；改回来候选又列出来（要自己再选）', () {
    final o = order();
    final i = o.node('i1')!;
    o.setField('i1', 'priceCents', 799900);
    expect([i.link, o.txCandidatesOf(i)], [ItemLink.none, isEmpty]);
    expect(itemOf(o.toApplyBody(), 'items', 'i1').containsKey('linkTransactionId'), isFalse);
    o.setField('i1', 'priceCents', 899900);
    expect([o.txCandidatesOf(i).length, i.link], [1, ItemLink.none]);
    o.setLink('i1', ItemLink.link, transactionId: 'tx-phone');
    o.setField('i1', 'purchasedOn', '2026-09-18');
    expect(i.link, ItemLink.link, reason: '差 3 天还算');
    o.setField('i1', 'purchasedOn', '2026-09-25');
    expect(i.link, ItemLink.none, reason: '差 4 天对不上了');
  });

  test('来源：网址的草稿和粘贴一样带原文存本机（恢复后还能高亮）；流水的草稿不带原文，扣费特征、上次扣费照样发给服务端', () {
    final url = PerkImportDraft.fromJson({...vip88Draft(), 'source': {'kind': 'url', 'text': vip88Source, 'url': 'https://vip.example/88vip'}}, clientId: 'c1');
    expect([url.hasSourceText, url.fromImages, url.fromTransactions], [true, false, false]);
    final back = PerkImportDraft.restore(jsonDecode(jsonEncode(url.toJson())) as Map<String, dynamic>);
    expect([back.sourceKind, back.sourceText, back.hasSourceText], ['url', vip88Source, true]);

    final tx = PerkImportDraft.fromJson(txDraft(), clientId: 'c2');
    expect([tx.fromTransactions, tx.hasSourceText, tx.sourceText], [true, false, '']);
    final saved = jsonDecode(jsonEncode(tx.toJson())) as Map<String, dynamic>;
    expect(saved['source'], {'kind': 'transactions'});
    final txBack = PerkImportDraft.restore(saved);
    expect([txBack.fromTransactions, tx.usedAi, txBack.usedAi], [true, false, false], reason: '「直接生成」没有渠道，恢复后也记得没问过模型');
    expect([url.usedAi, back.usedAi], [true, true]);
    expect(PerkImportDraft.restore({...saved}..remove('usedAi')).usedAi, isTrue, reason: '老草稿没这个键：按问过模型说（多提醒一句 token 不出错）');
    final m = itemOf(txBack.toApplyBody(), 'memberships', 'm1');
    expect([m['action'], (m['fields'] as Map)['payPattern'], (m['fields'] as Map)['lastChargeTxId']], [
      'create', {'keywords': ['腾讯视频'], 'minCents': 2400, 'maxCents': 3600}, 'tx-g_tv',
    ]);
  });
}
