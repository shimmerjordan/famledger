import 'normalizer.dart';
import 'source_profiles.dart';

/// 交易方向。
enum PayDirection { expense, income, transfer, unknown }

/// 原始通知（由原生 `CaptureListenerService` 透传）。
class RawNotification {
  const RawNotification({
    required this.packageName,
    required this.title,
    required this.text,
    this.bigText = '',
    required this.postedAt,
    this.transactionSource = 'notification',
  });

  final String packageName;
  final String title;
  final String text;
  final String bigText;
  final DateTime postedAt;

  /// 记成流水时的 `source`。服务端只对 notification/share 按「同金额 180 秒内」查重，
  /// 粘贴导入一次进来好几段、没写日期的都落在同一刻，得换成不查重的 `import`。
  final String transactionSource;

  /// MethodChannel 传来的 map（`{package,title,text,bigText,postedAt}`）。
  factory RawNotification.fromMap(Map<dynamic, dynamic> map) {
    final posted = map['postedAt'];
    return RawNotification(
      packageName: (map['package'] ?? map['packageName'] ?? '') as String,
      title: (map['title'] ?? '') as String,
      text: (map['text'] ?? '') as String,
      bigText: (map['bigText'] ?? '') as String,
      postedAt: posted is int
          ? DateTime.fromMillisecondsSinceEpoch(posted)
          : posted is String
              ? DateTime.parse(posted)
              : DateTime.now(),
    );
  }

  /// 正文：bigText 更完整时优先，且不重复拼接。
  String get body {
    final big = bigText.trim();
    final small = text.trim();
    if (big.isEmpty) return small;
    if (small.isEmpty || big.contains(small)) return big;
    return '$small $big';
  }

  /// 标题 + 正文，抽金额/商户/卡号时用。
  String get combinedText => <String>[title.trim(), body]
      .where((s) => s.isNotEmpty)
      .join(' ');
}

/// 解析结果。[isPayment] 为 false 表示噪声，直接丢弃。
class ParsedPayment {
  const ParsedPayment({
    required this.amountCents,
    required this.direction,
    required this.merchant,
    required this.channel,
    required this.cardTail,
    required this.occurredAt,
    required this.parseConfidence,
    required this.isPayment,
    required this.sourceApp,
    this.normalizedText = '',
  });

  final int? amountCents;
  final PayDirection direction;
  final String merchant;

  /// alipay|wechat|unionpay|bank_sms|unknown
  final String channel;
  final String? cardTail;
  final DateTime occurredAt;
  final double parseConfidence;
  final bool isPayment;

  /// 来源包名，规则 `field:'app'` 与账户 `matchHints.packages` 要用。
  final String sourceApp;

  /// 归一化后的「标题 + 正文」，管线拿它当 rawText 与去重哈希的输入，
  /// 免得同一段文本被归一化两次、两处结果不一致。
  final String normalizedText;
}

class _AmountHit {
  const _AmountHit(this.cents, this.score, this.position, this.negative);

  final int cents;
  final int score;

  /// 数字首字符在归一化文本里的下标，方向判断按「离金额最近」取词。
  final int position;

  /// 金额本身带负号（银行 App 的「交易金额：-128.00」写法）。
  final bool negative;

  bool get isStrong => score >= 2;
}

class _Cue {
  const _Cue(this.direction, this.start, this.word);
  final PayDirection direction;
  final int start;
  final String word;
}

/// 通知 → 支付要素。
class NotificationParser {
  const NotificationParser();

