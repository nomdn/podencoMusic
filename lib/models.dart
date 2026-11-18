/// 塞壬唱片（monster-siren.hypergryph.com）的数据模型。
///
/// 四个类对应四个接口，字段名尽量跟接口返回保持一致，
/// 这样对着抓包结果看代码时不用来回翻译。
///
/// 接口一览：
///   `/api/albums`             → 专辑列表
///   `/api/album/{cid}/detail` → 专辑详情 + 曲目
///   `/api/songs`              → 全站单曲
///   `/api/song/{cid}`         → 单曲详情（含音频直链）
library;

/// 接口里有一半地方写 artistes、一半写 artists，统一成一个函数兜住。
List<String> _names(dynamic raw) {
  if (raw is! List) return const [];
  return raw.map((e) => e.toString()).toList();
}

/// 专辑。列表页和详情页共用。
class Album {
  const Album({
    required this.cid,
    required this.name,
    required this.coverUrl,
    required this.artistes,
  });

  /// 塞壬内部 id，字符串，可能带前导零（如 "0256"），千万别当数字用
  final String cid;
  final String name;
  final String coverUrl;
  final List<String> artistes;

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    cid: json['cid'].toString(),
    name: json['name'] as String? ?? '',
    coverUrl: json['coverUrl'] as String? ?? '',
    artistes: _names(json['artistes'] ?? json['artists']),
  );
}

/// 专辑详情：多一段简介，和多一个封面（coverDeUrl 是详情页用的加长版）。
class AlbumDetail {
  const AlbumDetail({
    required this.cid,
    required this.name,
    required this.intro,
    required this.coverUrl,
    required this.songs,
  });

  final String cid;
  final String name;
  final String intro;
  final String coverUrl;
  final List<Track> songs;

  factory AlbumDetail.fromJson(Map<String, dynamic> json) {
    final cid = json['cid'].toString();
    return AlbumDetail(
      cid: cid,
      name: json['name'] as String? ?? '',
      intro: json['intro'] as String? ?? '',
      coverUrl: json['coverUrl'] as String? ?? '',
      // 曲目里没有 albumCid，这里统一补成当前专辑，后面全靠它查封面
      songs: (json['songs'] as List? ?? const [])
          .map(
            (e) => Track.fromJson(e as Map<String, dynamic>, albumCid: cid),
          )
          .toList(),
    );
  }

  /// 专辑详情页本地缓存用。曲目带上 albumCid（见 toJson 里 Track 的序列化），
  /// 读回来正好匹配上面 fromJson 的补齐逻辑。
  Map<String, dynamic> toJson() => {
    'cid': cid,
    'name': name,
    'intro': intro,
    'coverUrl': coverUrl,
    'songs': songs.map((track) => track.toJson()).toList(),
  };
}

/// 曲目的来源。两个源共用一套队列/歌单/播放器，靠这个字段决定
/// 播放时去哪里换音频地址、封面从哪来。
enum TrackSource {
  /// 塞壬唱片：cid 是塞壬的数字 id，封面靠 albumCid 反查
  siren,

  /// 哔哩哔哩：cid 就是 BV 号，封面直接存在 [Track.coverUrl] 里
  bilibili,
}

/// 列表里的一首歌。只有坐标信息，没有播放地址。
///
/// 播放地址得再调一次接口换（塞壬走 /api/song/{cid}，B站走 playurl），
/// 这也意味着**不能预加载音频**，点播放之后才开始拉流，会有一下等待。
/// 这是接口本身的限制。
class Track {
  const Track({
    required this.cid,
    required this.name,
    required this.albumCid,
    required this.artists,
    this.source = TrackSource.siren,
    this.coverUrl = '',
    this.durationMs = 0,
  });

  final String cid;
  final String name;

  /// 属于哪张专辑，用来反查封面和专辑名。
  /// B站曲目留空 —— 那边的「专辑」概念是 UP 主，用 artists 表达就够了，
  /// 填 mid 反而会被塞壬的专辑表查不到而显示成空白。
  final String albumCid;
  final List<String> artists;

  /// 来源。[TrackSource.bilibili] 时 [cid] 是 BV 号。
  final TrackSource source;

  /// 封面直链。塞壬的曲目不存（按 albumCid 现查），B站的必须存 ——
  /// 视频封面只属于这一条，没法反查。
  final String coverUrl;

  /// 音频时长（毫秒）。B站搜索结果里直接给，用来在播放前就显示进度条总长；
  /// 塞壬留 0，由播放器加载后自己测。
  final int durationMs;

  bool get isBili => source == TrackSource.bilibili;

