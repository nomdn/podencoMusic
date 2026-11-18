import 'models.dart';

/// 哔哩哔哩搜索 / 空间接口返回的一条视频。
///
/// 只保留播放和展示要用的字段：B站返回里还有一堆 UP 主签名、
/// 弹幕数、banner 之类，存下来只会让存档变大。
class BiliVideo {
  const BiliVideo({
    required this.bvid,
    required this.aid,
    required this.title,
    required this.cover,
    required this.author,
    required this.mid,
    required this.durationMs,
    this.play = 0,
    this.pubdate = 0,
  });

  final String bvid;
  final int aid;
  final String title;

  /// 封面直链。接口给的是 `//i0.hdslb.com/...`，协议相对地址，
  /// 必须补成 https，否则 Flutter 的图片加载器不认。
  final String cover;
  final String author;
  final int mid;
  final int durationMs;

  /// 播放量。列表里显示成「12.3 万」这种，纯展示用。
  final int play;
  final int pubdate;

  factory BiliVideo.fromJson(Map<String, dynamic> json) => BiliVideo(
    bvid: json['bvid']?.toString() ?? '',
    aid: (json['aid'] as num?)?.toInt() ?? 0,
    title: sanitizeBiliText(json['title']?.toString() ?? ''),
    cover: normalizeBiliImage(json['pic']?.toString() ?? ''),
    author: sanitizeBiliText(json['author']?.toString() ?? ''),
    mid: (json['mid'] as num?)?.toInt() ?? 0,
    durationMs: parseBiliDuration(json['duration']),
    play: (json['play'] as num?)?.toInt() ?? 0,
    pubdate: (json['pubdate'] as num?)?.toInt() ?? 0,
  );

  /// App 端空间接口（`/x/v2/space/archive/cursor`）的字段名不一样：
  /// `cover` 而不是 `pic`、`ctime` 而不是 `pubdate`、时长是秒数。
  /// 好处是它**不需要登录也不需要 wbi 签名**，比网页版空间接口可靠得多。
  ///
  /// [mid] 由调用方传入 —— 这个接口只返回 vmid 对应的视频，不重复回传。
  factory BiliVideo.fromSpaceJson(Map<String, dynamic> json, {int mid = 0}) =>
      BiliVideo(
        bvid: json['bvid']?.toString() ?? '',
        aid: int.tryParse(json['param']?.toString() ?? '') ?? 0,
        title: sanitizeBiliText(json['title']?.toString() ?? ''),
        cover: normalizeBiliImage(json['cover']?.toString() ?? ''),
        author: sanitizeBiliText(json['author']?.toString() ?? ''),
        mid: mid,
        durationMs: parseBiliDuration(json['duration']),
        play: (json['play'] as num?)?.toInt() ?? 0,
        pubdate: (json['ctime'] as num?)?.toInt() ?? 0,
      );

  /// 转成播放器认识的 Track。cid 用 BV 号 —— 它才是换音频地址的凭据，
  /// aid 只在拿详情时当副产物。
  Track toTrack() => Track(
    cid: bvid,
    name: title,
    albumCid: '',
    artists: author.isEmpty ? const [] : [author],
    source: TrackSource.bilibili,
    coverUrl: cover,
    durationMs: durationMs,
  );
}

/// 一个 UP 主。
class BiliUp {
  const BiliUp({
    required this.mid,
    required this.name,
    required this.face,
    this.fans = 0,
    this.sign = '',
    this.videoCount = 0,
  });

  final int mid;
  final String name;

  /// 头像直链，同样要补 https
  final String face;
  final int fans;
  final String sign;
  final int videoCount;

  factory BiliUp.fromJson(Map<String, dynamic> json) => BiliUp(
    mid: (json['mid'] as num?)?.toInt() ?? 0,
    name: sanitizeBiliText(json['uname']?.toString() ?? ''),
    face: normalizeBiliImage(json['upic']?.toString() ?? ''),
    fans: (json['fans'] as num?)?.toInt() ?? 0,
    sign: sanitizeBiliText(json['usign']?.toString() ?? ''),
    videoCount: (json['videos'] as num?)?.toInt() ?? 0,
  );

