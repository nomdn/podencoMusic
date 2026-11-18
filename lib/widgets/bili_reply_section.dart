import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../bili_api.dart';
import '../bili_models.dart';
import '../bili_store.dart';

/// 视频评论区的浏览 + 发送。
///
/// 作为独立组件挂在视频下方：视频页只管播放器，评论区自己拉数据、
/// 自己分页、自己处理发送后的刷新，避免把 300 行的视频页再撑大。
class BiliReplySection extends StatefulWidget {
  const BiliReplySection({super.key, required this.bvid});

  final String bvid;

  @override
  State<BiliReplySection> createState() => _BiliReplySectionState();
}

class _BiliReplySectionState extends State<BiliReplySection> {
  final _input = TextEditingController();
  final List<BiliReply> _replies = [];
  int? _nextPage;
  bool _loading = false;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(1));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await BiliApi.fetchReplies(widget.bvid, page: page);
      if (!mounted) return;
      setState(() {
        if (page == 1) {
          _replies
            ..clear()
            ..addAll(result.replies);
        } else {
          _replies.addAll(result.replies);
        }
        _nextPage = result.nextPage;
        _loading = false;
      });
    } on BiliException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '评论加载失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!biliModel.loggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要登录后才能发评论')),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await BiliApi.postReply(widget.bvid, text);
      if (!mounted) return;
      _input.clear();
      // 重新拉第一页，让刚发的评论立刻出现
      setState(() => _replies.clear());
      await _load(1);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('评论发送成功')),
      );
    } on BiliException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('评论发送失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(Icons.comment_outlined, size: 18,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('评论', style: theme.textTheme.titleMedium),
                const SizedBox(width: 6),
                Text(
                  '${_replies.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          // 发送框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    maxLines: 2,
                    minLines: 1,
                    maxLength: 2000,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: biliModel.loggedIn
                          ? '发一条友善的评论…'
                          : '登录后可发评论',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('发送'),
                ),
              ],
            ),
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ),

          // 评论列表
          if (_loading && _replies.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_replies.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  '还没有评论',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            ..._replies.map(
              (r) => _ReplyTile(reply: r, bvid: widget.bvid, onSent: () => _load(1)),
            ),

          if (_loading && _replies.isNotEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_nextPage != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: () => _load(_nextPage!),
                  child: const Text('加载更多'),
                ),
              ),
            ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 头像：优先网络图片，加载失败/空地址回退到首字母。
/// cacheWidth 限制解码尺寸——评论头像原始图可能有 200px，列表里只需要 64px。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.face, required this.name, this.radius = 16});

  final String face;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final letter = name.isEmpty ? '?' : name.substring(0, 1);
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        letter,
        style: TextStyle(
          color: theme.colorScheme.onPrimaryContainer,
          fontSize: 13,
        ),
      ),
    );
    if (face.isEmpty) return fallback;
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: ClipOval(
        child: Image.network(
          face,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          // 评论头像列表里只显示 32px，别把原图整张解码进内存
          cacheWidth: 96,
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return SizedBox(
              width: radius * 2,
              height: radius * 2,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress.expectedTotalBytes == null
                      ? null
                      : progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReplyTile extends StatefulWidget {
  const _ReplyTile({
    required this.reply,
    required this.bvid,
    required this.onSent,
  });

  final BiliReply reply;
  final String bvid;
  final VoidCallback onSent;

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
  bool _expanded = false;
  bool _loadingSubs = false;
  List<BiliReply>? _allSubs;
  String? _subError;
  int _subPage = 1;
  bool _subHasMore = true;

  Future<void> _toggleExpand() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    // 前 3 条主接口已经带了，只有回复数更多时才需要补拉
    if (widget.reply.rcount <= widget.reply.replies.length || _allSubs != null) {
      return;
    }
    await _loadSubs(1, append: false);
  }

  Future<void> _loadSubs(int page, {required bool append}) async {
    if (_loadingSubs) return;
    setState(() {
      _loadingSubs = true;
      _subError = null;
    });
    try {
      final items = await BiliApi.fetchSubReplies(
        widget.bvid,
        widget.reply.rpid,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        // 接口返回的往往包含主接口已带的前 3 条，按 rpid 去重后再合并
        final merged = <String, BiliReply>{};
        if (!append) {
          for (final s in widget.reply.replies) {
            merged[s.rpid] = s;
          }
        } else {
          for (final s in _allSubs ?? const <BiliReply>[]) {
            merged[s.rpid] = s;
          }
        }
        for (final s in items) {
          merged[s.rpid] = s;
        }
        _allSubs = merged.values.toList();
        _subPage = page;
        _subHasMore = items.length >= 10;
        _loadingSubs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _subError = '回复加载失败：$e';
        _loadingSubs = false;
        if (!append) _allSubs = List.of(widget.reply.replies);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reply = widget.reply;
    // 展开后用拉全的列表，没展开用主接口自带的前几条
    final subs = _expanded ? (_allSubs ?? reply.replies) : reply.replies;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(face: reply.face, name: reply.user),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      reply.user,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      reply.timeText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(reply.message, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.thumb_up_outlined,
                        size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      '${reply.like}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                // 楼中楼：只在有回复时才显示展开入口
                if (reply.rcount > 0 || subs.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  InkWell(
                    onTap: _toggleExpand,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 15,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _expanded
                                ? '收起回复'
                                : '展开 ${reply.rcount} 条回复',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_expanded) ...[
                  if (_subError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        _subError!,
                        style: TextStyle(
                            color: theme.colorScheme.error, fontSize: 12),
                      ),
                    ),
                  for (final sub in subs) _SubReply(sub: sub),
                  if (_loadingSubs)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_subHasMore && (subs.length < reply.rcount))
                    TextButton(
                      onPressed: () => _loadSubs(_subPage + 1, append: true),
                      child: const Text('加载更多回复'),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubReply extends StatelessWidget {
  const _SubReply({required this.sub});

  final BiliReply sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(face: sub.face, name: sub.user, radius: 11),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub.user,
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(sub.message, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