  /// [albumCid] 是外部补进来的：专辑详情接口返回的 song 里**没有** albumCid
  /// （只有 cid / name / artistes），而全站单曲接口有。
  /// 从专辑详情造 Track 时必须把所属专辑的 cid 传进来，
  /// 否则这歌进队列后就查不到封面和专辑名，播放页标题会退化成「正在播放」。
  factory Track.fromJson(Map<String, dynamic> json, {String? albumCid}) => Track(
    cid: json['cid'].toString(),
    name: json['name'] as String? ?? '',
    albumCid: albumCid ?? json['albumCid']?.toString() ?? '',
    artists: _names(json['artists'] ?? json['artistes']),
    source: json['source'] == 'bilibili'
        ? TrackSource.bilibili
        : TrackSource.siren,
    coverUrl: json['coverUrl'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
  );

  /// 持久化用。字段名跟接口返回保持一致，读回来能直接走 fromJson。
  /// 塞壬曲目不写后三个字段 —— 存档里 99% 是塞壬的歌，省下的字节
  /// 乘以几百首就是几 KB。
  Map<String, dynamic> toJson() => {
    'cid': cid,
    'name': name,
    'albumCid': albumCid,
    'artists': artists,
    if (source != TrackSource.siren) 'source': 'bilibili',
    if (coverUrl.isNotEmpty) 'coverUrl': coverUrl,
    if (durationMs > 0) 'durationMs': durationMs,
  };

  /// 只用来补字段：老存档里的歌可能缺 albumCid（见 fromJson 的说明），
  /// B站的歌可能缺时长（搜索结果没给时靠播放器补）。
  Track copyWith({String? albumCid, String? name, int? durationMs}) => Track(
    cid: cid,
    name: name ?? this.name,
    albumCid: albumCid ?? this.albumCid,
    artists: artists,
    source: source,
    coverUrl: coverUrl,
    durationMs: durationMs ?? this.durationMs,
  );

  /// 详情接口返回的 song 结构比列表多了音频地址，转成 Track 后进队列
  factory Track.fromSongDetail(SongDetail d) => Track(
    cid: d.cid,
    name: d.name,
    albumCid: d.albumCid,
    artists: d.artists,
  );
}

/// 播放模式。定义在 models 而不是 player_model，是为了让 storage
/// 不用反过来 import 播放器 —— 那会形成循环依赖。
enum PlayMode {
  /// 顺序播放，到末尾回第一首
  listLoop,

  /// 单曲循环：播完从头再来
  singleLoop,

  /// 随机：每次挑一个和当前不同的
  shuffle,
}

/// 单曲详情：真正能播的东西在这里。
class SongDetail {
  const SongDetail({
    required this.cid,
    required this.name,
    required this.albumCid,
    required this.sourceUrl,
    required this.lyricUrl,
    required this.artists,
  });

  final String cid;
  final String name;
  final String albumCid;

  /// 音频直链。注意格式不统一：老歌是 .mp3，新歌大量是 .wav（几十 MB）。
  final String sourceUrl;

  /// lrc 歌词直链，很多纯音乐 / 老歌是 null
  final String? lyricUrl;
  final List<String> artists;

  factory SongDetail.fromJson(Map<String, dynamic> json) => SongDetail(
    cid: json['cid'].toString(),
    name: json['name'] as String? ?? '',
    albumCid: json['albumCid']?.toString() ?? '',
    sourceUrl: json['sourceUrl'] as String? ?? '',
    lyricUrl: json['lyricUrl'] as String?,
    artists: _names(json['artists'] ?? json['artistes']),
  );
}

/// 一行歌词。LRC 里的 `[mm:ss.xx]` 已经换算成 Duration。
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

/// 用户自建的歌单。唯一不是从接口来的模型，只存在本地。
///
/// 曲目直接复用 [Track] 的序列化。和播放队列同理，**只存 Track 不存
/// SongDetail** —— 音频直链带签名会过期，播的时候反正要走一遍
/// /api/song/{cid} 重新换源。
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.tracks,
  });

  /// 本地 id，创建时拿当前时间戳生成，不引 uuid 依赖。
  final String id;
  final String name;
  final int createdAt;
  final List<Track> tracks;

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id']?.toString() ?? '',
    name: json['name'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    tracks: (json['tracks'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Track.fromJson)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
    'tracks': tracks.map((track) => track.toJson()).toList(),
  };

  /// 歌单增删曲目 / 改名后造一个新对象换掉旧的，
  /// 监听方比较引用就能看出变没变。
  Playlist copyWith({String? name, List<Track>? tracks}) => Playlist(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    tracks: tracks ?? this.tracks,
  );
}