  /// 收藏用：把展示需要的东西都塞进 subtitle，收藏页不用再请求接口。
  String get subtitle {
    final parts = <String>[
      if (fans > 0) '${formatBiliCount(fans)} 粉丝',
      if (videoCount > 0) '$videoCount 个视频',
    ];
    return parts.isEmpty ? sign : parts.join(' · ');
  }
}

/// 搜索结果里标题带 `<em class="keyword">明日方舟</em>` 这种高亮标签，
/// 直接显示会把尖括号一起露出来。顺手解一下常见的 HTML 实体。
String sanitizeBiliText(String raw) {
  var text = raw.replaceAll(RegExp(r'<[^>]*>'), '');
  const entities = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&nbsp;': ' ',
  };
  entities.forEach((from, to) => text = text.replaceAll(from, to));
  return text.trim();
}

/// `//i0.hdslb.com/xxx.jpg` → `https://i0.hdslb.com/xxx.jpg`
String normalizeBiliImage(String raw) {
  if (raw.isEmpty) return '';
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('http://')) {
    // B站图片走 http 也能下，但安卓 9 起默认禁明文，换 https 更省事
    return 'https://${raw.substring(7)}';
  }
  return raw;
}

/// 时长可能是 `13:36`、`1:02:03`，也可能是秒数。
int parseBiliDuration(dynamic raw) {
  if (raw is num) {
    // 有的接口直接给秒
    return raw.toInt() * 1000;
  }
  if (raw is! String || raw.isEmpty) return 0;

  var total = 0;
  for (final part in raw.split(':')) {
    final value = int.tryParse(part.trim());
    if (value == null) return 0;
    total = total * 60 + value;
  }
  return total * 1000;
}

/// 播放量 / 粉丝数：一万以上折成「12.3 万」，过亿折成「1.2 亿」。
String formatBiliCount(int count) {
  if (count >= 100000000) {
    return '${(count / 100000000).toStringAsFixed(1)} 亿';
  }
  if (count >= 10000) {
    return '${(count / 10000).toStringAsFixed(1)} 万';
  }
  return '$count';
}

/// 一条弹幕。
///
/// 字段来自B站弹幕 protobuf（DmSegMobileReply → DanmakuElem），
/// 用轻量手写解析器解出来的，不引入 protobuf 依赖。
class BiliDanmaku {
  const BiliDanmaku({
    required this.timeMs,
    required this.mode,
    required this.fontSize,
    required this.color,
    required this.text,
    this.id = 0,
    this.advanced,
  });

  /// 弹幕唯一 ID（B站 dmid，protobuf tag 6）。用于去重：同一 ID 出现
  /// 多次才算真重复（分段边界/重试），同秒同文本的「666」刷屏是不同 ID，
  /// 是合法弹幕，不能去重。
  final int id;

  /// 出现在视频的第几毫秒
  final int timeMs;

  /// 弹幕类型：1~3 滚动，4 底部，5 顶部，6 逆向，7 高级，8 代码
  final int mode;

  /// 字号（相对 25 的缩放，多数是 25）
  final int fontSize;

  /// ARGB 颜色（B站给的是 RGB，A 需补 FF）
  final int color;

  final String text;

  /// mode=7 高级弹幕的坐标信息，其余类型为 null。
  final BiliAdvancedDanmaku? advanced;
}

/// 高级弹幕（mode=7）的解析结果。
///
/// B站高级弹幕的 content 是一个 JSON 数组，有两种形态：
///  静止：`["0.05","0.1","1-1","4.07","正文",0,0,"0.05","0.1",0,0,1,"宋体",0]`
///  运动：`[0,0.9,"1-1",8,"正文",0,0,0.05,0.1,500,0,1,"SimHei",1]`
/// 下标：[0][1]=起点 xy，[7][8]=终点 xy，[9]=运动时长(ms，0 表示静止)，
/// [3]=显示秒数，[4]=正文，[12]=字体名。
///
/// 注意字体名**不用于渲染**：Web 上指定「宋体/SimHei」会让 Flutter 去
/// fonts.gstatic.com 拉几十个 Noto 子集，失败后反复重试，一个页面能吃到
/// 1G 内存。这里只保留数据，渲染统一用默认字体。
class BiliAdvancedDanmaku {
  const BiliAdvancedDanmaku({
    required this.x,
    required this.y,
    required this.toX,
    required this.toY,
    required this.moveMs,
    required this.showMs,
    required this.fontName,
    this.alpha1 = 1,
    this.alpha2 = 1,
    this.rotZ = 0,
    this.rotY = 0,
    this.pathXY,
    this.pathLength = 0,
  });

