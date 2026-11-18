// 粘贴 Cookie 登录的解析规则。
//
// 这段代码面对的是「用户从浏览器里捞出来的一坨文本」，形态完全不可控：
// 有人贴整段 Cookie，有人只贴 SESSDATA 的值，有人从 DevTools 连 Path 一起复制，
// 还有人贴的是登录跳转地址。解析错了的表现是「登录失败」四个字，
// 用户无从下手，所以这里逐种形态钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/bili_api.dart';

void main() {
  const sess = '5f4e9a1c%2C1794801182%2Cabcd1234*42uQx9Yz';

  group('整段 Cookie', () {
    test('标准写法', () {
      final jar = BiliApi.parseCookieInput(
        'SESSDATA=$sess; bili_jct=csrf123; DedeUserID=12345',
      );
      expect(jar['SESSDATA'], sess);
      expect(jar['bili_jct'], 'csrf123');
      expect(jar['DedeUserID'], '12345');
    });

    test('跳过 Path / Expires 这些属性', () {
      final jar = BiliApi.parseCookieInput(
        'SESSDATA=$sess; Path=/; Domain=.bilibili.com; '
        'Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure; HttpOnly',
      );
      expect(jar.keys, ['SESSDATA']);
    });

    test('换行分隔也能认', () {
      final jar = BiliApi.parseCookieInput('SESSDATA=$sess\nbili_jct=abc');
      expect(jar['SESSDATA'], sess);
      expect(jar['bili_jct'], 'abc');
    });

    test('多余的空白和结尾分号不影响', () {
      final jar = BiliApi.parseCookieInput('  SESSDATA = $sess ;  ');
      expect(jar['SESSDATA'], sess);
    });
  });

  group('只有一个值', () {
    test('裸 SESSDATA 值直接当成 SESSDATA', () {
      expect(BiliApi.parseCookieInput(sess)['SESSDATA'], sess);
    });

    test('太短的裸值不猜', () {
      expect(BiliApi.parseCookieInput('abc'), isEmpty);
    });
  });

  group('其它粘贴形态', () {
    test('登录跳转 URL', () {
      final jar = BiliApi.parseCookieInput(
        'https://passport.biligame.com/crossDomain?DedeUserID=99&SESSDATA=$sess'
        '&bili_jct=jct&gourl=https%3A%2F%2Fwww.bilibili.com',
      );
      expect(jar['SESSDATA'], sess);
      expect(jar['DedeUserID'], '99');
      // gourl 这种业务参数不该混进凭证
      expect(jar.containsKey('gourl'), isFalse);
    });

    test('插件导出的 JSON', () {
      final jar = BiliApi.parseCookieInput(
        '{"SESSDATA":"$sess","bili_jct":"jct","DedeUserID":"7"}',
      );
      expect(jar['SESSDATA'], sess);
      expect(jar['DedeUserID'], '7');
    });

    test('JSON 套一层 cookie 字段', () {
      final jar = BiliApi.parseCookieInput('{"cookie":"SESSDATA=$sess; bili_jct=j"}');
      expect(jar['SESSDATA'], sess);
      expect(jar['bili_jct'], 'j');
    });

    test('带 Cookie: 前缀和引号', () {
      final jar = BiliApi.parseCookieInput('Cookie: "SESSDATA=$sess"');
      expect(jar['SESSDATA'], sess);
    });

    test('空输入不抛异常', () {
      expect(BiliApi.parseCookieInput(''), isEmpty);
      expect(BiliApi.parseCookieInput('   '), isEmpty);
      expect(BiliApi.parseCookieInput(';;;'), isEmpty);
    });
  });
}
