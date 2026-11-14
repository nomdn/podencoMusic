// 接口代理配置测试：SirenApi 主机规范化 + ApiConfigStorage 往返。
// SirenApi 是静态全局 —— 每个用例结束后把主机恢复成默认，避免串味。

import 'package:flutter_test/flutter_test.dart';
import 'package:podenco_music/siren_api.dart';
import 'package:podenco_music/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SirenApi.host = '';
  });

  group('SirenApi.host', () {
    test('默认是官方接口（含 /api 路径段）', () {
      expect(
        SirenApi.host,
        'https://monster-siren.hypergryph.com/api',
      );
    });

    test('自定义主机：去掉尾部斜杠', () {
      SirenApi.host = 'https://proxy.example.com/msapi/';
      expect(SirenApi.host, 'https://proxy.example.com/msapi');
    });

    test('空串和纯空白恢复默认', () {
      SirenApi.host = 'https://proxy.example.com';
      SirenApi.host = '';
      expect(SirenApi.host, SirenApi.defaultHost);
      SirenApi.host = '   ';
      expect(SirenApi.host, SirenApi.defaultHost);
    });
  });

  group('ApiConfigStorage', () {
    test('存进去的地址能原样读回来', () async {
      await ApiConfigStorage.save('https://proxy.example.com/msapi');
      expect(await ApiConfigStorage.load(), 'https://proxy.example.com/msapi');
    });

    test('存空串 = 未配置', () async {
      await ApiConfigStorage.save('');
      expect(await ApiConfigStorage.load(), '');
    });

    test('没存过返回空串，不是抛异常', () async {
      expect(await ApiConfigStorage.load(), '');
    });
  });
}
