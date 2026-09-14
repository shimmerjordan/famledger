import 'package:famledger/capture/normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextNormalizer.normalize', () {
    test('全角字母数字转半角', () {
      expect(TextNormalizer.normalize('ＡＢＣ１２３'), 'ABC123');
    });

    test('全角标点转半角、￥ 统一为 ¥', () {
      expect(TextNormalizer.normalize('商户：￥１２．５０'), '商户:¥12.50');
      expect(TextNormalizer.normalize('（美团）'), '(美团)');
    });

    test('去掉 emoji 与变体选择符', () {
      expect(TextNormalizer.normalize('支付成功🎉✅'), '支付成功');
      expect(TextNormalizer.normalize('到账❗️88元'), '到账88元');
    });

    test('压缩空白并去首尾空格', () {
      expect(TextNormalizer.normalize('  支付   成功 \n 35元 '), '支付 成功 35元');
      expect(TextNormalizer.normalize('全角　空格'), '全角 空格');
    });

    test('保留中文与【】等结构字符', () {
      expect(
        TextNormalizer.normalize('【招商银行】您尾号1234'),
        '【招商银行】您尾号1234',
      );
    });

    test('空串安全', () {
      expect(TextNormalizer.normalize(''), '');
    });
  });

  group('TextNormalizer.tokenText', () {
    test('去标点空白并小写', () {
      expect(TextNormalizer.tokenText('美团外卖 ¥35.00, Ok！'), '美团外卖3500ok');
    });

    test('全角先归一再去标点', () {
      expect(TextNormalizer.tokenText('ＭｅｉＴｕａｎ：￥１０'), 'meituan10');
    });

    test('只剩标点时返回空串', () {
      expect(TextNormalizer.tokenText('，。！—— '), '');
    });

    test('符号/emoji/零宽字符全部丢掉，字母数字全部保留', () {
      // 与 server/src/lib/nb.js 的 /[^\p{L}\p{N}]/gu 同一口径
      expect(TextNormalizer.tokenText('支付成功🎉 ¥35.00'), '支付成功3500');
      expect(TextNormalizer.tokenText('【招商银行】尾号1234'), '招商银行尾号1234');
      expect(TextNormalizer.tokenText('Café'), 'café'); // 带音标的字母是字母
      expect(TextNormalizer.tokenText('ユニクロ Tシャツ'), 'ユニクロtシャツ');
    });

    test('全角 ASCII 折半角，其他字符原样进入过滤', () {
      expect(TextNormalizer.tokenText('ＵＮＩＱＬＯ优衣库  T恤 99元'),
          'uniqlo优衣库t恤99元');
      expect(TextNormalizer.tokenText('￥６６．６６'), '6666');
    });
  });
}
