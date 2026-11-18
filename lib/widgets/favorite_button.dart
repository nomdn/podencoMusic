import 'package:material_ui/material_ui.dart';

import '../favorites_model.dart';

/// 收藏按钮（心形）。
///
/// 状态直接读 [favoritesModel]，所以同一个条目在播放页、搜索结果、
/// UP 主页上的按钮会一起变 —— 点完不用手动刷新别的页面。
class FavoriteButton extends StatelessWidget {
  const FavoriteButton({
    super.key,
    required this.item,
    this.showToast = true,
    this.iconSize,
  });

  final FavoriteItem item;

  /// 点一下弹一条轻提示。列表里密密麻麻的按钮可以关掉，免得太吵。
  final bool showToast;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: favoritesModel,
      builder: (context, _) {
        final active = favoritesModel.contains(item.kind, item.id);
        return IconButton(
          tooltip: active ? '取消收录' : '收录',
          iconSize: iconSize,
          icon: Icon(
            active ? Icons.favorite : Icons.favorite_border,
            color: active ? Theme.of(context).colorScheme.error : null,
          ),
          onPressed: () {
            final now = favoritesModel.toggle(item);
            if (!showToast) return;
            final messenger = ScaffoldMessenger.of(context);
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  now ? '已收录「${item.name}」' : '已移出档案室',
                ),
                duration: const Duration(milliseconds: 1400),
              ),
            );
          },
        );
      },
    );
  }
}
