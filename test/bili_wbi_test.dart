// WBI 签名：错了只会表现为「字幕永远是空的」，不会报错，
// 所以必须有一条能对账的向量钉住算法。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';

void main() {
  const mixin = '0123456789abcdef0123456789abcdef';

  test('与官方 web 端算出的签名一致', () {
    // 向量由同一份规则在 python 里算出：
    //   query = aid=1&bvid=BV1xx411c7mD&cid=2&wts=1700000000
    //   w_rid = md5(query + mixin)
    final query = BiliApi.wbiSignedQuery(
      {'aid': '1', 'cid': '2', 'bvid': 'BV1xx411c7mD'},
      mixin,
      wts: 1700000000,
    );

    expect(query, contains('aid=1'));
    expect(query, contains('bvid=BV1xx411c7mD'));
    expect(query, contains('cid=2'));
    expect(query, contains('wts=1700000000'));
    expect(query, endsWith('w_rid=d8497c2e9dbf9f0479f9a73379e63350'));
  });

  test('参数按 key 排序，不受 map 插入顺序影响', () {
    final a = BiliApi.wbiSignedQuery(
      {'bvid': 'BV1xx411c7mD', 'aid': '1', 'cid': '2'},
      mixin,
      wts: 1700000000,
    );
    final b = BiliApi.wbiSignedQuery(
      {'cid': '2', 'bvid': 'BV1xx411c7mD', 'aid': '1'},
      mixin,
      wts: 1700000000,
    );
    expect(a, b);
  });

  test('值里的 !\'()* 要摘掉再签', () {
    final clean = BiliApi.wbiSignedQuery(
      {'keyword': 'abcdef'},
      mixin,
      wts: 1700000000,
    );
    final dirty = BiliApi.wbiSignedQuery(
      {"keyword": "a!b'c(d)e*f"},
      mixin,
      wts: 1700000000,
    );
    // 摘掉之后两边应该完全一样
    expect(dirty, clean);
  });

  test('换密钥签名就变', () {
    final one = BiliApi.wbiSignedQuery(
      {'aid': '1'},
      mixin,
      wts: 1700000000,
    );
    final two = BiliApi.wbiSignedQuery(
      {'aid': '1'},
      'ffffffffffffffffffffffffffffffff',
      wts: 1700000000,
    );
    expect(one, isNot(two));
  });
}