  ParsedPayment parse(RawNotification n) {
    final profile = SourceProfile.forPackage(n.packageName);
    final title = TextNormalizer.normalize(n.title);
    final body = TextNormalizer.normalize(n.body);
    // 分别归一化再拼，位置才和标题长度对得上（方向判断要跳过标题）。
    final combined =
        <String>[title, body].where((s) => s.isNotEmpty).join(' ');
    final bodyStart = title.isEmpty ? 0 : title.length + 1;
    final occurredAt = _extractOccurredAt(combined, n.postedAt);

    ParsedPayment noise() => ParsedPayment(
          amountCents: null,
          direction: PayDirection.unknown,
          merchant: '',
          channel: profile.channel,
          cardTail: null,
          occurredAt: occurredAt,
          parseConfidence: 0,
          isPayment: false,
          sourceApp: n.packageName,
          normalizedText: combined,
        );

    if (_hardNoiseRe.any((re) => re.hasMatch(combined))) return noise();
    if (profile.paymentMarkers.isNotEmpty &&
        !profile.paymentMarkers.any(combined.contains)) {
      return noise();
    }
    if (profile.requiredMarkers.isNotEmpty &&
        !profile.requiredMarkers.any(combined.contains)) {
      return noise();
    }

    final amount = _findAmount(combined);
    // 营销词只有在「没有付款动词 + 金额」时才算噪声：真实付款通知也会带
    // 「（已立减 2 元）」这种尾巴，那时立减金额已经被排除在候选之外了。
    if (_marketingRe.hasMatch(combined) &&
        !(amount != null && _paymentVerbRe.hasMatch(combined))) {
      return noise();
    }
    if (amount == null) return noise();
    // 通用兜底来源噪声多，必须带货币符号才认。
    if (profile.id == 'generic' && !amount.isStrong) return noise();

    final direction = _direction(combined, bodyStart, amount);
    final merchant = _merchant(combined, title, profile);

    var confidence = profile.baseConfidence;
    if (!amount.isStrong) confidence -= 0.15;
    if (direction == PayDirection.unknown) confidence -= 0.30;
    if (merchant.isEmpty && profile.penalizeMissingMerchant) confidence -= 0.05;
    confidence = confidence.clamp(0.0, 1.0).toDouble();

    return ParsedPayment(
      amountCents: amount.cents,
      direction: direction,
      merchant: merchant,
      channel: profile.channel,
      cardTail: _cardTail(combined),
      occurredAt: occurredAt,
      parseConfidence: (confidence * 100).round() / 100,
      isPayment: true,
      sourceApp: n.packageName,
      normalizedText: combined,
    );
  }

  // ---------------------------------------------------------------- 噪声

  /// 一票否决：这些词出现就不可能是一笔真实流水。
  static final List<RegExp> _hardNoiseRe = <RegExp>[
    RegExp(r'验证码|校验码|动态密码|动态码'),
    RegExp(r'账单提醒|账单已出|应还金额|应还款|请及时还款|还款提醒|最低还款|待还金额|本期应还'),
    RegExp(r'红包'),
  ];

  /// 营销词：只有在没有「付款动词 + 金额」时才判噪声（见 parse）。
  static final RegExp _marketingRe = RegExp(
    r'积分即将过期|积分兑换|领取好礼|限时优惠|优惠券|抽奖|点击领取|立减|满减|折扣券',
  );

  static final RegExp _paymentVerbRe = RegExp(
    r'消费|支付|付款|收款|到账|支出|收入|转账|退款|交易|还款|取款|提现|缴费|扣款|扣费|代扣|收益|入账',
  );

  // ---------------------------------------------------------------- 金额

  /// spec §6 的金额正则：可选货币前缀 + 可选负号 + 千分位 + 两位小数 + 可选「元」。
  /// 负号是银行 App 的「交易金额：-128.00」写法，不能当成「这不是金额」。
  static final RegExp _amountRe = RegExp(
    r'(¥|人民币|rmb)?\s*(-)?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?\s*(元|块)?',
    caseSensitive: false,
  );

  /// 紧挨在数字前面时说明这不是交易金额。
  static const List<String> _excludeBefore = <String>[
    '余额', '可用', '额度', '积分', '验证码', '尾号', '卡号', '单号', '订单',
    '编号', '优惠', '立减', '满减', '剩余', '折扣', '返现', '共计笔', '第',
    '领取', '赠送', '奖励', '券',
  ];

  /// 紧跟在数字后面时说明这是日期/时间/比例。
  static const String _excludeAfter = '月日号时分秒年%折期次件位岁';

  /// 紧跟在「金额 + 元」后面时说明这是张券/个红包，不是交易金额。
  static const String _excludeAfterUnit = '券包卡礼';

  static final RegExp _amountContextRe = RegExp(
    r'消费|支付|付款|收款|到账|支出|收入|转账|退款|交易|金额|还款|取款|提现|缴费|扣款|扣费|收益|入账|一笔',
  );

  // 负号不在其中：它是金额自己的符号，不是「别的数字的一部分」。
  static final RegExp _numberNeighbourRe = RegExp(r'[0-9.:/]');
  static final RegExp _currencyTailRe =
      RegExp(r'(¥|人民币|rmb)\s*$', caseSensitive: false);
  static final RegExp _fillerTailRe = RegExp(r'[\s:为是的]+$');