  /// 起点/终点屏幕坐标，0~1（0=最左/最上，1=最右/最下）
  final double x;
  final double y;
  final double toX;
  final double toY;

  /// 透明度渐变 content[2] "a-b"（如 "1-0.77" 渐隐到 77%、
  /// "0.99-0.2" 闪烁字符的快速淡出）。整个生存期线性过渡。
  final double alpha1;
  final double alpha2;

  /// 绕 Z 轴旋转（content[5]，度，屏幕平面内旋转）
  final double rotZ;

  /// 绕 Y 轴旋转（content[6]，度，像门一样绕竖直轴立起来）。
  /// 官方 3D 弹幕的核心：「超小杯」的 [6]=90 就是它 —— 文字立起
  /// 90° 后经透视投影，呈现为从屏幕中心指向锚点的斜条 + 近大远小。
  final double rotY;

  /// 从起点移动到终点的时长（毫秒），0 表示静止弹幕
  final int moveMs;

  /// 在屏幕上停留的总时长（毫秒）。B站 content[3] 给的是秒数，
  /// 没有它弹幕只显示固定的 4 秒就被掐掉 —— 表现就是「显示不全」。
  final int showMs;

  /// 字体名（仅记录，不用于渲染，见类注释）
  final String fontName;

  /// 路径弹幕（content[14] 的 SVG 折线，B站的轨迹特效弹幕）：
  /// 归一化到 0~1 的路径点，平铺成 [x0,y0,x1,y1,...]。
  /// 非路径弹幕为 null。
  final List<double>? pathXY;

  /// 路径总长（归一化坐标下的折线和），用于按进度等速取点
  final double pathLength;

  bool get isMoving => moveMs > 0;

  /// 路径弹幕：文字沿折线轨迹飞行
  bool get hasPath => pathXY != null && pathXY!.length >= 4;
}

/// 一条评论（含楼中楼）。
class BiliReply {
  const BiliReply({
    required this.rpid,
    required this.user,
    required this.message,
    required this.like,
    required this.timeText,
    this.face = '',
    this.rcount = 0,
    this.replies = const [],
  });

  final String rpid;
  final String user;
  final String message;
  final int like;
  final String timeText;

  /// 用户头像地址（已归一化为 https），空串表示没有
  final String face;

  /// 楼中楼回复总数（B站字段 rcount）。接口默认只带 3 条，
  /// 展开时再按 root 拉全。
  final int rcount;

  /// 楼中楼（接口默认返回的前 3 条）
  final List<BiliReply> replies;
}

/// 拉评论返回的结果：列表 + 分页游标。
class BiliReplyPage {
  const BiliReplyPage({required this.replies, required this.nextPage});

  final List<BiliReply> replies;

  /// 下一页页码，null 表示没有更多了
  final int? nextPage;
}

/// dash 下载资源集合：视频轨 + 音轨，各带候选地址。
///
/// 下载时视频轨和音轨分开取，再用 ffmpeg 合并。候选地址是同一个资源的
/// 镜像（主站 CDN / PCDN），谁通就用谁，和播放侧同一套重试思路。
class BiliDashStreams {
  const BiliDashStreams({
    required this.bvid,
    required this.cid,
    required this.quality,
    required this.videoUrls,
    required this.audioUrls,
  });

  final String bvid;
  final String cid;

  /// 实际拿到的画质 id（120=4K, 112=1080P 等），下载完写进文件名提示用
  final int quality;

  final List<String> videoUrls;
  final List<String> audioUrls;
}
