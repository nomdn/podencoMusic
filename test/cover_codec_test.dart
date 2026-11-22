// 本地选图 → 压缩 → base64 → 存档 ↔ 回显 的纯逻辑测试。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:podenco_music/cover_codec.dart';
import 'package:podenco_music/cover_provider_data.dart';
import 'package:podenco_music/widgets/cover_crop_page.dart';
import 'package:podenco_music/models.dart';
import 'package:podenco_music/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一张纯色测试图，返回 PNG 字节。
List<int> _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 100, 50));
  return img.encodePng(image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeCover', () {
    test('输出 jpeg data URI，base64 能解回图片', () {
      final uri = encodeCover(_png(120, 90));
      expect(uri.startsWith('data:image/jpeg;base64,'), isTrue);

      final bytes = decodeCoverDataUri(uri);
      expect(bytes, isNotNull);
      final decoded = img.decodeJpg(bytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 120);
      expect(decoded.height, 90);
    });

    test('大图等比缩到最长边 320，不拉伸', () {
      final uri = encodeCover(_png(640, 480));
      final decoded = img.decodeJpg(decodeCoverDataUri(uri)!)!;

      expect(decoded.width, coverMaxEdge);
      expect(decoded.height, 240);
    });

    test('竖图也按最长边缩放', () {
      final uri = encodeCover(_png(480, 960));
      final decoded = img.decodeJpg(decodeCoverDataUri(uri)!)!;

      expect(decoded.width, 160);
      expect(decoded.height, coverMaxEdge);
    });

    test('小图不放大', () {
      final uri = encodeCover(_png(64, 48));
      final decoded = img.decodeJpg(decodeCoverDataUri(uri)!)!;

      expect(decoded.width, 64);
      expect(decoded.height, 48);
    });

    test('空字节和坏图片给中文错误', () {
      expect(() => encodeCover(const <int>[]), throwsA(isA<CoverCodecException>()));
      expect(() => encodeCover(const [1, 2, 3]), throwsA(isA<CoverCodecException>()));
    });
  });

  group('CoverCropLayout', () {
    const layout = CoverCropLayout(
      imageWidth: 640,
      imageHeight: 480,
      viewSize: 320,
    );

    test('初始按短边铺满裁剪框，长边溢出', () {
      expect(layout.baseWidth, closeTo(426.67, 0.01));
      expect(layout.baseHeight, 320);
    });

    test('默认居中裁出最大的正方形', () {
      final rect = layout.cropRectFor(scale: 1, offsetX: 0, offsetY: 0);
      expect(rect.size, 480);
      expect(rect.x, 80);
      expect(rect.y, 0);
    });

    test('放大后裁剪区域变小', () {
      final rect = layout.cropRectFor(scale: 2, offsetX: 0, offsetY: 0);
      expect(rect.size, 240);
      expect(rect.x, 200);
      expect(rect.y, 120);
    });

    test('拖到边界外自动 clamp，不越界不留黑边', () {
      final farRight = layout.cropRectFor(
        scale: 1,
        offsetX: 10000,
        offsetY: -10000,
      );
      expect(farRight.x, 0);
      expect(farRight.y, 0);
      expect(farRight.x + farRight.size, lessThanOrEqualTo(640));
      expect(farRight.y + farRight.size, lessThanOrEqualTo(480));

      final farLeft = layout.cropRectFor(
        scale: 1,
        offsetX: -10000,
        offsetY: 10000,
      );
      expect(farLeft.x, 160);
      expect(farLeft.y, 0);
    });

    test('裁剪后编码仍是正方形，且不超过 320px', () {
      final bytes = _png(640, 480);
      final rect = layout.cropRectFor(scale: 1, offsetX: 0, offsetY: 0);
      final uri = encodeCoverCropped(
        bytes,
        x: rect.x,
        y: rect.y,
        size: rect.size,
      );
      final decoded = img.decodeJpg(decodeCoverDataUri(uri)!)!;

      expect(decoded.width, decoded.height);
      expect(decoded.width, coverMaxEdge);
    });
  });

  group('decodeCoverDataUri', () {
    test('普通 http 链接不当 data URI 处理', () {
      expect(decodeCoverDataUri('https://example.com/cover.jpg'), isNull);
    });

    test('截断或写坏的 base64 当没封面', () {
      expect(decodeCoverDataUri('data:image/jpeg;base64,!!!'), isNull);
      expect(decodeCoverDataUri('data:image/jpeg(no comma)'), isNull);
    });
  });

  group('dataUriProvider', () {
    test('data URI 给出 MemoryImage，普通链接交给平台实现', () {
      final uri = encodeCover(_png(80, 80));
      expect(dataUriProvider(uri), isA<MemoryImage>());
      expect(dataUriProvider('https://example.com/cover.jpg'), isNull);
      expect(dataUriProvider('data:image/jpeg;base64,!!!'), isNull);
    });
  });

  test('base64 封面跟着歌单存档完整往返', () async {
    SharedPreferences.setMockInitialValues({});
    final uri = encodeCover(_png(400, 300));
    const playlist = Playlist(
      id: '1',
      name: '本地封面',
      createdAt: 0,
      tracks: [],
    );

    await PlaylistStorage.save([playlist.copyWith(coverUrl: uri)]);
    final loaded = await PlaylistStorage.load();

    expect(loaded.single.coverUrl, uri);
    // 解码后仍是合法 jpeg，而不是在 JSON 里被截断
    expect(img.decodeJpg(decodeCoverDataUri(loaded.single.coverUrl)!), isNotNull);
  });

  testWidgets('裁剪页点完成才返回 data URI', (tester) async {
    final bytes = Uint8List.fromList(_png(640, 480));
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showCoverCropPage(context, bytes);
              },
              child: const Text('打开裁剪'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开裁剪'));
    await tester.pumpAndSettle();
    expect(find.text('裁剪封面'), findsOneWidget);

    // 没点完成前不落库
    expect(result, isNull);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.startsWith('data:image/jpeg;base64,'), isTrue);
  });

  test('base64 封面写进导出 JSON 也是合法字符串', () {
    final uri = encodeCover(_png(400, 300));
    final encoded = jsonEncode({
      'playlist': const Playlist(
        id: '1',
        name: '本地封面',
        createdAt: 0,
        tracks: [],
      ).copyWith(coverUrl: uri).toJson(),
    });

    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    final playlist = decoded['playlist'] as Map<String, dynamic>;
    expect(playlist['coverUrl'], uri);
  });
}