  _AmountHit? _findAmount(String text) {
    _AmountHit? best;
    for (final m in _amountRe.allMatches(text)) {
      final prefix = m.group(1);
      final digits = m.group(3)!;
      final frac = m.group(4);
      final suffix = m.group(5);

      final numStart = text.indexOf(digits, m.start);
      if (numStart < 0) continue;
      final numEnd =
          numStart + digits.length + (frac == null ? 0 : frac.length + 1);

      // 负号紧贴数字时算金额的符号，再往前才是「是不是别的数字」的判断。
      var boundary = numStart;
      var negative = false;
      if (boundary > 0 && text[boundary - 1] == '-') {
        negative = true;
        boundary -= 1;
      }
      if (boundary > 0 && _numberNeighbourRe.hasMatch(text[boundary - 1])) {
        continue; // 别的数字的一部分（时间、长数字、区间）
      }
      if (suffix == null && numEnd < text.length) {
        if (_excludeAfter.contains(text[numEnd])) continue;
        if (text[numEnd] == ':') continue;
      }
      // 「8 元券」：单位后面还跟着「券/包/卡」，这是营销物不是流水金额。
      if (m.end < text.length && _excludeAfterUnit.contains(text[m.end])) {
        continue;
      }

      var before =
          text.substring(boundary - 8 < 0 ? 0 : boundary - 8, boundary);
      before = before.replaceFirst(_currencyTailRe, '');
      final context = before.replaceFirst(_fillerTailRe, '');
      if (_excludeBefore.any(context.endsWith)) continue;

      var score = 0;
      if (prefix != null || suffix != null) score += 2;
      if (_amountContextRe.hasMatch(context)) score += 1;
      if (score == 0) continue; // 既无货币符号又无交易上下文 → 不是金额

      final cents = int.parse(digits.replaceAll(',', '')) * 100 +
          (frac == null
              ? 0
              : frac.length == 1
                  ? int.parse(frac) * 10
                  : int.parse(frac));
      if (cents <= 0) continue;
      if (best == null || score > best.score) {
        best = _AmountHit(cents, score, numStart, negative);
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- 方向

  static final RegExp _incomeRe = RegExp(
    r'退款|退回|退还|收款(?!方|人|码|二维码)|到账|入账|进账|收益|收入|转入|返现|存入',
  );
  static final RegExp _transferRe = RegExp(r'还款|提现|取款|转出|转账');
  static final RegExp _expenseRe = RegExp(
    r'消费|支出|付款|支付|扣款|扣费|代扣|缴费|购买|交易成功',
  );

  static const Set<String> _payVerbs = <String>{'消费', '支付', '付款'};
  static const Set<String> _refundWords = <String>{'退款', '退回', '退还'};

  /// 取**离金额最近**的那个方向词。
  ///
  /// 只认正文里的词（标题多是 App 名，「微信支付」会把一切推成支出）；
  /// 「消费 ¥30 …支持七天无理由退款」这种句子里，「退款」只是售后说明，
  /// 既离金额远、又被「金额前面有付款动词」这条规则直接剔除。
  PayDirection _direction(String text, int bodyStart, _AmountHit amount) {
    final cues = <_Cue>[];
    void collect(RegExp re, PayDirection direction) {
      for (final m in re.allMatches(text)) {
        if (m.start < bodyStart) continue;
        cues.add(_Cue(direction, m.start, m.group(0)!));
      }
    }

    collect(_incomeRe, PayDirection.income);
    collect(_transferRe, PayDirection.transfer);
    collect(_expenseRe, PayDirection.expense);
    if (cues.isEmpty) {
      return amount.negative ? PayDirection.expense : PayDirection.unknown;
    }

    final anchor = amount.position;
    final payVerbBefore = cues.any((c) =>
        c.direction == PayDirection.expense &&
        c.start < anchor &&
        _payVerbs.contains(c.word));
    final scored = cues
        .where((c) => !(payVerbBefore && _refundWords.contains(c.word)))
        .toList();
    if (scored.isEmpty) return PayDirection.expense;

    scored.sort((a, b) {
      final byDistance =
          (a.start - anchor).abs().compareTo((b.start - anchor).abs());
      if (byDistance != 0) return byDistance;
      return _tieRank(a.direction).compareTo(_tieRank(b.direction));
    });
    return scored.first.direction;
  }

  /// 距离相同时：消费/支付/付款 这类支出词优先。
  static int _tieRank(PayDirection direction) => switch (direction) {
        PayDirection.expense => 0,
        PayDirection.income => 1,
        PayDirection.transfer => 2,
        PayDirection.unknown => 3,
      };

  // ---------------------------------------------------------------- 商户

  static final List<RegExp> _merchantRe = <RegExp>[
    RegExp(r'商户全名[:：]?\s*([^，,。；;\s]+)'),
    RegExp(r'商户名称[:：]?\s*([^，,。；;\s]+)'),
    RegExp(r'商户[:：]\s*([^，,。；;\s]+)'),
    RegExp(r'商家[:：]?\s*([^，,。；;\s]+)'),
    RegExp(r'收款方[:：]?\s*([^，,。；;\s]+)'),
    RegExp(r'收款人[:：]?\s*([^，,。；;\s]+)'),
    RegExp(r'向\s*(.+?)\s*(?:付款|转账|支付)'),
    RegExp(r'(?:付款|支付|转账)[^给]{0,12}给\s*([^，,。；;\s]+)'),
    RegExp(r'在\s*(.+?)\s*(?:消费|付款|支付)'),
    RegExp(r'来自\s*([^，,。；;\s]+)'),
  ];

  static final RegExp _merchantTrimRe = RegExp(r'^[-:：，,。.、\s]+|[-:：，,。.、\s]+$');
  static final RegExp _digitsOnlyRe = RegExp(r'^[\d.,¥]+$');

  /// 商户名到括号为止：「肯德基（已立减2元）」的门店/活动后缀不是商户的一部分。
  static const String _merchantStopChars = '()（）【】[]{}<>《》';

  String _merchant(String combined, String title, SourceProfile profile) {
    for (final re in _merchantRe) {
      final m = re.firstMatch(combined);
      final raw = m?.group(1);
      final cleaned = _cleanMerchant(raw);
      if (cleaned.isNotEmpty) return cleaned;
    }
    if (!profile.titleFallbackMerchant) return '';
    var fallback = title;
    for (final name in profile.appTitleNames) {
      fallback = fallback.replaceAll(name, '');
    }
    return _cleanMerchant(fallback);
  }

  String _cleanMerchant(String? raw) {
    if (raw == null) return '';
    var s = raw;
    for (var i = 0; i < s.length; i++) {
      if (_merchantStopChars.contains(s[i])) {
        s = s.substring(0, i);
        break;
      }
    }
    s = s.replaceAll(_merchantTrimRe, '').trim();
    if (s.isEmpty || _digitsOnlyRe.hasMatch(s)) return '';
    if (s.runes.length > 30) {
      s = String.fromCharCodes(s.runes.take(30));
    }
    return s;
  }

  // ---------------------------------------------------------------- 卡号

  static final List<RegExp> _cardTailRe = <RegExp>[
    RegExp(r'尾号\s*[:：]?\s*(\d{4})'),
    RegExp(r'卡号\s*[:：]?\s*\**(\d{4})'),
    RegExp(r'\*{2,}\s*(\d{4})'),
    RegExp(r'\((\d{4})\)'),
  ];

  String? _cardTail(String text) {
    for (final re in _cardTailRe) {
      final m = re.firstMatch(text);
      if (m != null) return m.group(1);
    }
    return null;
  }

  // ---------------------------------------------------------------- 时间

  static final RegExp _dateTimeRe = RegExp(
    r'(\d{1,2})[月\-/](\d{1,2})[日号]?(?:\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  );

  /// 银行短信常带交易时间；解析失败就用通知时间。
  DateTime _extractOccurredAt(String text, DateTime postedAt) {
    final m = _dateTimeRe.firstMatch(text);
    if (m == null) return postedAt;
    final month = int.parse(m.group(1)!);
    final day = int.parse(m.group(2)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return postedAt;
    final hour = int.tryParse(m.group(3) ?? '') ?? 0;
    final minute = int.tryParse(m.group(4) ?? '') ?? 0;
    final second = int.tryParse(m.group(5) ?? '') ?? 0;
    if (hour > 23 || minute > 59 || second > 59) return postedAt;
    var when = DateTime(postedAt.year, month, day, hour, minute, second);
    if (when.isAfter(postedAt.add(const Duration(days: 2)))) {
      when = DateTime(postedAt.year - 1, month, day, hour, minute, second);
    }
    return when;
  }
}
